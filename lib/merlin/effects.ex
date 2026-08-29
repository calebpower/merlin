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
  alias Merlin.Effects.Tap

  @type effect ::
          {:set_group, atom(), term()}
          | {:publish, binary(), binary(), keyword()}
          | {:set_fact, Merlin.Path.t(), term()}
          | {:log, atom(), binary()}
          | {:notify, atom(), binary()}

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

  Options:

    * `:rule`    -- the rule id that produced these, for the log suffix
    * `:source`  -- who caused it, overriding `:rule`. `{:rule, id}` or
      `{:operator, who}`. An operator command passed as `rule: :tui` would
      write a lie into the log; this is how it says what it actually was.
    * `:dry_run` -- override the daemon's setting for these effects only
    * `:cause`   -- causal opts from the change that triggered the rule

  Every effect's fate is reported to `Merlin.Effects.Tap`.
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
    source = Keyword.get(opts, :source) || rule_source(Keyword.get(opts, :rule))
    # Causal chain, from the change that triggered the rule. Carried through so
    # a fact written in reaction is bounded by the writer's depth guard.
    cause = Keyword.get(opts, :cause, [])

    settling? = Merlin.Settle.settling?()

    Enum.each(effects, fn effect ->
      # The outcome is computed rather than implied by which branch logged.
      # It was always known here and never said; a reader of the log could
      # tell dry-run from held only by the prefix, and could not tell a
      # dispatch that succeeded from one that failed at all.
      outcome =
        cond do
          dry? ->
            Logger.info("[dry-run] #{describe(effect)}#{source_suffix(source)}")
            :dry_run

          settling? and Merlin.Settle.suppresses?(effect) ->
            # Reported, never silent. A settle window you cannot see the
            # workings of is indistinguishable from a daemon that has stopped
            # acting, and the difference matters at 3am. Every held effect
            # names itself, what produced it, and how long is left.
            remaining = Merlin.Settle.remaining_ms()

            Logger.info(
              "[settling #{remaining}ms] held: " <>
                "#{describe(effect)}#{source_suffix(source)}"
            )

            {:held, remaining}

          true ->
            do_perform(effect, source, cause)
        end

      Tap.notify(outcome, effect, source)
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
  def describe({:notify, channel, message}), do: "notify #{channel}: #{message}"

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

  defp resolve_action({:notify, channel, message}, env, _groups) do
    with {:ok, m} <- value(message, env), do: {:ok, {:notify, channel, to_payload(m)}}
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

  # Every clause returns :performed or {:failed, reason}. They used to return
  # whatever Logger.warning/1 happened to return, which meant the one thing
  # the caller most wanted to know -- did it work -- was the one thing thrown
  # away. A failed publish and a successful one were indistinguishable to
  # anything but a human reading the log.
  @spec do_perform(effect(), Merlin.Effects.Report.source(), keyword()) ::
          :performed | {:failed, term()}

  defp do_perform({:set_group, group, value}, source, _cause) do
    case Merlin.Groups.set(group, value) do
      :ok ->
        :performed

      {:error, reason} ->
        Logger.warning("#{source_label(source)}: set group #{group} failed: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  defp do_perform({:publish, topic, payload, opts}, source, _cause) do
    case Merlin.MQTT.Connection.publish(topic, payload, opts) do
      :ok ->
        :performed

      {:error, reason} ->
        Logger.warning("#{source_label(source)}: publish #{topic} failed: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  defp do_perform({:set_fact, path, value}, source, cause) do
    # The causal opts are what make the writer's depth guard enforceable. A
    # rule reacting to a change writes at that change's depth + 1, so a cycle
    # between two rules trips the ceiling instead of spinning forever.
    #
    # `source` reaches the fact, so an operator-written fact is distinguishable
    # from a rule-written one for ever afterwards -- which is the difference
    # between "the latch is fired because something happened" and "the latch is
    # fired because somebody set it by hand at 2am".
    case World.put(path, value, Keyword.merge(cause, source: source)) do
      {:dropped, :max_depth} -> {:failed, :max_depth}
      _changed_or_unchanged -> :performed
    end
  end

  defp do_perform({:notify, :discord, message}, source, _cause) do
    case Merlin.Notify.Discord.send(message) do
      :ok ->
        :performed

      {:error, reason} ->
        Logger.warning("#{source_label(source)}: discord notify failed: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  # A channel that resolves to the log is how an alerting rule ships before it
  # is trusted to wake anyone. Both vehicle rules and the intruder latch use it.
  defp do_perform({:notify, :log, message}, source, _cause) do
    Logger.warning("[notify] #{message}#{source_suffix(source)}")
    :performed
  end

  defp do_perform({:notify, channel, message}, source, _cause) do
    Logger.warning(
      "#{source_label(source)}: unknown notify channel #{inspect(channel)}: #{message}"
    )

    {:failed, {:unknown_channel, channel}}
  end

  defp do_perform({:log, level, message}, source, _cause) do
    Logger.log(level, "#{message}#{source_suffix(source)}")
    :performed
  end

  # --- attribution ----------------------------------------------------------

  # `rule: :lamps_toggle` becomes `{:rule, :lamps_toggle}` so that everything
  # downstream has one shape to match on, and the rendered suffix is unchanged
  # -- " (lamps_toggle)" is what the soak runbook greps for.
  defp rule_source(nil), do: nil
  defp rule_source(rule), do: {:rule, rule}

  @doc false
  @spec source_suffix(Merlin.Effects.Report.source()) :: binary()
  def source_suffix(nil), do: ""
  def source_suffix({:rule, rule}), do: " (#{rule})"
  def source_suffix({:operator, who}), do: " (operator #{who})"
  def source_suffix(other), do: " (#{inspect(other)})"

  defp source_label(nil), do: "effect"
  defp source_label({:rule, rule}), do: "rule #{rule}"
  defp source_label({:operator, who}), do: "operator #{who}"
  defp source_label(other), do: inspect(other)
end
