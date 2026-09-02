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

  # watch_groups counts. A rule whose only trigger is {:changes_in, group}
  # subscribes through the group's members and has no watches of its own, so
  # omitting it here would report a live rule as one that can never fire.
  defp watches_any?(%Merlin.Rule{} = r),
    do: r.watches != [] or r.watch_events != [] or r.watch_groups != []

  defp watches_any?(%Merlin.Machine{} = m),
    do: m.watches != [] or m.watch_events != [] or m.watch_groups != []

  defp triggers_of(%Merlin.Rule{triggers: triggers}), do: triggers

  defp triggers_of(%Merlin.Machine{states: states}) do
    for {_state, clauses} <- states,
        %Merlin.Machine.Clause{trigger: trigger} <- clauses,
        do: trigger
  end

  # The real file, not a fixture.
  @config_path Path.expand("../../priv/example.exs", __DIR__)

  # The shipped config references secrets it does not contain -- that is the
  # point of the split. These placeholders let the structural assertions run;
  # separate tests below prove the validator DOES refuse a config whose
  # secrets are missing.
  @secrets %{
    hapn_auth_endpoint: "https://example/token",
    hapn_device_endpoint: "https://example/device",
    hapn_client_id: "id",
    hapn_client_secret: "secret",
    weather_endpoint: "https://example/weather",
    weather_api_key: "key",
    discord_webhook: "https://example/webhook"
  }

  # Reinstalled before EVERY test, not once in setup_all. Secrets live in
  # :persistent_term, which is global: a test that deliberately empties them
  # would otherwise corrupt whichever tests ExUnit shuffled after it, and the
  # failure would move with the seed. Per-test restoration confines the blast
  # radius to the test that asked for it.
  setup do
    Merlin.Secrets.put(@secrets)
    on_exit(fn -> Merlin.Secrets.put(@secrets) end)
    :ok
  end

  setup_all do
    assert File.exists?(@config_path), "shipped config is missing: #{@config_path}"
    Merlin.Secrets.put(@secrets)

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

    test "every group has members", %{config: config} do
      for {id, group} <- config.groups do
        assert group.members != [], "group #{id} has no members"
      end
    end

    test "every group a rule commands declares somewhere to publish", %{config: config} do
      # set_topic is optional, because a group is a named SET of facts first
      # and a command target second -- :exterior_doors has members and nothing
      # to publish to. What must hold is the pairing: anything commanded has a
      # topic.
      for rule <- config.rules, {:set_group, group, _} <- actions_of(rule) do
        assert is_binary(config.groups[group][:set_topic]),
               "rule #{rule.id} commands #{inspect(group)}, which has no set_topic"
      end
    end

    test "every group a rule triggers on exists", %{config: config} do
      for rule <- config.rules, {:changes_in, group} <- triggers_of(rule) do
        assert Map.has_key?(config.groups, group),
               "rule #{rule.id} triggers on unknown group #{inspect(group)}"
      end
    end

    test "the intruder latch selects doors by name, not by prefix", %{config: config} do
      # The regression this whole change exists to prevent. Under
      # {:changes_under, [:door]} the latch alarmed on the bedroom and office
      # doors, because interior and exterior doors have identically shaped
      # paths and a prefix can only select on shape.
      latch = Enum.find(config.rules, &(&1.id == :intruder_latch))
      triggers = triggers_of(latch)

      refute {:changes_under, [:door]} in triggers,
             "the latch is back on the bare [:door] prefix: it will alarm on interior doors"

      assert Enum.any?(triggers, &match?({:changes_in, _}, &1)),
             "the intruder latch no longer names a group of doors"
    end

    test "the exterior door group holds door contacts", %{config: config} do
      members = config.groups[:exterior_doors][:members]

      assert members != []

      for path <- members do
        assert match?([:door, _room, :contact], path),
               "#{inspect(path)} is in :exterior_doors but is not a door contact"
      end

      # A group listing every door is the prefix trigger wearing a different
      # hat, and it would pass every other assertion here.
      doors_source = Enum.find(config.sources, &(&1.id == :doors))

      assert doors_source,
             "the exterior door group is meaningless without the source that produces doors"
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

    test "the vehicle poller declares every field the endpoint actually returns", %{
      config: config
    } do
      # Nine, not ten. `batteryPercentage` came from hapn_tracker.py and is not
      # in the API's response at all -- the field list was read from the code
      # rather than from the endpoint.
      hapn = Enum.find(config.derived, &(&1.id == :hapn))
      assert hapn, "the vehicle poller is missing"

      assert {:ok, paths} = Config.File.produced_paths(hapn)

      for leaf <- [
            :lat,
            :lon,
            :accuracy_m,
            :heading_deg,
            :odometer_mi,
            :speed_mph,
            :fix_at,
            :reported_at,
            :address
          ] do
        assert [:vehicle, :car, leaf] in paths, "vehicle.car.#{leaf} is not declared"
      end
    end

    # The defect that made the whole vehicle half inert: HAPN sends every
    # number as a JSON string, the geofence requires numbers, so the zone was
    # permanently :unknown and no vehicle rule could ever fire.
    test "every field the geofence needs is decoded to a number", %{config: config} do
      hapn = Enum.find(config.derived, &(&1.id == :hapn))

      numeric = [:lat, :lon, :accuracy_m, :heading_deg, :odometer_mi, :speed_mph]

      for leaf <- numeric do
        spec = Enum.find(hapn.facts, &(&1.path == [:vehicle, :car, leaf]))
        assert spec, "vehicle.car.#{leaf} is not declared"

        assert Map.get(spec, :codec) in [:float, :integer],
               "vehicle.car.#{leaf} has no numeric codec, so it would land as a string " <>
                 "and the geofence would never resolve a zone"
      end
    end

    test "a geofence's coordinate sources are all numerically decoded", %{config: config} do
      # Generalised: for any geofence, whatever produces its lat and lon must
      # decode to a number. Otherwise the fence silently never resolves.
      producers =
        for d <- config.derived,
            Map.get(d, :kind) == :http_poll,
            f <- Map.get(d, :facts, []),
            into: %{},
            do: {f.path, Map.get(f, :codec)}

      for d <- config.derived, Map.get(d, :kind) == :geofence do
        for path <- [d.lat, d.lon], Map.has_key?(producers, path) do
          assert producers[path] in [:float, :integer],
                 "#{d.id} reads #{Merlin.Path.to_string(path)}, which is produced without a " <>
                   "numeric codec -- the fence would never resolve"
        end
      end
    end

    test "every poller sets stale_after_ms", %{config: config} do
      # A poller without it freezes its last reading forever on failure, which
      # is exactly how the Python reported the car parked at home while it was
      # being driven away. Staleness must be an honest :unknown.
      for d <- config.derived, d.kind == :http_poll do
        assert is_integer(Map.get(d, :stale_after_ms)),
               "poller #{d.id} would freeze its facts on failure"
      end
    end

    test "every secret the shipped config references is in the example file", %{raw: raw} do
      # Otherwise the first thing a fresh install learns is that the example
      # is incomplete, one missing key per restart.
      example = Path.join(Path.dirname(@config_path), "merlin.secrets.exs.example")
      assert File.exists?(example), "the secrets example is missing"

      {defined, _} = Code.eval_file(example)

      for name <- Enum.uniq(Merlin.Secrets.referenced(raw)) do
        assert Map.has_key?(defined, name), "secret #{inspect(name)} is not in the example file"
      end
    end

    test "the example's zones are coherent with each other", %{config: config} do
      # The real house's config had coordinates in the wrong STATE -- plausible
      # numbers, hundreds of miles from anything -- and every presence rule
      # read :unknown for ever without a word of complaint.
      #
      # A shipped example cannot assert "near the house" because it has no
      # house. It can assert the property that actually broke: the zones must
      # be near ONE ANOTHER, on the scale a person travels between them. Two
      # zones a thousand miles apart are a copy-paste accident, and so is a
      # zone at {0, 0}.
      zones = config.zones
      assert map_size(zones) >= 2, "the example should show more than one zone"

      centres = Enum.map(zones, fn {_id, z} -> z.center end)

      for {lat, lon} <- centres do
        refute {lat, lon} == {0.0, 0.0}, "a zone sits at null island"
        assert lat >= -90.0 and lat <= 90.0, "latitude #{lat} is not a latitude"
        assert lon >= -180.0 and lon <= 180.0, "longitude #{lon} is not a longitude"
      end

      for a <- centres, b <- centres, a != b do
        km = Merlin.Geo.distance(a, b) / 1000

        assert km < 200,
               "two zones are #{round(km)} km apart, which is not a house and the places " <>
                 "its occupant goes -- the likeliest cause is coordinates copied from " <>
                 "somewhere else entirely"
      end
    end

    test "declares what survives a restart", %{config: config} do
      prefixes = Merlin.Config.persisted_prefixes(config)

      # Presence and vehicle position: nothing else can tell us these again.
      assert [:person] in prefixes
      assert [:vehicle] in prefixes

      # The latch, contributed by the machine's own persist: true rather than
      # by a second list someone has to remember to edit.
      assert [:rule, :intruder_latch] in prefixes

      # Device state is NOT persisted -- retained messages are the broker's
      # job, and a second copy would only ever be the stale one.
      refute Enum.any?(prefixes, &Merlin.Path.prefix?(&1, [:climate, :office, :power]))
      refute Enum.any?(prefixes, &Merlin.Path.prefix?(&1, [:door, "garage", :contact]))

      assert config[:settle_ms] > 0, "the settle window is switched off in the shipped config"
    end

    test "a latch declares itself persistent", %{config: config} do
      # A latch that re-arms on restart is not a latch, and nothing else in the
      # system would report that it had silently stopped being one.
      latch = Enum.find(config.rules, &(&1.id == :intruder_latch))
      assert %Merlin.Machine{persist: true} = latch
    end

    # Behaviour, not text. These evaluate the expressions the shipped config
    # actually contains against a world built to be the dangerous case, which
    # is the only way to assert what a rule will not do. Checking the compute
    # string would pass for a rule that says the right words and means
    # something else.
    defp env_with(facts) do
      %{
        read: fn path -> Map.get(facts, path, :unknown) end,
        trigger: %{},
        group: fn _ -> [] end,
        locals: %{}
      }
    end

    defp guards_of(%Merlin.Machine{states: states}, state) do
      for %Merlin.Machine.Clause{guard: g} <- Map.fetch!(states, state), g != nil, do: g
    end

    test "the intruder latch does not fire when the phone is unlocatable", %{config: config} do
      latch = Enum.find(config.rules, &(&1.id == :intruder_latch))
      guards = guards_of(latch, :armed)
      assert guards != [], "the armed state has no guard at all -- it would fire on any door"

      for guard <- guards do
        for zone <- [:unknown, nil] do
          refute Merlin.Expr.truthy?(Merlin.Expr.eval(guard, env_with(%{[:person, :owner, :zone] => zone}))),
                 "a door moving with the phone at #{inspect(zone)} would raise an intruder alert"
        end
      end
    end

    test "the intruder latch DOES fire when the phone is demonstrably out", %{config: config} do
      # The other half. A guard that never fires satisfies the test above
      # perfectly, and is exactly what the house had before :away existed.
      latch = Enum.find(config.rules, &(&1.id == :intruder_latch))
      [guard] = guards_of(latch, :armed)

      for zone <- [:away, :workshop] do
        assert Merlin.Expr.truthy?(Merlin.Expr.eval(guard, env_with(%{[:person, :owner, :zone] => zone}))),
               "a door moving while at #{inspect(zone)} would NOT alert"
      end

      refute Merlin.Expr.truthy?(Merlin.Expr.eval(guard, env_with(%{[:person, :owner, :zone] => :home}))),
             "a door moving while home would alert"
    end

    # Stronger than "does not fire": the fact must SAY it does not know.
    #
    # A rule reading `false` cannot tell "we checked and the car is fine" from
    # "the tracker is dark". Both suppress the alert, so a behavioural test
    # alone passes either way -- which is exactly why the mutation check
    # survived until this assertion existed. The dashboard at M9 will render
    # this value, and rendering "no" for "no idea" is how a display lies.
    test "away_while_home? reads :unknown on a dark tracker, not false", %{raw: raw} do
      spec = Enum.find(Map.get(raw, :derived, []), &(Map.get(&1, :id) == :vehicle_away_while_home))
      {:ok, expr} = Merlin.Expr.compile(spec.compute)

      dark =
        env_with(%{
          [:person, :owner, :zone] => :home,
          [:vehicle, :car, :zone] => :unknown
        })

      assert Merlin.Expr.eval(expr, dark) == :unknown,
             "the daemon claimed to know the car was not away while the tracker was dark"

      # And it still answers plainly when it can see the car.
      seen =
        env_with(%{
          [:person, :owner, :zone] => :home,
          [:vehicle, :car, :zone] => :away
        })

      assert Merlin.Expr.eval(expr, seen) == true

      home =
        env_with(%{
          [:person, :owner, :zone] => :home,
          [:vehicle, :car, :zone] => :home
        })

      assert Merlin.Expr.eval(expr, home) == false
    end

    test "unaccounted? reads :unknown on a dark tracker too", %{raw: raw} do
      spec = Enum.find(Map.get(raw, :derived, []), &(Map.get(&1, :id) == :vehicle_unaccounted))
      {:ok, expr} = Merlin.Expr.compile(spec.compute)

      dark =
        env_with(%{
          [:vehicle, :car, :zone] => :unknown,
          [:vehicle, :car, :with_phone?] => false
        })

      assert Merlin.Expr.eval(expr, dark) == :unknown
    end

    test "the vehicle rules do not fire on a dead tracker", %{raw: raw} do
      # `unknown?(zone)` used to mean "unaccounted for", so a tracker outage
      # read as a possible theft. Both rules must now decline on :unknown.
      for id <- [:vehicle_unaccounted, :vehicle_away_while_home] do
        spec = Enum.find(Map.get(raw, :derived, []), &(Map.get(&1, :id) == id))
        assert spec, "#{id} is missing from the shipped config"

        {:ok, expr} = Merlin.Expr.compile(spec.compute)

        env =
          env_with(%{
            [:person, :owner, :zone] => :home,
            [:vehicle, :car, :zone] => :unknown,
            [:vehicle, :car, :with_phone?] => false
          })

        refute Merlin.Expr.truthy?(Merlin.Expr.eval(expr, env)),
               "#{id} fires on a tracker that has gone dark"
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

    # stale_after_ms is the only thing standing between a dead battery and a
    # daemon that keeps acting on the last thing a sensor said. A typo that
    # silently meant "no horizon" would remove exactly the check it was added
    # for, and the house would look identical either way -- so a bad value has
    # to refuse to boot rather than be ignored.
    test "a source with a nonsense stale_after_ms is refused" do
      # "1h" is the plausible typo; 0 and -5 are horizons no fact can satisfy;
      # 1.5 is milliseconds someone thought were seconds.
      for bad <- ["1h", 0, -5, 1.5, :never] do
        config = %{sources: [%{id: :s, topic: "a/b", stale_after_ms: bad}], groups: [], rules: []}

        assert {:error, errors} = Config.File.validate(config),
               "stale_after_ms: #{inspect(bad)} was accepted"

        assert Enum.any?(errors, &match?({:source_bad_stale_after, :s, ^bad}, &1)),
               "stale_after_ms: #{inspect(bad)} produced no source_bad_stale_after error"
      end
    end

    # The control: a good value, and no value, must both pass. Without this the
    # test above is satisfied by a validator that rejects the key outright.
    test "a positive stale_after_ms, and its absence, both validate" do
      good = %{sources: [%{id: :s, topic: "a/b", stale_after_ms: 60_000}], groups: [], rules: []}
      absent = %{sources: [%{id: :s, topic: "a/b"}], groups: [], rules: []}

      for config <- [good, absent] do
        case Config.File.validate(config) do
          {:ok, _} ->
            :ok

          {:error, errors} ->
            refute Enum.any?(errors, &match?({:source_bad_stale_after, _, _}, &1)),
                   "a valid stale_after_ms was reported as bad: #{inspect(errors)}"
        end
      end
    end

    test "a rule triggering on an unknown group" do
      config = %{
        groups: [],
        rules: [
          %{id: :r, desc: "x", on: [{:changes_in, :nope}], do: [{:log, :info, "hi"}]}
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:unknown_group, :r, :nope, _}, &1))
    end

    test "a machine triggering on an unknown group is caught inside its clauses" do
      # A check that only walked top-level triggers would pass this, and the
      # intruder latch is a machine -- so the one rule this trigger was added
      # for would be the one rule the validator did not cover.
      config = %{
        groups: [],
        rules: [
          %{
            id: :m,
            desc: "x",
            machine: %{
              initial: :armed,
              states: %{
                armed: [%{on: {:changes_in, :nope}, do: [{:log, :info, "hi"}], goto: :armed}]
              }
            }
          }
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:unknown_group, :m, :nope, _}, &1))
    end

    test "commanding a group that declares no set_topic" do
      config = %{
        groups: [%{id: :set_only, members: [[:door, "front", :contact]]}],
        rules: [
          %{id: :r, desc: "x", on: [{:changes, [:a]}], do: [{:set_group, :set_only, :off}]}
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:group_not_commandable, :r, :set_only}, &1))
    end

    test "a group with no set_topic is fine when nothing commands it" do
      config = %{
        groups: [%{id: :set_only, members: [[:door, "front", :contact]]}],
        rules: [
          %{id: :r, desc: "x", on: [{:changes_in, :set_only}], do: [{:log, :info, "hi"}]}
        ],
        sources: []
      }

      assert {:ok, _} = Config.File.validate(config)
    end

    test "a set_topic that is not a string is still refused" do
      config = %{
        groups: [%{id: :g, set_topic: :not_a_topic, members: [[:a]]}],
        rules: []
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:group_bad_set_topic, :g, :not_a_topic}, &1))
    end

    test "a topic capture named after a built-in trigger key is refused" do
      # It would land in the captures map that Merlin.Expr consults only after
      # the built-in keys, so trigger.value would keep meaning the changed
      # value and the capture would be silently unreachable.
      config = %{
        sources: [%{id: :s, topic: "z2m/+value/state"}],
        groups: [],
        rules: []
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:capture_shadows_trigger_key, :s, "value"}, &1))
    end

    test "an ordinary capture name is accepted" do
      config = %{sources: [%{id: :s, topic: "z2m/+room/state"}], groups: [], rules: []}
      assert {:ok, _} = Config.File.validate(config)
    end

    test "a literal string that reads like an expression is refused" do
      # The mistake this catches was made while writing the door rules: the
      # {:expr, ...} wrapper was omitted, so the latch would have logged its
      # own source text -- quotes, operators and all -- and kept working.
      config = %{
        groups: [],
        rules: [
          %{
            id: :r,
            desc: "x",
            on: [{:changes, [:a]}],
            do: [{:notify, :log, "a door moved: to_s(trigger.room)"}]
          }
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:literal_looks_like_an_expression, :r, _}, &1))
    end

    test "the same string wrapped as an expression is accepted" do
      config = %{
        groups: [],
        sources: [],
        rules: [
          %{
            id: :r,
            desc: "x",
            on: [{:changes, [:a]}],
            do: [{:notify, :log, {:expr, "to_s(trigger.room, \"unnamed\")"}}]
          }
        ]
      }

      assert {:ok, _} = Config.File.validate(config)
    end

    test "an ordinary message is not flagged" do
      config = %{
        groups: [],
        sources: [],
        rules: [
          %{id: :r, desc: "x", on: [{:changes, [:a]}], do: [{:log, :info, "the door moved"}]}
        ]
      }

      assert {:ok, _} = Config.File.validate(config)
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

    test "a config referencing an undefined secret is refused" do
      # And every missing name is reported together: finding them one restart
      # at a time is how a cutover window gets eaten.
      Merlin.Secrets.put(%{})

      config = %{
        groups: [],
        rules: [],
        sources: [],
        derived: [
          %{id: :p, kind: :http_poll, out: [:x], request: [url: {:secret, :nope}]},
          %{id: :q, kind: :http_poll, out: [:y], request: [url: {:secret, :also_nope}]}
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.member?(errors, {:missing_secret, :nope})
      assert Enum.member?(errors, {:missing_secret, :also_nope})
    end

    test "two derived facts writing the same path are refused" do
      config = %{
        groups: [],
        rules: [],
        sources: [],
        derived: [
          %{id: :a, kind: :expr, out: [:x, :y], compute: "1"},
          %{id: :b, kind: :expr, out: [:x, :y], compute: "2"}
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert {:duplicate_producer, "x.y", [:a, :b]} in errors
    end

    test "a poller colliding with an expression is refused" do
      # The case that only exists because a poller declares many paths: the
      # collision is with ONE of ten, and reading the two declarations side by
      # side would not show it.
      config = %{
        groups: [],
        rules: [],
        sources: [],
        derived: [
          %{id: :e, kind: :expr, out: [:vehicle, :car, :lat], compute: "1"},
          %{
            id: :p,
            kind: :http_poll,
            request: [url: "https://example"],
            facts: [
              %{path: [:vehicle, :car, :lon], from: ["lon"]},
              %{path: [:vehicle, :car, :lat], from: ["lat"]}
            ]
          }
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert {:duplicate_producer, "vehicle.car.lat", [:e, :p]} in errors
      # ...and the path that does NOT collide is not reported.
      refute Enum.any?(errors, &match?({:duplicate_producer, "vehicle.car.lon", _}, &1))
    end

    test "a poller declaring no facts is refused" do
      # It would start, poll on schedule, decode the response and write
      # nothing -- a silent no-op that looks healthy in every log.
      config = %{
        groups: [],
        rules: [],
        sources: [],
        derived: [%{id: :p, kind: :http_poll, request: [url: "https://example"], facts: []}]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert {:derived_missing_out, :p} in errors
    end

    test "a typo'd top-level key is refused, with a suggestion" do
      # The silent-no-op defect, in the file that configures everything.
      # `persits:` would disable persistence and fail nowhere.
      config = %{groups: [], rules: [], sources: [], persits: [[:person]]}

      assert {:error, errors} = Config.File.validate(config)
      assert {:unknown_key, :persits, :persist} in errors
    end

    test "an unknown key with no near match still names the known ones" do
      config = %{groups: [], rules: [], sources: [], wombat: 1}

      assert {:error, errors} = Config.File.validate(config)
      assert {:unknown_key, :wombat, nil} in errors
      assert Config.File.format_errors(errors) =~ "Known keys:"
    end

    # The regression. @known_keys said `persist:` was legal and build/2 threw
    # it away, so the config validated, the daemon started, and nothing was
    # ever persisted. Nothing failed anywhere.
    test "every known key survives into the loaded config" do
      {:ok, built} = Config.File.validate(%{groups: [], rules: [], sources: []})

      for key <- Config.File.known_keys() do
        assert Map.has_key?(built, key),
               "#{inspect(key)} is a known key but build/2 drops it -- setting it would do nothing"
      end
    end

    test "a value set for a known key reaches the loaded config" do
      {:ok, built} =
        Config.File.validate(%{
          groups: [],
          rules: [],
          sources: [],
          persist: [[:person]],
          settle_ms: 4321,
          api: %{port: 9999}
        })

      assert built[:persist] == [[:person]]
      assert built[:settle_ms] == 4321
      assert built[:api] == %{port: 9999}
    end

    test "every key the shipped config uses is a known key", %{} do
      # The inverse direction: the validator's list and the shipped file must
      # agree, or one of them is out of date and the check is theatre.
      {raw, _} = Code.eval_file(@config_path)

      for key <- Map.keys(raw) do
        assert key in Config.File.known_keys(),
               "the shipped config uses #{inspect(key)}, which the validator does not know"
      end
    end

    test "a persist entry that is not a path is refused" do
      for bad <- [[:person, "x"], [], "person", :person] do
        config = %{groups: [], rules: [], sources: [], persist: [bad]}

        assert {:error, errors} = Config.File.validate(config)

        assert Enum.any?(errors, &match?({:bad_persist_prefix, ^bad}, &1)),
               "persist: #{inspect(bad)} was accepted"
      end
    end

    test "persist must be a list" do
      config = %{groups: [], rules: [], sources: [], persist: %{a: 1}}
      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:persist_not_a_list, _}, &1))
    end

    # The defect that shipped through M7 and would have shipped to production:
    # the intruder latch compared against :work and :gym, zones this house has
    # never had. It compiles, it loads, it is never true, and nothing anywhere
    # says so.
    test "a guard comparing against an undeclared zone is refused" do
      config = %{
        groups: [],
        sources: [],
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        rules: [
          %{
            id: :bad,
            desc: "d",
            on: [{:changes, [:x]}],
            when: "person.owner.zone == :work",
            do: [{:log, :info, "x"}]
          }
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:unknown_zone, :bad, :work, _}, &1))
      assert Config.File.format_errors(errors) =~ "never be true"
    end

    test "a declared zone is accepted" do
      config = %{
        groups: [],
        sources: [],
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        rules: [
          %{
            id: :ok_rule,
            desc: "d",
            on: [{:changes, [:x]}],
            when: "person.owner.zone == :home",
            do: [{:log, :info, "x"}]
          }
        ]
      }

      assert {:ok, _} = Config.File.validate(config)
    end

    test "comparing a zone against :unknown is refused by the compiler" do
      # Not a zone check -- the expression compiler rejects it before the zone
      # validator ever sees it, because `!= :unknown` is permanently :unknown
      # and would disable the rule silently.
      config = %{
        groups: [],
        sources: [],
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        rules: [
          %{
            id: :ok_rule,
            desc: "d",
            on: [{:changes, [:x]}],
            when: "person.owner.zone != :unknown",
            do: [{:log, :info, "x"}]
          }
        ]
      }

      assert {:error, errors} = Config.File.validate(config)

      assert Enum.any?(errors, fn
               {_id, {:bad_guard, _, {:unknown_literal_comparison, _, _}}} -> true
               _ -> false
             end),
             "the config loaded with a guard that can never be true"
    end

    test ":away IS a legal zone comparison" do
      # It is a real answer the geofence gives, not a marker for absence.
      config = %{
        groups: [],
        sources: [],
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        rules: [
          %{
            id: :ok_rule,
            desc: "d",
            on: [{:changes, [:x]}],
            when: "person.owner.zone == :away",
            do: [{:log, :info, "x"}]
          }
        ]
      }

      assert {:ok, _} = Config.File.validate(config)
    end

    test "a machine clause guard is checked too" do
      # The latch IS a machine, so checking only stateless rules would have
      # missed the actual defect.
      config = %{
        groups: [],
        sources: [],
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        rules: [
          %{
            id: :bad_machine,
            desc: "d",
            machine: %{
              initial: :a,
              states: %{
                a: [%{on: {:changes, [:x]}, when: "person.owner.zone == :gym", goto: :a}]
              }
            }
          }
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:unknown_zone, :bad_machine, :gym, _}, &1))
    end

    test "an undeclared zone inside an `in` list is refused too" do
      config = %{
        groups: [],
        sources: [],
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        rules: [
          %{
            id: :bad_list,
            desc: "d",
            on: [{:changes, [:x]}],
            when: "person.owner.zone in [:home, :atlantis]",
            do: [{:log, :info, "x"}]
          }
        ]
      }

      assert {:error, errors} = Config.File.validate(config)
      assert Enum.any?(errors, &match?({:unknown_zone, :bad_list, :atlantis, _}, &1))
      refute Enum.any?(errors, &match?({:unknown_zone, _, :home, _}, &1))
    end

    test "a non-zone fact compared against an atom is not checked" do
      # `printer.state == :idle` must not be measured against the zone list.
      config = %{
        groups: [],
        sources: [],
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        rules: [
          %{
            id: :ok_rule,
            desc: "d",
            on: [{:changes, [:x]}],
            when: "printer.kobra_neo.job == :printing",
            do: [{:log, :info, "x"}]
          }
        ]
      }

      assert {:ok, _} = Config.File.validate(config)
    end

    test "a missing file is an error, not an empty config" do
      assert {:error, [{:missing_file, _}]} = Config.File.load("/nonexistent/merlin.exs")
    end
  end
end
