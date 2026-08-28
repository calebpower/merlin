defmodule Merlin.Rules.Env do
  @moduledoc """
  What a guard sees, and what it answered. Defined once.

  ## One definition of the environment

  `Merlin.Rules.Engine` and `Merlin.Machine.Server` each built this map inline,
  with the same four keys and a byte-identical private `read/1` beside it. Two
  copies of "what a guard can see" is the shape of defect this codebase has
  paid for repeatedly -- the deep resolver beside the shallow one, the key
  whitelist beside the builder, the tier tag beside the filter. Each time the
  two agreed until they quietly did not.

  It also blocks a feature outright: `Merlin.Rules.Explain` has to evaluate a
  guard exactly as the engine would, and a third copy would be a third thing to
  drift.

  ## Three-valued answers, kept

  `guard/2` returns the raw answer rather than a boolean. Every operator in
  `Merlin.Expr` propagates `:unknown`, so a guard has three outcomes and the
  callers were recording one bit:

    * `true`     -- fire
    * `false`    -- the condition is genuinely not met
    * `:unknown` -- something it reads is stale, absent, or unknowable

  `false` and `:unknown` mean completely different things to somebody asking
  why a rule did not fire. "The door is shut" and "the sensor has not been
  heard from since Tuesday" are different houses. Collapsing them was invisible
  by construction: `guard_passes?/2` returned a bare boolean and logged
  nothing at any level, so a rule declining because a fact went stale looked
  exactly like one declining because the world was fine.

  Firing behaviour is unchanged: `:pass` still requires literal `true`, which
  is what `Merlin.Expr.truthy?/1` meant. This observes the decision; it does
  not alter it.
  """

  alias Merlin.{Expr, Fact, Groups, World}

  @typedoc "Why a guard did not pass. The raw evaluation result, not a boolean."
  @type refusal :: false | :unknown | term()

  @doc """
  The evaluation environment for a guard or an action expression.

  `locals` is a machine's data slots, readable as `local.<slot>`; a stateless
  rule has none.
  """
  @spec build(map(), map()) :: Expr.env()
  def build(trigger, locals \\ %{}) do
    %{read: &read/1, trigger: trigger, group: Groups.resolver(), locals: locals}
  end

  @doc """
  Read a fact as a guard sees it.

  A fact past its `stale_after` reads `:unknown` rather than its last value,
  which is the difference between "the car is at home" and "the car was at
  home when the tracker last spoke, four hours ago". An absent fact is
  `:unknown` too -- a rule cannot tell the two apart, and should not.
  """
  @spec read(Merlin.Path.t()) :: term()
  def read(path) do
    case World.fetch(path) do
      {:ok, fact} -> if Fact.stale?(fact), do: :unknown, else: fact.value
      :error -> :unknown
    end
  end

  @doc """
  Evaluate a guard, keeping the answer.

  Returns `:pass` or `{:refused, why}`, where `why` is the raw result. A rule
  with no guard passes.
  """
  @spec guard(Expr.t() | nil, Expr.env()) :: :pass | {:refused, refusal()}
  def guard(nil, _env), do: :pass

  def guard(expr, env) do
    case Expr.eval(expr, env) do
      true -> :pass
      other -> {:refused, other}
    end
  end

  @doc """
  A one-line account of a refusal, for a log or a UI.

  Kept here rather than at each call site so the engine and the machines
  describe the same refusal the same way.
  """
  @spec describe_refusal(refusal()) :: binary()
  def describe_refusal(:unknown),
    do: "guard is :unknown -- something it reads is stale, absent, or unknowable"

  def describe_refusal(false), do: "guard is false"

  def describe_refusal(other),
    do: "guard evaluated to #{inspect(other)}, which is neither true nor false"
end
