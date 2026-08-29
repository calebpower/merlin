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
        topic: "z2m/home/office/plug/climate/set",   # :publish only
        payload: ~s({"state":"ON"}),             # :publish only
        note: "door garage -> open",             # :step only
        settling?: false,
        facts: %{[:person, :owner, :zone] => :home, ...}
      }

  `facts` is the world as it stood immediately after the entry. Carrying it per
  entry is wasteful and worth it: an invariant that has to reconstruct history
  is an invariant nobody will read, and one that reconstructs it wrongly fails
  silently in the direction of passing.

  ## A seed fixes the trace, not the interleaving

  `MERLIN_SIM_SEED` makes the *sequence of device actions* reproducible. It
  does not make the run deterministic: the daemon is a supervision tree of real
  processes, and which of them observes a fact between two writes is decided by
  the scheduler, not by the seed.

  So a violation found under a seed may not recur under it. That is not the
  harness failing -- an intermittent defect is still a defect, and finding one
  at all is the point -- but it means "pin with MERLIN_SIM_SEED" promises more
  than it delivers, and a re-run that passes is NOT evidence the defect is
  gone. Two single samples of a nondeterministic process cannot be compared,
  and treating them as an A/B is how a real race gets recorded as fixed.

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
      {:latch_never_fires_on_a_lost_phone, &latch_never_fires_on_a_lost_phone/1},
      {:latch_only_fires_on_an_exterior_door, &latch_only_fires_on_an_exterior_door/1},
      {:tui_never_lies, &tui_never_lies/1},
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
        e.topic == "z2m/home/office/plug/3d_printer/set" and state_of(e.payload) == :off ->
          {e.seq, violations}

        e.topic == "z2m/home/office/plug/3d_printer/set" and state_of(e.payload) == :on ->
          {nil, violations}

        printer_down_at != nil and e.topic == "z2m/home/office/plug/climate/set" and
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
      zone = Map.get(entry.facts, [:person, :owner, :zone])

      if from != :fired and to == :fired and zone == :home do
        ["the latch fired at seq #{entry.seq} while the phone was home"]
      else
        []
      end
    end)
  end

  @doc """
  The latch must never fire while the phone's location is unknown.

  This is the safety property the whole `:away` / `:unknown` split exists to
  protect. `:unknown` means merlin has no usable fix -- the phone is off, the
  battery died, GPS is reporting a two-kilometre error. A door moving then is
  not evidence of anything, and alarming on it is how a home alarm teaches you
  to ignore it.

  Before the split there was one value for "somewhere unnamed" and "no fix", so
  excluding one excluded both. Now that they are separable, the exclusion has
  to be asserted or it can be dropped from a guard with nothing noticing.
  """
  @spec latch_never_fires_on_a_lost_phone(timeline()) :: [binary()]
  def latch_never_fires_on_a_lost_phone(timeline) do
    timeline
    |> transitions([:rule, :intruder_latch, :state])
    |> Enum.flat_map(fn {entry, from, to} ->
      zone = Map.get(entry.facts, [:person, :owner, :zone], :absent)

      if from != :fired and to == :fired and zone in [:unknown, :absent] do
        ["the latch fired at seq #{entry.seq} with the phone's location #{inspect(zone)}"]
      else
        []
      end
    end)
  end

  @doc """
  The latch fires only for a door the house calls exterior.

  Every door in this house arrives from one wildcard source and lands at a path
  of exactly the same shape, so `{:changes_under, [:door]}` selects all of them
  -- the bedroom and the office included. Which doors are worth alarming about
  is a fact about the building, not about the path, and it lives in the
  `:exterior_doors` group.

  Asserted against that group rather than a list written here, so adding an
  interior door to the house cannot quietly fall outside what this checks.

  The failure it exists to catch is not theoretical: the latch shipped through
  M7 on the bare prefix, so walking from the bedroom to the kitchen while the
  phone had no fix looked exactly like someone coming in through a window.
  """
  @spec latch_only_fires_on_an_exterior_door(timeline()) :: [binary()]
  def latch_only_fires_on_an_exterior_door(timeline),
    do: latch_only_fires_on_an_exterior_door(timeline, Merlin.Groups.members(:exterior_doors))

  @doc """
  As above, against an explicit member list.

  The self-test needs to drive this without installing a whole house, and an
  invariant whose reference data is only reachable through global state is one
  that cannot be shown to fire.
  """
  @spec latch_only_fires_on_an_exterior_door(timeline(), [Merlin.Path.t()]) :: [binary()]
  def latch_only_fires_on_an_exterior_door(timeline, members) do
    exterior = MapSet.new(members)

    timeline
    |> transitions([:rule, :intruder_latch, :state])
    |> Enum.flat_map(fn {entry, from, to} ->
      with true <- from != :fired and to == :fired,
           {:ok, room} <- door_room(entry) do
        cond do
          # No members means the group is gone or the config never loaded.
          # Reporting that is the point: an invariant that silently checks
          # nothing against an empty set is the failure this whole tier is
          # built to avoid.
          Enum.empty?(exterior) ->
            ["no :exterior_doors members to check the fire at seq #{entry.seq} against"]

          MapSet.member?(exterior, [:door, room, :contact]) ->
            []

          true ->
            ["the latch fired at seq #{entry.seq} on #{room}, which is not an exterior door"]
        end
      else
        # A transition to :fired with no door in the note is a different
        # defect, and latch_never_fires_at_home/1 owns it. Saying nothing here
        # is deliberate: an invariant that reports on what it does not check is
        # an invariant nobody trusts.
        _ -> []
      end
    end)
  end

  # Steps are recorded as "<topic> <payload>", so the room is the wildcard
  # segment of the door filter. Matching the shape rather than a list of names
  # keeps this working when the house gains a door.
  defp door_room(%{note: note}) when is_binary(note) do
    case Regex.run(~r{^z2m/home/([^/]+)/sensor/contact\s}, note) do
      [_, room] -> {:ok, room}
      nil -> :error
    end
  end

  defp door_room(_entry), do: :error

  @doc """
  Every fact the operator's screen displays is the fact merlin holds.

  The defect this exists for is the one an operator cannot catch: a frame that
  is well-formed, correctly laid out, and *wrong*. A stale render, a scroll
  window pointing one row off, a value formatted from the previous tick -- none
  of those look like faults. They look like a house behaving oddly, and the
  person reading the screen goes and investigates the house.

  No cheaper tier can see it. Tier 2 renders scenes somebody wrote by hand, so
  it only ever asks about the situations that were imagined. This renders the
  world as it actually stood at two hundred points of a seeded run, and asks
  the frame to agree with it every time.

  Read from the timeline rather than by attaching a session: `facts` is already
  recorded per entry, and reconstructing the screen from it needs no daemon, no
  terminal and no tap. What it therefore does NOT prove is that the client
  receives the right scene -- that is delivery, and tier 5 owns it.
  """
  @spec tui_never_lies(timeline()) :: [binary()]
  def tui_never_lies(timeline), do: tui_never_lies(timeline, &render_facts/1)

  @doc """
  As above, against a supplied renderer.

  The renderer is a parameter for one reason: without it this invariant is
  almost incapable of failing. It renders from the same facts it then checks,
  so the view and the expectation agree by construction, and a self-test cannot
  create a disagreement between them.

  Passing in a renderer that drops a row or corrupts a value is how the
  invariant is shown to fire -- the same argument as
  `latch_only_fires_on_an_exterior_door/2`, and the same reason: an invariant
  that has never been made to complain is indistinguishable from one that
  cannot.
  """
  @spec tui_never_lies(timeline(), (map() -> binary())) :: [binary()]
  def tui_never_lies(timeline, render) do
    Enum.flat_map(timeline, fn entry ->
      facts = Map.get(entry, :facts) || %{}

      if map_size(facts) == 0 do
        []
      else
        text = render.(facts)

        facts
        |> Enum.reject(fn {path, value} -> shown?(text, path, value) end)
        |> Enum.map(fn {path, value} ->
          "at seq #{entry.seq} the frame does not show " <>
            "#{Merlin.Path.to_string(path)} = #{inspect(value)}"
        end)
      end
    end)
  end

  @doc false
  # A frame wide enough that nothing is truncated and tall enough that nothing
  # scrolls, because this invariant is about truthfulness rather than layout --
  # tier 2 owns what happens when a column is too narrow.
  def render_facts(facts) do
    scene = %Merlin.TUI.Scene{
      facts: Enum.map(facts, fn {path, value} -> as_fact(path, value) end),
      now: 0
    }

    scene
    |> Merlin.TUI.View.Facts.render(%{}, {160, map_size(facts) + 3})
    |> Merlin.TUI.Buffer.to_text()
  end

  defp as_fact(path, value) do
    %Merlin.Fact{
      path: path,
      value: value,
      changed_at: 0,
      observed_at: 0,
      source: nil,
      seq: 1,
      stale_after: nil
    }
  end

  # The row for this path must carry this value. Compared against what the view
  # itself would render -- Scene.value/1 -- rather than against inspect/1, so
  # this asserts agreement with the display rather than re-deciding formatting
  # and then disagreeing with the thing under test about it.
  defp shown?(text, path, value) do
    rendered = Merlin.TUI.Scene.value(value)
    path_string = Merlin.Path.to_string(path)

    text
    |> String.split("\n")
    |> Enum.any?(fn line ->
      String.starts_with?(line, path_string) and String.contains?(line, visible(rendered))
    end)
  end

  # The value column is fourteen wide, so a longer value is legitimately shown
  # truncated. Asserting the whole of it would fail on honest rendering.
  defp visible(rendered), do: String.slice(rendered, 0, 14)

  @doc """
  A latch that un-latches on its own is not a latch.

  Once fired it stays fired until the phone arrives home. Any other transition
  back to `:armed` means something re-armed it -- a restart that forgot, a
  clause that matched too broadly -- and the alert can then fire twice for one
  absence.
  """
  @spec latch_stays_fired_until_home(timeline()) :: [binary()]
  def latch_stays_fired_until_home(timeline) do
    indexed = Enum.with_index(timeline)

    timeline
    |> transitions([:rule, :intruder_latch, :state])
    |> Enum.flat_map(fn {entry, from, to} ->
      zone = Map.get(entry.facts, [:person, :owner, :zone])

      if from == :fired and to == :armed and zone != :home do
        # Both the zone AT the entry and the zone BEFORE it.
        #
        # The timeline records facts once per step, after everything that step
        # caused has settled. So a zone that legitimately entered :home and
        # then moved on within the same step is indistinguishable, from the
        # snapshot alone, from one that was never :home at all -- and those are
        # completely different defects. Reporting only the first made this
        # invariant able to say something was wrong without saying what.
        ["the latch re-armed at seq #{entry.seq} with the phone at #{inspect(zone)}, " <>
           "not home (it was #{inspect(previous_zone(indexed, entry))} in the step before, " <>
           "and this step was #{inspect(entry.note)})"]
      else
        []
      end
    end)
  end

  defp previous_zone(indexed, entry) do
    case Enum.find(indexed, fn {e, _i} -> e.seq == entry.seq end) do
      {_e, 0} -> :none
      {_e, i} ->
        indexed
        |> Enum.at(i - 1)
        |> elem(0)
        |> Map.get(:facts)
        |> Map.get([:person, :owner, :zone])
      nil -> :none
    end
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
