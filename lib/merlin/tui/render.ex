defmodule Merlin.TUI.Render do
  @moduledoc """
  The only module in `lib/` permitted to emit an ANSI byte.

  Everything upstream produces a `Merlin.TUI.Buffer` -- a grid of characters --
  and this turns one into bytes. Keeping the escape codes in one place is what
  makes every view a pure function assertable by string equality, and it means
  there is exactly one thing to read when a frame comes out wrong.

  ## Full repaint, for now

  `full/1` repaints the whole screen. At 80x24 that is about 8 KB, and at ten
  frames a second on a loopback link it is nothing worth optimising before it
  has been measured. A cell diff is roughly a hundred more lines and its own
  class of bug -- a stale previous buffer after a resize emits cursor moves off
  the end of the screen -- so it waits until something demands it.

  The op list exists so it can arrive without disturbing anything: `diff/2`
  would produce the same ops `full/1` does, and `emit/1` would not change at
  all.

  ## Styles are a closed whitelist

  A style is a list of atoms and they are looked up in a map, not applied to
  `IO.ANSI` by name. `apply(IO.ANSI, atom, [])` on an atom that arrived from
  config or from a device is a code path nobody intended; an unknown attribute
  here is simply ignored.
  """

  alias Merlin.TUI.Buffer

  @typedoc "One drawing instruction. `emit/1` turns a list of these into bytes."
  @type op ::
          {:move, non_neg_integer(), non_neg_integer()}
          | {:style, [atom()]}
          | {:text, binary()}

  # The attributes a view may ask for. Anything else is ignored rather than
  # reached for dynamically.
  @sgr %{
    reset: "\e[0m",
    bright: "\e[1m",
    faint: "\e[2m",
    underline: "\e[4m",
    reverse: "\e[7m",
    black: "\e[30m",
    red: "\e[31m",
    green: "\e[32m",
    yellow: "\e[33m",
    blue: "\e[34m",
    magenta: "\e[35m",
    cyan: "\e[36m",
    white: "\e[37m",
    red_background: "\e[41m",
    green_background: "\e[42m",
    yellow_background: "\e[43m",
    blue_background: "\e[44m"
  }

  @doc "The attributes a style may name."
  @spec attributes() :: [atom()]
  def attributes, do: Map.keys(@sgr)

  @doc "Ops that repaint the whole buffer."
  @spec full(Buffer.t()) :: [op()]
  def full(%Buffer{} = b) do
    Enum.flat_map(0..(b.h - 1), fn y -> row_ops(b, y) end)
  end

  # One move per row, then runs of like-styled text. A move per cell would be
  # correct and roughly forty times the bytes.
  defp row_ops(%Buffer{} = b, y) do
    runs =
      0..(b.w - 1)
      |> Enum.map(fn x -> Map.fetch!(b.cells, {x, y}) end)
      |> Enum.chunk_by(fn {_char, style} -> style end)

    [{:move, 0, y}] ++
      Enum.flat_map(runs, fn run ->
        {_char, style} = hd(run)
        [{:style, style}, {:text, Enum.map_join(run, fn {char, _} -> char end)}]
      end)
  end

  @doc """
  Turn ops into bytes.

  Emits an SGR only when the style actually changes, so a plain row costs one
  escape rather than one per run.
  """
  @spec emit([op()]) :: iodata()
  def emit(ops) do
    {out, _last_style} =
      Enum.reduce(ops, {[], :none}, fn
        {:move, x, y}, {acc, style} ->
          {[acc, "\e[", Integer.to_string(y + 1), ";", Integer.to_string(x + 1), "H"], style}

        {:style, style}, {acc, style} ->
          {acc, style}

        {:style, style}, {acc, _different} ->
          {[acc, sgr(style)], style}

        {:text, text}, {acc, style} ->
          {[acc, text], style}
      end)

    out
  end

  @doc "Repaint a buffer, as bytes. `emit(full(buffer))`, with the screen cleared first."
  @spec paint(Buffer.t()) :: iodata()
  def paint(%Buffer{} = b), do: [clear(), emit(full(b)), sgr([])]

  # --- screen control -------------------------------------------------------

  @doc "Switch to the alternate screen, so quitting restores the scrollback."
  @spec enter() :: iodata()
  def enter, do: ["\e[?1049h", "\e[?25l", clear()]

  @doc """
  Restore the terminal.

  Emitted on the way out of *every* exit path, including a crash. A TUI that
  leaves the alternate screen up with the cursor hidden is the worst failure
  mode there is: the operator's shell still works and looks broken.
  """
  @spec leave() :: iodata()
  def leave, do: [sgr([]), "\e[?25h", "\e[?1049l"]

  @doc "Clear the screen and home the cursor."
  @spec clear() :: iodata()
  def clear, do: ["\e[2J", "\e[1;1H"]

  @doc "Ask the terminal where the cursor is. The reply is `\\e[<rows>;<cols>R`."
  @spec cursor_report() :: iodata()
  def cursor_report, do: "\e[6n"

  @doc "Park the cursor at the bottom right, so a size query reports the extent."
  @spec cursor_to_extreme() :: iodata()
  def cursor_to_extreme, do: "\e[999;999H"

  # --- styles ---------------------------------------------------------------

  defp sgr([]), do: @sgr.reset

  defp sgr(style) do
    [@sgr.reset | Enum.flat_map(style, fn attr -> List.wrap(Map.get(@sgr, attr)) end)]
  end
end
