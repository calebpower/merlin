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
        groups_errors(term),
        sources_errors(term),
        zones_errors(term),
        derived_errors(term)
      ])

    case {errors, compile_rules(term)} do
      {[], {:ok, rules}} ->
        group_ids = term |> Map.get(:groups, []) |> MapSet.new(& &1.id)

        case rule_reference_errors(rules, group_ids) do
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

  defp valid_radius?({n, unit}) when is_number(n) and n > 0 and unit in [:m, :ft, :mi, :km],
    do: true

  defp valid_radius?(n) when is_number(n) and n > 0, do: true
  defp valid_radius?(_), do: false

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

        Map.get(d, :kind) not in [:geofence, :expr, :sun] ->
          [{:derived_bad_kind, d[:id], Map.get(d, :kind)}]

        not is_list(Map.get(d, :out)) ->
          [{:derived_missing_out, d[:id]}]

        d.kind == :expr ->
          case Merlin.Expr.compile(Map.get(d, :compute, "")) do
            {:ok, expr} -> self_reference_errors(d, expr, zone_ids)
            {:error, reason} -> [{:derived_bad_expression, d.id, reason}]
          end

        true ->
          []
      end
    end)
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

  defp compile_rules(term) do
    {ok, errors} =
      term
      |> Map.get(:rules, [])
      |> Enum.map(&Rule.compile/1)
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
      Enum.flat_map(rule.actions, fn
        {:set_group, group, _} ->
          if MapSet.member?(group_ids, group),
            do: [],
            else: [{:unknown_group, rule.id, group, MapSet.to_list(group_ids)}]

        _ ->
          []
      end)
    end)
  end

  defp build(term, rules) do
    %{
      mqtt: Map.get(term, :mqtt, %{}),
      dry_run: Map.get(term, :dry_run, false),
      groups: term |> Map.get(:groups, []) |> Map.new(&{&1.id, &1}),
      sources: Map.get(term, :sources, []),
      zones: Merlin.Zones.compile(Map.get(term, :zones, [])),
      colocation_distance: Map.get(term, :colocation_distance, {0.25, :mi}),
      derived: Map.get(term, :derived, []),
      rules: rules
    }
  end

  # --- error rendering ------------------------------------------------------

  defp describe({:missing_file, path}), do: "config file not found: #{path}"
  defp describe({:eval_failed, path, message}), do: "could not evaluate #{path}: #{message}"
  defp describe({:not_a_map, _}), do: "config must evaluate to a map"
  defp describe({:not_plain_data, message}), do: message

  defp describe({:unknown_group, rule_id, group, known}),
    do: "rule #{rule_id} commands unknown group #{inspect(group)} (known: #{inspect(known)})"

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
