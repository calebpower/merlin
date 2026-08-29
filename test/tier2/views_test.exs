defmodule Merlin.ViewsTest do
  @moduledoc """
  Tier 2: conformance for the rules, stream and devices panes.

  Same three techniques as the facts pane: structural properties that hold for
  any scene at any size, layout against a specification written here rather
  than imported, and sensitivity -- perturb one datum, require the frame to
  move. Sensitivity is what proves a column is wired to the screen at all,
  which no golden captured from the implementation can.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier2

  alias Merlin.TUI.{Buffer, Scene}
  alias Merlin.TUI.View.{Devices, Rules, Stream}

  @now 1_000_000

  defp fact(path, value, opts \\ []) do
    %Merlin.Fact{
      path: path,
      value: value,
      changed_at: @now,
      observed_at: @now - Keyword.get(opts, :age, 1_000),
      source: Keyword.get(opts, :source),
      seq: 1,
      stale_after: nil
    }
  end

  defp rule(id, opts) do
    {:ok, r} =
      Merlin.Rule.compile(%{
        id: id,
        desc: "x",
        on: [{:changes, [:a]}],
        when: Keyword.get(opts, :guard),
        do: [{:log, :info, "hi"}]
      })

    r
  end

  defp machine(id) do
    {:ok, m} =
      Merlin.Machine.compile(%{
        id: id,
        desc: "x",
        machine: %{
          initial: :armed,
          states: %{
            armed: [%{on: {:changes, [:d]}, do: [{:log, :info, "hi"}], goto: :fired}],
            fired: [%{on: {:changes, [:d]}, do: [{:log, :info, "hi"}], goto: :armed}]
          }
        }
      })

    m
  end

  # --- rules ----------------------------------------------------------------

  describe "the rules pane" do
    defp rules_scene do
      %Scene{
        rules: [rule(:lamps_toggle, guard: "1 == 1"), machine(:intruder_latch)],
        states: %{intruder_latch: :fired},
        now: @now
      }
    end

    test "shows both kinds, which is the point" do
      # Machines were absent from /rules.json entirely, so the whole stateful
      # half of the automation was invisible where a rule is diagnosed.
      text = rules_scene() |> Rules.render(%{}, {80, 8}) |> Buffer.to_text()

      assert text =~ "lamps_toggle"
      assert text =~ "intruder_latch"
      assert text =~ "machine"
      assert text =~ "rule"
    end

    test "a machine shows the state it is actually in" do
      text = rules_scene() |> Rules.render(%{}, {80, 8}) |> Buffer.to_text()
      assert text =~ "fired"
    end

    test "a machine with no reported state falls back to its declared initial" do
      # Honest -- it is what the machine would be in -- and better than a blank
      # column that reads as "no idea".
      scene = %{rules_scene() | states: %{}}
      assert Rules.render(scene, %{}, {80, 8}) |> Buffer.to_text() =~ "armed"
    end

    test "a rule shows its guard, because that is where the answer usually is" do
      assert rules_scene() |> Rules.render(%{}, {80, 8}) |> Buffer.to_text() =~ "1 == 1"
    end

    property "the frame is always the rect it was given" do
      check all w <- integer(30..120), h <- integer(3..20) do
        buffer = Rules.render(rules_scene(), %{}, {w, h})
        assert buffer.w == w and buffer.h == h
      end
    end
  end

  # --- stream ---------------------------------------------------------------

  describe "the stream pane" do
    defp change_item do
      {:change,
       %Merlin.Change{
         path: [:door, "front", :contact],
         old: :closed,
         new: :open,
         at: 0,
         source: nil,
         seq: 1,
         first?: false
       }}
    end

    defp effect_item(outcome) do
      {:effect,
       %Merlin.Effects.Report{
         outcome: outcome,
         effect: {:set_group, :lamps, :off},
         source: {:rule, :lamps_off},
         at: 0,
         wall: 0
       }}
    end

    test "an empty stream says what it is waiting for" do
      text = %Scene{now: @now} |> Stream.render(%{}, {80, 6}) |> Buffer.to_text()
      assert text =~ "from now on"
    end

    test "an event is visible here and nowhere else" do
      # Events are never stored, so a button press that did nothing is
      # unobservable the instant after it happens, except here.
      item =
        {:event,
         %Merlin.Event{path: [:button, :lr, :pressed], payload: :double, at: 0, source: nil}}

      text = %Scene{stream: [item], now: @now} |> Stream.render(%{}, {80, 6}) |> Buffer.to_text()

      assert text =~ "event"
      assert text =~ "button.lr.pressed"
      assert text =~ "double"
    end

    test "an effect shows its OUTCOME, not merely that it was decided" do
      # During a dry-run soak this distinction is the entire product.
      dry = %Scene{stream: [effect_item(:dry_run)], now: @now}
      did = %Scene{stream: [effect_item(:performed)], now: @now}

      assert Stream.render(dry, %{}, {80, 6}) |> Buffer.to_text() =~ "dry-run"
      assert Stream.render(did, %{}, {80, 6}) |> Buffer.to_text() =~ "did"

      refute Buffer.to_text(Stream.render(dry, %{}, {80, 6})) ==
               Buffer.to_text(Stream.render(did, %{}, {80, 6}))
    end

    test "a failure is distinguishable from a success" do
      failed = %Scene{stream: [effect_item({:failed, :nope})], now: @now}
      assert Stream.render(failed, %{}, {80, 6}) |> Buffer.to_text() =~ "FAILED"
    end

    test "a drop is stated, never swallowed" do
      scene = %Scene{stream: [{:dropped, 42}], now: @now}
      assert Stream.render(scene, %{}, {80, 6}) |> Buffer.to_text() =~ "42 dropped"
    end

    test "filtering narrows the stream" do
      scene = %Scene{stream: [change_item(), effect_item(:dry_run)], now: @now}
      text = Stream.render(scene, %{filter: "door"}, {80, 6}) |> Buffer.to_text()

      assert text =~ "door.front.contact"
      refute text =~ "set group"
    end

    property "hostile payloads cannot escape the grid" do
      check all hostile <- string(:printable, max_length: 30) do
        item =
          {:event, %Merlin.Event{path: [:x], payload: hostile, at: 0, source: nil}}

        buffer = Stream.render(%Scene{stream: [item], now: @now}, %{}, {60, 5})

        refute Buffer.to_text(buffer) =~ "\e"
        assert buffer.w == 60 and buffer.h == 5
      end
    end
  end

  # --- devices --------------------------------------------------------------

  describe "the devices pane" do
    defp devices_scene do
      %Scene{
        groups: %{
          lamps: %{
            id: :lamps,
            members: [[:lamp, :one, :power], [:lamp, :two, :power]],
            set_topic: "z2m/lamps/set"
          },
          exterior_doors: %{id: :exterior_doors, members: [[:door, "front", :contact]]}
        },
        facts: [
          fact([:lamp, :one, :power], :on),
          fact([:lamp, :two, :power], :off),
          fact([:door, "front", :contact], :closed)
        ],
        now: @now
      }
    end

    test "members are shown individually, because they can disagree" do
      # The toggle rule's asymmetry -- off only when BOTH are on -- is
      # invisible if two bulbs are collapsed into one aggregate state.
      text = devices_scene() |> Devices.render(%{}, {80, 6}) |> Buffer.to_text()

      assert text =~ ":on"
      assert text =~ ":off"
    end

    test "a group with no set_topic is shown and marked read-only" do
      # It exists to be READ -- :exterior_doors names which doors alarm --
      # and hiding it would leave an operator hunting a group a rule names.
      text = devices_scene() |> Devices.render(%{}, {80, 6}) |> Buffer.to_text()

      assert text =~ "exterior_doors"
      assert text =~ "read-only"
      assert text =~ "commandable"
    end

    test "a member with no fact reads as unknown, not as absent" do
      scene = %{devices_scene() | facts: []}
      assert Devices.render(scene, %{}, {80, 6}) |> Buffer.to_text() =~ "?"
    end

    property "the frame is always the rect it was given" do
      check all w <- integer(30..120), h <- integer(2..20) do
        buffer = Devices.render(devices_scene(), %{}, {w, h})
        assert buffer.w == w and buffer.h == h
      end
    end
  end

  # --- sensitivity ----------------------------------------------------------

  describe "every displayed datum is wired to the screen" do
    test "a machine's state" do
      a = %Scene{rules: [machine(:m)], states: %{m: :armed}, now: @now}
      b = %Scene{rules: [machine(:m)], states: %{m: :fired}, now: @now}

      refute Buffer.to_text(Rules.render(a, %{}, {80, 6})) ==
               Buffer.to_text(Rules.render(b, %{}, {80, 6}))
    end

    test "a rule's guard" do
      a = %Scene{rules: [rule(:r, guard: "1 == 1")], now: @now}
      b = %Scene{rules: [rule(:r, guard: "2 == 2")], now: @now}

      refute Buffer.to_text(Rules.render(a, %{}, {80, 6})) ==
               Buffer.to_text(Rules.render(b, %{}, {80, 6}))
    end

    test "a member's value" do
      on = devices_scene()
      off = %{on | facts: [fact([:lamp, :one, :power], :off), fact([:lamp, :two, :power], :off)]}

      refute Buffer.to_text(Devices.render(on, %{}, {80, 6})) ==
               Buffer.to_text(Devices.render(off, %{}, {80, 6}))
    end
  end
end
