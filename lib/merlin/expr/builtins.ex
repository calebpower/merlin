defmodule Merlin.Expr.Builtins do
  @moduledoc """
  The closed set of functions rule data may call.

  Every one is pure, total, and bounded: no I/O, no unbounded iteration, no
  state carried between evaluations. `count_eq/2` and friends iterate a
  *declared* group, whose membership is fixed in config, which is why they are
  admissible where "for every sensor in the house" would not be.

  `:unknown` propagates through all of them unless the builtin's whole purpose
  is to interrogate unknown-ness (`defined?/1`, `unknown?/1`) or to choose
  between branches (`if/3`).

  Adding one means adding a test for it and checking the budget in
  `Merlin.Expr`. The ceiling is 25 and this is where you will notice you have
  reached it.
  """

  alias Merlin.Geo

  @doc false
  # Each clause returns a closure over the already-built argument closures.

  # if(cond, a, b) -- short-circuits, and refuses to guess on :unknown.
  def build(:if_, [c, a, b]) do
    fn env ->
      case c.(env) do
        true -> a.(env)
        false -> b.(env)
        _ -> :unknown
      end
    end
  end

  # Has a real value: neither absent nor stale nor explicitly :unknown.
  def build(:defined?, [a]) do
    fn env ->
      case a.(env) do
        :unknown -> false
        nil -> false
        _ -> true
      end
    end
  end

  def build(:unknown?, [a]) do
    fn env -> a.(env) == :unknown end
  end

  # Group aggregates. Membership is declared config, so these are bounded.
  def build(:all_eq?, [g, v]), do: group_pred(g, v, :all)
  def build(:any_eq?, [g, v]), do: group_pred(g, v, :any)

  def build(:count_eq, [g, v]) do
    fn env ->
      with {:ok, values, target} <- group_values(g, v, env) do
        Enum.count(values, &(&1 == target))
      end
    end
  end

  def build(:distance, [a, b]) do
    fn env ->
      with {:ok, pa} <- point(a.(env)),
           {:ok, pb} <- point(b.(env)) do
        Geo.distance(pa, pb)
      else
        _ -> :unknown
      end
    end
  end

  def build(:within?, [a, b, r]) do
    fn env ->
      with {:ok, pa} <- point(a.(env)),
           {:ok, pb} <- point(b.(env)),
           radius when is_number(radius) <- r.(env) do
        Geo.within?(pa, pb, radius)
      else
        _ -> :unknown
      end
    end
  end

  def build(:to_s, [a]) do
    fn env ->
      case a.(env) do
        :unknown -> :unknown
        v when is_binary(v) -> v
        v when is_atom(v) -> Atom.to_string(v)
        v when is_number(v) -> to_string(v)
        v -> inspect(v)
      end
    end
  end

  # to_s/2: render, or fall back if the value is unknown.
  #
  # to_s/1 propagates :unknown, which is right -- three-valued logic is the
  # whole discipline and a stringified "unknown" leaking into a comparison is
  # exactly what it exists to stop. But it makes the obvious spelling of a
  # message dangerous: `"a door opened: " + to_s(trigger.room)` is :unknown
  # when the room is missing, the action is skipped as an unresolvable value,
  # and an intruder alert is silently suppressed because merlin could not name
  # the door. Losing the name must not cost the alert.
  #
  # So the safe form is the SHORT form. Anything that names a thing in a
  # message should reach for this one.
  def build(:to_s_or, [a, fallback]) do
    rendered = build(:to_s, [a])

    fn env ->
      case rendered.(env) do
        :unknown -> fallback.(env)
        v -> v
      end
    end
  end

  def build(:abs_, [a]) do
    fn env ->
      case a.(env) do
        v when is_number(v) -> abs(v)
        _ -> :unknown
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp group_pred(g, v, mode) do
    fn env ->
      case group_values(g, v, env) do
        {:ok, [], _target} ->
          # An empty group is a config error, not a truth. Saying "all of
          # nothing is ON" would silently make a rule fire on a typo'd group
          # name; :unknown makes it visible instead.
          :unknown

        {:ok, values, target} ->
          cond do
            Enum.any?(values, &(&1 == :unknown)) -> :unknown
            mode == :all -> Enum.all?(values, &(&1 == target))
            mode == :any -> Enum.any?(values, &(&1 == target))
          end

        other ->
          other
      end
    end
  end

  defp group_values(g, v, env) do
    with name when name != :unknown <- g.(env),
         target when target != :unknown <- v.(env) do
      paths = env.group.(name)
      {:ok, Enum.map(paths, env.read), target}
    else
      _ -> :unknown
    end
  end

  defp point({lat, lon}) when is_number(lat) and is_number(lon), do: {:ok, {lat, lon}}
  defp point([lat, lon]) when is_number(lat) and is_number(lon), do: {:ok, {lat, lon}}
  defp point(_), do: :error
end
