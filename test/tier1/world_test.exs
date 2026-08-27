defmodule Merlin.WorldTest do
  @moduledoc """
  Tier 1: the level/event split, and the two jobs the Python dedup conflated.

  Every claim made in `Merlin.World.Writer`'s moduledoc is asserted here. The
  most important is that an unchanged write still *happens* -- because that is
  the difference between "this sensor is reporting the same value" and "this
  sensor stopped reporting three days ago", which the Python model could not
  express at all.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.{Bus, Fact, World}

  # Unique per test, so the shared ETS table does not force async: false.
  defp path(suffix), do: [:test, "#{System.unique_integer([:positive])}", suffix]

  describe "levels: put/3" do
    test "a first write is a change, and is marked as first" do
      p = path(:power)
      Bus.subscribe(p)

      assert {:changed, nil, :on} = World.put(p, :on)
      assert_receive {:merlin, %Merlin.Change{old: nil, new: :on, first?: true}}
      assert World.get(p) == :on
    end

    test "a different value is a change and notifies" do
      p = path(:power)
      World.put(p, :on)
      Bus.subscribe(p)

      assert {:changed, :on, :off} = World.put(p, :off)
      assert_receive {:merlin, %Merlin.Change{old: :on, new: :off, first?: false}}
    end

    test "an identical value does NOT notify" do
      p = path(:power)
      World.put(p, :on)
      Bus.subscribe(p)

      assert :unchanged = World.put(p, :on)
      refute_receive {:merlin, %Merlin.Change{}}, 50
    end

    test "an identical value still records the observation" do
      # The whole reason the write is decoupled from the notification. If this
      # regressed, staleness detection would silently stop working while every
      # other test kept passing.
      p = path(:power)
      World.put(p, :on)
      {:ok, before} = World.fetch(p)

      assert :unchanged = World.put(p, :on)
      {:ok, after_} = World.fetch(p)

      assert after_.seq > before.seq, "the write did not happen"
      assert after_.observed_at >= before.observed_at
      assert after_.changed_at == before.changed_at, "changed_at moved on an unchanged write"
    end

    test "notify: :always forces a notification for an unchanged value" do
      p = path(:power)
      World.put(p, :on)
      Bus.subscribe(p)

      assert :unchanged = World.put(p, :on, notify: :always)
      assert_receive {:merlin, %Merlin.Change{old: :on, new: :on}}
    end

    test "nil is a value, distinguishable from absence" do
      p = path(:maybe)
      refute World.known?(p)
      assert World.get(p, :default) == :default

      assert {:changed, nil, nil} = World.put(p, nil)
      assert World.known?(p)
      assert World.get(p, :default) == nil
    end

    test "source is carried onto the fact and the change" do
      p = path(:power)
      Bus.subscribe(p)

      World.put(p, :on, source: {:adapter, :some_adapter})

      assert_receive {:merlin, %Merlin.Change{source: {:adapter, :some_adapter}}}
      assert {:ok, %Fact{source: {:adapter, :some_adapter}}} = World.fetch(p)
    end
  end

  describe "the causal depth guard" do
    test "a write beyond max depth is dropped and reported" do
      p = path(:loop)
      assert {:dropped, :max_depth} = World.put(p, :x, depth: Merlin.World.Writer.max_depth() + 1)
      refute World.known?(p)
    end

    test "a write at max depth still lands" do
      p = path(:loop)
      assert {:changed, _, :x} = World.put(p, :x, depth: Merlin.World.Writer.max_depth())
    end

    test "depth is carried on the change so a reacting writer can propagate it" do
      p = path(:chain)
      Bus.subscribe(p)

      World.put(p, :a, depth: 3)
      assert_receive {:merlin, %Merlin.Change{depth: 3} = change}

      # This is the contract a reacting process follows. Without it every
      # write would look like the head of a fresh chain and the guard would
      # never trip -- the mechanism would be present but inert.
      assert Merlin.Change.caused_by(change) == [cause: change.seq, depth: 4]
    end

    test "a chain reacting correctly terminates at the guard" do
      # Simulate what a rule does: react to a change by writing, propagating
      # depth each time. The guard must stop it rather than running forever.
      p = path(:cycle)
      Bus.subscribe(p)

      World.put(p, 0)
      result = drive_chain(p, 0)

      assert result == {:dropped, :max_depth}
    end
  end

  # Writes in a loop, propagating depth as a well-behaved reactor would, until
  # the writer refuses.
  defp drive_chain(path, n) when n < 50 do
    receive do
      {:merlin, %Merlin.Change{} = change} ->
        case World.put(path, n + 1, Merlin.Change.caused_by(change)) do
          {:dropped, :max_depth} = dropped -> dropped
          _ -> drive_chain(path, n + 1)
        end
    after
      100 -> {:no_change_after, n}
    end
  end

  defp drive_chain(_path, n), do: {:did_not_terminate, n}

  describe "events: emit/3" do
    test "every emit is delivered, including repeats of the same payload" do
      p = path(:pressed)
      Bus.subscribe_events(p)

      World.emit(p, :single)
      World.emit(p, :single)
      World.emit(p, :single)

      assert_receive {:merlin, %Merlin.Event{payload: :single}}
      assert_receive {:merlin, %Merlin.Event{payload: :single}}
      assert_receive {:merlin, %Merlin.Event{payload: :single}}
    end

    test "events are never stored" do
      # This is what retires the time.time() hack: a button press does not
      # need a forever-changing value to defeat deduplication, because it is
      # not a value at all.
      p = path(:pressed)
      World.emit(p, :double)

      refute World.known?(p)
      assert World.get(p) == nil
    end

    test "a fact subscriber does not receive events, and vice versa" do
      p = path(:mixed)
      Bus.subscribe(p)

      World.emit(p, :an_event)
      refute_receive {:merlin, %Merlin.Event{}}, 50
    end
  end

  describe "reads" do
    test "age is :never for an unknown fact" do
      assert World.age(path(:nothing)) == :never
    end

    test "a fact with no stale_after is never stale" do
      p = path(:fresh)
      World.put(p, 1)
      refute World.stale?(p)
    end

    test "an absent fact is not stale — it is absent" do
      # Distinguishing "the tracker stopped reporting" from "there is no
      # tracker" matters: only the first should alarm.
      refute World.stale?(path(:nothing))
    end

    test "staleness is decided against a supplied clock, not a slept-through one" do
      # Fact.stale?/2 takes `now` explicitly precisely so this is deterministic.
      # Sleeping past a threshold would make the test slow AND flaky, and the
      # thing under test is the comparison, not the passage of time.
      p = path(:old)
      World.put(p, 1, stale_after: 1_000)
      {:ok, fact} = World.fetch(p)

      refute Fact.stale?(fact, fact.observed_at)
      refute Fact.stale?(fact, fact.observed_at + 1_000)
      assert Fact.stale?(fact, fact.observed_at + 1_001)
    end

    test "age is measured from observation, not from change" do
      p = path(:repeating)
      World.put(p, :same)
      World.put(p, :same)
      {:ok, fact} = World.fetch(p)

      # A sensor still reporting the same value has a small age and an older
      # changed_at. Collapsing these is what made the Python unable to tell a
      # steady reading from a dead sensor.
      assert fact.observed_at >= fact.changed_at
      assert Fact.age(fact, fact.observed_at + 5_000) == 5_000
    end

    test "dump/1 returns only facts beneath the prefix, and no internals" do
      id = "#{System.unique_integer([:positive])}"
      World.put([:test, id, :a], 1)
      World.put([:test, id, :b], 2)

      dumped = World.dump([:test, id])
      assert length(dumped) == 2
      assert Enum.all?(dumped, &match?(%Fact{}, &1))
      assert Enum.map(dumped, & &1.value) |> Enum.sort() == [1, 2]
    end
  end
end
