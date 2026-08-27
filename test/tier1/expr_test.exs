defmodule Merlin.ExprTest do
  @moduledoc """
  Tier 1: the expression language.

  The highest-risk component in the design, so it gets the most assertions.
  Three things are under test and each fails differently:

    * the **whitelist** -- what is refused matters more than what is allowed,
      because an accepted-but-unlisted form is an escape from the sandbox;
    * **three-valued logic** -- the direct fix for the `""`-instead-of-`false`
      bug that stopped the Python's away-detection from ever firing; and
    * **dependency extraction** -- subscriptions are derived from this, so a
      missed dep is a rule that silently never runs.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier1

  alias Merlin.Expr

  defp ev(source, env \\ %{}) do
    Expr.compile!(source) |> Expr.eval(env)
  end

  defp with_facts(facts) do
    %{read: fn path -> Map.get(facts, path, :unknown) end}
  end

  describe "literals" do
    test "numbers, strings, atoms, booleans, nil" do
      assert ev("1") == 1
      assert ev("1.5") == 1.5
      assert ev("\"hi\"") == "hi"
      assert ev(":home") == :home
      assert ev("true") == true
      assert ev("false") == false
      assert ev("nil") == nil
    end

    test "lists of literals" do
      assert ev("[1, 2, 3]") == [1, 2, 3]
      assert ev("[:a, :b]") == [:a, :b]
    end
  end

  describe "comparison and arithmetic" do
    test "equality" do
      assert ev(":home == :home") == true
      assert ev(":home == :work") == false
      assert ev(":home != :work") == true
    end

    test "ordering on numbers" do
      assert ev("2 > 1") == true
      assert ev("1 >= 1") == true
      assert ev("1 < 0") == false
    end

    test "ordering across incomparable types is :unknown, not a crash" do
      # Elixir would happily order an atom against a number; that is a rule
      # authoring mistake and must surface as unknown rather than a confident
      # wrong answer.
      assert ev(":home > 1") == :unknown
      assert ev("\"a\" > 1") == :unknown
    end

    test "arithmetic" do
      assert ev("2 + 3") == 5
      assert ev("10 / 4") == 2.5
    end

    test "division by zero is :unknown, not an exception" do
      assert ev("1 / 0") == :unknown
      assert ev("1 / 0.0") == :unknown
    end

    test "arithmetic on non-numbers is :unknown" do
      assert ev(":home + 1") == :unknown
    end

    test "membership" do
      assert ev(":a in [:a, :b]") == true
      assert ev(":c in [:a, :b]") == false
      assert ev(":a in 5") == :unknown
    end
  end

  describe "three-valued logic" do
    # The complete Kleene tables. These are the assertions that stop
    # "we do not know" from silently becoming "no" -- the exact defect that
    # made user_location's away path dead code in production.
    test "and" do
      assert ev("true and true") == true
      assert ev("true and false") == false
      assert ev("false and true") == false
      assert ev("false and false") == false
      assert ev("true and unknown.x", with_facts(%{})) == :unknown
      assert ev("false and unknown.x", with_facts(%{})) == false
      assert ev("unknown.x and true", with_facts(%{})) == :unknown
      assert ev("unknown.x and false", with_facts(%{})) == false
    end

    test "or" do
      assert ev("true or true") == true
      assert ev("true or false") == true
      assert ev("false or true") == true
      assert ev("false or false") == false
      assert ev("true or unknown.x", with_facts(%{})) == true
      assert ev("false or unknown.x", with_facts(%{})) == :unknown
      assert ev("unknown.x or true", with_facts(%{})) == true
      assert ev("unknown.x or false", with_facts(%{})) == :unknown
    end

    test "not" do
      assert ev("not true") == false
      assert ev("not false") == true
      assert ev("not unknown.x", with_facts(%{})) == :unknown
    end

    test "comparison against an unknown is unknown, never false" do
      # If this returned false, "the car is not home" would be true whenever
      # we had simply lost track of the car.
      env = with_facts(%{})
      assert ev("a.b == :home", env) == :unknown
      assert ev("a.b != :home", env) == :unknown
    end

    test "a guard fires only on literal true" do
      assert Expr.truthy?(true)
      refute Expr.truthy?(false)
      refute Expr.truthy?(:unknown)
      refute Expr.truthy?(nil)
      refute Expr.truthy?("yes")
      refute Expr.truthy?(1)
    end
  end

  describe "fact reads" do
    test "dotted paths resolve through the environment" do
      env = with_facts(%{[:person, :cal, :zone] => :home})
      assert ev("person.cal.zone", env) == :home
      assert ev("person.cal.zone == :home", env) == true
    end

    test "a bare identifier is a one-segment path" do
      env = with_facts(%{[:mode] => :night})
      assert ev("mode", env) == :night
      assert ev("mode == :night", env) == true
    end

    test "the user's own example expression" do
      env =
        with_facts(%{
          [:person, :cal, :zone] => :home,
          [:vehicle, :car, :zone] => :work
        })

      assert ev("person.cal.zone == :home and vehicle.car.zone != :home", env) == true
    end

    test "an absent fact yields :unknown, and the example does not fire on it" do
      env = with_facts(%{[:person, :cal, :zone] => :home})
      assert ev("person.cal.zone == :home and vehicle.car.zone != :home", env) == :unknown
      refute Expr.truthy?(ev("person.cal.zone == :home and vehicle.car.zone != :home", env))
    end
  end

  describe "scoped reads" do
    test "trigger.value and trigger.prev" do
      env = %{trigger: %{value: :open, prev: :closed}}
      assert ev("trigger.value", env) == :open
      assert ev("trigger.prev", env) == :closed
    end

    test "trigger captures are reachable by name" do
      env = %{trigger: %{captures: %{"room" => "office"}}}
      assert ev("trigger.room", env) == "office"
    end

    test "local slots" do
      env = %{locals: %{desired: :on}}
      assert ev("local.desired == :on", env) == true
    end

    test "a missing local is :unknown" do
      assert ev("local.nope", %{locals: %{}}) == :unknown
    end
  end

  describe "builtins" do
    test "if/3 short-circuits and refuses to guess" do
      assert ev("if(true, :a, :b)") == :a
      assert ev("if(false, :a, :b)") == :b
      assert ev("if(unknown.x, :a, :b)", with_facts(%{})) == :unknown
    end

    test "defined?/1" do
      env = with_facts(%{[:a] => :v, [:b] => nil})
      assert ev("defined?(a)", env) == true
      assert ev("defined?(b)", env) == false
      assert ev("defined?(missing)", env) == false
    end

    test "unknown?/1" do
      env = with_facts(%{[:a] => :v})
      assert ev("unknown?(a)", env) == false
      assert ev("unknown?(missing)", env) == true
    end

    test "group aggregates over declared membership" do
      env = %{
        read: fn
          [:lamp, :one] -> :on
          [:lamp, :two] -> :on
          _ -> :unknown
        end,
        group: fn :lamps -> [[:lamp, :one], [:lamp, :two]] end
      }

      assert ev("all_eq?(:lamps, :on)", env) == true
      assert ev("any_eq?(:lamps, :off)", env) == false
      assert ev("count_eq(:lamps, :on)", env) == 2
    end

    test "the lamp toggle rule, exactly as the Python computed it" do
      # target OFF only when BOTH are ON; otherwise ON.
      mixed = %{
        read: fn
          [:lamp, :one] -> :on
          [:lamp, :two] -> :off
          _ -> :unknown
        end,
        group: fn :lamps -> [[:lamp, :one], [:lamp, :two]] end
      }

      source = "if(all_eq?(:lamps, :on), :off, :on)"
      assert ev(source, mixed) == :on

      both_on = put_in(mixed.read, fn _ -> :on end)
      assert ev(source, both_on) == :off

      both_off = put_in(mixed.read, fn _ -> :off end)
      assert ev(source, both_off) == :on
    end

    test "an empty group is :unknown, not vacuously true" do
      # all_eq? over nothing must not fire a rule. A typo'd group name would
      # otherwise silently satisfy every guard that used it.
      env = %{read: fn _ -> :unknown end, group: fn _ -> [] end}
      assert ev("all_eq?(:nope, :on)", env) == :unknown
    end

    test "an unknown member makes the aggregate unknown" do
      env = %{
        read: fn
          [:lamp, :one] -> :on
          _ -> :unknown
        end,
        group: fn :lamps -> [[:lamp, :one], [:lamp, :two]] end
      }

      assert ev("all_eq?(:lamps, :on)", env) == :unknown
    end

    test "distance and within? over geopoints" do
      env = with_facts(%{[:a] => {0.0, 0.0}, [:b] => {0.0, 1.0}})
      assert_in_delta ev("distance(a, b)", env), 111_194.9, 1.0
      assert ev("within?(a, b, 200000)", env) == true
      assert ev("within?(a, b, 1000)", env) == false
    end

    test "to_s and abs" do
      assert ev("to_s(:home)") == "home"
      assert ev("abs(0 - 5)") == 5
      assert ev("abs(:home)") == :unknown
    end
  end

  describe "the whitelist refuses" do
    # What is refused matters more than what is allowed: an accepted-but-
    # unlisted form is an escape from the sandbox, not a missing feature.
    test "module calls" do
      assert {:error, _} = Expr.compile("System.cmd(\"rm\", [\"-rf\", \"/\"])")
      assert {:error, _} = Expr.compile("File.read!(\"/etc/passwd\")")
      assert {:error, _} = Expr.compile(~S|:os.cmd(~c"id")|)
    end

    test "anonymous functions" do
      assert {:error, _} = Expr.compile("fn -> 1 end")
    end

    test "comprehensions — the only way to loop" do
      assert {:error, _} = Expr.compile("for x <- [1,2], do: x")
    end

    test "case, cond and with" do
      assert {:error, _} = Expr.compile("case 1 do _ -> 2 end")
      assert {:error, _} = Expr.compile("cond do true -> 1 end")
    end

    test "assignment" do
      assert {:error, _} = Expr.compile("x = 1")
    end

    test "pipes into unlisted functions" do
      assert {:error, _} = Expr.compile("1 |> IO.inspect()")
    end

    test "string interpolation" do
      assert {:error, _} = Expr.compile(~S|"#{System.get_env("HOME")}"|)
    end

    test "an unknown function names itself in the error" do
      assert {:error, {:unknown_function, :frobnicate, 1, _}} = Expr.compile("frobnicate(1)")
    end

    test "a builtin called at the wrong arity" do
      assert {:error, {:wrong_arity, :if, 2, _}} = Expr.compile("if(true, 1)")
    end

    test "a syntax error is reported, not raised" do
      assert {:error, {:parse_error, _}} = Expr.compile("1 +")
    end
  end

  describe "dependency extraction" do
    test "collects every fact path read" do
      {:ok, expr} = Expr.compile("person.cal.zone == :home and vehicle.car.zone != :home")

      assert Enum.sort(Expr.deps(expr)) == [
               [:person, :cal, :zone],
               [:vehicle, :car, :zone]
             ]
    end

    test "reaches inside builtin arguments" do
      {:ok, expr} = Expr.compile("if(defined?(a.b), c.d, e.f)")
      assert Enum.sort(Expr.deps(expr)) == [[:a, :b], [:c, :d], [:e, :f]]
    end

    test "scoped reads are not fact dependencies" do
      # Subscribing to trigger.value would be meaningless; it arrives with the
      # trigger rather than being read from the world.
      {:ok, expr} = Expr.compile("trigger.value == :open and local.armed")
      assert Expr.deps(expr) == []
    end
  end

  describe "the builtin budget" do
    test "is under the documented ceiling" do
      # The guardrail against this becoming a programming language. If this
      # fails, the answer is to write a module, not to raise the number.
      assert Expr.builtin_count() <= Expr.builtin_budget()
    end
  end

  describe "properties" do
    property "a guard never yields anything but true, false or :unknown" do
      sources = [
        "a.b == :x",
        "a.b != :x",
        "not (a.b == :x)",
        "a.b == :x and c.d == :y",
        "a.b == :x or c.d == :y",
        "defined?(a.b)",
        "unknown?(a.b)"
      ]

      check all source <- StreamData.member_of(sources),
                av <- StreamData.member_of([:unknown, :x, :y, nil]),
                cv <- StreamData.member_of([:unknown, :x, :y, nil]) do
        env = %{read: fn
                  [:a, :b] -> av
                  [:c, :d] -> cv
                  _ -> :unknown
                end}

        assert ev(source, env) in [true, false, :unknown]
      end
    end
  end

  describe "scoped reads that are not well-formed" do
    test "a single-key scoped read compiles" do
      assert {:ok, _} = Expr.compile("local.x")
      assert {:ok, _} = Expr.compile("trigger.value")
    end

    # These used to compile into a closure that raised when the rule ran, so a
    # typo in a guard became a rule that was skipped forever and logged once
    # per event -- a config error presenting as a mysteriously inert house.
    # A bad expression must fail at boot, like every other bad config.
    test "a multi-segment scoped read is refused at compile time" do
      for source <- ["local.a.b", "trigger.x.y", "local.a.b.c"] do
        assert {:error, {:bad_scoped_read, _}} = Expr.compile(source),
               "#{source} compiled instead of being refused"
      end
    end

    test "the refusal names what was wrong" do
      assert {:error, {:bad_scoped_read, text}} = Expr.compile("trigger.x.y")
      assert text =~ "trigger.x.y"
    end

    # A dotted path that is NOT scoped is an ordinary fact read of any depth,
    # and must keep working -- the fix must not have narrowed those too.
    test "ordinary fact paths of any depth still compile" do
      assert {:ok, _} = Expr.compile("a.b.c.d.e")
      assert {:ok, _} = Expr.compile("person.cal.zone")
    end
  end

  describe "comparing against the literal :unknown" do
    # The trap: every operator propagates :unknown, so `x != :unknown` is
    # ALWAYS :unknown and a guard written that way never fires. It reads
    # perfectly, compiles, loads, and silently disables the rule -- which is
    # exactly what it did to the intruder latch.
    test "== :unknown is refused, and says what to use instead" do
      assert {:error, {:unknown_literal_comparison, _, msg}} =
               Expr.compile("person.cal.zone == :unknown")

      assert msg =~ "unknown?(x)"
      assert msg =~ "never be true"
    end

    test "!= :unknown is refused, and points at defined?" do
      assert {:error, {:unknown_literal_comparison, _, msg}} =
               Expr.compile("person.cal.zone != :unknown")

      assert msg =~ "defined?(x)"
    end

    test "refused on either side of the operator" do
      assert {:error, {:unknown_literal_comparison, _, _}} =
               Expr.compile(":unknown == person.cal.zone")
    end

    test "refused inside a larger expression" do
      # Where it actually appeared: a conjunction whose other half is fine.
      assert {:error, {:unknown_literal_comparison, _, _}} =
               Expr.compile("person.cal.zone != :home and person.cal.zone != :unknown")
    end

    # The replacements must work, or the refusal is just an obstruction.
    test "defined? and unknown? do what the refused form was reaching for" do
      env = %{read: fn _ -> :unknown end, trigger: %{}, locals: %{}, group: fn _ -> [] end}
      known = %{read: fn _ -> :workshop end, trigger: %{}, locals: %{}, group: fn _ -> [] end}

      {:ok, is_def} = Expr.compile("defined?(person.cal.zone)")
      {:ok, is_unk} = Expr.compile("unknown?(person.cal.zone)")

      assert Expr.eval(is_def, env) == false
      assert Expr.eval(is_unk, env) == true
      assert Expr.eval(is_def, known) == true
      assert Expr.eval(is_unk, known) == false
    end

    test "the guard the latch actually uses fires when out and declines when lost" do
      {:ok, guard} = Expr.compile("defined?(person.cal.zone) and person.cal.zone != :home")

      env = fn zone ->
        %{read: fn _ -> zone end, trigger: %{}, locals: %{}, group: fn _ -> [] end}
      end

      assert Expr.truthy?(Expr.eval(guard, env.(:away))), "would not alert while out"
      assert Expr.truthy?(Expr.eval(guard, env.(:workshop))), "would not alert at the workshop"
      refute Expr.truthy?(Expr.eval(guard, env.(:home))), "would alert while home"
      refute Expr.truthy?(Expr.eval(guard, env.(:unknown))), "would alert with no fix"
    end

    test "an `in` list containing :unknown is refused for the same reason" do
      # Less visible than `==` and identically broken: if x IS :unknown the
      # propagation answers :unknown, so the membership test can never be true
      # for the one value it was written to catch.
      assert {:error, {:unknown_literal_comparison, _, _}} =
               Expr.compile("person.cal.zone in [:home, :unknown]")
    end

    test "an `in` list of ordinary atoms still compiles and works" do
      {:ok, expr} = Expr.compile("person.cal.zone in [:home, :workshop]")

      env = fn zone ->
        %{read: fn _ -> zone end, trigger: %{}, locals: %{}, group: fn _ -> [] end}
      end

      assert Expr.eval(expr, env.(:home)) == true
      assert Expr.eval(expr, env.(:away)) == false
    end

    # Comparing against other atoms is untouched.
    test "comparing against ordinary atoms still compiles" do
      assert {:ok, _} = Expr.compile("person.cal.zone == :home")
      assert {:ok, _} = Expr.compile("person.cal.zone != :away")
    end
  end
end
