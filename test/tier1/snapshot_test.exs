defmodule Merlin.SnapshotTest do
  @moduledoc """
  Tier 1: the snapshot codec and its time arithmetic.

  The interesting content here is not the round trip -- it is that a restored
  fact arrives with the right *age*. Restoring a two-day-old position as though
  it had just been observed would make the daemon confidently wrong about where
  someone is, which is worse than having no snapshot at all.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.{Fact, Snapshot}

  defp fact(path, value, opts \\ []) do
    now = Keyword.get(opts, :now, 1_000_000)

    %Fact{
      path: path,
      value: value,
      changed_at: now - Keyword.get(opts, :changed_ago, 0),
      observed_at: now - Keyword.get(opts, :observed_ago, 0),
      source: :test,
      seq: 1,
      stale_after: Keyword.get(opts, :stale_after)
    }
  end

  defp round_trip(facts, opts \\ []) do
    snap_wall = Keyword.get(opts, :snap_wall, 1_700_000_000_000)
    now_wall = Keyword.get(opts, :now_wall, snap_wall)
    now_mono = Keyword.get(opts, :now_mono, 5_000_000)
    encode_mono = Keyword.get(opts, :encode_mono, 1_000_000)

    {binary, _skipped} = Snapshot.encode(facts, snap_wall, encode_mono)
    assert {:ok, ^snap_wall, entries} = Snapshot.decode(binary)
    Snapshot.restore(entries, snap_wall, now_wall, now_mono)
  end

  describe "round trip" do
    test "a scalar fact survives" do
      {[restored], []} = round_trip([fact([:rule, :intruder_latch, :state], :fired)])

      assert restored.path == [:rule, :intruder_latch, :state]
      assert restored.value == :fired
    end

    for {value, label} <- [
          {:fired, "an atom"},
          {true, "true"},
          {false, "false"},
          {nil, "nil"},
          {42, "an integer"},
          {35.9606, "a float"},
          {"garage", "a binary"}
        ] do
      test "#{label} round-trips exactly" do
        value = unquote(Macro.escape(value))
        {[restored], []} = round_trip([fact([:a, :b], value)])
        assert restored.value === value
      end
    end

    # THE ONE THAT MATTERS. A path is a list of atoms *and* binaries, because
    # captured MQTT segments stay binaries by design. Encoding a path as
    # "door.garage.contact" would intern every segment on the way back and
    # silently change which fact this is -- and the doors are precisely what
    # the intruder latch watches.
    test "a binary path segment stays a binary" do
      # :garage exists as an atom in this VM, so a careless implementation
      # would happily intern it and the test would still find a fact.
      _ = :garage

      {[restored], []} = round_trip([fact([:door, "garage", :contact], :open)])

      assert restored.path == [:door, "garage", :contact]
      assert [_, segment, _] = restored.path
      assert is_binary(segment), "the captured segment was interned into an atom"
    end

    test "atom and binary segments that read the same are distinguishable" do
      facts = [fact([:door, :garage], 1), fact([:door, "garage"], 2)]
      {restored, []} = round_trip(facts)

      assert length(restored) == 2
      assert Enum.find(restored, &(&1.path == [:door, :garage])).value == 1
      assert Enum.find(restored, &(&1.path == [:door, "garage"])).value == 2
    end

    test "stale_after survives" do
      {[restored], []} = round_trip([fact([:person, :owner, :lat], 35.9, stale_after: 30_000)])
      assert restored.stale_after == 30_000
    end

    test "the source records that it came from a snapshot" do
      {[restored], []} = round_trip([fact([:a], 1)], snap_wall: 1_700_000_000_000)
      assert {:snapshot, 1_700_000_000_000} = restored.source
    end

    test "an empty snapshot is legal" do
      assert {[], []} = round_trip([])
    end
  end

  describe "ages, which is the whole point" do
    test "a fact keeps its age when no time passes" do
      {[restored], []} =
        round_trip([fact([:a], 1, now: 1_000_000, observed_ago: 4_000)],
          encode_mono: 1_000_000,
          now_mono: 5_000_000,
          snap_wall: 1_700_000_000_000,
          now_wall: 1_700_000_000_000
        )

      assert Fact.age(restored, 5_000_000) == 4_000
    end

    test "downtime is added to the age" do
      # Observed 4s before the snapshot; the daemon was then down for 60s.
      {[restored], []} =
        round_trip([fact([:a], 1, now: 1_000_000, observed_ago: 4_000)],
          encode_mono: 1_000_000,
          now_mono: 5_000_000,
          snap_wall: 1_700_000_000_000,
          now_wall: 1_700_000_060_000
        )

      assert Fact.age(restored, 5_000_000) == 64_000
    end

    test "changed_at and observed_at age independently" do
      # A sensor reporting the same value: changed long ago, observed recently.
      {[restored], []} =
        round_trip([fact([:a], 1, now: 1_000_000, changed_ago: 900_000, observed_ago: 1_000)],
          encode_mono: 1_000_000,
          now_mono: 5_000_000,
          snap_wall: 1_700_000_000_000,
          now_wall: 1_700_000_010_000
        )

      assert 5_000_000 - restored.observed_at == 11_000
      assert 5_000_000 - restored.changed_at == 910_000
    end

    # Bug 6's class, in a new place. A stale position restored as fresh is a
    # daemon that will act on where someone was two days ago.
    test "a fact from a two-day-old snapshot restores STALE, not fresh" do
      two_days = 2 * 24 * 60 * 60 * 1_000

      {[restored], []} =
        round_trip([fact([:person, :owner, :lat], 35.9, now: 1_000_000, stale_after: 30_000)],
          encode_mono: 1_000_000,
          now_mono: 5_000_000,
          snap_wall: 1_700_000_000_000,
          now_wall: 1_700_000_000_000 + two_days
        )

      assert Fact.stale?(restored, 5_000_000),
             "a two-day-old position restored fresh -- the daemon would act on it"
    end

    test "a latch has no stale_after and so is never stale, however old" do
      year = 365 * 24 * 60 * 60 * 1_000

      {[restored], []} =
        round_trip([fact([:rule, :intruder_latch, :state], :fired, now: 1_000_000)],
          encode_mono: 1_000_000,
          now_mono: 5_000_000,
          snap_wall: 1_700_000_000_000,
          now_wall: 1_700_000_000_000 + year
        )

      refute Fact.stale?(restored, 5_000_000)
      assert restored.value == :fired
    end
  end

  describe "elapsed_since/2 and a clock that has moved" do
    test "ordinary forward time" do
      assert Snapshot.elapsed_since(1_000, 61_000) == 60_000
    end

    test "no time at all" do
      assert Snapshot.elapsed_since(1_000, 1_000) == 0
    end

    test "small backwards jitter is treated as no time" do
      assert Snapshot.elapsed_since(10_000, 10_000 - Snapshot.clock_tolerance_ms() + 1) == 0
    end

    # An untrustworthy clock must not produce confident fresh data. Stale is
    # the conservative direction: it reads :unknown and waits to be told.
    test "a large backwards jump makes facts very old, not fresh" do
      elapsed = Snapshot.elapsed_since(10_000_000, 1_000)

      assert elapsed == Snapshot.untrusted_elapsed_ms()
      assert elapsed > 0, "a wrong clock restored facts as fresh"
    end

    test "the untrusted elapsed time outlives any plausible stale_after" do
      # An hour is already a generous stale_after; the untrusted value has to
      # dwarf it or the policy does not actually make anything stale.
      assert Snapshot.untrusted_elapsed_ms() > 60 * 60 * 1_000
    end
  end

  describe "what will not be persisted" do
    for {value, label} <- [
          {%{a: 1}, "a map"},
          {[1, 2], "a list"},
          {{1, 2}, "a tuple"}
        ] do
      test "#{label} is refused rather than written" do
        value = unquote(Macro.escape(value))
        {binary, skipped} = Snapshot.encode([fact([:a], value)], 1_000, 1_000)

        assert {:ok, _wall, []} = Snapshot.decode(binary)
        assert [{[:a], _type}] = skipped
      end
    end

    test "a refused value does not take the rest of the snapshot with it" do
      facts = [fact([:a], %{no: :good}), fact([:b], :fine)]
      {restored, []} = round_trip(facts)

      assert [%{path: [:b], value: :fine}] = restored
    end

    # Reported to the caller rather than logged from inside a pure function
    # that runs every five seconds for the life of the daemon. The server logs
    # each path once; a warning that repeats forever is wallpaper, and it
    # takes the warnings that matter down with it.
    test "what was skipped is returned, with its type, not logged" do
      facts = [fact([:person, :owner, :position], {35.9, -83.9}), fact([:b], :fine)]
      {_binary, skipped} = Snapshot.encode(facts, 1_000, 1_000)

      assert [{[:person, :owner, :position], "tuple"}] = skipped
    end

    test "nothing skipped means an empty list, not nil" do
      {_binary, skipped} = Snapshot.encode([fact([:a], 1)], 1_000, 1_000)
      assert skipped == []
    end
  end

  describe "a snapshot that no longer matches the config" do
    test "an entry whose path names a vanished atom is dropped alone" do
      # Simulating a rule deleted from the config: the atom no longer exists in
      # the new build. Constructed at the entry level because this VM cannot
      # forget an atom it has.
      entries = [
        %{
          path: [{:a, "rule"}, {:a, "a_rule_that_was_deleted_from_the_config"}],
          value: {:atom, "fired"},
          changed_ago: 0,
          observed_ago: 0,
          stale_after: nil
        },
        %{
          path: [{:a, "person"}],
          value: {:number, 1},
          changed_ago: 0,
          observed_ago: 0,
          stale_after: nil
        }
      ]

      {facts, dropped} = Snapshot.restore(entries, 1_000, 1_000, 500_000)

      assert [%{path: [:person]}] = facts
      assert [{path, {:unknown_segment, _}}] = dropped
      assert path =~ "a_rule_that_was_deleted_from_the_config"
    end

    # The failure this guards against: editing the config, restarting, and
    # silently losing every latch in the house because one entry no longer
    # decodes. Per-entry decoding is why the file stores segments rather than
    # one opaque term.
    test "one undecodable entry does not discard the others" do
      entries =
        for i <- 1..5 do
          %{
            path: [{:a, "rule"}, {:b, "latch_#{i}"}],
            value: {:atom, "fired"},
            changed_ago: 0,
            observed_ago: 0,
            stale_after: nil
          }
        end ++
          [
            %{
              path: [{:a, "definitely_not_an_existing_atom_xyzzy"}],
              value: :null,
              changed_ago: 0,
              observed_ago: 0,
              stale_after: nil
            }
          ]

      {facts, dropped} = Snapshot.restore(entries, 1_000, 1_000, 500_000)

      assert length(facts) == 5
      assert length(dropped) == 1
    end
  end

  describe "decoding something that is not a snapshot" do
    test "random bytes are an error, not a crash" do
      assert {:error, _} = Snapshot.decode(<<0, 1, 2, 3, 4, 5>>)
    end

    test "a truncated file is an error, not a crash" do
      {binary, _} = Snapshot.encode([fact([:a], 1)], 1_000, 1_000)
      half = binary_part(binary, 0, div(byte_size(binary), 2))
      assert {:error, _} = Snapshot.decode(half)
    end

    test "a valid term that is not a snapshot is refused" do
      assert {:error, :not_a_snapshot} = Snapshot.decode(:erlang.term_to_binary(%{a: 1}))
    end

    test "a future format version is refused rather than misread" do
      binary = :erlang.term_to_binary({:merlin_snapshot, Snapshot.format() + 1, 0, []})
      assert {:error, {:unsupported_format, _}} = Snapshot.decode(binary)
    end
  end
end
