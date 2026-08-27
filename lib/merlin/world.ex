defmodule Merlin.World do
  @moduledoc """
  The world model: what merlin currently believes about the house.

  Reads go straight to ETS in the calling process -- no message passing, no
  GenServer in the hot path, unlimited concurrency. Writes are funnelled
  through `Merlin.World.Writer`, which is the only process permitted to touch
  the table. That asymmetry is the whole design: reads are frequent, cheap and
  safe to parallelise; writes are rare and must be ordered.

  There is deliberately no direct-write function here. The single-writer
  discipline is enforced by this module's API surface rather than by ETS
  permissions, because the table has to stay `:public` for the writer to avoid
  copying through the owner.
  """

  alias Merlin.{Fact, Path}
  alias Merlin.World.{Table, Writer}

  @doc "The current value at `path`, or `default` if there is no such fact."
  @spec get(Path.t(), term()) :: term()
  def get(path, default \\ nil) do
    case fetch(path) do
      {:ok, %Fact{value: value}} -> value
      :error -> default
    end
  end

  @doc "The whole fact at `path`."
  @spec fetch(Path.t()) :: {:ok, Fact.t()} | :error
  def fetch(path) when is_list(path) do
    case :ets.lookup(Table.table(), path) do
      [{^path, %Fact{} = fact}] -> {:ok, fact}
      [] -> :error
    end
  end

  @doc """
  Milliseconds since `path` was last observed, or `:never` if it has no fact.

  Note this is *observed*, not *changed*: a sensor reporting the same value
  every 30 seconds has a small age and a large time-since-change, and telling
  those apart is the point.
  """
  @spec age(Path.t()) :: non_neg_integer() | :never
  def age(path) do
    case fetch(path) do
      {:ok, fact} -> Fact.age(fact)
      :error -> :never
    end
  end

  @doc "Whether the fact at `path` has aged past its declared `stale_after`."
  @spec stale?(Path.t()) :: boolean()
  def stale?(path) do
    case fetch(path) do
      {:ok, fact} -> Fact.stale?(fact)
      # A fact that has never arrived is not "stale"; it is absent. Rules must
      # distinguish "the tracker stopped reporting" from "there is no tracker".
      :error -> false
    end
  end

  @doc "Whether a fact exists at `path` at all."
  @spec known?(Path.t()) :: boolean()
  def known?(path), do: match?({:ok, _}, fetch(path))

  @doc "Every fact at or beneath `prefix`, as a list of `%Merlin.Fact{}`."
  @spec dump(Path.t()) :: [Fact.t()]
  def dump(prefix \\ []) when is_list(prefix) do
    Table.table()
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {path, %Fact{} = fact} when is_list(path) ->
        if Path.prefix?(prefix, path), do: [fact], else: []

      _other ->
        # The sequence counter shares the table; it is not a fact.
        []
    end)
    |> Enum.sort_by(& &1.path)
  end

  @doc "Write a fact. See `Merlin.World.Writer.put/3`."
  defdelegate put(path, value, opts \\ []), to: Writer

  @doc "Emit an event. See `Merlin.World.Writer.emit/3`."
  defdelegate emit(path, payload, opts \\ []), to: Writer
end
