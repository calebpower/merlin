defmodule Merlin.TriggerTest do
  @moduledoc """
  Tier 1: the two mechanisms that let a rule say *which* thing moved.

  Both exist for one defect. Every door in the house arrives from a single
  wildcard source, so `door.front_door.contact` and `door.bedroom_door.contact`
  differ only in a path segment. A rule could see that *a* door moved and
  nothing more: `{:changes_under, [:door]}` selects all of them, and the room
  reached the rule nowhere at all -- the router's captures were consumed
  building the fact path and then dropped.

  So the intruder latch alarmed on the bedroom door, and `door_presence` logged
  `open` under a description promising it named the room.

    * `{:changes_in, group}` fires for members of a named set, so which doors
      alarm is house data rather than a shape in the platform's vocabulary.
    * `captures` rides on the change, so `trigger.room` resolves.

  What this tier does NOT prove: that either reaches a running daemon. Tier 9
  drives a real house and asserts the latch never fires on an interior door.
  """

  # async: false, like geofence_test and machine_test: the group under test has
  # to be installed in the process-global config, and a concurrent module that
  # installed its own would see this one's.
  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.{Bus, Change, Config, Event, Expr, Groups, Rule}

  # A unique room per test, so a subscription left registered by one test
  # cannot receive another's publishes.
  defp uniq, do: "trig-#{System.unique_integer([:positive])}"

  defp change(path, opts \\ []) do
    %Change{
      path: path,
      old: Keyword.get(opts, :old, :closed),
      new: Keyword.get(opts, :new, :open),
      at: 0,
      source: nil,
      seq: 1,
      first?: false,
      captures: Keyword.get(opts, :captures, %{})
    }
  end

  defp compile!(data) do
    {:ok, rule} = Rule.compile(data)
    rule
  end

  # --- {:changes_in, group} -------------------------------------------------

  describe "the changes_in trigger" do
    setup do
      room = uniq()

      Config.put(%{
        groups: %{
          exterior: %{
            id: :exterior,
            members: [[:door, room, :contact], [:door, "#{room}-two", :contact]]
          }
        }
      })

      on_exit(fn -> Config.put(%{}) end)
      %{room: room}
    end

    test "fires for a member", %{room: room} do
      rule = compile!(%{id: :r, on: [{:changes_in, :exterior}], do: [{:log, :info, "x"}]})

      assert Rule.fires?(rule, change([:door, room, :contact]))
    end

    test "does not fire for a non-member of the same shape", %{room: room} do
      rule = compile!(%{id: :r, on: [{:changes_in, :exterior}], do: [{:log, :info, "x"}]})

      # The whole point. This path is a door, it is under [:door], and
      # {:changes_under, [:door]} would select it -- which is exactly how the
      # bedroom door came to set off an intruder alarm.
      refute Rule.fires?(rule, change([:door, "#{room}-interior", :contact]))
    end

    test "a prefix trigger DOES select the interior door", %{room: room} do
      # The contrast, asserted rather than described, so the test above is
      # known to be testing something.
      prefix = compile!(%{id: :r, on: [{:changes_under, [:door]}], do: [{:log, :info, "x"}]})

      assert Rule.fires?(prefix, change([:door, "#{room}-interior", :contact]))
    end

    test "does not fire for an event" do
      rule = compile!(%{id: :r, on: [{:changes_in, :exterior}], do: [{:log, :info, "x"}]})

      refute Rule.fires?(rule, %Event{path: [:door], payload: :x, at: 0, source: nil})
    end

    test "the group is the subscription", %{room: room} do
      rule = compile!(%{id: :r, on: [{:changes_in, :exterior}], do: [{:log, :info, "x"}]})

      # Derived, not written: watch_groups carries the group and watches is
      # empty, so nothing subscribes to the [:door] prefix by accident.
      assert rule.watch_groups == [:exterior]
      assert rule.watches == []

      Enum.each(rule.watch_groups, &Groups.subscribe/1)

      Bus.publish(change([:door, room, :contact]))
      assert_receive {:merlin, %Change{path: [:door, ^room, :contact]}}

      interior = "#{room}-interior"
      Bus.publish(change([:door, interior, :contact]))
      refute_receive {:merlin, %Change{path: [:door, ^interior, :contact]}}, 50
    end

    test "a group with no members is refused as a rule trigger at boot" do
      # Config.File is where this is caught; here we only assert the runtime
      # does not pretend otherwise.
      rule = compile!(%{id: :r, on: [{:changes_in, :nonexistent}], do: [{:log, :info, "x"}]})

      refute Rule.fires?(rule, change([:door, "anything", :contact]))
    end
  end

  # --- captures -------------------------------------------------------------

  describe "captures on a change" do
    test "trigger.<name> resolves to the captured segment" do
      {:ok, expr} = Expr.compile("trigger.room")
      c = change([:door, "front_door", :contact], captures: %{"room" => "front_door"})

      assert Expr.eval(expr, env(c)) == "front_door"
    end

    test "trigger.<name> is :unknown when nothing captured it" do
      {:ok, expr} = Expr.compile("trigger.room")

      # A derived fact, a rule's own set_fact, a snapshot restore. Not an
      # error: merlin genuinely does not know the room, and :unknown is that
      # answer rather than a missing one.
      assert Expr.eval(expr, env(change([:door, "front_door", :contact]))) == :unknown
    end

    test "a built-in key wins over a capture of the same name" do
      c = change([:door, "x", :contact], new: :open, captures: %{"value" => "shadowed"})
      {:ok, expr} = Expr.compile("trigger.value")

      assert Expr.eval(expr, env(c)) == :open
    end

    test "the reserved names are exactly the keys a trigger env produces" do
      # The "two things that must agree" check. Config.File refuses a topic
      # capture named after a built-in because such a capture would be
      # unreachable; if a key is ever added to the env and not to that list, a
      # source could shadow it and nothing would say so.
      produced =
        change([:a], captures: %{})
        |> Change.trigger_env()
        |> Map.keys()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort()

      assert produced == Enum.sort(Config.File.reserved_trigger_keys())
    end

    test "an event carries its captures too" do
      e = %Event{
        path: [:button, "living_room", :action],
        payload: :single,
        at: 0,
        source: nil,
        captures: %{"room" => "living_room"}
      }

      {:ok, expr} = Expr.compile("trigger.room")
      assert Expr.eval(expr, Map.put(base_env(), :trigger, Event.trigger_env(e))) == "living_room"
    end
  end

  # --- composing a message --------------------------------------------------

  describe "rendering a name into a message" do
    test "to_s/2 falls back rather than propagating :unknown" do
      # to_s/1 propagating :unknown is correct and dangerous in one specific
      # place: an action whose message resolves to :unknown is SKIPPED. Losing
      # the door's name must not lose the intruder alert.
      {:ok, unsafe} = Expr.compile("to_s(trigger.room)")
      {:ok, safe} = Expr.compile("to_s(trigger.room, \"an unnamed door\")")

      nameless = env(change([:door, "x", :contact]))

      assert Expr.eval(unsafe, nameless) == :unknown
      assert Expr.eval(safe, nameless) == "an unnamed door"
    end

    test "to_s/2 renders the value when there is one" do
      {:ok, expr} = Expr.compile("to_s(trigger.room, \"unnamed\")")
      c = change([:door, "back_door", :contact], captures: %{"room" => "back_door"})

      assert Expr.eval(expr, env(c)) == "back_door"
    end

    test "+ joins two strings" do
      {:ok, expr} = Expr.compile("\"a door moved: \" + to_s(trigger.room, \"unnamed\")")
      c = change([:door, "balcony_door", :contact], captures: %{"room" => "balcony_door"})

      assert Expr.eval(expr, env(c)) == "a door moved: balcony_door"
    end

    test "+ still adds numbers" do
      {:ok, expr} = Expr.compile("1 + 2")
      assert Expr.eval(expr, base_env()) == 3
    end

    test "+ refuses to coerce across types" do
      # Mixed operands are a mistake, not an intention: silently rendering a
      # number joined to a string hides a rule that meant something else.
      {:ok, expr} = Expr.compile("1 + \"2\"")
      assert Expr.eval(expr, base_env()) == :unknown
    end

    test "the builtin budget still holds" do
      assert Expr.builtin_count() <= Expr.builtin_budget()
    end
  end

  defp base_env,
    do: %{read: fn _ -> :unknown end, trigger: %{}, group: fn _ -> [] end, locals: %{}}

  defp env(%Change{} = c), do: Map.put(base_env(), :trigger, Change.trigger_env(c))
end
