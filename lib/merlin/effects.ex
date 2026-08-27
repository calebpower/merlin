defmodule Merlin.Effects do
  @moduledoc """
  Turns a rule's resolved actions into things that happen -- or, in dry-run,
  into a log line and nothing else.

  ## dry_run

  Three lines of behaviour and the highest-value operational feature in the
  whole rewrite. With `dry_run: true` every outbound effect is logged and
  discarded, so the daemon can run against the live broker for days, making
  real decisions about the real house, without touching a single device.

  That is what converts a big-bang cutover from a leap of faith into a
  rehearsed procedure: you get to read what it *would* have done before it
  does anything. Three of the Python's rules have never fired in production
  (the intruder alert, lights-off-when-away, and phone location ingest), so
  their first live execution will be against this rewrite -- and dry-run is
  how that happens somewhere other than the actual lights.

  ## Values are resolved before dispatch, not during

  An action's expression is evaluated in the rule's own context, at the moment
  it fires, and the *resolved* effect is what reaches here. Resolving later
  would read whatever the world happened to look like once the I/O got round
  to running, which is a race that only shows up under load.
  """

  require Logger

  alias Merlin.{Expr, World}

  @type effect ::
          {:set_group, atom(), term()}
          | {:publish, binary(), binary(), keyword()}
          | {:set_fact, Merlin.Path.t(), term()}
          | {:log, atom(), binary()}

  @doc """
  Resolve a rule's actions against an evaluation environment.

  Returns `{:ok, effects}` or `{:skip, reason}` -- the latter when a value
  evaluates to `:unknown`, because acting on a value we do not have is exactly
  the failure mode three-valued logic exists to prevent.
  """
  @spec resolve([Merlin.Rule.action()], Expr.env(), map()) ::
          {:ok, [effect()]} | {:skip, term()}
  def resolve(actions, env, groups) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      case resolve_action(action, env, groups) do
        {:ok, effect} -> {:cont, {:ok, acc ++ [effect]}}
        {:skip, _} = skip -> {:halt, skip}
      end
    end)
  end

  @doc """
  Perform the effects, or log them if `dry_run?` is true.

  Returns the effects performed, so a caller (and the smoke tier) can assert
  on what happened rather than inferring it.
  """
  @spec perform([effect()], keyword()) :: [effect()]
  def perform(effects, opts \\ []) do
    # A test observer, if one is registered. Effects are sent in the order the
    # clause produced them, which is what lets a test assert that the printer
    # emitted OFF *then* ON rather than merely that both happened -- ordering
    # is the entire content of a sequence, and a set-based assertion would
    # pass for a machine that did them backwards.
    case Application.get_env(:merlin, :effects_observer) do
      pid when is_pid(pid) -> send(pid, {:effects, Keyword.get(opts, :rule), effects})
      _ -> :ok
    end

    dry? = Keyword.get(opts, :dry_run, Merlin.Config.dry_run?())
    rule = Keyword.get(opts, :rule)
    # Causal chain, from the change that triggered the rule. Carried through so
    # a fact written in reaction is bounded by the writer's depth guard.
    cause = Keyword.get(opts, :cause, [])

    Enum.each(effects, fn effect ->
      if dry? do
        Logger.info("[dry-run] #{describe(effect)}#{rule_suffix(rule)}")
      else
        do_perform(effect, rule, cause)
      end
    end)

    effects
  end

  @doc "Human-readable rendering of an effect. Used by dry-run logging and diagnostics."
  @spec describe(effect()) :: binary()
  def describe({:set_group, group, value}), do: "set group #{group} -> #{inspect(value)}"
  def describe({:publish, topic, payload, _}), do: "publish #{topic} #{inspect(payload)}"

  def describe({:set_fact, path, value}),
    do: "set #{Merlin.Path.to_string(path)} -> #{inspect(value)}"

  def describe({:log, level, message}), do: "log #{level}: #{message}"

  # --- resolution -----------------------------------------------------------

  defp resolve_action({:set_group, group, value}, env, groups) do
    with {:ok, v} <- value(value, env) do
      if Map.has_key?(groups, group) do
        {:ok, {:set_group, group, v}}
      else
        # A typo'd group name must not be a silent no-op. It is caught at boot
        # by the validator; this is the belt to that braces.
        {:skip, {:unknown_group, group}}
      end
    end
  end

  defp resolve_action({:publish, topic, payload}, env, _groups) do
    with {:ok, p} <- value(payload, env) do
      {:ok, {:publish, topic, to_payload(p), []}}
    end
  end

  defp resolve_action({:set_fact, path, v}, env, _groups) do
    with {:ok, resolved} <- value(v, env), do: {:ok, {:set_fact, path, resolved}}
  end

  defp resolve_action({:log, level, message}, env, _groups) do
    with {:ok, m} <- value(message, env), do: {:ok, {:log, level, to_payload(m)}}
  end

  defp value({:lit, literal}, _env), do: {:ok, literal}

  defp value({:expr, expr}, env) do
    case Expr.eval(expr, env) do
      :unknown -> {:skip, {:unknown_value, expr.source}}
      resolved -> {:ok, resolved}
    end
  end

  defp to_payload(p) when is_binary(p), do: p
  defp to_payload(p) when is_atom(p), do: Atom.to_string(p)
  defp to_payload(p) when is_number(p), do: to_string(p)
  defp to_payload(p), do: Jason.encode!(p)

  # --- performance ----------------------------------------------------------

  defp do_perform({:set_group, group, value}, rule, _cause) do
    case Merlin.Groups.set(group, value) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("rule #{inspect(rule)}: set group #{group} failed: #{inspect(reason)}")
    end
  end

  defp do_perform({:publish, topic, payload, opts}, rule, _cause) do
    case Merlin.MQTT.Connection.publish(topic, payload, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("rule #{inspect(rule)}: publish #{topic} failed: #{inspect(reason)}")
    end
  end

  defp do_perform({:set_fact, path, value}, rule, cause) do
    # The causal opts are what make the writer's depth guard enforceable. A
    # rule reacting to a change writes at that change's depth + 1, so a cycle
    # between two rules trips the ceiling instead of spinning forever.
    World.put(path, value, Keyword.merge(cause, source: {:rule, rule}))
  end

  defp do_perform({:log, level, message}, rule, _cause) do
    Logger.log(level, "#{message}#{rule_suffix(rule)}")
  end

  defp rule_suffix(nil), do: ""
  defp rule_suffix(rule), do: " (#{rule})"
end
