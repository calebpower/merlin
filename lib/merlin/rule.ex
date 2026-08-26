defmodule Merlin.Rule do
  @moduledoc """
  A rule, compiled from data.

  At this milestone rules are stateless: a trigger, an optional guard, and a
  list of actions. Stateful rules -- the printer's timed power-cycle, the A/C
  load-shed's remembered desire, the intruder latch -- become `:gen_statem`
  executors at M5. Everything here is what they will be built on.

      %{
        id: :lamps_off_when_away,
        desc: "When I leave, turn the living room lamps off.",
        on: [{:leaves, [:person, :caleb, :zone], :home}],
        do: [{:set_group, :living_room_lamps, :off}]
      }

  ## Subscriptions are derived, never written

  A rule's watched paths come from its triggers *and* from the fact reads
  inside its guard, extracted by `Merlin.Expr`. There is no `watches:` key to
  get wrong. In the Python every hook received every state change and re-checked
  the key by hand, so forgetting a case was invisible; here forgetting is not
  expressible.
  """

  alias Merlin.Expr

  @enforce_keys [:id, :triggers, :actions]
  defstruct [:id, :desc, :triggers, :guard, :actions, :watches, :watch_events, enabled: true]

  @type trigger ::
          {:changes, Merlin.Path.t()}
          | {:changes_under, Merlin.Path.t()}
          | {:enters, Merlin.Path.t(), term()}
          | {:leaves, Merlin.Path.t(), term()}
          | {:receives, Merlin.Path.t()}

  @type action ::
          {:set_group, atom(), term() | {:expr, binary()}}
          | {:publish, binary(), term()}
          | {:set_fact, Merlin.Path.t(), term() | {:expr, binary()}}
          | {:log, atom(), binary() | {:expr, binary()}}

  @type t :: %__MODULE__{
          id: atom(),
          desc: binary() | nil,
          triggers: [trigger()],
          guard: Expr.t() | nil,
          actions: [action()],
          watches: [Merlin.Path.t()],
          watch_events: [Merlin.Path.t()],
          enabled: boolean()
        }

  @doc """
  Compile a rule from its data form.

  Returns `{:ok, rule}` or `{:error, reason}`. Every error names the rule id,
  because a boot report listing twelve anonymous failures is not a report.
  """
  @spec compile(map()) :: {:ok, t()} | {:error, term()}
  def compile(%{id: id} = data) when is_atom(id) do
    with {:ok, triggers} <- compile_triggers(id, Map.get(data, :on, [])),
         {:ok, guard} <- compile_guard(id, Map.get(data, :when)),
         {:ok, actions} <- compile_actions(id, Map.get(data, :do, [])) do
      {fact_watches, event_watches} = watches(triggers, guard)

      {:ok,
       %__MODULE__{
         id: id,
         desc: Map.get(data, :desc),
         triggers: triggers,
         guard: guard,
         actions: actions,
         watches: fact_watches,
         watch_events: event_watches,
         enabled: Map.get(data, :enabled, true)
       }}
    end
  end

  def compile(data), do: {:error, {:missing_id, data}}

  @doc "Whether `change_or_event` fires any of this rule's triggers."
  @spec fires?(t(), Merlin.Change.t() | Merlin.Event.t()) :: boolean()
  def fires?(%__MODULE__{triggers: triggers}, subject) do
    Enum.any?(triggers, &trigger_fires?(&1, subject))
  end

  defp trigger_fires?({:changes, path}, %Merlin.Change{path: p}), do: p == path

  defp trigger_fires?({:changes_under, prefix}, %Merlin.Change{path: p}),
    do: Merlin.Path.prefix?(prefix, p)

  defp trigger_fires?({:enters, path, value}, %Merlin.Change{path: p, new: new, old: old}),
    do: p == path and new == value and old != value

  defp trigger_fires?({:leaves, path, value}, %Merlin.Change{path: p, new: new, old: old}),
    do: p == path and old == value and new != value

  defp trigger_fires?({:receives, path}, %Merlin.Event{path: p}), do: p == path
  defp trigger_fires?(_, _), do: false

  # --- compilation ----------------------------------------------------------

  defp compile_triggers(id, []), do: {:error, {id, :no_triggers}}

  defp compile_triggers(id, triggers) when is_list(triggers) do
    Enum.reduce_while(triggers, {:ok, []}, fn t, {:ok, acc} ->
      case validate_trigger(t) do
        :ok -> {:cont, {:ok, acc ++ [t]}}
        {:error, reason} -> {:halt, {:error, {id, reason}}}
      end
    end)
  end

  defp compile_triggers(id, _), do: {:error, {id, :triggers_not_a_list}}

  defp validate_trigger({:changes, path}) when is_list(path), do: :ok
  defp validate_trigger({:changes_under, path}) when is_list(path), do: :ok
  defp validate_trigger({:enters, path, _}) when is_list(path), do: :ok
  defp validate_trigger({:leaves, path, _}) when is_list(path), do: :ok
  defp validate_trigger({:receives, path}) when is_list(path), do: :ok
  defp validate_trigger(other), do: {:error, {:bad_trigger, other}}

  defp compile_guard(_id, nil), do: {:ok, nil}

  defp compile_guard(id, source) when is_binary(source) do
    case Expr.compile(source) do
      {:ok, expr} -> {:ok, expr}
      {:error, reason} -> {:error, {id, {:bad_guard, source, reason}}}
    end
  end

  defp compile_guard(id, other), do: {:error, {id, {:guard_not_a_string, other}}}

  defp compile_actions(id, []), do: {:error, {id, :no_actions}}

  defp compile_actions(id, actions) when is_list(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      case compile_action(action) do
        {:ok, compiled} -> {:cont, {:ok, acc ++ [compiled]}}
        {:error, reason} -> {:halt, {:error, {id, reason}}}
      end
    end)
  end

  defp compile_actions(id, _), do: {:error, {id, :actions_not_a_list}}

  # Action parameters may be literals or expressions. Expressions are compiled
  # here, at boot, so a typo in an action is a boot failure rather than a
  # surprise at 3am when the rule first fires.
  defp compile_action({:set_group, group, value}) when is_atom(group) do
    with {:ok, v} <- compile_value(value), do: {:ok, {:set_group, group, v}}
  end

  defp compile_action({:publish, topic, payload}) when is_binary(topic) do
    with {:ok, p} <- compile_value(payload), do: {:ok, {:publish, topic, p}}
  end

  defp compile_action({:set_fact, path, value}) when is_list(path) do
    with {:ok, v} <- compile_value(value), do: {:ok, {:set_fact, path, v}}
  end

  defp compile_action({:log, level, message})
       when level in [:debug, :info, :warning, :error] do
    with {:ok, m} <- compile_value(message), do: {:ok, {:log, level, m}}
  end

  defp compile_action(other), do: {:error, {:bad_action, other}}

  defp compile_value({:expr, source}) when is_binary(source) do
    case Expr.compile(source) do
      {:ok, expr} -> {:ok, {:expr, expr}}
      {:error, reason} -> {:error, {:bad_expression, source, reason}}
    end
  end

  defp compile_value(literal), do: {:ok, {:lit, literal}}

  # --- watch derivation -----------------------------------------------------

  defp watches(triggers, guard) do
    from_triggers =
      Enum.flat_map(triggers, fn
        {:changes, path} -> [{:fact, path}]
        {:changes_under, prefix} -> [{:fact, prefix}]
        {:enters, path, _} -> [{:fact, path}]
        {:leaves, path, _} -> [{:fact, path}]
        {:receives, path} -> [{:event, path}]
      end)

    from_guard = if guard, do: Enum.map(Expr.deps(guard), &{:fact, &1}), else: []

    all = Enum.uniq(from_triggers ++ from_guard)

    {
      for({:fact, p} <- all, do: p),
      for({:event, p} <- all, do: p)
    }
  end
end
