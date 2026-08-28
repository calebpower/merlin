defmodule Merlin.Effects.Report do
  @moduledoc """
  What happened to one effect.

  The distinction this exists to carry is between what merlin *decided* and
  what merlin *did*. Until now the log recorded the decision and left the
  outcome implicit in which of three branches happened to write the line, so
  "set group living_room_lamps -> :off" appeared whether the command reached
  the broker, was discarded by dry-run, or was held by the settle window.

  During a dry-run soak that distinction is the entire product.
  """

  @enforce_keys [:outcome, :effect, :source, :at, :wall]
  defstruct [:outcome, :effect, :source, :at, :wall]

  @typedoc """
  What became of the effect.

    * `:performed`      -- dispatched, and the dispatch returned ok
    * `:dry_run`        -- logged and discarded; the daemon is in dry run
    * `{:held, ms}`     -- suppressed by the settle window, with time remaining
    * `{:failed, term}` -- dispatched and the dispatch failed
  """
  @type outcome :: :performed | :dry_run | {:held, non_neg_integer()} | {:failed, term()}

  @typedoc "Who caused it. `nil` when nothing said."
  @type source :: {:rule, atom()} | {:operator, binary()} | nil

  @type t :: %__MODULE__{
          outcome: outcome(),
          effect: Merlin.Effects.effect(),
          source: source(),
          at: integer(),
          wall: integer()
        }
end

defmodule Merlin.Effects.Tap do
  @moduledoc """
  Observation of effects, for anything that wants to watch the house act.

  ## Why not `Merlin.Bus`

  Putting effects on the bus would make them addressable by
  `{:receives, [:effect, ...]}`, and a rule that fires on merlin's own effects
  is a feedback loop with a rules engine on both ends. `Merlin.Bus` and
  `Merlin.Settle` are both written to prevent exactly that shape. Effects go
  to observers, never back into the world model.

  ## Why `:persistent_term`

  `Merlin.Effects.perform/2` runs on the hot path, once per effect. With no
  subscribers this is a lock-free read of a literal and a comparison against
  `[]` -- cheaper than the `Application.get_env` ETS lookup it sits beside.

  The rule that makes that true: **never write per effect.** `:persistent_term`
  writes trigger a global scan, so a put in the notify path would be a garbage
  collection per light switched. Writes happen on subscribe and unsubscribe
  only, which is once per session.

  ## This is not the test observer

  `Application.get_env(:merlin, :effects_observer)` still exists and still does
  something different: it fires *before* the dry-run and settle branches, so a
  test can assert what a machine **decided** without a broker. This tap fires
  *after*, and reports what actually **became** of each effect. Both are
  wanted; neither is the other's duplicate.
  """

  require Logger

  alias Merlin.Effects.Report

  @key {__MODULE__, :subscribers}

  @doc """
  Receive `{:merlin_effect, %Report{}}` for every effect from now on.

  Subscribers are responsible for unsubscribing. `Merlin.Tap` does it from a
  monitor, so a session that dies ungracefully is cleaned up by the process
  that was watching it rather than by hope.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) when is_pid(pid) do
    update(fn subs -> if pid in subs, do: subs, else: [pid | subs] end)
  end

  @doc "Stop receiving effect reports."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) when is_pid(pid) do
    update(fn subs -> List.delete(subs, pid) end)
  end

  @doc "The current subscriber list."
  @spec subscribers() :: [pid()]
  def subscribers, do: :persistent_term.get(@key, [])

  @doc false
  @spec clear() :: :ok
  def clear, do: :persistent_term.put(@key, [])

  @doc """
  Report the fate of one effect.

  Returns the report so a caller can use it; returns `nil` when nobody is
  listening, which is the overwhelmingly common case and costs one read.
  """
  @spec notify(Report.outcome(), Merlin.Effects.effect(), Report.source()) :: Report.t() | nil
  def notify(outcome, effect, source) do
    case subscribers() do
      [] ->
        nil

      subs ->
        report = %Report{
          outcome: outcome,
          effect: effect,
          source: source,
          # Monotonic for ordering and age; wall for display. The same pairing
          # Merlin.Snapshot uses, and for the same reason: monotonic time is
          # meaningless to a human and wall time is unsafe to subtract.
          at: System.monotonic_time(:millisecond),
          wall: System.system_time(:millisecond)
        }

        deliver(subs, report)
        report
    end
  end

  # Sending to a dead pid is a harmless no-op, so delivery never needs to check
  # liveness. Pruning does, but only lazily: a put here would defeat the whole
  # reason this lives in :persistent_term, so it happens only when a dead
  # subscriber is actually observed -- once per crashed session, not per effect.
  defp deliver(subs, report) do
    Enum.each(subs, &send(&1, {:merlin_effect, report}))

    case Enum.filter(subs, &dead?/1) do
      [] ->
        :ok

      dead ->
        Logger.debug("effects tap: pruning #{length(dead)} dead subscriber(s)")
        update(fn current -> Enum.reject(current, &(&1 in dead)) end)
    end
  end

  @doc """
  Whether a subscriber is known-dead and safe to prune.

  `Process.alive?/1` **raises** on a remote pid rather than answering, so
  asking it about a subscriber on another node would turn every effect into an
  ArgumentError -- which is precisely what a TUI attaching over distribution
  would do. A remote subscriber is therefore never pruned from this side: its
  liveness belongs to whatever monitors it, and guessing from here would drop
  a live session on a slow link.

  `local_node` is a parameter rather than a call so the remote branch is
  testable without standing up distribution for a unit tier.
  """
  @spec dead?(pid(), node()) :: boolean()
  def dead?(pid, local_node \\ node())
  def dead?(pid, local_node) when node(pid) != local_node, do: false
  def dead?(pid, _local_node), do: not Process.alive?(pid)

  defp update(fun) do
    :persistent_term.put(@key, fun.(subscribers()))
  end
end
