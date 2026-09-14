defmodule Merlin.DeriveHorizonTest do
  @moduledoc """
  Tier 1: a derived fact notices its input going stale, with nothing else
  changing at all.

  Staleness was passive. `Merlin.Derive.Expr.read/1` correctly returned
  `:unknown` for a fact past its `stale_after` -- but the process only
  re-read its inputs when one of them CHANGED, and a sensor going quiet is
  the one event that produces no change. So a derived fact over a dead sensor
  sat at its last value indefinitely, and a rule built to fail safe on exactly
  that could never fire.

  A downstream configuration's own battery found it. A scenario in which a
  sensor goes quiet and the load it governs must stop could not pass on a
  platform where the horizon was correctly stamped on the fact, because
  stamping it was only half the job: the other half is being woken up when it
  is crossed. `stale_after_ms` on MQTT sources shipped without that half, and
  looked complete.

  Every test here writes an input ONCE and then touches nothing. If the
  output moves, it moved because the derive woke itself up.
  """

  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.{Derive, World, Zones}

  setup do
    Merlin.Config.put(%{
      zones: Zones.compile([]),
      rules: [],
      groups: %{},
      sources: [],
      derived: []
    })

    id = :"horizon_#{System.unique_integer([:positive])}"
    %{id: id, input: [id, :temp], out: [id, :warm?]}
  end

  defp start(id, out, opts \\ []) do
    spec =
      %{id: id, kind: :expr, out: out, compute: "#{id}.temp > 20.0"}
      |> Map.merge(Map.new(opts))

    {:ok, pid} = Derive.Expr.start_link(spec)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  describe "an input crossing its horizon" do
    test "flips the output to :unknown with no other change", %{id: id, input: input, out: out} do
      World.put(input, 25.0, stale_after: 300)
      start(id, out)
      Process.sleep(30)
      assert World.get(out) == true

      # Nothing is written from here on. This sleep is the entire stimulus.
      Process.sleep(450)

      assert World.get(out) == :unknown,
             "the input went stale and the derived fact never noticed -- " <>
               "nothing re-evaluated it, because nothing changed"
    end

    # The control. Without it the test above passes on an implementation that
    # decays every derived fact on a clock, whether or not the input has a
    # horizon at all.
    test "an input with no horizon is left alone", %{id: id, input: input, out: out} do
      World.put(input, 25.0)
      start(id, out)
      Process.sleep(30)
      assert World.get(out) == true

      Process.sleep(450)

      assert World.get(out) == true, "a fact with no stale_after must never go stale"
    end
  end

  describe "the timer follows the freshest report" do
    # A refresh -- the same value, written again -- moves observed_at and so
    # moves the horizon. The wake-up armed for the OLD horizon fires, finds
    # the input still fresh, leaves the output alone, and re-arms for the new
    # one. Re-evaluate rather than trust: the same rule the hold follows.
    test "a refresh pushes the horizon out, and it still lands afterwards", %{id: id, input: input, out: out} do
      World.put(input, 25.0, stale_after: 300)
      start(id, out)
      Process.sleep(200)
      World.put(input, 25.0, stale_after: 300)

      # 200 + 250 = 450 past the first write: the first horizon has passed,
      # the second (refreshed at 200, stale at 500) has not.
      Process.sleep(250)
      assert World.get(out) == true, "a refreshed input was treated as stale"

      Process.sleep(150)
      assert World.get(out) == :unknown, "the re-armed horizon never fired"
    end
  end

  describe "an input that is already stale" do
    # Scheduling for a fact that is already past its horizon would fire at
    # once, re-arm at once, and spin. It reads :unknown in the evaluation that
    # just happened; there is nothing to wake up for until it is refreshed,
    # and a refresh is a change, which wakes the process anyway.
    test "arms no timer, so the process cannot spin", %{id: id, input: input, out: out} do
      World.put(input, 25.0, stale_after: 1)
      Process.sleep(20)
      pid = start(id, out)
      Process.sleep(30)

      assert World.get(out) == :unknown
      assert :sys.get_state(pid).horizon_ref == nil,
             "a timer was armed for an input that is already stale"
    end
  end

  describe "with a hold" do
    # The hold's own wake-up writes `true` without going through recompute/1,
    # so it is a separate path that must also re-arm the horizon -- or a fact
    # that became true via the hold would then never notice its input dying.
    test "the horizon is re-armed after the hold elapses", %{id: id, input: input, out: out} do
      World.put(input, 25.0, stale_after: 400)
      start(id, out, hold: {:true_for, 100})
      Process.sleep(160)
      assert World.get(out) == true, "the hold never elapsed"

      Process.sleep(350)
      assert World.get(out) == :unknown,
             "true via the hold, and then blind to the input going stale"
    end
  end

  # ---------------------------------------------------------------------------
  # `unchanged_for?` is the same lesson one step further on. Staleness needed a
  # wake-up because a source going quiet produces no change; this needs one
  # because a source that keeps reporting the SAME VALUE produces no change
  # either. Every test below writes its input and then either touches nothing
  # or refreshes it with a value that is deliberately identical.
  describe "a fact that has stopped moving" do
    defp start_unchanged(id, out, ms) do
      spec = %{id: id, kind: :expr, out: out, compute: "unchanged_for?(#{id}.temp, #{ms})"}
      {:ok, pid} = Derive.Expr.start_link(spec)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    test "becomes true with no write at all", %{id: id, input: input, out: out} do
      World.put(input, 25.0)
      start_unchanged(id, out, 300)
      Process.sleep(30)
      assert World.get(out) == false

      # Nothing is written from here on. This sleep is the entire stimulus.
      Process.sleep(450)

      assert World.get(out) == true,
             "the input stopped moving and the derive never noticed -- nothing " <>
               "re-evaluated it, because nothing changed"
    end

    # THE STUCK-SENSOR CASE, and the reason staleness cannot cover it. A sensor
    # wedged at a constant still heartbeats, so observed_at keeps moving and the
    # fact is never stale. changed_at does not move, and that is what this reads.
    test "a refresh with the SAME value does not reset it", %{id: id, input: input, out: out} do
      World.put(input, 25.0, stale_after: 10_000)
      start_unchanged(id, out, 300)

      # Three heartbeats carrying an identical reading, as a stuck sensor sends.
      for _ <- 1..3 do
        Process.sleep(120)
        World.put(input, 25.0, stale_after: 10_000)
      end

      assert World.get(out) == true,
             "an identical re-report was treated as movement, which is exactly " <>
               "how a wedged sensor hides from a staleness check"
    end

    test "a real change resets it", %{id: id, input: input, out: out} do
      World.put(input, 25.0)
      start_unchanged(id, out, 300)
      Process.sleep(400)
      assert World.get(out) == true

      World.put(input, 25.5)
      Process.sleep(50)
      assert World.get(out) == false, "a genuine change must restart the clock"

      Process.sleep(400)
      assert World.get(out) == true, "and the horizon must be re-armed after it"
    end

    # Ignorance propagates rather than being answered: a stale fact has no
    # honest answer, and `true` here would be an accusation on no evidence.
    test "a stale input reads :unknown, not true", %{id: id, input: input, out: out} do
      World.put(input, 25.0, stale_after: 100)
      start_unchanged(id, out, 300)
      Process.sleep(450)

      assert World.get(out) == :unknown,
             "a fact past its own horizon was reported as having stopped moving"
    end
  end
end
