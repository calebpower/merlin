defmodule Merlin.Rules.Engine do
  @moduledoc """
  Evaluates stateless rules against the bus.

  At boot it compiles every configured rule, subscribes to the union of their
  derived watches, and thereafter: a change or event arrives, the rules whose
  triggers it fires are selected, each guard is evaluated, and the surviving
  actions are resolved and performed.

  ## Stateless only

  Stateful rules are `Merlin.Machine.Server` processes under
  `Merlin.Machine.Supervisor`, one `:gen_statem` each. This engine evaluates
  the rest, all in one process.

  That asymmetry is deliberate rather than unfinished. Machines hold state,
  arm timers and benefit from crash isolation; a stateless trigger-guard-action
  rule has nothing to isolate and would cost a process each for no gain.

  What one process costs, stated plainly: a rule that raises would take the
  engine down and every stateless rule with it. Guard and action evaluation is
  therefore wrapped, and a raising rule is logged and skipped -- the same
  reasoning as `Merlin.MQTT.Connection`, since rule data is authored input and
  a bad expression must not cost the house its lights.

  ## Causality

  A fact written by a rule carries `Merlin.Change.caused_by/1` from the change
  that triggered it. That is what makes the writer's depth guard enforceable:
  without it every reactive write looks like the head of a fresh chain and a
  cycle would never trip the ceiling.
  """

  use GenServer
  require Logger

  alias Merlin.{Bus, Change, Effects, Event, Groups, Rule}
  alias Merlin.Rules.Env

  defstruct [:rules, :dry_run]

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The compiled rules currently loaded."
  @spec rules() :: [Rule.t()]
  def rules, do: GenServer.call(__MODULE__, :rules)

  @impl true
  def init(opts) do
    # Stateless rules only. Machines are their own :gen_statem processes under
    # Merlin.Machine.Supervisor -- crash isolation per machine is most of the
    # point of giving them processes at all.
    enabled =
      opts
      |> Keyword.get(:rules, Merlin.Config.rules())
      |> Enum.filter(&match?(%Merlin.Rule{}, &1))
      |> Enum.filter(& &1.enabled)

    for rule <- enabled do
      Enum.each(rule.watches, &Bus.subscribe/1)
      Enum.each(rule.watch_events, &Bus.subscribe_events/1)
      Enum.each(rule.watch_groups, &Groups.subscribe/1)
    end

    Logger.info(
      "rules engine: #{length(enabled)} rule(s) loaded" <>
        if(Merlin.Config.dry_run?(), do: " [DRY RUN — no effect will be performed]", else: "")
    )

    {:ok, %__MODULE__{rules: enabled, dry_run: Merlin.Config.dry_run?()}}
  end

  @impl true
  def handle_call(:rules, _from, state), do: {:reply, state.rules, state}

  @impl true
  def handle_info({:merlin, %Change{} = change}, state) do
    dispatch(change, trigger_env(change), Change.caused_by(change), state)
    {:noreply, state}
  end

  def handle_info({:merlin, %Event{} = event}, state) do
    # Events have no causal seq to chain from; a fact written in reaction to
    # one starts a fresh chain at depth 1.
    dispatch(event, trigger_env(event), [depth: 1], state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- dispatch -------------------------------------------------------------

  defp dispatch(subject, trigger, cause_opts, state) do
    # One definition of what a guard sees, shared with the machines and with
    # anything that needs to evaluate a guard the way the engine would.
    env = Env.build(trigger)

    state.rules
    |> Enum.filter(&Rule.fires?(&1, subject))
    |> Enum.each(&run(&1, env, cause_opts, state))
  end

  defp run(rule, env, cause_opts, state) do
    case Env.guard(rule.guard, env) do
      :pass ->
        case Effects.resolve(rule.actions, env, Groups.all()) do
          {:ok, effects} ->
            Effects.perform(effects, rule: rule.id, dry_run: state.dry_run, cause: cause_opts)

          {:skip, reason} ->
            # Most often {:unknown_value, _}: an action's expression evaluated
            # to :unknown. Acting anyway is precisely what three-valued logic
            # exists to prevent, so the rule declines rather than guessing.
            Logger.debug("rule #{rule.id} skipped: #{inspect(reason)}")
        end

      {:refused, why} ->
        refused(rule, why)
    end
  rescue
    e ->
      Logger.warning("rule #{rule.id} raised: #{Exception.message(e)} -- skipped")
  catch
    kind, reason ->
      Logger.warning("rule #{rule.id} threw #{kind}: #{inspect(reason)} -- skipped")
  end

  # A rule that declines is no longer silent.
  #
  # Debug, not info, because at house event rates every guard that is merely
  # false would otherwise be a log line -- and "the door is shut, so the
  # lights-off rule did nothing" is not news. What IS news is the guard source,
  # which is carried so the answer does not require opening the config.
  #
  # A guard that is neither true nor false is a different matter and warns: the
  # rule can never fire, no operator would ever guess why, and it costs nothing
  # to say so because a well-formed config never produces one.
  defp refused(%Rule{} = rule, why) when why in [false, :unknown] do
    Logger.debug(fn ->
      "rule #{rule.id} did not fire: #{Env.describe_refusal(why)}" <> guard_source(rule)
    end)
  end

  defp refused(%Rule{} = rule, why) do
    Logger.warning(
      "rule #{rule.id} did not fire: #{Env.describe_refusal(why)}" <> guard_source(rule)
    )
  end

  defp guard_source(%Rule{guard: nil}), do: ""
  defp guard_source(%Rule{guard: guard}), do: " -- #{guard.source}"

  defp trigger_env(%Change{} = c), do: Change.trigger_env(c)
  defp trigger_env(%Event{} = e), do: Event.trigger_env(e)
end
