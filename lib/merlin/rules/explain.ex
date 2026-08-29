defmodule Merlin.Rules.Explanation do
  @moduledoc "What a rule would do, and why."

  @enforce_keys [:id, :kind, :triggered?, :guard, :fires?]
  defstruct [
    :id,
    :kind,
    :triggered?,
    :guard,
    :guard_source,
    :fires?,
    :state,
    :clause,
    effects: [],
    skipped: nil
  ]

  @type guard_outcome :: :none | :pass | {:refused, term()}

  @type t :: %__MODULE__{
          id: atom(),
          kind: :rule | :machine,
          triggered?: boolean(),
          guard: guard_outcome(),
          guard_source: binary() | nil,
          fires?: boolean(),
          state: atom() | nil,
          clause: non_neg_integer() | nil,
          effects: [Merlin.Effects.effect()],
          skipped: term() | nil
        }
end

defmodule Merlin.Rules.Explain do
  @moduledoc """
  Why a rule did, or did not, do anything.

  Answers the question the log cannot: given this change, what would each rule
  do, and for the ones that do nothing, which step declined -- the trigger, the
  guard, or an action whose value could not be resolved.

  ## Replay, not a recording

  Nothing is recorded on the hot path. `Merlin.Rule.fires?/2` and the guard
  evaluator are pure with respect to the world, so the question is answered by
  running them again rather than by writing an audit trail per change per rule.
  That keeps the cost at zero when nobody is asking.

  It has a consequence that must be labelled honestly wherever this is
  displayed: a re-run evaluates against the world **as it is now**, not as it
  was. Two modes, and the distinction is the caller's to present:

    * **hypothetical** -- "if this door opened right now, what would happen?"
      Entirely truthful: the change is invented, so now is the only sensible
      moment to evaluate it against.

    * **retrospective** -- "here is a change from four minutes ago; why did
      nothing happen?" The guard result may differ from what it was at the
      time, because a fact it reads may have moved since. Presenting this as a
      record of what happened would be a lie, and the kind that costs a night.

  ## Why it lives on the daemon

  Two things it needs are daemon-local and neither is obvious. Firstly
  `trigger_fires?({:changes_in, group}, ...)` consults `Merlin.Groups.members/1`,
  which reads the loaded configuration. Secondly a guard needs an environment
  bound to the live ETS table. A client evaluating either from outside would
  get a confident wrong answer rather than an error.

  ## It never performs anything

  Actions are resolved -- which is where `{:skip, {:unknown_value, _}}` comes
  from, and is worth reporting -- and then thrown away. `Merlin.Effects.perform/2`
  is not called and is not reachable from here.
  """

  alias Merlin.{Change, Config, Effects, Event, Machine, Rule}
  alias Merlin.Machine.Clause
  alias Merlin.Rules.{Env, Explanation}

  @type subject :: Change.t() | Event.t()

  @doc """
  Explain every configured rule against `subject`.

  Ordered as the configuration declares them, so two runs read the same way.
  """
  @spec explain_all(subject()) :: [Explanation.t()]
  def explain_all(subject) do
    Config.rules() |> Enum.map(&explain(&1, subject))
  end

  @doc """
  Explain one rule, by id or by struct.

  Returns `{:error, {:unknown_rule, id}}` for an id this house does not
  declare, rather than an explanation that says nothing would happen -- which
  would be indistinguishable from a rule that exists and declines.
  """
  @spec explain(atom() | Rule.t() | Machine.t(), subject()) ::
          Explanation.t() | {:error, {:unknown_rule, atom()}}
  def explain(id, subject) when is_atom(id) do
    case Enum.find(Config.rules(), &(rule_id(&1) == id)) do
      nil -> {:error, {:unknown_rule, id}}
      rule -> explain(rule, subject)
    end
  end

  def explain(%Rule{} = rule, subject) do
    env = Env.build(trigger_env(subject))

    if Rule.fires?(rule, subject) do
      guarded(rule.id, :rule, rule.guard, rule.actions, env)
    else
      %Explanation{
        id: rule.id,
        kind: :rule,
        triggered?: false,
        guard: :none,
        fires?: false
      }
    end
  end

  def explain(%Machine{} = machine, subject) do
    state = current_state(machine)
    data = current_data(machine)
    env = Env.build(trigger_env(subject), data)
    clauses = Map.get(machine.states, state, [])

    clauses
    |> Enum.with_index()
    |> Enum.find_value(fn {clause, index} ->
      if Rule.trigger_fires?(clause.trigger, subject) do
        {clause, index}
      end
    end)
    |> case do
      nil ->
        %Explanation{
          id: machine.id,
          kind: :machine,
          triggered?: false,
          guard: :none,
          fires?: false,
          state: state
        }

      {%Clause{} = clause, index} ->
        explanation = guarded(machine.id, :machine, clause.guard, clause.actions, env)
        %{explanation | state: state, clause: index}
    end
  end

  # --- the shared half ------------------------------------------------------

  defp guarded(id, kind, guard, actions, env) do
    base = %Explanation{
      id: id,
      kind: kind,
      triggered?: true,
      # :none, not :pass. Env.guard/2 answers :pass for a nil guard, which is
      # right for the engine -- there is nothing to refuse -- but a reader
      # asking why a rule fired is owed the difference between "its guard was
      # satisfied" and "it has no guard at all".
      guard: if(guard, do: Env.guard(guard, env), else: :none),
      guard_source: guard && guard.source,
      fires?: false
    }

    case base.guard do
      {:refused, _} ->
        base

      _passed_or_absent ->
        # Resolved, never performed. This is also where an action whose value
        # evaluates to :unknown shows up -- a rule that triggers, passes its
        # guard, and still does nothing, which is otherwise only visible as a
        # debug line nobody has enabled.
        case Effects.resolve(actions, env, Config.groups()) do
          {:ok, effects} -> %{base | fires?: true, effects: effects}
          {:skip, reason} -> %{base | fires?: false, skipped: reason}
        end
    end
  end

  # --- machine state, without assuming one is running -----------------------

  # A machine declared in the config may have no process: in a test, or during
  # boot, or if its supervisor is still starting. Falling back to the declared
  # initial state is honest -- it is what the machine WOULD be in -- and it is
  # better than refusing to explain anything at all.
  defp current_state(%Machine{} = m) do
    Machine.Server.state(m.id)
  catch
    :exit, _ -> m.initial
  end

  defp current_data(%Machine{} = m) do
    Machine.Server.data(m.id)
  catch
    :exit, _ -> m.data
  end

  defp rule_id(%Rule{id: id}), do: id
  defp rule_id(%Machine{id: id}), do: id

  defp trigger_env(%Change{} = c), do: Change.trigger_env(c)
  defp trigger_env(%Event{} = e), do: Event.trigger_env(e)
end
