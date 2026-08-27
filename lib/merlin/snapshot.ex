defmodule Merlin.Snapshot do
  @moduledoc """
  Encoding and decoding the fact snapshot. Pure; the file handling and the
  schedule live in `Merlin.Snapshot.Server`.

  ## Bug 8

  The Python persisted nothing. Every restart -- a `pkg upgrade`, a power cut,
  a crash -- began with an empty `GlobalState`, so the intruder latch re-armed
  itself, the A/C's desired setting was forgotten, and presence was unknown
  until the next phone update. None of that was visible as a failure; it looked
  exactly like a normal boot.

  ## Time is the whole problem

  Facts carry `changed_at` and `observed_at` in **monotonic** time, which is
  measured from an arbitrary origin chosen when the VM starts. It is the right
  choice while running -- an NTP step cannot make a fact appear to arrive from
  the future -- and it is meaningless across a restart. Writing those integers
  to disk and reading them back yields a number with no relationship to
  anything.

  So the snapshot records, per fact, *how long ago* it was observed, plus one
  wall-clock stamp for the file as a whole. On restore the elapsed wall time is
  added back:

      observed_at = now_monotonic - (observed_ago + (now_wall - snapshot_wall))

  A two-day-old snapshot therefore restores facts that are two days old, and
  anything with a `stale_after` reads `:unknown` exactly as it should. Restoring
  them as fresh would be worse than not restoring at all: the daemon would
  assert a stale position with confidence, which is bug 6 wearing a new hat.

  ## Paths are not strings

  A path is a list of atoms *and* binaries -- `[:door, "garage", :contact]` --
  because captured MQTT segments stay binaries by design. Encoding a path as
  `"door.garage.contact"` would round-trip it to three atoms and silently
  change which fact it is. Every segment is therefore tagged with its type.

  ## Scalars only

  Persisted values are latch states, desired settings and presence: atoms,
  booleans, numbers, strings. Anything else is refused at encode time and
  named in the log. That keeps the file readable with `:erlang.binary_to_term/2`
  in `:safe` mode and keeps a config change from being able to make the file
  undecodable.
  """

  require Logger

  alias Merlin.Fact

  @format 1

  # A clock that has gone backwards by less than this is jitter; anything more
  # is a real disagreement about what time it is.
  @clock_tolerance_ms 5_000

  # When the elapsed time cannot be trusted, facts restore as very old rather
  # than as fresh. Stale is the conservative direction -- it reads `:unknown`,
  # suppresses rules, and waits for a real observation. "Fresh" would have the
  # daemon acting on a position from an unknown point in the past.
  @untrusted_elapsed_ms 30 * 24 * 60 * 60 * 1_000

  @type entry :: %{
          path: [{:a, binary()} | {:b, binary()}],
          value: term(),
          changed_ago: non_neg_integer(),
          observed_ago: non_neg_integer(),
          stale_after: pos_integer() | nil
        }

  @doc "The format version written by this build."
  @spec format() :: pos_integer()
  def format, do: @format

  @doc """
  Encode facts into a snapshot binary.

  `now_mono` is subtracted to turn absolute monotonic stamps into ages, and
  `now_wall` is written so the restore can add back the time the daemon spent
  stopped. Both are parameters rather than reads so this stays testable
  without controlling the system clock.

  Returns `{binary, skipped}`, where `skipped` names the facts whose values are
  not persistable. Returned rather than logged: this runs every five seconds
  for the life of the daemon, and a warning on each pass would repeat forever.
  A log line that appears every five seconds is not a warning, it is wallpaper,
  and it trains you to stop reading the warnings that matter -- the same defect
  as Discord's 204 being reported as an error on every successful alert.
  """
  @spec encode([Fact.t()], integer(), integer()) :: {binary(), [{Merlin.Path.t(), binary()}]}
  def encode(facts, now_wall, now_mono) do
    {entries, skipped} =
      Enum.reduce(facts, {[], []}, fn fact, {entries, skipped} ->
        case encode_value(fact.value) do
          {:ok, value} ->
            entry = %{
              path: Enum.map(fact.path, &encode_segment/1),
              value: value,
              changed_ago: max(now_mono - fact.changed_at, 0),
              observed_ago: max(now_mono - fact.observed_at, 0),
              stale_after: fact.stale_after
            }

            {[entry | entries], skipped}

          :error ->
            {entries, [{fact.path, type_of(fact.value)} | skipped]}
        end
      end)

    binary =
      :erlang.term_to_binary(
        {:merlin_snapshot, @format, now_wall, Enum.reverse(entries)},
        compressed: 6
      )

    {binary, Enum.reverse(skipped)}
  end

  @doc """
  Decode a snapshot binary.

  `:safe` mode is used deliberately: the file contains no atoms beyond this
  module's own tags, so a corrupted or hostile file cannot exhaust the atom
  table. It is in a 0750 directory and this is still the right default.
  """
  @spec decode(binary()) :: {:ok, integer(), [entry()]} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {:merlin_snapshot, @format, wall, entries} when is_list(entries) ->
        {:ok, wall, entries}

      {:merlin_snapshot, other, _wall, _entries} ->
        {:error, {:unsupported_format, other}}

      _other ->
        {:error, :not_a_snapshot}
    end
  rescue
    e -> {:error, {:corrupt, Exception.message(e)}}
  end

  @doc """
  Turn decoded entries back into facts, ageing them by the time that passed.

  Returns `{facts, dropped}`. A dropped entry is one whose path names an atom
  this build no longer has -- a rule deleted from the config, most likely --
  and dropping just that entry is why paths are stored segment-wise rather
  than as one opaque term. A config edit costs you the facts you removed, not
  every latch in the house.
  """
  @spec restore([entry()], integer(), integer(), integer()) ::
          {[Fact.t()], [{binary(), term()}]}
  def restore(entries, snapshot_wall, now_wall, now_mono) do
    elapsed = elapsed_since(snapshot_wall, now_wall)

    {facts, dropped} =
      Enum.reduce(entries, {[], []}, fn entry, {facts, dropped} ->
        case decode_path(entry.path) do
          {:ok, path} ->
            fact = %Fact{
              path: path,
              value: decode_value(entry.value),
              changed_at: now_mono - (entry.changed_ago + elapsed),
              observed_at: now_mono - (entry.observed_ago + elapsed),
              source: {:snapshot, snapshot_wall},
              # Restored facts have no place in the live sequence; the writer
              # assigns a real seq when it inserts them.
              seq: 0,
              stale_after: entry.stale_after
            }

            {[fact | facts], dropped}

          {:error, reason} ->
            {facts, [{describe_path(entry.path), reason} | dropped]}
        end
      end)

    {Enum.reverse(facts), Enum.reverse(dropped)}
  end

  @doc """
  Wall-clock milliseconds elapsed between a snapshot and now, as the restore
  should treat it.

  Exposed because the clock-skew policy is a decision, not an implementation
  detail, and it deserves its own tests.
  """
  @spec elapsed_since(integer(), integer()) :: non_neg_integer()
  def elapsed_since(snapshot_wall, now_wall) do
    elapsed = now_wall - snapshot_wall

    cond do
      elapsed >= 0 ->
        elapsed

      elapsed >= -@clock_tolerance_ms ->
        # Jitter. The daemon restarted faster than the clock's resolution, or
        # NTP nudged it a few milliseconds. Treat as no time at all.
        0

      true ->
        Logger.warning(
          "snapshot is stamped #{abs(elapsed)}ms in the future -- the clock has moved " <>
            "backwards. Restoring facts as very old rather than as fresh: a wrong clock " <>
            "must not become confident stale data."
        )

        @untrusted_elapsed_ms
    end
  end

  @doc "How far in the past an untrusted snapshot's facts are placed."
  @spec untrusted_elapsed_ms() :: pos_integer()
  def untrusted_elapsed_ms, do: @untrusted_elapsed_ms

  @doc "Backwards clock jitter tolerated before the elapsed time is distrusted."
  @spec clock_tolerance_ms() :: pos_integer()
  def clock_tolerance_ms, do: @clock_tolerance_ms

  # --- segments -------------------------------------------------------------

  defp encode_segment(seg) when is_atom(seg), do: {:a, Atom.to_string(seg)}
  defp encode_segment(seg) when is_binary(seg), do: {:b, seg}

  defp decode_path(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn
      {:b, s}, {:ok, acc} ->
        {:cont, {:ok, [s | acc]}}

      {:a, s}, {:ok, acc} ->
        try do
          {:cont, {:ok, [String.to_existing_atom(s) | acc]}}
        rescue
          ArgumentError -> {:halt, {:error, {:unknown_segment, s}}}
        end

      other, _acc ->
        {:halt, {:error, {:bad_segment, other}}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp describe_path(segments) do
    Enum.map_join(segments, ".", fn
      {_tag, s} -> s
      other -> inspect(other)
    end)
  end

  # --- values ---------------------------------------------------------------

  defp encode_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: {:ok, {:atom, Atom.to_string(v)}}

  defp encode_value(v) when is_boolean(v), do: {:ok, {:boolean, v}}
  defp encode_value(nil), do: {:ok, :null}
  defp encode_value(v) when is_number(v), do: {:ok, {:number, v}}
  defp encode_value(v) when is_binary(v), do: {:ok, {:binary, v}}
  defp encode_value(_other), do: :error

  # An atom value that no longer exists stays a binary rather than dropping
  # the fact. A value is data, not vocabulary: `:home` becoming "home" is a
  # visible, comparable degradation, whereas losing the latch is not.
  defp decode_value({:atom, s}) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
  end

  defp decode_value({:boolean, v}), do: v
  defp decode_value(:null), do: nil
  defp decode_value({:number, v}), do: v
  defp decode_value({:binary, v}), do: v

  defp type_of(v) when is_map(v), do: "map"
  defp type_of(v) when is_list(v), do: "list"
  defp type_of(v) when is_tuple(v), do: "tuple"
  defp type_of(v) when is_pid(v), do: "pid"
  defp type_of(v) when is_function(v), do: "function"
  defp type_of(_), do: "value"
end
