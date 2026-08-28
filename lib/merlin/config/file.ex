defmodule Merlin.Config.File do
  @moduledoc """
  Loads and validates the configuration data file.

  The file is `.exs` evaluated to a plain map. TOML was rejected because the
  entire semantic vocabulary is atoms (`:home`, `:on`, `:printing`) and TOML
  has none, so every one would need a string-to-atom layer at each boundary;
  and because nested rule trees in TOML mean `[[rules.do]]` array-of-table
  headers. YAML was rejected outright: it coerces `ON`/`OFF` to booleans,
  which is catastrophic when those are literally the device vocabulary.

  The tradeoff is that the file is executable. It is mitigated, not ignored:
  the file is root-owned and read from a fixed path, and `validate/1` asserts
  the evaluated term is **plain data** -- no functions, no pids, no refs -- so
  a config file cannot smuggle behaviour past validation into the engine.

  ## Fail loudly

  `main.py:135` wrapped its config load in `try/except Exception` and fell back
  to `{}`, so a typo produced a daemon that started successfully and did
  nothing. Every error here is collected (not fail-on-first) and reported with
  the offending value, and a failed load is a refusal to boot.
  """

  require Logger

  alias Merlin.Rule

  @type result :: {:ok, map()} | {:error, [term()]}

  @doc "Read, evaluate and validate the file at `path`."
  @spec load(binary()) :: result()
  def load(path) do
    with {:ok, term} <- eval(path) do
      validate(term)
    end
  end

  @doc "Load, raising a formatted report on failure."
  @spec load!(binary()) :: map()
  def load!(path) do
    case load(path) do
      {:ok, config} ->
        config

      {:error, errors} ->
        raise ArgumentError, "invalid config #{path}:\n" <> format_errors(errors)
    end
  end

  @doc "Render errors as a numbered report."
  @spec format_errors([term()]) :: binary()
  def format_errors(errors) do
    errors
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {e, i} -> "  #{i}. #{describe(e)}" end)
  end

  # SECURITY: Code.eval_file/1 executes the file. That is deliberate -- see the
  # moduledoc for why .exs was chosen over TOML and YAML -- and it is bounded
  # by trust, not by sandboxing. Be precise about what is and is not true:
  #
  #   * The path is fixed (MERLIN_CONFIG, defaulting under /usr/local/etc),
  #     root-owned and 0640. It is at the same trust level as the release
  #     binary: anyone who can rewrite it can already replace the daemon.
  #   * The plain-data assertion in validate/1 runs AFTER evaluation. It stops
  #     a closure reaching the engine; it does NOT stop a side effect during
  #     load. This is not a sandbox and must not be described as one.
  #   * Therefore: never point this at a file from anywhere else. Not a user
  #     upload, not a network fetch, not a world-writable directory. If rules
  #     ever need to come from such a source, they get a parser, not this.
  #
  # Merlin.Expr is the opposite case and is genuinely sandboxed: it parses
  # without executing and interprets a closed whitelist.
  defp eval(path) do
    if File.exists?(path) do
      try do
        {term, _bindings} = Code.eval_file(path)
        {:ok, term}
      rescue
        e -> {:error, [{:eval_failed, path, Exception.message(e)}]}
      end
    else
      {:error, [{:missing_file, path}]}
    end
  end

  @doc """
  Validate an already-evaluated config term.

  Collects every error rather than stopping at the first, because a boot
  report naming one problem when there are four costs four restarts.
  """
  @spec validate(term()) :: result()
  def validate(term) when is_map(term) do
    errors =
      List.flatten([
        plain_data_errors(term),
        unknown_key_errors(term),
        persist_errors(term),
        groups_errors(term),
        sources_errors(term),
        zones_errors(term),
        derived_errors(term),
        producer_errors(term),
        secret_errors(term)
      ])

    case {errors, compile_rules(term)} do
      {[], {:ok, rules}} ->
        group_ids = term |> Map.get(:groups, []) |> MapSet.new(& &1.id)

        zone_ids = term |> Map.get(:zones, []) |> MapSet.new(& &1[:id])

        case rule_reference_errors(rules, group_ids) ++ zone_errors(term, rules, zone_ids) do
          [] -> {:ok, build(term, rules)}
          refs -> {:error, refs}
        end

      {errors, {:ok, _}} ->
        {:error, errors}

      {errors, {:error, rule_errors}} ->
        {:error, errors ++ rule_errors}
    end
  end

  def validate(other), do: {:error, [{:not_a_map, other}]}

  # The config file is executable, so assert that what it evaluated to is
  # inert. A map of data cannot do anything; a map containing a closure can.
  defp plain_data_errors(term) do
    if plain?(term), do: [], else: [{:not_plain_data, "config contains a function, pid or ref"}]
  end

  defp plain?(term) when is_function(term) or is_pid(term) or is_reference(term) or is_port(term),
    do: false

  defp plain?(term) when is_map(term) and not is_struct(term) do
    Enum.all?(term, fn {k, v} -> plain?(k) and plain?(v) end)
  end

  defp plain?(term) when is_list(term), do: Enum.all?(term, &plain?/1)
  defp plain?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.all?(&plain?/1)
  defp plain?(_), do: true

  defp groups_errors(term) do
    term
    |> Map.get(:groups, [])
    |> Enum.flat_map(fn group ->
      cond do
        not is_map(group) -> [{:bad_group, group}]
        not is_atom(Map.get(group, :id)) -> [{:group_missing_id, group}]
        not is_binary(Map.get(group, :set_topic)) -> [{:group_missing_set_topic, group.id}]
        Map.get(group, :members, []) == [] -> [{:group_has_no_members, group.id}]
        true -> []
      end
    end)
  end

  defp sources_errors(term) do
    term
    |> Map.get(:sources, [])
    |> Enum.flat_map(fn source ->
      cond do
        not is_map(source) ->
          [{:bad_source, source}]

        not is_atom(Map.get(source, :id)) ->
          [{:source_missing_id, source}]

        not is_binary(Map.get(source, :topic)) ->
          [{:source_missing_topic, source.id}]

        true ->
          # A filter that will not compile is a boot failure, not a runtime
          # surprise on the first message that would have matched it.
          case Merlin.MQTT.Router.add(Merlin.MQTT.Router.new(), source.topic, :x) do
            {:ok, _} -> []
            {:error, reason} -> [{:bad_topic_filter, source.id, source.topic, reason}]
          end
      end
    end)
  end

  defp zones_errors(term) do
    term
    |> Map.get(:zones, [])
    |> Enum.flat_map(fn zone ->
      cond do
        not is_map(zone) -> [{:bad_zone, zone}]
        not is_atom(Map.get(zone, :id)) -> [{:zone_missing_id, zone}]
        not valid_point?(Map.get(zone, :center)) -> [{:zone_bad_center, zone[:id]}]
        not valid_radius?(Map.get(zone, :radius)) -> [{:zone_bad_radius, zone[:id]}]
        Map.get(zone, :hysteresis, 1.25) < 1.0 -> [{:zone_hysteresis_below_one, zone[:id]}]
        true -> []
      end
    end)
  end

  # A hysteresis below 1.0 would make leaving EASIER than arriving, which
  # inverts the anti-flap and is almost certainly a typo rather than intent.
  defp valid_point?({lat, lon})
       when is_number(lat) and is_number(lon) and lat >= -90 and lat <= 90 and lon >= -180 and
              lon <= 180,
       do: true

  defp valid_point?(_), do: false

  defp valid_speed?({n, unit}) when is_number(n) and n > 0 and unit in [:mps, :kph, :mph],
    do: true

  defp valid_speed?(n) when is_number(n) and n > 0, do: true
  defp valid_speed?(_), do: false

  defp valid_radius?({n, unit}) when is_number(n) and n > 0 and unit in [:m, :ft, :mi, :km],
    do: true

  defp valid_radius?(n) when is_number(n) and n > 0, do: true
  defp valid_radius?(_), do: false

  @doc """
  The fact paths a derived spec writes.

  Single-output kinds declare `out:`; a poller declares a `facts:` list and
  writes all of them. Both are "what does this produce", and asking that
  question in one place is what lets the collision check below see a poller's
  ten paths as well as an expression's one.
  """
  @spec produced_paths(map()) :: {:ok, [[atom()]]} | :error
  def produced_paths(%{kind: :http_poll} = d) do
    facts = Map.get(d, :facts, [])

    if is_list(facts) and facts != [] and Enum.all?(facts, &is_list(Map.get(&1, :path))) do
      {:ok, Enum.map(facts, & &1.path)}
    else
      :error
    end
  end

  def produced_paths(d) do
    case Map.get(d, :out) do
      out when is_list(out) -> {:ok, [out]}
      _ -> :error
    end
  end


  # Two producers writing one path is the defect that presents as a fact
  # flickering between two values with no rule to blame, and it is invisible
  # in review because the two declarations are hundreds of lines apart. It
  # became reachable the moment a poller could declare ten paths at once.
  defp producer_errors(term) do
    term
    |> Map.get(:derived, [])
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn d ->
      case produced_paths(d) do
        {:ok, paths} -> Enum.map(paths, &{&1, Map.get(d, :id)})
        :error -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn
      {_path, [_only]} ->
        []

      {path, ids} ->
        [{:duplicate_producer, Merlin.Path.to_string(path), Enum.sort(ids)}]
    end)
  end

  # Every key merlin actually reads. A config key it does not read is a typo,
  # and a typo here is silent: `persits:` disables persistence, `dry_run` typed
  # wrong actuates the house, and neither fails anywhere. That is the defect
  # this whole milestone is about, in the file that configures it.
  @known_keys [
    :mqtt,
    :api,
    :dry_run,
    :settle_ms,
    :persist,
    :zones,
    :colocation_distance,
    :groups,
    :sources,
    :derived,
    :rules
  ]

  @doc "The top-level configuration keys merlin reads."
  @spec known_keys() :: [atom()]
  def known_keys, do: @known_keys

  # No non-map clause: validate/1 rejects a non-map before reaching here, and
  # a fallback that can never run is a fallback nobody can test.
  defp unknown_key_errors(term) do
    term
    |> Map.keys()
    |> Enum.reject(&(&1 in @known_keys))
    |> Enum.map(&{:unknown_key, &1, did_you_mean(&1)})
  end

  # A typo is nearly always one edit away from the key that was meant, and
  # naming the intended key turns a refusal to boot into a one-line fix.
  defp did_you_mean(key) do
    name = Atom.to_string(key)

    @known_keys
    |> Enum.map(&{&1, String.jaro_distance(name, Atom.to_string(&1))})
    |> Enum.filter(fn {_k, score} -> score > 0.8 end)
    |> Enum.max_by(fn {_k, score} -> score end, fn -> nil end)
    |> case do
      {suggestion, _score} -> suggestion
      nil -> nil
    end
  end

  defp persist_errors(term) do
    case Map.get(term, :persist, []) do
      list when is_list(list) ->
        list
        |> Enum.reject(&(is_list(&1) and &1 != [] and Enum.all?(&1, fn s -> is_atom(s) end)))
        |> Enum.map(&{:bad_persist_prefix, &1})

      other ->
        [{:persist_not_a_list, other}]
    end
  end

  defp derived_errors(term) do
    zone_ids = term |> Map.get(:zones, []) |> Enum.map(& &1[:id]) |> MapSet.new()

    term
    |> Map.get(:derived, [])
    |> Enum.flat_map(fn d ->
      cond do
        not is_map(d) ->
          [{:bad_derived, d}]

        not is_atom(Map.get(d, :id)) ->
          [{:derived_missing_id, d}]

        Map.get(d, :kind) not in [:geofence, :expr, :sun, :http_poll] ->
          [{:derived_bad_kind, d[:id], Map.get(d, :kind)}]

        produced_paths(d) == :error ->
          [{:derived_missing_out, d[:id]}]

        Map.get(d, :kind) == :geofence and Map.has_key?(d, :max_speed) and
            not valid_speed?(d.max_speed) ->
          [{:bad_max_speed, d.id, d.max_speed}]

        d.kind == :expr ->
          hold_errors(d) ++
            case Merlin.Expr.compile(Map.get(d, :compute, "")) do
              {:ok, expr} -> self_reference_errors(d, expr, zone_ids)
              {:error, reason} -> [{:derived_bad_expression, d.id, reason}]
            end

        true ->
          []
      end
    end)
  end

  # A bad hold spec must fail at boot, not raise inside the process's init/1
  # where it would present as a supervisor restart loop with no explanation.
  defp hold_errors(d) do
    case Map.get(d, :hold) do
      nil ->
        []

      {:true_for, duration} ->
        case Merlin.Machine.to_ms(duration) do
          {:ok, _} -> []
          {:error, reason} -> [{:derived_bad_hold, d.id, reason}]
        end

      other ->
        [{:derived_bad_hold, d.id, other}]
    end
  end

  # A derived fact that reads itself is a cycle. It would terminate here only
  # because Derive.Expr refuses to react to its own output -- which is a
  # guard, not a licence. Catch it at boot instead.
  defp self_reference_errors(d, expr, _zone_ids) do
    if d.out in Merlin.Expr.deps(expr) do
      [{:derived_self_reference, d.id, Merlin.Path.to_string(d.out)}]
    else
      []
    end
  end

  # A config entry with a :machine key is a stateful rule; everything else is
  # stateless. One list, so the ordering in the file is the ordering a reader
  # sees, rather than two lists that must be mentally interleaved.
  # Every secret the config names must be defined. Reported together, because
  # discovering them one restart at a time is how a cutover window gets eaten.
  defp secret_errors(term) do
    case Merlin.Secrets.missing(term) do
      [] -> []
      names -> Enum.map(names, &{:missing_secret, &1})
    end
  end

  defp compile_rules(term) do
    {ok, errors} =
      term
      |> Map.get(:rules, [])
      |> Enum.map(fn
        %{machine: _} = m -> Merlin.Machine.compile(m)
        r -> Rule.compile(r)
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(ok, fn {:ok, r} -> r end)}
      _ -> {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end

  # Every group a rule commands must exist. This is the check that turns a
  # typo'd group name from a silent no-op into a refusal to start.
  defp rule_reference_errors(rules, group_ids) do
    Enum.flat_map(rules, fn rule ->
      rule
      |> all_actions()
      |> Enum.flat_map(fn
        {:set_group, group, _} ->
          if MapSet.member?(group_ids, group),
            do: [],
            else: [{:unknown_group, rule.id, group, MapSet.to_list(group_ids)}]

        _ ->
          []
      end)
    end)
  end

  # A stateless rule keeps its actions at the top level; a machine keeps them
  # inside each clause of each state. Both must be checked, or a typo'd group
  # name inside a machine would be a silent no-op at 3am instead of a boot
  # failure -- which is the whole reason this check exists.
  # Every zone a guard compares against must be a zone this house has.
  #
  # `person.owner.zone == :work` compiles, loads and is simply never true when
  # no `:work` zone is declared. The rule then does nothing for ever, and the
  # house looks quiet rather than broken -- there is no error, no warning, and
  # nothing in any log to notice.
  #
  # The configuration shipped through M7 compared against `:work` and `:gym`
  # in the intruder latch, and this house has only ever had `home` and
  # `hackspace`. The whole presence half of the automation would have been
  # inert, and the dry-run soak would have shown a reassuring silence.
  defp zone_errors(term, rules, zone_ids) do
    from_rules =
      Enum.flat_map(rules, fn rule ->
        rule
        |> all_guards()
        |> Enum.flat_map(&Merlin.Expr.zone_atoms/1)
        |> Enum.map(&{rule.id, &1})
      end)

    from_derived =
      term
      |> Map.get(:derived, [])
      |> Enum.filter(&(is_map(&1) and Map.get(&1, :kind) == :expr))
      |> Enum.flat_map(fn d ->
        case Merlin.Expr.compile(Map.get(d, :compute, "")) do
          {:ok, expr} -> expr |> Merlin.Expr.zone_atoms() |> Enum.map(&{d.id, &1})
          {:error, _} -> []
        end
      end)

    (from_rules ++ from_derived)
    |> Enum.reject(fn {_where, zone} -> MapSet.member?(zone_ids, zone) end)
    |> Enum.uniq()
    |> Enum.map(fn {where, zone} ->
      {:unknown_zone, where, zone, Enum.sort(MapSet.to_list(zone_ids))}
    end)
  end

  defp all_guards(%Merlin.Rule{guard: nil}), do: []
  defp all_guards(%Merlin.Rule{guard: guard}), do: [guard]

  defp all_guards(%Merlin.Machine{states: states}) do
    for {_state, clauses} <- states,
        %Merlin.Machine.Clause{guard: guard} <- clauses,
        guard != nil,
        do: guard
  end

  defp all_actions(%Merlin.Rule{actions: actions}), do: actions

  defp all_actions(%Merlin.Machine{states: states}) do
    for {_state, clauses} <- states,
        %Merlin.Machine.Clause{actions: actions} <- clauses,
        action <- actions,
        do: action
  end

  # Built from @known_keys rather than from a second hand-written list.
  #
  # Two lists that must agree -- one naming what is legal, one naming what is
  # kept -- is the same shape as the deep validator beside the shallow
  # resolver, and it failed the same way: `persist:` and `settle_ms:` validated
  # cleanly, were dropped here, and the daemon silently ran with no persistence
  # and a default settle window. `api:` was being dropped too, so an api port
  # in the config would have been ignored in favour of the default.
  #
  # Deriving one from the other means adding a key cannot half-work.
  defp build(term, rules) do
    Map.new(@known_keys, fn key -> {key, built(key, term, rules)} end)
  end

  defp built(:rules, _term, rules), do: rules

  defp built(:groups, term, _rules),
    do: term |> Map.get(:groups, []) |> Map.new(&{&1.id, &1})

  defp built(:zones, term, _rules), do: Merlin.Zones.compile(Map.get(term, :zones, []))
  defp built(:mqtt, term, _rules), do: Map.get(term, :mqtt, %{})
  defp built(:api, term, _rules), do: Map.get(term, :api, %{})
  defp built(:dry_run, term, _rules), do: Map.get(term, :dry_run, false)
  defp built(:settle_ms, term, _rules), do: Map.get(term, :settle_ms, Merlin.Settle.default_ms())
  defp built(:persist, term, _rules), do: Map.get(term, :persist, [])
  defp built(:sources, term, _rules), do: Map.get(term, :sources, [])
  defp built(:derived, term, _rules), do: Map.get(term, :derived, [])

  defp built(:colocation_distance, term, _rules),
    do: Map.get(term, :colocation_distance, {0.25, :mi})

  # --- error rendering ------------------------------------------------------

  defp describe({:unknown_key, key, nil}),
    do:
      "unknown top-level key #{inspect(key)} -- merlin does not read it, so whatever " <>
        "you set there has no effect. Known keys: #{Enum.map_join(@known_keys, ", ", &inspect/1)}"

  defp describe({:unknown_key, key, suggestion}),
    do: "unknown top-level key #{inspect(key)} -- did you mean #{inspect(suggestion)}?"

  defp describe({:bad_persist_prefix, prefix}),
    do: "persist: #{inspect(prefix)} is not a non-empty path, e.g. [:person] or [:rule, :my_latch]"

  defp describe({:persist_not_a_list, other}),
    do: "persist: must be a list of paths, got #{inspect(other)}"

  defp describe({:duplicate_producer, path, ids}),
    do: "#{path} is written by more than one derived fact: #{Enum.map_join(ids, ", ", &inspect/1)}"

  defp describe({:bad_max_speed, id, speed}),
    do:
      "#{inspect(id)} declares max_speed: #{inspect(speed)}, which is not a positive speed. " <>
        "Use {120, :kph}, {75, :mph} or {33, :mps}."

  defp describe({:unknown_zone, where, zone, declared}),
    do:
      "#{inspect(where)} compares a zone against #{inspect(zone)}, which this house does " <>
        "not declare. It would never be true and the rule would never fire. " <>
        "Declared zones: #{Enum.map_join(declared, ", ", &inspect/1)}"

  defp describe({:missing_file, path}), do: "config file not found: #{path}"
  defp describe({:eval_failed, path, message}), do: "could not evaluate #{path}: #{message}"
  defp describe({:not_a_map, _}), do: "config must evaluate to a map"
  defp describe({:not_plain_data, message}), do: message

  defp describe({:unknown_group, rule_id, group, known}),
    do: "rule #{rule_id} commands unknown group #{inspect(group)} (known: #{inspect(known)})"

  defp describe({:missing_secret, name}),
    do: "secret #{inspect(name)} is referenced by the config but not defined in #{Merlin.Secrets.path()}"

  defp describe({:derived_bad_hold, id, reason}),
    do: "derived fact #{id}: bad hold: #{inspect(reason)} (expected {:true_for, {n, unit}})"

  defp describe({:derived_self_reference, id, path}),
    do: "derived fact #{id} reads its own output #{path} -- that is a cycle"

  defp describe({:derived_bad_expression, id, reason}),
    do: "derived fact #{id}: expression rejected: #{inspect(reason)}"

  defp describe({:zone_hysteresis_below_one, id}),
    do: "zone #{id}: hysteresis below 1.0 would make leaving easier than arriving"

  defp describe({:bad_topic_filter, id, filter, reason}),
    do: "source #{id}: bad topic filter #{inspect(filter)}: #{reason}"

  defp describe({rule_id, {:bad_guard, source, reason}}),
    do: "rule #{rule_id}: guard #{inspect(source)} rejected: #{inspect(reason)}"

  defp describe({rule_id, reason}) when is_atom(rule_id),
    do: "rule #{rule_id}: #{inspect(reason)}"

  defp describe(other), do: inspect(other)
end
