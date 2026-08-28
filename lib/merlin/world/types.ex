defmodule Merlin.Fact do
  @moduledoc """
  A **level**: something that has a current value.

  A fact has identity (its path), a value, and the times it was last *changed*
  and last *observed*. Writing the same value again is a legal and meaningful
  operation -- it refreshes `observed_at` without notifying anyone.

  That distinction is the thing the Python `GlobalState` could not express. Its
  `set/2` did nothing at all when the value was unchanged, so a sensor still
  reporting the same reading every 30 seconds was indistinguishable from a
  sensor that had stopped reporting three days ago. Staleness detection is
  impossible without recording the observation separately from the change.
  """

  @enforce_keys [:path, :value, :changed_at, :observed_at, :source, :seq]
  defstruct [:path, :value, :changed_at, :observed_at, :source, :seq, :stale_after]

  @type t :: %__MODULE__{
          path: Merlin.Path.t(),
          value: term(),
          changed_at: integer(),
          observed_at: integer(),
          source: term(),
          seq: pos_integer(),
          stale_after: pos_integer() | nil
        }

  @doc """
  Age in milliseconds since this fact was last *observed* (not last changed).

  Monotonic, so an NTP step or a DST transition cannot make a fact appear to
  arrive from the future.
  """
  @spec age(t(), integer()) :: integer()
  def age(%__MODULE__{observed_at: at}, now \\ System.monotonic_time(:millisecond)) do
    now - at
  end

  @doc "Whether the fact has aged past its declared `stale_after`."
  @spec stale?(t(), integer()) :: boolean()
  def stale?(fact, now \\ System.monotonic_time(:millisecond))
  def stale?(%__MODULE__{stale_after: nil}, _now), do: false
  def stale?(%__MODULE__{stale_after: ms} = fact, now), do: age(fact, now) > ms
end

defmodule Merlin.Event do
  @moduledoc """
  An **edge**: something that happened.

  No stored value, no identity beyond its path, no deduplication, never
  persisted. Every emit is delivered.

  This exists so that momentary occurrences stop being smuggled through the
  fact store as state. `livingroom_button.py` wrote `time.time()` floats into
  the Python state dict for no reason other than to force a value-equality
  check to see a difference on every press. A button press is not state; it is
  an event, and it needs its own primitive rather than a timestamp hack.
  """

  @enforce_keys [:path, :payload, :at, :source]
  defstruct [:path, :payload, :at, :source, captures: %{}]

  @type t :: %__MODULE__{
          path: Merlin.Path.t(),
          payload: term(),
          at: integer(),
          source: term(),
          captures: %{optional(binary()) => binary()}
        }

  @doc "The `trigger.*` bindings an expression sees for this event."
  @spec trigger_env(t()) :: map()
  def trigger_env(%__MODULE__{} = e),
    do: %{value: e.payload, path: e.path, captures: e.captures}
end

defmodule Merlin.Change do
  @moduledoc """
  What the bus delivers when a fact's value changes.

  Carries the previous value as well as the new one, because edge triggers
  (`{:enters, path, v}`, `{:leaves, path, v}`) are defined by the transition
  and not by the resting value. `old` is `nil` for a fact's first write, which
  is distinguishable from a change *to* nil by `first?`.

  ## Captures

  `captures` holds the named topic wildcards of the message that produced this
  change, so a rule can read `trigger.room` for a fact written by a source
  bound to `z2m/home/+room/sensor/contact`.

  Without it the room is *structural* -- it is a segment of the fact path and
  nothing else -- and a rule triggered on `{:changes_under, [:door]}` can see
  that a door moved but not which one. `door_presence`'s description promised
  to name the room for a whole milestone while it logged only `open`/`closed`,
  because there was no way for it to say more.

  Empty for every write that did not come from a captured topic: a derived
  fact, a rule's own `set_fact`, a snapshot restore. `trigger.room` is then
  `:unknown`, which is the correct answer rather than a missing one.
  """

  @enforce_keys [:path, :old, :new, :at, :source, :seq, :first?]
  defstruct [:path, :old, :new, :at, :source, :seq, :first?, :cause, depth: 0, captures: %{}]

  @type t :: %__MODULE__{
          path: Merlin.Path.t(),
          old: term(),
          new: term(),
          at: integer(),
          source: term(),
          seq: pos_integer(),
          first?: boolean(),
          cause: pos_integer() | nil,
          depth: non_neg_integer(),
          captures: %{optional(binary()) => binary()}
        }

  @doc """
  The options a process should pass when writing a fact *in reaction to* this
  change, so the causal chain stays traceable and bounded.

      World.put(other_path, value, Change.caused_by(change))

  Without this the depth guard is unenforceable: a reacting writer has no way
  to know what depth it is at, so every write looks like the start of a fresh
  chain and a cycle never trips the limit.
  """
  @spec caused_by(t()) :: keyword()
  def caused_by(%__MODULE__{seq: seq, depth: depth}) do
    [cause: seq, depth: depth + 1]
  end

  @doc """
  The `trigger.*` bindings an expression sees for this change.

  Here rather than in the two callers because the rules engine and the machine
  server had this written out identically, and the keys it produces are the
  reserved names `Merlin.Config.File` refuses as topic captures. Three copies
  of one list is how the last several defects in this system got in; the tier 1
  test asserts these keys against that refusal list directly.
  """
  @spec trigger_env(t()) :: map()
  def trigger_env(%__MODULE__{} = c),
    do: %{value: c.new, prev: c.old, path: c.path, first?: c.first?, captures: c.captures}
end
