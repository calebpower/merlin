defmodule Merlin.RulesEnvTest do
  @moduledoc """
  Tier 1: what a guard sees, and what it answered.

  Two claims, and the second is the reason this module exists.

  **One environment.** `Merlin.Rules.Engine` and `Merlin.Machine.Server` each
  built the same four-key map inline with a byte-identical private `read/1`
  beside it. Two copies of "what a guard can see" is the defect shape this
  codebase has paid for repeatedly, and it also blocked `Rules.Explain`, which
  has to evaluate a guard exactly as the engine would.

  **Three answers, not two.** Every operator propagates `:unknown`, so a guard
  has three outcomes, and both callers recorded one bit. `false` and
  `:unknown` mean entirely different things to somebody asking why a rule did
  not fire: "the door is shut" versus "the sensor has not been heard from since
  Tuesday". The collapse was invisible by construction -- the old
  `guard_passes?/2` returned a bare boolean and logged nothing at any level.

  ## What this tier does not prove

  That the engine and the machines now log a refusal. That is a `Logger` side
  effect at `:debug`, asserted where a daemon is running rather than here.
  What is asserted here is that the distinction *survives* into a value a
  caller can act on, which is what makes the logging possible at all.
  """

  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.{Expr, World}
  alias Merlin.Rules.Env

  # Binary roots for read/1, which takes a path directly. A hyphen is fine
  # here and would NOT be in an expression, where `env-1.zone` parses as a
  # subtraction.
  defp uniq, do: "env-#{System.unique_integer([:positive])}"

  # Expressions compile to atom segments -- `envtest.zone` is [:envtest, :zone]
  # -- so a fact a guard reads has to be written at an atom path. Fixed rather
  # than unique, because minting an atom per test is how an atom table fills.
  # Safe: this module is async: false and its tests run one at a time.
  @path [:envtest, :zone]
  @count [:envtest, :n]

  defp clear_fixture do
    World.put(@path, :unknown)
    World.put(@count, :unknown)
  end

  defp compile!(source) do
    {:ok, expr} = Expr.compile(source)
    expr
  end

  # --- the environment ------------------------------------------------------

  describe "build/2" do
    test "carries exactly what an expression can address" do
      env = Env.build(%{value: :open})

      # read, trigger, group, locals. An expression addresses facts through
      # `read`, `trigger.*`, `local.*`, and groups through `group`. Anything
      # else in here would be reachable by nothing.
      assert Map.keys(env) |> Enum.sort() == [:group, :locals, :read, :trigger]
    end

    test "a stateless rule has no locals" do
      assert Env.build(%{}).locals == %{}
    end

    test "a machine's data slots become its locals" do
      assert Env.build(%{}, %{desired: :off}).locals == %{desired: :off}
    end

    test "the built env actually evaluates an expression" do
      # The point of the map is that Expr can use it. Asserting the keys alone
      # would pass for a map with the right names and the wrong values.
      World.put(@path, :home)

      assert Expr.eval(compile!("envtest.zone == :home"), Env.build(%{})) == true
    end
  end

  # --- reading --------------------------------------------------------------

  describe "read/1" do
    test "an absent fact is :unknown, not nil" do
      assert Env.read([uniq(), "nothing"]) == :unknown
    end

    test "a fresh fact is its value" do
      root = uniq()
      World.put([root, "contact"], :open)
      assert Env.read([root, "contact"]) == :open
    end

    test "a stale fact is :unknown, not its last value" do
      # The difference between "the car is at home" and "the car was at home
      # when the tracker last spoke, four hours ago".
      root = uniq()
      World.put([root, "lat"], 51.4779, stale_after: 0)

      assert eventually(fn -> Env.read([root, "lat"]) == :unknown end),
             "a fact past its stale_after must not keep reporting its value"
    end

    test "a fact with no stale_after never goes stale" do
      root = uniq()
      World.put([root, "power"], :on)
      refute eventually(fn -> Env.read([root, "power"]) == :unknown end, 5)
    end
  end

  # --- the three answers ----------------------------------------------------

  describe "guard/2" do
    test "no guard passes" do
      assert Env.guard(nil, Env.build(%{})) == :pass
    end

    test "literal true passes" do
      assert Env.guard(compile!("1 == 1"), Env.build(%{})) == :pass
    end

    test "false is refused as false" do
      assert Env.guard(compile!("1 == 2"), Env.build(%{})) == {:refused, false}
    end

    test ":unknown is refused as :unknown, and is NOT false" do
      # The whole point. Before this, both arrived as `false` and a rule
      # declining because a sensor went stale was indistinguishable from one
      # declining because the world was fine.
      clear_fixture()
      env = Env.build(%{})
      guard = compile!("envtest.zone == :home")

      assert Env.guard(guard, env) == {:refused, :unknown}

      refute Env.guard(guard, env) == {:refused, false},
             "a stale or absent fact must not be reported as a condition that was false"
    end

    test "a guard that is neither true nor false is refused with its value" do
      # A rule-authoring mistake that can never fire and never explains itself.
      # Kept as the raw value so the report can say what it actually was.
      World.put(@path, :home)

      assert Env.guard(compile!("envtest.zone"), Env.build(%{})) == {:refused, :home}
    end

    test "firing behaviour is unchanged: only literal true passes" do
      # This observes the decision; it must not alter it. Expr.truthy?/1 was
      # `true -> true; _ -> false`, so anything but literal true is a refusal.
      World.put(@count, 1)
      env = Env.build(%{})

      for source <- ["envtest.n", "envtest.n == 2", "not (envtest.n == 1)"] do
        assert match?({:refused, _}, Env.guard(compile!(source), env)),
               "#{source} must not fire"
      end
    end
  end

  # --- how a refusal reads --------------------------------------------------

  describe "describe_refusal/1" do
    test "an unknown says what unknown means" do
      # An operator reading this at 3am should not have to know what
      # three-valued logic is to understand why nothing happened.
      assert Env.describe_refusal(:unknown) =~ "stale"
      assert Env.describe_refusal(:unknown) =~ ":unknown"
    end

    test "false says false, and does not mention staleness" do
      refute Env.describe_refusal(false) =~ "stale"
    end

    test "the two are not the same sentence" do
      refute Env.describe_refusal(false) == Env.describe_refusal(:unknown)
    end

    test "a non-boolean names the value it actually got" do
      assert Env.describe_refusal(:home) =~ ":home"
    end
  end

  # Bounded retry, matching the convention in bus_test.exs: a claim that is
  # eventual rather than immediate, without a sleep whose length is a guess.
  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(1)
        {:cont, false}
      end
    end)
  end
end
