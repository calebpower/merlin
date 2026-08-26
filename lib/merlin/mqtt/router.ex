defmodule Merlin.MQTT.Router do
  @moduledoc """
  MQTT topic-filter matching, with named captures.

  Filters use ordinary MQTT wildcards -- `+` for exactly one level, `#` for
  zero or more trailing levels -- and `+` may be named to capture the segment
  it matched:

      "home/+room/sensor/contact"   matches "home/office/sensor/contact"
                                    capturing %{"room" => "office"}

  ## Why this exists

  `home_doors.py` reimplemented `+` matching by hand: split both strings on
  `/`, bail if the segment counts differ, walk them in step. It worked, it was
  the only such matcher in the codebase, and it silently did not support `#`.
  Every other hook did exact string equality instead, because the daemon
  subscribed to `#` and each hook had to filter for itself.

  Doing it once, correctly, in one place is what lets adapters *declare* the
  topics they want so the connection can subscribe to exactly those.

  ## Capture names live with the entry, not in the trie

  Two filters may use the same wildcard position with different names --
  `home/+room/x` and `home/+/x` share a node. Storing names in the trie would
  make them collide, so the trie is anonymous and each terminal entry carries
  its own ordered list of names, zipped against the segments captured on the
  way down.
  """

  defstruct root: nil

  @type value :: term()
  @type captures :: %{optional(binary()) => binary()}
  @type t :: %__MODULE__{root: map()}

  @doc "An empty router."
  @spec new() :: t()
  def new, do: %__MODULE__{root: empty_node()}

  @doc """
  Add `filter` to the router, associating it with `value`.

  Returns `{:ok, router}` or `{:error, reason}`. Refuses a `#` that is not the
  final segment, which MQTT forbids and which would otherwise match in ways
  the author did not intend.
  """
  @spec add(t(), binary(), value()) :: {:ok, t()} | {:error, term()}
  def add(%__MODULE__{root: root} = router, filter, value) when is_binary(filter) do
    segments = String.split(filter, "/")

    with :ok <- validate(segments, filter) do
      names = Enum.flat_map(segments, &capture_name/1)
      {:ok, %{router | root: insert(root, segments, {value, names})}}
    end
  end

  @doc "Add a filter, raising on an invalid one."
  @spec add!(t(), binary(), value()) :: t()
  def add!(router, filter, value) do
    case add(router, filter, value) do
      {:ok, r} -> r
      {:error, reason} -> raise ArgumentError, "bad topic filter #{inspect(filter)}: #{reason}"
    end
  end

  @doc """
  Every entry whose filter matches `topic`, as `{value, captures}`.

  A topic may match several filters; all of them are returned. Order is not
  meaningful and callers must not depend on it.
  """
  @spec match(t(), binary()) :: [{value(), captures()}]
  def match(%__MODULE__{root: root}, topic) when is_binary(topic) do
    do_match(root, String.split(topic, "/"), [])
  end

  # --- construction ---------------------------------------------------------

  defp empty_node, do: %{literals: %{}, plus: nil, hash: [], values: []}

  defp validate(segments, filter) do
    cond do
      segments == [] or filter == "" ->
        {:error, "empty filter"}

      Enum.any?(Enum.drop(segments, -1), &(&1 == "#")) ->
        {:error, "# must be the final segment"}

      Enum.any?(segments, fn s -> String.contains?(s, "#") and s != "#" end) ->
        {:error, "# must occupy a whole segment"}

      true ->
        :ok
    end
  end

  # A bare "+" captures nothing; "+name" captures under that name. Order
  # matters here: the exact match must come first.
  defp capture_name("+"), do: [nil]
  defp capture_name("+" <> name), do: [name]
  defp capture_name(_), do: []

  defp insert(node, [], entry), do: %{node | values: [entry | node.values]}

  defp insert(node, ["#"], entry), do: %{node | hash: [entry | node.hash]}

  defp insert(node, [seg | rest], entry) do
    if plus?(seg) do
      %{node | plus: insert(node.plus || empty_node(), rest, entry)}
    else
      child = Map.get(node.literals, seg, empty_node())
      %{node | literals: Map.put(node.literals, seg, insert(child, rest, entry))}
    end
  end

  defp plus?("+" <> _), do: true
  defp plus?(_), do: false

  # --- matching -------------------------------------------------------------

  # Topic exhausted: terminal entries here, plus any `#` at this node, since
  # `#` matches zero or more levels ("sport/#" does match "sport").
  defp do_match(node, [], captured) do
    entries(node.values, captured) ++ entries(node.hash, captured)
  end

  defp do_match(node, [seg | rest], captured) do
    literal =
      case Map.fetch(node.literals, seg) do
        {:ok, child} -> do_match(child, rest, captured)
        :error -> []
      end

    plus =
      case node.plus do
        nil -> []
        child -> do_match(child, rest, captured ++ [seg])
      end

    # `#` swallows this segment and everything after it.
    entries(node.hash, captured) ++ literal ++ plus
  end

  defp entries(list, captured) do
    Enum.map(list, fn {value, names} -> {value, zip_captures(names, captured)} end)
  end

  # `names` is the ordered list of capture names (nil for a bare `+`) as they
  # appear in the filter; `captured` is the ordered list of segments the `+`
  # positions actually matched. An unnamed wildcard is matched but discarded.
  defp zip_captures(names, captured) do
    names
    |> Enum.zip(captured)
    |> Enum.reduce(%{}, fn
      {nil, _segment}, acc -> acc
      {name, segment}, acc -> Map.put(acc, name, segment)
    end)
  end
end
