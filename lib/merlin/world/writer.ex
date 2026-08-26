defmodule Merlin.World.Writer do
  @moduledoc """
  The only process that writes facts.

  ## Why a single writer

  In the Python, `klipper_monitor`, `3dprinter_kobra_neo` and `office_aircond`
  all wrote `DEV_3DPRNT_REQ`, and two of them reset it to `None` after acting.
  Which one observed which value was a race, and the convention governing it
  existed only in a comment. Serialising every write through one process makes
  that class of race structurally impossible rather than conventionally
  avoided.

  ## Why `call` and not `cast`

  `call` gives back-pressure. A saturated writer blocks its callers instead of
  growing an unbounded mailbox, which is precisely the failure mode of the
  Python's three fire-and-forget task sets. There is no deadlock risk because
  this process never calls back into anything: it delivers by `send/2` through
  `Merlin.Bus` and returns.

  ## The two jobs the Python `!=` was doing

  `GlobalState.set/2` compared old and new and did nothing when they matched.
  That single comparison was serving two unrelated purposes, which is why it
  felt load-bearing and why nobody could remove it:

    * suppressing redundant notifications, and
    * preventing infinite callback recursion.

  Here they are separated. Suppression is an explicit `:notify` option and the
  write itself *always* happens, so `observed_at` is never lost -- which is
  what makes staleness detectable at all. Recursion is prevented structurally
  by `send/2` delivery, with the causal depth guard below as a backstop that
  turns a runaway cycle into one loud error instead of a silent livelock.
  """

  use GenServer
  require Logger

  alias Merlin.{Bus, Change, Event, Fact, Path}
  alias Merlin.World.Table

  # A fact write triggered by a fact write triggered by... Eight is far beyond
  # any legitimate chain in this system (the deepest real one is three) and
  # well below anything that would take a noticeable time to unwind.
  @max_depth 8

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Write a fact.

  Returns `{:changed, old, new}` when the value differed, `:unchanged` when it
  did not (the observation is still recorded), or `{:dropped, :max_depth}`.

  Options:

    * `:source`  -- who wrote it; carried on the fact and the change
    * `:notify`  -- `:on_change` (default) or `:always`
    * `:cause`   -- the `seq` of the change that triggered this write
    * `:depth`   -- causal chain depth, defaulting to 0
    * `:stale_after` -- milliseconds after which the fact counts as stale
  """
  @spec put(Path.t(), term(), keyword()) ::
          {:changed, term(), term()} | :unchanged | {:dropped, :max_depth}
  def put(path, value, opts \\ []) when is_list(path) do
    GenServer.call(__MODULE__, {:put, path, value, opts})
  end

  @doc """
  Emit an event.

  Events are never stored and never deduplicated; every emit is delivered.
  Returns the number of subscribers messaged.
  """
  @spec emit(Path.t(), term(), keyword()) :: non_neg_integer()
  def emit(path, payload, opts \\ []) when is_list(path) do
    GenServer.call(__MODULE__, {:emit, path, payload, opts})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:put, path, value, opts}, _from, state) do
    depth = Keyword.get(opts, :depth, 0)

    if depth > @max_depth do
      Logger.error(
        "fact write dropped at depth #{depth}: #{Path.to_string(path)} = #{inspect(value)} " <>
          "-- a causal cycle. Something is writing a fact in reaction to itself."
      )

      {:reply, {:dropped, :max_depth}, state}
    else
      {:reply, do_put(path, value, opts, depth), state}
    end
  end

  @impl true
  def handle_call({:emit, path, payload, opts}, _from, state) do
    event = %Event{
      path: path,
      payload: payload,
      at: now(),
      source: Keyword.get(opts, :source)
    }

    {:reply, Bus.emit(event), state}
  end

  defp do_put(path, value, opts, depth) do
    table = Table.table()
    at = now()
    source = Keyword.get(opts, :source)
    notify = Keyword.get(opts, :notify, :on_change)

    previous =
      case :ets.lookup(table, path) do
        [{^path, %Fact{} = f}] -> f
        [] -> nil
      end

    changed? = is_nil(previous) or previous.value != value
    seq = :ets.update_counter(table, Table.seq_key(), 1)

    fact = %Fact{
      path: path,
      value: value,
      # An unchanged write refreshes the observation but must NOT move
      # changed_at -- "when did this last actually change" and "when did we
      # last hear from it" are different questions and both get asked.
      changed_at: if(changed?, do: at, else: previous.changed_at),
      observed_at: at,
      source: source,
      seq: seq,
      stale_after: Keyword.get(opts, :stale_after, previous && previous.stale_after)
    }

    :ets.insert(table, {path, fact})

    if changed? or notify == :always do
      Bus.publish(%Change{
        path: path,
        old: previous && previous.value,
        new: value,
        at: at,
        source: source,
        seq: seq,
        first?: is_nil(previous),
        cause: Keyword.get(opts, :cause),
        # Carried so that a process reacting to this change can pass
        # Change.caused_by/1 and have the guard actually bound the chain.
        depth: depth
      })
    end

    if changed?, do: {:changed, previous && previous.value, value}, else: :unchanged
  end

  # Monotonic throughout. Wall-clock would let an NTP step or a DST transition
  # make a fact appear to have been observed in the future, and every staleness
  # decision in the system is a subtraction of these.
  defp now, do: System.monotonic_time(:millisecond)

  @doc false
  def max_depth, do: @max_depth
end
