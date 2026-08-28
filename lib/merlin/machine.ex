defmodule Merlin.Machine do
  @moduledoc """
  A stateful rule, declared as data and compiled for `:gen_statem`.

      %{
        id: :printer_power,
        machine: %{
          initial: :idle,
          states: %{
            idle: [
              %{on: {:receives, [:printer, :power_request]},
                when: "trigger.value == :reboot",
                do: [{:publish, "...", ~s({"state":"OFF"})}],
                goto: :dwell}
            ],
            dwell: [
              %{on: {:after, {10, :second}},
                do: [{:publish, "...", ~s({"state":"ON"})}],
                goto: :idle},
              %{on: {:receives, [:printer, :power_request]}, postpone: true}
            ]
          }
        }
      }

  ## Why one interpreter rather than four executors

  The obvious shape is a `Sequence` executor, a `LoadShed` executor, a `Latch`
  executor and a `Cooldown` executor -- four modules parameterised by config.
  This is one interpreter over declared states and clauses instead, because
  the four are the same machine with different tables, and because it keeps
  your stated split intact: the *executor* is a module, the *machine* is data.

  The concrete win is `office_aircond.py`. Its masking behaviour lived in
  `self.printer_active`, an instance variable that no rule could read, no
  dashboard could show, and no restart preserved. Here it is a **named state**
  -- `:shedding` -- published as `rule.<id>.state`, so "why did the A/C not
  come back on" is a question you can answer by looking.

  ## Clause semantics

  First match wins, exactly like `cond`. No match in the current state means
  the event is ignored: logged at debug, counted, and otherwise nothing. That
  "ignore by default" is what makes a dwell state trivially correct -- during
  the printer's ten seconds, anything not explicitly handled simply does not
  happen.
  """

  alias Merlin.{Expr, Rule}

  @enforce_keys [:id, :initial, :states]
  defstruct [
    :id,
    :desc,
    :initial,
    :states,
    :watches,
    :watch_events,
    :watch_groups,
    data: %{},
    persist: false,
    enabled: true
  ]

  defmodule Clause do
    @moduledoc "One row of a state's table."
    @enforce_keys [:trigger]
    defstruct [:trigger, :guard, :goto, sets: %{}, actions: [], postpone: false]
  end

  @type t :: %__MODULE__{}

  @doc """
  Compile a machine from its data form.

  Every error names the machine and, where it can, the state and clause index.
  A boot report saying only "invalid machine" costs a bisect.
  """
  @spec compile(map()) :: {:ok, t()} | {:error, term()}
  def compile(%{id: id, machine: m} = outer) when is_atom(id) and is_map(m) do
    with {:ok, initial} <- fetch_initial(id, m),
         {:ok, states} <- compile_states(id, Map.get(m, :states, %{})),
         :ok <- check_gotos(id, initial, states),
         :ok <- check_slots(id, Map.get(m, :data, %{}), states) do
      {fact_watches, event_watches, group_watches} = watches(states)

      {:ok,
       %__MODULE__{
         id: id,
         desc: Map.get(outer, :desc) || Map.get(m, :desc),
         initial: initial,
         states: states,
         data: Map.get(m, :data, %{}),
         persist: Map.get(m, :persist, false),
         enabled: Map.get(m, :enabled, true),
         watches: fact_watches,
         watch_events: event_watches,
         watch_groups: group_watches
       }}
    end
  end

  def compile(other), do: {:error, {:not_a_machine, other}}

  # --- compilation ----------------------------------------------------------

  defp fetch_initial(id, m) do
    case Map.get(m, :initial) do
      nil -> {:error, {id, :no_initial_state}}
      state when is_atom(state) -> {:ok, state}
      other -> {:error, {id, {:bad_initial_state, other}}}
    end
  end

  defp compile_states(id, states) when map_size(states) == 0,
    do: {:error, {id, :no_states}}

  defp compile_states(id, states) do
    Enum.reduce_while(states, {:ok, %{}}, fn {name, clauses}, {:ok, acc} ->
      case compile_clauses(id, name, clauses) do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, name, compiled)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp compile_clauses(id, state, clauses) when is_list(clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {clause, index}, {:ok, acc} ->
      case compile_clause(id, state, index, clause) do
        {:ok, c} -> {:cont, {:ok, acc ++ [c]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp compile_clauses(id, state, _), do: {:error, {id, {state, :clauses_not_a_list}}}

  defp compile_clause(id, state, index, clause) when is_map(clause) do
    with {:ok, trigger} <- compile_trigger(id, state, index, Map.get(clause, :on)),
         {:ok, guard} <- compile_guard(id, state, index, Map.get(clause, :when)),
         {:ok, actions} <- compile_actions(id, state, index, Map.get(clause, :do, [])),
         {:ok, sets} <- compile_sets(id, state, index, Map.get(clause, :set, %{})) do
      {:ok,
       %Clause{
         trigger: trigger,
         guard: guard,
         actions: actions,
         sets: sets,
         goto: Map.get(clause, :goto),
         postpone: Map.get(clause, :postpone, false)
       }}
    end
  end

  defp compile_clause(id, state, index, _), do: {:error, {id, {state, index, :bad_clause}}}

  # Durations are declared as {n, unit} and canonicalised to milliseconds here,
  # so nothing downstream has to know what a minute is -- and so a test can
  # declare {10, :millisecond} where production declares {10, :second} and
  # exercise the identical state timeout.
  defp compile_trigger(_id, _s, _i, {:after, duration}) do
    with {:ok, ms} <- to_ms(duration), do: {:ok, {:after, ms}}
  end

  defp compile_trigger(_id, _s, _i, {:idle_for, duration}) do
    with {:ok, ms} <- to_ms(duration), do: {:ok, {:idle_for, ms}}
  end

  defp compile_trigger(id, state, index, nil),
    do: {:error, {id, {state, index, :clause_has_no_trigger}}}

  defp compile_trigger(id, state, index, trigger) do
    case Rule.validate_trigger(trigger) do
      :ok -> {:ok, trigger}
      {:error, reason} -> {:error, {id, {state, index, reason}}}
    end
  end

  defp compile_guard(_id, _s, _i, nil), do: {:ok, nil}

  defp compile_guard(id, state, index, source) when is_binary(source) do
    case Expr.compile(source) do
      {:ok, expr} -> {:ok, expr}
      {:error, reason} -> {:error, {id, {state, index, {:bad_guard, source, reason}}}}
    end
  end

  defp compile_guard(id, state, index, other),
    do: {:error, {id, {state, index, {:guard_not_a_string, other}}}}

  defp compile_actions(id, state, index, actions) when is_list(actions) do
    case Rule.compile_action_list(actions) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> {:error, {id, {state, index, reason}}}
    end
  end

  defp compile_actions(id, state, index, _),
    do: {:error, {id, {state, index, :actions_not_a_list}}}

  defp compile_sets(id, state, index, sets) when is_map(sets) do
    Enum.reduce_while(sets, {:ok, %{}}, fn {slot, value}, {:ok, acc} ->
      case Rule.compile_value(value) do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, slot, compiled)}}
        {:error, reason} -> {:halt, {:error, {id, {state, index, {slot, reason}}}}}
      end
    end)
  end

  defp compile_sets(id, state, index, _), do: {:error, {id, {state, index, :set_not_a_map}}}

  @doc "Canonicalise a duration to milliseconds."
  @spec to_ms({number(), atom()} | non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def to_ms(ms) when is_integer(ms) and ms >= 0, do: {:ok, ms}
  def to_ms({n, :millisecond}) when is_number(n) and n >= 0, do: {:ok, round(n)}
  def to_ms({n, :second}) when is_number(n) and n >= 0, do: {:ok, round(n * 1_000)}
  def to_ms({n, :minute}) when is_number(n) and n >= 0, do: {:ok, round(n * 60_000)}
  def to_ms({n, :hour}) when is_number(n) and n >= 0, do: {:ok, round(n * 3_600_000)}
  def to_ms(other), do: {:error, {:bad_duration, other}}

  # --- structural checks ----------------------------------------------------

  # A goto naming a state that does not exist is a machine that wedges the
  # first time that clause fires -- at 3am, months later. Boot instead.
  defp check_gotos(id, initial, states) do
    names = Map.keys(states) |> MapSet.new()

    bad =
      for {state, clauses} <- states,
          %Clause{goto: goto} <- clauses,
          not is_nil(goto),
          not MapSet.member?(names, goto),
          do: {state, goto}

    cond do
      not MapSet.member?(names, initial) -> {:error, {id, {:initial_state_undefined, initial}}}
      bad != [] -> {:error, {id, {:goto_undefined_state, bad}}}
      true -> :ok
    end
  end

  # A `set:` writing a slot that `data:` never declared is a typo that would
  # otherwise create the slot silently and be readable as :unknown forever.
  defp check_slots(id, data, states) do
    declared = data |> Map.keys() |> MapSet.new()

    undeclared =
      for {state, clauses} <- states,
          %Clause{sets: sets} <- clauses,
          slot <- Map.keys(sets),
          not MapSet.member?(declared, slot),
          do: {state, slot}

    if undeclared == [], do: :ok, else: {:error, {id, {:undeclared_slots, undeclared}}}
  end

  defp watches(states) do
    all =
      for {_state, clauses} <- states,
          %Clause{trigger: trigger, guard: guard} <- clauses,
          watch <- trigger_watches(trigger) ++ guard_watches(guard),
          do: watch

    all = Enum.uniq(all)

    {for({:fact, p} <- all, do: p), for({:event, p} <- all, do: p),
     for({:group, g} <- all, do: g)}
  end

  defp trigger_watches({:changes, path}), do: [{:fact, path}]
  defp trigger_watches({:changes_under, prefix}), do: [{:fact, prefix}]
  defp trigger_watches({:changes_in, group}), do: [{:group, group}]
  defp trigger_watches({:enters, path, _}), do: [{:fact, path}]
  defp trigger_watches({:leaves, path, _}), do: [{:fact, path}]
  defp trigger_watches({:receives, path}), do: [{:event, path}]
  defp trigger_watches(_timer), do: []

  defp guard_watches(nil), do: []
  defp guard_watches(expr), do: Enum.map(Expr.deps(expr), &{:fact, &1})
end
