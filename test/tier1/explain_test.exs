defmodule Merlin.ExplainTest do
  @moduledoc """
  Tier 1: why a rule did, or did not, do anything.

  The claim is that every way a rule can decline is distinguishable from every
  other way. There are four, and before this they were one silence:

    * the trigger never fired
    * the guard was false
    * the guard was `:unknown` -- something it reads is stale or absent
    * the guard passed and an action's value could not be resolved

  An operator asking "why did nothing happen" needs to know which. "The door is
  shut" and "the sensor has not been heard from since Tuesday" lead to
  completely different mornings.

  ## What this tier does not prove

  That an explanation matches what the engine actually did at the time. It
  cannot: the replay evaluates against the world as it is NOW. That is a
  property of the approach, not a gap in the tests, and it is why the caller
  must label a retrospective replay as re-evaluated rather than as a record.
  """

  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.{Change, Rule, World}
  alias Merlin.Rules.{Explain, Explanation}

  # Atom segments, because expressions compile to atoms.
  @door [:xdoor, :front, :contact]
  @zone [:xperson, :zone]

  defp change(path, old \\ :closed, new \\ :open) do
    %Change{
      path: path,
      old: old,
      new: new,
      at: 0,
      source: nil,
      seq: System.unique_integer([:positive]),
      first?: false
    }
  end

  defp install(rules) do
    compiled =
      Enum.map(rules, fn data ->
        {:ok, rule} = Rule.compile(data)
        rule
      end)

    Merlin.Config.put(%{rules: compiled, groups: %{}})
  end

  setup do
    World.put(@zone, :home)
    on_exit(fn -> Merlin.Config.put(%{}) end)
    :ok
  end

  describe "the four ways a rule declines" do
    test "the trigger never fired" do
      install([
        %{id: :r, desc: "x", on: [{:changes, [:something, :else]}], do: [{:log, :info, "hi"}]}
      ])

      assert %Explanation{triggered?: false, guard: :none, fires?: false} =
               Explain.explain(:r, change(@door))
    end

    test "the guard was false" do
      World.put(@zone, :home)

      install([
        %{
          id: :r,
          desc: "x",
          on: [{:changes, @door}],
          when: "xperson.zone == :away",
          do: [{:log, :info, "hi"}]
        }
      ])

      assert %Explanation{triggered?: true, guard: {:refused, false}, fires?: false} =
               Explain.explain(:r, change(@door))
    end

    test "the guard was :unknown, and that is NOT the same as false" do
      # The distinction the whole thing exists for.
      World.put(@zone, :unknown)

      install([
        %{
          id: :r,
          desc: "x",
          on: [{:changes, @door}],
          when: "xperson.zone == :away",
          do: [{:log, :info, "hi"}]
        }
      ])

      assert %Explanation{guard: {:refused, :unknown}} = Explain.explain(:r, change(@door))

      refute match?(%Explanation{guard: {:refused, false}}, Explain.explain(:r, change(@door))),
             "a stale or absent fact must not be reported as a condition that was false"
    end

    test "the guard passed and an action could not be resolved" do
      # A rule that triggers, passes its guard, and still does nothing. Visible
      # before this only as a debug line nobody has enabled.
      World.put([:xmissing, :value], :unknown)

      install([
        %{
          id: :r,
          desc: "x",
          on: [{:changes, @door}],
          do: [{:log, :info, {:expr, "to_s(xmissing.value)"}}]
        }
      ])

      assert %Explanation{triggered?: true, guard: :none, fires?: false, skipped: skipped} =
               Explain.explain(:r, change(@door))

      assert {:unknown_value, _} = skipped
    end
  end

  describe "a rule that does fire" do
    test "reports the effects it would produce, resolved" do
      install([
        %{id: :r, desc: "x", on: [{:changes, @door}], do: [{:log, :info, "opened"}]}
      ])

      assert %Explanation{fires?: true, effects: [{:log, :info, "opened"}]} =
               Explain.explain(:r, change(@door))
    end

    test "and performs nothing" do
      # Resolved, then thrown away. If this performed, the effect would reach
      # Merlin.Effects.Tap -- which is exactly how it is asserted not to.
      Merlin.Effects.Tap.clear()
      :ok = Merlin.Effects.Tap.subscribe()
      on_exit(&Merlin.Effects.Tap.clear/0)

      install([
        %{id: :r, desc: "x", on: [{:changes, @door}], do: [{:log, :info, "opened"}]}
      ])

      Explain.explain(:r, change(@door))

      refute_receive {:merlin_effect, _}, 100
    end

    test "no guard is reported as :none, not as a guard that passed" do
      # Different things to a reader asking why a rule fired. Env.guard/2
      # answers :pass for a nil guard, which is right for the engine -- there
      # is nothing to refuse -- but wrong to show to a person.
      install([
        %{id: :bare, desc: "x", on: [{:changes, @door}], do: [{:log, :info, "hi"}]},
        %{
          id: :guarded,
          desc: "x",
          on: [{:changes, @door}],
          when: "xperson.zone == :home",
          do: [{:log, :info, "hi"}]
        }
      ])

      assert %Explanation{guard: :none, fires?: true} = Explain.explain(:bare, change(@door))
      assert %Explanation{guard: :pass, fires?: true} = Explain.explain(:guarded, change(@door))
    end

    test "carries the guard source, so the answer needs no config file" do
      install([
        %{
          id: :r,
          desc: "x",
          on: [{:changes, @door}],
          when: "xperson.zone == :home",
          do: [{:log, :info, "hi"}]
        }
      ])

      assert %Explanation{guard_source: "xperson.zone == :home"} =
               Explain.explain(:r, change(@door))
    end
  end

  describe "explain_all" do
    test "answers which rules a change would fire" do
      install([
        %{id: :a, desc: "x", on: [{:changes, @door}], do: [{:log, :info, "a"}]},
        %{id: :b, desc: "x", on: [{:changes, [:other]}], do: [{:log, :info, "b"}]},
        %{
          id: :c,
          desc: "x",
          on: [{:changes, @door}],
          when: "xperson.zone == :away",
          do: [{:log, :info, "c"}]
        }
      ])

      explanations = Explain.explain_all(change(@door))

      assert length(explanations) == 3
      assert Enum.map(explanations, & &1.id) == [:a, :b, :c], "declaration order is preserved"

      assert [:a] == explanations |> Enum.filter(& &1.fires?) |> Enum.map(& &1.id)
    end
  end

  describe "an id this house does not declare" do
    test "is an error, not an explanation that nothing happens" do
      # Otherwise a typo'd rule name looks exactly like a rule that exists and
      # declines -- which is the failure this endpoint exists to diagnose.
      install([])
      assert {:error, {:unknown_rule, :nope}} = Explain.explain(:nope, change(@door))
    end
  end
end
