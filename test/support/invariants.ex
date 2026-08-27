defmodule Merlin.Test.Invariants do
  @moduledoc """
  Properties that must hold across a whole run of the house, checked against a
  recorded timeline rather than at a single moment.

  This is what tier 9 is for. Every other tier asks "given this input, is the
  output right"; these ask "did anything wrong happen over the course of two
  hundred events", which is the shape of the defects that actually wake people
  up at 3am. Bug 7 is invisible to a unit test of the load shed and obvious to
  `ac_off_for_the_whole_cycle/1`.

  ## The timeline

  A list of entries, oldest first:

      %{
        seq: 12,
        kind: :publish | :step,
        topic: "home/office/plug/climate/set",   # :publish only
        payload: ~s({"state":"ON"}),             # :publish only
        note: "door garage -> open",             # :step only
        settling?: false,
        facts: %{[:person, :caleb, :zone] => :home, ...}
      }

  `facts` is the world as it stood immediately after the entry. Carrying it per
  entry is wasteful and worth it: an invariant that has to reconstruct history
  is an invariant nobody will read, and one that reconstructs it wrongly fails
  silently in the direction of passing.

  ## Every invariant must be shown to fire

  "An invariant that never fires is indistinguishable from a passing suite."
  Each function here has a matching case in the tier 9 test that feeds it a
  deliberately broken timeline and requires it to complain. An invariant that
  cannot be made to fail is not evidence.
  """

  @type entry :: map()
  @type timeline :: [entry()]
  @type violation :: {atom(), binary()}

  @doc "Every invariant, by name."
  @spec all() :: [{atom(), (timeline() -> [binary()])}]
  def all do
    [
      {:ac_off_for_the_whole_cycle, &ac_off_for_the_whole_cycle/1},
      {:latch_never_fires_at_home, &latch_never_fires_at_home/1},
      {:nothing_published_while_settling, &nothing_published_while_settling/1},
      {:latch_stays_fired_until_home, &latch_stays_fired_until_home/1},
      {:lamps_never_commanded_in_daylight, &lamps_never_commanded_in_daylight/1},
      {:no_command_without_a_reason, &no_command_without_a_reason/1}
    ]
  end

  @doc "Run every invariant. Returns `[]` when the run was clean."
  @spec check(timeline()) :: [violation()]
  def check(timeline) do
    Enum.flat_map(all(), fn {name, fun} ->
      Enum.map(fun.(timeline), &{name, &1})
    end)
  end

  # --- bug 7 ---------------------------------------------------------------

  @doc """
  The A/C must not be commanded ON between the printer being powered down and
  powered back up.

  `office_aircond.py` restored the A/C on the printer's *request* value, so a
  REBOOT un-masked it immediately and the A/C came back at t=0 -- during the
  ten seconds the printer was deliberately off. A test of the load shed alone
  cannot see this; it needs the two machines' outputs interleaved in time.
  """
  @spec ac_off_for_the_whole_cycle(timeline()) :: [binary()]
  def ac_off_for_the_whole_cycle(timeline) do
    timeline
    |> Enum.filter(&(&1.kind == :publish))
    |> Enum.reduce({nil, []}, fn e, {printer_down_at, violations} ->
      cond do
        e.topic == "home/office/plug/3d_printer/set" and state_of(e.payload) == :off ->
          {e.seq, violations}

        e.topic == "home/office/plug/3d_printer/set" and state_of(e.payload) == :on ->
          {nil, violations}

        printer_down_at != nil and e.topic == "home/office/plug/climate/set" and
            state_of(e.payload) == :on ->
          {printer_down_at,
           [
             "the A/C was commanded ON at seq #{e.seq}, while the printer had been " <>
               "powered down since seq #{printer_down_at} -- bug 7"
             | violations
           ]}

        true ->
          {printer_down_at, violations}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # --- bug 2's class -------------------------------------------------------

  @doc """
  The intruder latch must never fire while the phone is home.

  In the Python this was unreachable for a different reason (`"" is False`),
  so it never fired at all. Turning it on is what makes this worth asserting:
  the rule now runs, and the failure mode has changed from "never alerts" to
  "alerts while you are standing in the kitchen".
  """
  @spec latch_never_fires_at_home(timeline()) :: [binary()]
  def latch_never_fires_at_home(timeline) do
    timeline
    |> transitions([:rule, :intruder_latch, :state])
    |> Enum.flat_map(fn {entry, from, to} ->
      zone = Map.get(entry.facts, [:person, :caleb, :zone])

      if from != :fired and to == :fired and zone == :home do
        ["the latch fired at seq #{entry.seq} while the phone was home"]
      else
        []
      end
    end)
  end

  @doc """
  A latch that un-latches on its own is not a latch.

  Once fired it stays fired until the phone arrives home. Any other transition
  back to `:armed` means something re-armed it -- a restart that forgot, a
  clause that matched too broadly -- and the alert can then fire twice for one
  absence.
  """
  @spec latch_stays_fired_until_home(timeline()) :: [binary()]
  def latch_stays_fired_until_home(timeline) do
    timeline
    |> transitions([:rule, :intruder_latch, :state])
    |> Enum.flat_map(fn {entry, from, to} ->
      zone = Map.get(entry.facts, [:person, :caleb, :zone])

      if from == :fired and to == :armed and zone != :home do
        ["the latch re-armed at seq #{entry.seq} with the phone at #{inspect(zone)}, not home"]
      else
        []
      end
    end)
  end

  # --- bug 8 ---------------------------------------------------------------

  @doc """
  Nothing reaches the house while the settle window is open.

  The window exists because retained messages replay in a burst on every
  connect and are indistinguishable from the whole house changing at once.
  """
  @spec nothing_published_while_settling(timeline()) :: [binary()]
  def nothing_published_while_settling(timeline) do
    timeline
    |> Enum.filter(&(&1.kind == :publish and &1.settling?))
    |> Enum.map(fn e ->
      "published #{e.topic} at seq #{e.seq} while still settling"
    end)
  end

  # --- the lamps -----------------------------------------------------------

  @doc """
  The arrival rule must not turn the lamps on in daylight.

  Chosen at planning: "only after dark, and only if I arrive home -- not if I
  am already home."
  """
  @spec lamps_never_commanded_in_daylight(timeline()) :: [binary()]
  def lamps_never_commanded_in_daylight(timeline) do
    timeline
    |> Enum.filter(fn e ->
      e.kind == :publish and String.contains?(e.topic, "living_room") and
        state_of(e.payload) == :on and Map.get(e.facts, [:sun, :state]) == :day
    end)
    |> Enum.map(&"the lamps were commanded ON at seq #{&1.seq} in daylight")
  end

  # --- the general one -----------------------------------------------------

  @doc """
  Every command to the house is preceded by something that could have caused
  it.

  Deliberately weak -- it only requires *some* inbound event earlier in the
  run -- because the strong version is a second implementation of the rules
  engine. What it catches is the class where merlin actuates from nothing at
  all: a timer firing on an empty world, a restored fact being mistaken for a
  change, a machine resuming into a state it then immediately leaves.
  """
  @spec no_command_without_a_reason(timeline()) :: [binary()]
  def no_command_without_a_reason(timeline) do
    case Enum.split_while(timeline, &(&1.kind != :step)) do
      {before_any_step, _rest} ->
        before_any_step
        |> Enum.filter(&(&1.kind == :publish))
        |> Enum.map(&"commanded #{&1.topic} at seq #{&1.seq} before anything had happened")
    end
  end

  # --- helpers -------------------------------------------------------------

  # Successive entries where `path` changed, with the value either side.
  defp transitions(timeline, path) do
    timeline
    |> Enum.reduce({:absent, []}, fn entry, {previous, acc} ->
      current = Map.get(entry.facts, path, :absent)

      if current != previous and previous != :absent do
        {current, [{entry, previous, current} | acc]}
      else
        {current, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp state_of(payload) when is_binary(payload) do
    cond do
      String.contains?(payload, "\"ON\"") -> :on
      String.contains?(payload, "\"OFF\"") -> :off
      payload == "ON" -> :on
      payload == "OFF" -> :off
      true -> :unknown
    end
  end

  defp state_of(_), do: :unknown
end
