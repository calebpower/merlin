defmodule Merlin.ConfigSourceTest do
  @moduledoc """
  Tier 3: source-as-data.

  The question this tier answers that no cheaper one can: is the *declared*
  configuration structurally sound, independent of whether anything has run it.
  It asserts against the shipped file itself rather than against a fixture or a
  re-export of it, which is the whole point -- a test that validates a copy
  proves the copy.

  This is also the boot validator, run as a test. If it passes here it will not
  halt the daemon at boot, and if it fails here the daemon would have refused
  to start -- which is the behaviour `main.py` lacked when it swallowed config
  errors and started a daemon that quietly did nothing.
  """

  use ExUnit.Case, async: true

  @moduletag :tier3

  alias Merlin.Config

  # A stateless rule keeps its actions at the top level; a machine keeps them
  # inside each clause of each state. Tests that assert over "every rule" have
  # to know that, or they quietly stop covering half the rules.
  defp actions_of(%Merlin.Rule{actions: actions}), do: actions

  defp actions_of(%Merlin.Machine{states: states}) do
    for {_state, clauses} <- states,
        %Merlin.Machine.Clause{actions: actions} <- clauses,
        action <- actions,
        do: action
  end

  defp watches_any?(%Merlin.Rule{} = r), do: r.watches != [] or r.watch_events != []
  defp watches_any?(%Merlin.Machine{} = m), do: m.watches != [] or m.watch_events != []

  # The real file, not a fixture.
  @config_path Path.expand("../../priv/merlin.exs", __DIR__)

  setup_all do
    assert File.exists?(@config_path), "shipped config is missing: #{@config_path}"
    {:ok, config} = Config.File.load(@config_path)
    {raw, _bindings} = Code.eval_file(@config_path)
    %{config: config, raw: raw}
  end

  describe "the shipped configuration" do
    test "loads and validates", %{config: config} do
      assert is_map(config)
    end

    test "is plain data — no functions, pids or refs", %{raw: raw} do
      # Asserted against the term the file actually evaluates to. The file is
      # executable by construction, so this is what stops behaviour being
      # smuggled past validation and into the engine.
      assert {:ok, _} = Config.File.validate(raw)
    end

    test "every rule commands a group that exists", %{config: config} do
      group_ids = Map.keys(config.groups)

      for rule <- config.rules, {:set_group, group, _} <- actions_of(rule) do
        assert group in group_ids,
               "rule #{rule.id} commands unknown group #{inspect(group)}"
      end
    end

    test "every group has members and a set topic", %{config: config} do
      for {id, group} <- config.groups do
        assert group.members != [], "group #{id} has no members"
        assert is_binary(group.set_topic), "group #{id} has no set_topic"
      end
    end

    test "every source topic is a compilable MQTT filter", %{config: config} do
      for source <- config.sources do
        assert {:ok, _} = Merlin.MQTT.Router.add(Merlin.MQTT.Router.new(), source.topic, source.id)
      end
    end

    test "every source topic yields a wire-legal subscription", %{config: config} do
      # What actually goes to the broker. A named capture reaching a SUBSCRIBE
      # is rejected as a malformed packet and the connection is dropped, with
      # nothing in the client's own logs to say why.
      for source <- config.sources do
        wire = Merlin.MQTT.Router.wire_filter(source.topic)

        for segment <- String.split(wire, "/") do
          assert segment == "+" or not String.starts_with?(segment, "+"),
                 "source #{source.id}: #{source.topic} -> illegal wire segment #{inspect(segment)}"
        end
      end
    end

    test "no source subscribes to everything", %{config: config} do
      # The defect the whole adapter layer exists to retire. main.py subscribed
      # to `#` and fanned every message on the broker out to twelve hooks.
      for source <- config.sources do
        refute source.topic == "#", "source #{source.id} subscribes to '#'"
      end
    end

    test "source ids and rule ids are unique", %{config: config} do
      source_ids = Enum.map(config.sources, & &1.id)
      rule_ids = Enum.map(config.rules, & &1.id)

      assert length(Enum.uniq(source_ids)) == length(source_ids), "duplicate source id"
      assert length(Enum.uniq(rule_ids)) == length(rule_ids), "duplicate rule id"
    end

    test "both rule shapes are present in the shipped config", %{config: config} do
      # If this ever fails, the assertions below have quietly stopped covering
      # one of the two shapes -- which is how a whole class of rule ends up
      # untested without anyone noticing.
      assert Enum.any?(config.rules, &match?(%Merlin.Rule{}, &1)), "no stateless rules"
      assert Enum.any?(config.rules, &match?(%Merlin.Machine{}, &1)), "no machines"
    end

    test "every rule has a description", %{config: config} do
      # The description is the English sentence the rule claims to implement.
      # A rule nobody could describe is a rule nobody can review.
      for rule <- config.rules do
        assert is_binary(rule.desc) and rule.desc != "",
               "rule #{rule.id} has no description"
      end
    end

    test "every rule watches something", %{config: config} do
      for rule <- config.rules do
        assert watches_any?(rule), "rule #{rule.id} watches nothing and can never fire"
      end
    end

    test "ships with dry_run enabled", %{config: config} do
      # Deliberate. The first thing this daemon does against the real broker
      # should be to say what it would have done. Three of the rules it
      # replaces have never executed in production.
      assert config.dry_run == true,
             "the shipped config must dry-run; flip it at cutover, not in the repo"
    end
  end

  describe "the validator refuses bad configurations" do
    # The invalid cases are the half that matters: a validator whose rejections
    # have never been observed is a validator nobody has checked.
    test "a rule commanding an unknown group" do
      config = %{
        groups: [],
        rules: [%{id: :r, desc: "x", on: [{:changes, [:a]}], do: [{:set_group, :nope, :off}]}]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:unknown_group, :r, :nope, _}, &1))
    end

    test "a rule with a guard that will not compile" do
      config = %{
        groups: [],
        rules: [
          %{id: :r, desc: "x", on: [{:changes, [:a]}], when: "System.cmd(\"x\", [])", do: [{:log, :info, "hi"}]}
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:r, {:bad_guard, _, _}}, &1))
    end

    test "a rule with no triggers can never fire" do
      config = %{groups: [], rules: [%{id: :r, desc: "x", on: [], do: [{:log, :info, "hi"}]}]}
      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:r, :no_triggers}, &1))
    end

    test "a source with an invalid topic filter" do
      config = %{sources: [%{id: :s, topic: "a/#/b"}], groups: [], rules: []}
      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:bad_topic_filter, :s, _, _}, &1))
    end

    test "a group with no members" do
      config = %{groups: [%{id: :g, set_topic: "t", members: []}], rules: []}
      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:group_has_no_members, :g}, &1))
    end

    test "a config containing a function is refused" do
      # The plain-data assertion. Not a sandbox -- the file has already run by
      # this point -- but it stops a closure reaching the engine.
      config = %{groups: [], rules: [], sources: [], callback: fn -> :boom end}
      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:not_plain_data, _}, &1))
    end

    test "errors are collected, not reported one at a time" do
      config = %{
        groups: [%{id: :g, set_topic: "t", members: []}],
        sources: [%{id: :s, topic: "a/#/b"}],
        rules: []
      }

      assert {:error, errors} = Config.File.validate(config)
      assert length(errors) >= 2, "a boot report naming one of several problems costs a restart each"
    end

    test "a missing file is an error, not an empty config" do
      assert {:error, [{:missing_file, _}]} = Config.File.load("/nonexistent/merlin.exs")
    end
  end
end
