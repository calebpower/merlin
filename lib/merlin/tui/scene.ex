defmodule Merlin.TUI.Scene do
  @moduledoc """
  Everything a frame is drawn from, as one immutable value.

  A view is `render(scene, session, rect) -> Buffer`, and it is pure because
  everything it could possibly need is already in here. Nothing renders from
  the live world: a view that read `Merlin.World` directly would be untestable
  without a daemon, and -- worse on the client side -- would read an empty ETS
  table and confidently draw an empty house.

  ## Where it comes from

  Built on the **daemon** by `Merlin.Tap.scene/0` and carried across
  distribution. The client never reads the world itself. That is not a
  preference: a TUI client loads every `Merlin.*` module but starts no
  application, so `Merlin.Config.dry_run?()` there answers `false` and
  `Merlin.World.fetch/1` raises on a table that does not exist. A banner
  reading LIVE while the daemon is dry is the exact failure that discipline
  prevents.

  ## Named Scene, not Snapshot

  `Merlin.Snapshot` already exists and means the persisted fact file. Two
  things called snapshot in one codebase is how the wrong one gets reached for.
  """

  alias Merlin.TUI.Scene

  @type stream_item :: Merlin.Tap.item()

  @type t :: %__MODULE__{
          facts: [Merlin.Fact.t()],
          rules: [Merlin.Rule.t() | Merlin.Machine.t()],
          states: %{atom() => atom()},
          groups: %{atom() => map()},
          stream: [stream_item()],
          dropped: non_neg_integer(),
          dry_run?: boolean(),
          settling_ms: non_neg_integer(),
          connected?: boolean(),
          version: binary(),
          now: integer()
        }

  defstruct facts: [],
            rules: [],
            states: %{},
            groups: %{},
            stream: [],
            dropped: 0,
            dry_run?: false,
            settling_ms: 0,
            connected?: false,
            version: "",
            now: 0

  @doc """
  Facts whose path contains `filter`, in path order.

  Matching on the rendered path rather than segment-wise, because a filter is
  something typed in a hurry: `door.front` should find
  `door.front_door.contact` without anybody having to think about where the
  segment boundaries are.
  """
  @spec facts(t(), binary() | nil) :: [Merlin.Fact.t()]
  def facts(%Scene{facts: facts}, nil), do: Enum.sort_by(facts, & &1.path)

  def facts(%Scene{facts: facts}, "") , do: Enum.sort_by(facts, & &1.path)

  def facts(%Scene{facts: facts}, filter) do
    needle = String.downcase(filter)

    facts
    |> Enum.filter(fn fact ->
      fact.path |> Merlin.Path.to_string() |> String.downcase() |> String.contains?(needle)
    end)
    |> Enum.sort_by(& &1.path)
  end

  @doc """
  How long ago a fact was last *observed*, rendered for a human.

  Observed, not changed: a sensor reporting the same value every thirty
  seconds has a small age and a large time-since-change, and the question an
  operator is asking -- "is this thing still talking to me" -- is the first
  one.
  """
  @spec age(t(), Merlin.Fact.t()) :: binary()
  def age(%Scene{now: now}, %{observed_at: at}), do: duration(now - at)

  @doc "A duration in milliseconds, rendered short."
  @spec duration(integer()) :: binary()
  def duration(ms) when ms < 0, do: "?"
  def duration(ms) when ms < 1_000, do: "now"
  def duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"
  def duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  def duration(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h"
  def duration(ms), do: "#{div(ms, 86_400_000)}d"

  @doc """
  Whether a fact is past its declared staleness.

  Computed against the scene's own `now` rather than by calling
  `Merlin.Fact.stale?/1`, which reads the clock. A frame must be a function of
  its inputs, or two renders of the same scene can disagree and no test can
  pin either.
  """
  @spec stale?(t(), Merlin.Fact.t()) :: boolean()
  def stale?(%Scene{}, %{stale_after: nil}), do: false
  def stale?(%Scene{now: now}, %{stale_after: ms, observed_at: at}), do: now - at > ms

  @doc "A value, rendered for one cell-wide column."
  @spec value(term()) :: binary()
  def value(:unknown), do: "unknown"
  def value(value) when is_binary(value), do: value
  def value(value) when is_atom(value), do: inspect(value)
  def value(value) when is_number(value), do: to_string(value)
  def value(value), do: inspect(value)

  @doc "The banner text. The one thing on screen that must never be wrong."
  @spec mode(t()) :: {binary(), [atom()]}
  def mode(%Scene{connected?: false}), do: {"DISCONNECTED", [:reverse, :red]}
  def mode(%Scene{dry_run?: true}), do: {"DRY-RUN", [:reverse, :yellow]}
  def mode(%Scene{}), do: {"LIVE", [:reverse, :green]}
end
