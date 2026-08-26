defmodule Merlin.Expr do
  @moduledoc """
  The bounded expression language that rule data is written in.

      "person.caleb.zone == :home and vehicle.car.zone != :home"

  ## How it works, and what it deliberately is not

  Source is parsed with `Code.string_to_quoted/1` -- Elixir's own parser, so
  the syntax is exactly what you would write in Elixir and there is no grammar
  to maintain. The resulting AST is then **walked and compiled into a closure
  tree**. It is never `eval`'d and never `Code.eval_quoted`'d, so nothing
  outside the whitelist below can execute, however the source is spelled.

  The whitelist is closed: literals, a fixed operator set, fact reads, three
  scoped reads, and a fixed set of builtins. There is **no way to loop** --
  no comprehensions, no recursion, no function definitions -- so every
  expression terminates in bounded time. That guarantee is the invariant of
  this module; anything that would break it belongs in an Elixir module
  instead.

  ## Three-valued logic

  Every fact is `value | :unknown`, and `:unknown` propagates. This is the
  direct fix for `user_location.py:124`, which yielded `""` for "phone is
  outside every zone" while its consumers tested `is False` -- so the
  user-has-left path never fired in production.

  Kleene semantics, so that "we do not know" cannot masquerade as "no":

      true  and :unknown  ->  :unknown        false and :unknown  ->  false
      true  or  :unknown  ->  true            false or  :unknown  ->  :unknown
      not :unknown        ->  :unknown
      :unknown == anything ->  :unknown

  A guard fires only on literal `true`. `:unknown` never fires a rule.

  ## The builtin budget

  There are #{10} builtins and the ceiling is **25**, written down in the
  README. Crossing it means this has become a programming language with no
  debugger, no types and no stack traces, and the answer at that point is to
  write a module. Anything with I/O, anything iterating an unbounded
  collection, anything stateful across evaluations, and anything a reasonable
  person would call an algorithm is a module by definition.
  """

  defstruct [:source, :fun, :deps]

  @type value :: term() | :unknown
  @type env :: %{
          optional(:read) => (Merlin.Path.t() -> value()),
          optional(:trigger) => map(),
          optional(:locals) => map(),
          optional(:group) => (atom() -> [Merlin.Path.t()])
        }
  @type t :: %__MODULE__{
          source: binary(),
          fun: (env() -> value()),
          deps: [Merlin.Path.t()]
        }

  @operators [:==, :!=, :<, :<=, :>, :>=, :and, :or, :not, :in, :+, :-, :*, :/]

  # {name, arity} => implementation. The budget is 25; this is 10.
  @builtins %{
    {:if, 3} => :if_,
    {:defined?, 1} => :defined?,
    {:unknown?, 1} => :unknown?,
    {:all_eq?, 2} => :all_eq?,
    {:any_eq?, 2} => :any_eq?,
    {:count_eq, 2} => :count_eq,
    {:distance, 2} => :distance,
    {:within?, 3} => :within?,
    {:to_s, 1} => :to_s,
    {:abs, 1} => :abs_
  }

  @scoped_roots [:local, :trigger]

  @doc "The number of builtins currently defined. Asserted against the budget in tier 1."
  @spec builtin_count() :: non_neg_integer()
  def builtin_count, do: map_size(@builtins)

  @doc "The hard ceiling on builtins."
  @spec builtin_budget() :: pos_integer()
  def builtin_budget, do: 25

  @doc "Every builtin's `{name, arity}`."
  @spec builtins() :: [{atom(), non_neg_integer()}]
  def builtins, do: Map.keys(@builtins)

  @doc """
  Compile source into a closure tree.

  Returns `{:ok, expr}` or `{:error, reason}`. Errors carry the offending
  fragment, because a rule author needs to know which part of their line was
  refused, not merely that the line was.
  """
  @spec compile(binary()) :: {:ok, t()} | {:error, term()}
  def compile(source) when is_binary(source) do
    with {:ok, ast} <- parse(source),
         {:ok, node} <- check(ast) do
      {:ok, %__MODULE__{source: source, fun: build(node), deps: extract_deps(node)}}
    end
  end

  @doc "Compile, raising on refusal."
  @spec compile!(binary()) :: t()
  def compile!(source) do
    case compile(source) do
      {:ok, expr} -> expr
      {:error, reason} -> raise ArgumentError, "bad expression #{inspect(source)}: #{inspect(reason)}"
    end
  end

  @doc """
  Evaluate against an environment.

  NOT an evaluator of source. By the time this runs, `compile/1` has already
  reduced the expression to a tree of closures drawn exclusively from the
  whitelist in this module; `fun` is an ordinary Elixir function and there is
  no interpreter, no `Code.eval_*`, and no path by which unlisted code could
  execute. `Code.string_to_quoted/1` in `compile/1` parses and does not run
  anything.

  (One consequence of using Elixir's parser worth knowing: it interns atoms.
  Rule sources come from a root-owned config file at the same trust level as
  the release binary, so that is acceptable here -- but it is a reason not to
  compile expressions arriving from anywhere else, ever.)

  Never raises on ordinary data problems -- a comparison against a missing
  fact yields `:unknown` rather than blowing up, because a home daemon must
  not lose the lights to a bad comparison.
  """
  @spec eval(t(), env()) :: value()
  def eval(%__MODULE__{fun: fun}, env), do: fun.(normalise(env))

  @doc "Whether a value fires a guard. Only literal `true` does."
  @spec truthy?(value()) :: boolean()
  def truthy?(true), do: true
  def truthy?(_), do: false

  @doc "The fact paths this expression reads. Used to derive subscriptions automatically."
  @spec deps(t()) :: [Merlin.Path.t()]
  def deps(%__MODULE__{deps: deps}), do: deps

  # --- parsing --------------------------------------------------------------

  defp parse(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {_meta, message, token}} -> {:error, {:parse_error, "#{message}#{token}"}}
    end
  end

  # --- checking: the whitelist walk ----------------------------------------

  defp check(lit) when is_number(lit) or is_binary(lit) or is_boolean(lit) or is_nil(lit),
    do: {:ok, {:lit, lit}}

  defp check(lit) when is_atom(lit), do: {:ok, {:lit, lit}}

  defp check(list) when is_list(list) do
    with {:ok, items} <- check_all(list), do: {:ok, {:list, items}}
  end

  # Operators.
  defp check({op, _meta, args}) when op in @operators and is_list(args) do
    with {:ok, checked} <- check_all(args), do: {:ok, {:op, op, checked}}
  end

  # Builtins.
  defp check({name, meta, args}) when is_atom(name) and is_list(args) do
    case Map.fetch(@builtins, {name, length(args)}) do
      {:ok, impl} ->
        with {:ok, checked} <- check_all(args), do: {:ok, {:call, impl, checked}}

      :error ->
        if Map.has_key?(@builtins, name) or Enum.any?(@builtins, fn {{n, _}, _} -> n == name end) do
          {:error, {:wrong_arity, name, length(args), line(meta)}}
        else
          # Might still be a dotted fact path with parens, or simply unknown.
          {:error, {:unknown_function, name, length(args), line(meta)}}
        end
    end
  end

  # Dotted paths: fact reads and scoped reads.
  defp check({{:., _, [_, _]}, _, []} = dotted) do
    case path_segments(dotted) do
      {:ok, [root | rest]} when root in @scoped_roots -> {:ok, {:scoped, root, rest}}
      {:ok, segments} -> {:ok, {:fact, segments}}
      :error -> {:error, {:forbidden_syntax, Macro.to_string(dotted)}}
    end
  end

  # A bare identifier is a one-segment fact path.
  defp check({name, _meta, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: {:ok, {:fact, [name]}}

  defp check(other), do: {:error, {:forbidden_syntax, Macro.to_string(other)}}

  defp check_all(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case check(item) do
        {:ok, checked} -> {:cont, {:ok, acc ++ [checked]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line(_), do: nil

  # `a.b.c` nests as {{:., _, [inner, :c]}, _, []}.
  defp path_segments({{:., _, [inner, seg]}, _, []}) when is_atom(seg) do
    case path_segments(inner) do
      {:ok, segments} -> {:ok, segments ++ [seg]}
      :error -> :error
    end
  end

  defp path_segments({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: {:ok, [name]}

  defp path_segments(_), do: :error

  # --- dependency extraction ------------------------------------------------

  defp extract_deps({:fact, segments}), do: [segments]
  defp extract_deps({:op, _, args}), do: Enum.flat_map(args, &extract_deps/1)
  defp extract_deps({:call, _, args}), do: Enum.flat_map(args, &extract_deps/1)
  defp extract_deps({:list, items}), do: Enum.flat_map(items, &extract_deps/1)
  defp extract_deps(_), do: []

  # --- compilation to closures ---------------------------------------------

  defp build({:lit, value}), do: fn _env -> value end

  defp build({:list, items}) do
    funs = Enum.map(items, &build/1)
    fn env -> Enum.map(funs, & &1.(env)) end
  end

  defp build({:fact, segments}), do: fn env -> env.read.(segments) end

  defp build({:scoped, :local, [key]}), do: fn env -> Map.get(env.locals, key, :unknown) end

  defp build({:scoped, :trigger, [key]}) do
    fn env ->
      case Map.fetch(env.trigger, key) do
        {:ok, value} -> value
        :error -> Map.get(env.trigger[:captures] || %{}, Atom.to_string(key), :unknown)
      end
    end
  end

  defp build({:scoped, root, rest}) do
    fn _env -> raise ArgumentError, "bad scoped read #{root}.#{Enum.join(rest, ".")}" end
  end

  # Short-circuiting, three-valued.
  defp build({:op, :and, [l, r]}) do
    lf = build(l)
    rf = build(r)

    fn env ->
      case lf.(env) do
        false -> false
        left -> kleene_and(left, rf.(env))
      end
    end
  end

  defp build({:op, :or, [l, r]}) do
    lf = build(l)
    rf = build(r)

    fn env ->
      case lf.(env) do
        true -> true
        left -> kleene_or(left, rf.(env))
      end
    end
  end

  defp build({:op, :not, [a]}) do
    af = build(a)

    fn env ->
      case af.(env) do
        true -> false
        false -> true
        _ -> :unknown
      end
    end
  end

  defp build({:op, op, args}) do
    funs = Enum.map(args, &build/1)

    fn env ->
      values = Enum.map(funs, & &1.(env))
      if Enum.any?(values, &(&1 == :unknown)), do: :unknown, else: apply_op(op, values)
    end
  end

  defp build({:call, impl, args}) do
    funs = Enum.map(args, &build/1)
    Merlin.Expr.Builtins.build(impl, funs)
  end

  # --- operator application -------------------------------------------------

  defp apply_op(:==, [a, b]), do: a == b
  defp apply_op(:!=, [a, b]), do: a != b
  defp apply_op(:in, [a, b]) when is_list(b), do: a in b
  defp apply_op(:in, [_, _]), do: :unknown

  defp apply_op(op, [a, b]) when op in [:<, :<=, :>, :>=] do
    # Ordering a number against a non-number is a rule-authoring mistake, not
    # a reason to crash the daemon. Refuse it as :unknown.
    if comparable?(a, b), do: compare(op, a, b), else: :unknown
  end

  defp apply_op(:/, [_, 0]), do: :unknown
  defp apply_op(:/, [_, +0.0]), do: :unknown

  defp apply_op(op, [a, b]) when op in [:+, :-, :*, :/] do
    if is_number(a) and is_number(b), do: arith(op, a, b), else: :unknown
  end

  defp apply_op(_op, _values), do: :unknown

  defp comparable?(a, b) when is_number(a) and is_number(b), do: true
  defp comparable?(a, b) when is_binary(a) and is_binary(b), do: true
  defp comparable?(_, _), do: false

  defp compare(:<, a, b), do: a < b
  defp compare(:<=, a, b), do: a <= b
  defp compare(:>, a, b), do: a > b
  defp compare(:>=, a, b), do: a >= b

  defp arith(:+, a, b), do: a + b
  defp arith(:-, a, b), do: a - b
  defp arith(:*, a, b), do: a * b
  defp arith(:/, a, b), do: a / b

  # --- Kleene ---------------------------------------------------------------

  defp kleene_and(false, _), do: false
  defp kleene_and(_, false), do: false
  defp kleene_and(true, true), do: true
  defp kleene_and(_, _), do: :unknown

  defp kleene_or(true, _), do: true
  defp kleene_or(_, true), do: true
  defp kleene_or(false, false), do: false
  defp kleene_or(_, _), do: :unknown

  # --- environment ----------------------------------------------------------

  defp normalise(env) do
    %{
      read: Map.get(env, :read, &default_read/1),
      trigger: Map.get(env, :trigger, %{}),
      locals: Map.get(env, :locals, %{}),
      group: Map.get(env, :group, fn _ -> [] end)
    }
  end

  defp default_read(path) do
    case Merlin.World.fetch(path) do
      {:ok, fact} -> if Merlin.Fact.stale?(fact), do: :unknown, else: fact.value
      :error -> :unknown
    end
  end
end
