defmodule Merlin.Path do
  @moduledoc """
  Fact and event addresses.

  A path is a list whose segments are atoms for fixed structure and binaries
  for values captured from the world: `[:door, "office", :contact]`. The atom
  segments are written by us and come from a closed vocabulary; the binary
  segments are room names, device ids and the like, and are not trusted to be
  a closed set.

  That split is deliberate. Interning arbitrary device names as atoms would
  make an unbounded input stream able to exhaust the atom table -- a device
  that renames itself on every message would eventually take the VM down.
  """

  @type segment :: atom() | binary()
  @type t :: [segment()]

  @doc """
  Every prefix of `path`, shortest first, including the empty path and the
  path itself.

      iex> Merlin.Path.prefixes([:door, "office", :contact])
      [[], [:door], [:door, "office"], [:door, "office", :contact]]

  This is what makes bus subscription O(depth) rather than a scan: a publish
  looks up each prefix directly instead of testing every registered pattern.
  """
  @spec prefixes(t()) :: [t()]
  def prefixes(path) when is_list(path) do
    path
    |> Enum.reduce([[]], fn seg, [acc_head | _] = acc -> [acc_head ++ [seg] | acc] end)
    |> Enum.reverse()
  end

  @doc """
  Render a path for logs and display.

      iex> Merlin.Path.to_string([:door, "office", :contact])
      "door.office.contact"
  """
  @spec to_string(t()) :: binary()
  def to_string(path) when is_list(path) do
    Enum.map_join(path, ".", fn
      seg when is_atom(seg) -> Atom.to_string(seg)
      seg when is_binary(seg) -> seg
    end)
  end

  @doc """
  Parse a dotted string into a path, interning only against atoms that
  already exist.

  Returns `{:ok, path}` or `{:error, {:unknown_segment, binary}}`. Segments
  that do not correspond to an existing atom stay binaries, which is the
  correct outcome for captured values -- so this never fails on a device name,
  only reports which segments were not part of the declared vocabulary.
  """
  @spec parse(binary()) :: t()
  def parse(str) when is_binary(str) do
    str
    |> String.split(".")
    |> Enum.map(fn seg ->
      try do
        String.to_existing_atom(seg)
      rescue
        ArgumentError -> seg
      end
    end)
  end

  @doc "Whether `prefix` is a prefix of `path` (or equal to it)."
  @spec prefix?(t(), t()) :: boolean()
  def prefix?([], _path), do: true
  def prefix?([h | pt], [h | t]), do: prefix?(pt, t)
  def prefix?(_, _), do: false
end
