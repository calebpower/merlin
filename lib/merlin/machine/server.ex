defmodule Merlin.Machine.Server do
  @moduledoc """
  Runs one declared machine as a `:gen_statem`.

  ## Why `:gen_statem` rather than a GenServer with a mode field

  Three of its features are the reason the stateful rules are tractable at all:

    * **state timeouts cancel themselves on any state change.** The printer's
      ten-second dwell is `{:state_timeout, 10_000, :after}`, and if anything
      moves the machine out of `:dwell` the timer is gone. The Python did this
      with `await asyncio.sleep(10)` inside the hook, which blocks that hook's
      task for ten seconds and cannot be cancelled by anything.
    * **`:postpone`** defers an event until after the next state change, so a
      power request arriving mid-cycle is queued rather than dropped -- one
      keyword instead of a hand-rolled pending queue.
    * **`:state_enter` callbacks** give a single place to publish the current
      state and persist it, so every transition is observable without each
      clause remembering to say so.

  ## The state is a fact

  On entry the machine publishes `rule.<id>.state` and one fact per data slot.
  That is the direct answer to `self.printer_active` and
  `self.presence_alert_fired`: latches and masks become things you can read on
  `/facts.json` and reason about, rather than instance variables that existed
  only inside a Python object and vanished on restart.
  """

  @behaviour :gen_statem

  require Logger

  alias Merlin.{Bus, Change, Effects, Event, Expr, Groups, Machine, Path, World}
  alias Merlin.Machine.Clause

  defstruct [:machine, :data, :dry_run]

  @doc false
  def child_spec(machine) do
    %{id: {__MODULE__, machine.id}, start: {__MODULE__, :start_link, [machine]}}
  end

  @doc false
  def start_link(%Machine{} = machine),
    do: :gen_statem.start_link(via(machine.id), __MODULE__, machine, [])

  defp via(id), do: {:via, Registry, {Merlin.Machine.Registry, id}}

  @doc "The machine's current state name. For tests and introspection."
  @spec state(atom()) :: atom()
  def state(id), do: :gen_statem.call(via(id), :__state__)

  @doc "The machine's current data slots."
  @spec data(atom()) :: map()
  def data(id), do: :gen_statem.call(via(id), :__data__)

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(%Machine{} = machine) do
    Enum.each(machine.watches, &Bus.subscribe/1)
    Enum.each(machine.watch_events, &Bus.subscribe_events/1)
    Enum.each(machine.watch_groups, &Groups.subscribe/1)

    {initial, data} = restored(machine)

    state = %__MODULE__{
      machine: machine,
      data: data,
      dry_run: Merlin.Config.dry_run?()
    }

    {:ok, initial, state}
  end

  # --- restoring from a snapshot -------------------------------------------

  # A latch is only a latch if it survives a restart. `alerts.py` held its
  # latch in an instance variable, so every restart re-armed it silently and
  # the alert could fire again immediately -- the failure looked exactly like
  # correct behaviour.
  #
  # Restores nothing unless the machine asked for it. The state and data are
  # already published as facts, so the snapshotter needs no special knowledge
  # of machines; this reads back what it wrote.
  defp restored(%Machine{persist: false} = m), do: {m.initial, m.data}

  defp restored(%Machine{} = m) do
    {restored_state(m), restored_data(m)}
  end

  defp restored_state(%Machine{} = m) do
    with {:ok, %{value: name}} when is_atom(name) <- World.fetch([:rule, m.id, :state]),
         true <- Map.has_key?(m.states, name),
         :ok <- resumable(m, name) do
      if name != m.initial do
        Logger.info("machine #{m.id}: resumed in #{name} from the snapshot")
      end

      name
    else
      {:error, reason} ->
        Logger.info(
          "machine #{m.id}: not resuming #{inspect(reason)} -- starting at #{m.initial}"
        )

        m.initial

      _ ->
        m.initial
    end
  end

  # A state with a deadline cannot be resumed, because how much of the deadline
  # remains is unknowable: the daemon may have been down for a second or a
  # week, and the snapshot records when the fact was written, not how long the
  # timer had left.
  #
  # Guessing either way is wrong in a way that acts. Resume with a full timer
  # and a ten-second printer dwell becomes ten seconds *after* the restart, so
  # the A/C stays shed for longer than the print. Resume with none and the
  # sequence never completes, leaving the printer powered off indefinitely.
  # Falling back to the initial state is the only option that is merely
  # forgetful rather than actively wrong, and it says so in the log.
  defp resumable(%Machine{states: states}, name) do
    if Enum.any?(Map.get(states, name, []), &match?(%Clause{trigger: {:after, _}}, &1)) do
      {:error, {:state_has_a_deadline, name}}
    else
      :ok
    end
  end

  defp restored_data(%Machine{data: declared} = m) do
    Map.new(declared, fn {slot, default} ->
      case World.fetch([:rule, m.id, :data, slot]) do
        {:ok, %{value: value}} -> {slot, value}
        :error -> {slot, default}
      end
    end)
  end

  # --- state entry ----------------------------------------------------------

  @impl true
  def handle_event(:enter, old, new, %__MODULE__{machine: m} = s) do
    if old != new do
      Logger.info("machine #{m.id}: #{old} -> #{new}")
    end

    publish_introspection(m.id, new, s.data)

    # Arm the state timeout, if this state declares one. Re-entering the same
    # state re-arms it, which is what `:repeat_state` is for.
    {:keep_state_and_data, timeout_actions(m, new)}
  end

  # --- inbound facts and events --------------------------------------------

  def handle_event(:info, {:merlin, %Change{} = change}, state_name, s) do
    dispatch(change, trigger_env(change), Change.caused_by(change), state_name, s)
  end

  def handle_event(:info, {:merlin, %Event{} = event}, state_name, s) do
    dispatch(event, trigger_env(event), [depth: 1], state_name, s)
  end

  def handle_event(:info, _other, _state_name, _s), do: :keep_state_and_data

  # --- timeouts -------------------------------------------------------------

  def handle_event(:state_timeout, :after, state_name, s) do
    dispatch(:after, %{value: :timeout}, [], state_name, s)
  end

  def handle_event(:timeout, :idle_for, state_name, s) do
    dispatch(:idle_for, %{value: :idle}, [], state_name, s)
  end

  # --- introspection --------------------------------------------------------

  def handle_event({:call, from}, :__state__, state_name, _s) do
    {:keep_state_and_data, [{:reply, from, state_name}]}
  end

  def handle_event({:call, from}, :__data__, _state_name, s) do
    {:keep_state_and_data, [{:reply, from, s.data}]}
  end

  def handle_event(_type, _content, _state_name, _s), do: :keep_state_and_data

  # --- the core -------------------------------------------------------------

  defp dispatch(subject, trigger, cause_opts, state_name, %__MODULE__{machine: m} = s) do
    clauses = Map.get(m.states, state_name, [])
    env = base_env(trigger, s)

    case Enum.find(clauses, &matches?(&1, subject, env)) do
      nil ->
        # Ignore by default. This is what makes a dwell state correct without
        # enumerating everything it should not do.
        Logger.debug(fn -> "machine #{m.id}/#{state_name}: no clause for #{describe(subject)}" end)
        :keep_state_and_data

      %Clause{postpone: true} ->
        {:keep_state_and_data, [:postpone]}

      clause ->
        run(clause, env, cause_opts, state_name, s)
    end
  rescue
    e ->
      # Machine data is authored input. A bad expression must not cost the
      # house its lights, and a crash-looping machine would take its restart
      # intensity with it.
      Logger.warning("machine #{s.machine.id} raised: #{Exception.message(e)} -- event skipped")
      :keep_state_and_data
  end

  defp run(%Clause{} = clause, env, cause_opts, state_name, %__MODULE__{machine: m} = s) do
    # Slots are resolved and applied BEFORE the actions, so an action reading
    # local.<slot> sees the value this clause just set rather than the previous
    # one. That ordering is what makes the load-shed restore read the desire
    # it remembered rather than the one it is replacing.
    data = apply_sets(clause.sets, env, s.data)
    env = Map.put(env, :locals, data)

    case Effects.resolve(clause.actions, env, Groups.all()) do
      {:ok, effects} ->
        Effects.perform(effects, rule: m.id, dry_run: s.dry_run, cause: cause_opts)

      {:skip, reason} ->
        Logger.debug("machine #{m.id}/#{state_name} skipped actions: #{inspect(reason)}")
    end

    s = %{s | data: data}

    case clause.goto do
      nil -> {:keep_state, s}
      ^state_name -> {:repeat_state, s}
      next -> {:next_state, next, s}
    end
  end

  defp apply_sets(sets, env, data) do
    Enum.reduce(sets, data, fn {slot, value_spec}, acc ->
      case resolve_value(value_spec, env) do
        {:ok, value} -> Map.put(acc, slot, value)
        :skip -> acc
      end
    end)
  end

  defp resolve_value({:lit, literal}, _env), do: {:ok, literal}

  defp resolve_value({:expr, expr}, env) do
    case Expr.eval(expr, env) do
      # Refusing to store :unknown in a slot is deliberate: a remembered
      # desire that becomes "we do not know" is worse than a stale one, since
      # the restore would then have nothing to restore to.
      :unknown -> :skip
      value -> {:ok, value}
    end
  end

  defp matches?(%Clause{trigger: {:after, _}}, :after, _env), do: true
  defp matches?(%Clause{trigger: {:idle_for, _}}, :idle_for, _env), do: true
  defp matches?(%Clause{trigger: {:after, _}}, _subject, _env), do: false
  defp matches?(%Clause{trigger: {:idle_for, _}}, _subject, _env), do: false

  defp matches?(%Clause{trigger: trigger, guard: guard}, subject, env) do
    Merlin.Rule.trigger_fires?(trigger, subject) and guard_passes?(guard, env)
  end

  defp guard_passes?(nil, _env), do: true
  defp guard_passes?(guard, env), do: Expr.truthy?(Expr.eval(guard, env))

  defp timeout_actions(%Machine{states: states}, state_name) do
    states
    |> Map.get(state_name, [])
    |> Enum.flat_map(fn
      %Clause{trigger: {:after, ms}} -> [{:state_timeout, ms, :after}]
      %Clause{trigger: {:idle_for, ms}} -> [{:timeout, ms, :idle_for}]
      _ -> []
    end)
  end

  # Atom segments, not binaries. An expression writes `rule.printer_power.state`,
  # which parses to [:rule, :printer_power, :state] -- so publishing under
  # to_string(id) would put the fact somewhere no rule could name it. The ids
  # and slot names are already atoms from the config, so no atom is created
  # here that did not already exist.
  defp publish_introspection(id, state_name, data) do
    World.put([:rule, id, :state], state_name, source: {:machine, id})

    for {slot, value} <- data do
      World.put([:rule, id, :data, slot], value, source: {:machine, id})
    end
  end

  defp base_env(trigger, %__MODULE__{data: data}) do
    %{read: &read/1, trigger: trigger, locals: data, group: Groups.resolver()}
  end

  defp trigger_env(%Change{} = c), do: Change.trigger_env(c)
  defp trigger_env(%Event{} = e), do: Event.trigger_env(e)

  defp read(path) do
    case World.fetch(path) do
      {:ok, fact} -> if Merlin.Fact.stale?(fact), do: :unknown, else: fact.value
      :error -> :unknown
    end
  end

  defp describe(%Change{path: p}), do: "change #{Path.to_string(p)}"
  defp describe(%Event{path: p}), do: "event #{Path.to_string(p)}"
  defp describe(other), do: inspect(other)
end
