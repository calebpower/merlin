defmodule Merlin.TUI.Buffer do
  @moduledoc """
  A grid of characters. No terminal, no escape codes, no I/O.

  Everything a view produces is one of these, which is what makes a view a
  pure function of the world and therefore assertable by string equality. The
  ANSI lives in `Merlin.TUI.Render` and nowhere else.

  ## Two invariants, both enforced here rather than remembered

  **Exactly `h` rows of exactly `w` cells, always.** Every write is clipped
  rather than growing the grid, so an over-long device name shortens instead of
  pushing the frame out of shape. A frame that is 81 columns wide on an
  80-column terminal wraps, and a wrapped frame corrupts every subsequent
  cursor position.

  **No cell ever holds a control character.** This is a security property, not
  a cosmetic one. Fact values come from MQTT payloads, so a device that has
  been tampered with can publish

      \\e[2J\\e[1;1H  ALL CLEAR

  and, without this, repaint the operator's screen with a lie. Sanitising at
  render time would mean every future caller has to remember; sanitising here
  means the grid cannot represent the attack. `Merlin.TUI.Render` may then emit
  cell contents verbatim, because by construction they are safe.

  Substitution rather than removal, because a name that silently loses a
  character is a name you will misread later.
  """

  alias Merlin.TUI.Buffer

  @typedoc "An ANSI attribute list, e.g. `[:bright]` or `[:red, :bright]`. `[]` is plain."
  @type style :: [atom()]

  @type cell :: {binary(), style()}

  @type t :: %__MODULE__{
          w: pos_integer(),
          h: pos_integer(),
          cells: %{{integer(), integer()} => cell()}
        }

  @enforce_keys [:w, :h, :cells]
  defstruct [:w, :h, :cells]

  # What a control character becomes. Visible, one column wide, and obviously
  # not the original -- so a value containing one looks wrong rather than looking
  # like something else.
  @substitute "·"

  @doc "A blank buffer, `w` by `h`."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(w, h) when w > 0 and h > 0 do
    cells =
      for x <- 0..(w - 1), y <- 0..(h - 1), into: %{} do
        {{x, y}, {" ", []}}
      end

    %Buffer{w: w, h: h, cells: cells}
  end

  @doc "One cell. Out-of-bounds writes are dropped, never grow the grid."
  @spec put(t(), integer(), integer(), binary(), style()) :: t()
  def put(%Buffer{} = b, x, y, char, style \\ []) do
    if inside?(b, x, y) do
      %{b | cells: Map.put(b.cells, {x, y}, {safe(char), style})}
    else
      b
    end
  end

  @doc """
  Write `text` starting at `x, y`, clipped to the row.

  Grapheme-wise, so a multi-byte character occupies one cell rather than
  however many bytes it happens to be.
  """
  @spec write(t(), integer(), integer(), binary(), style()) :: t()
  def write(%Buffer{} = b, x, y, text, style \\ []) when is_binary(text) do
    if y < 0 or y >= b.h do
      b
    else
      text
      |> String.graphemes()
      |> Enum.with_index(x)
      |> Enum.reduce(b, fn {g, at}, acc -> put(acc, at, y, g, style) end)
    end
  end

  @doc "`text` truncated to `width` graphemes, padded with spaces to exactly that."
  @spec fit(binary(), non_neg_integer()) :: binary()
  def fit(text, width) when is_binary(text) and width >= 0 do
    graphemes = String.graphemes(text)

    case length(graphemes) do
      n when n >= width -> graphemes |> Enum.take(width) |> Enum.join()
      n -> text <> String.duplicate(" ", width - n)
    end
  end

  @doc "One row, as a string. Styles are dropped -- this is the text, not the paint."
  @spec row(t(), integer()) :: binary()
  def row(%Buffer{} = b, y) do
    if y < 0 or y >= b.h do
      ""
    else
      0..(b.w - 1)
      |> Enum.map_join(fn x -> b.cells |> Map.fetch!({x, y}) |> elem(0) end)
    end
  end

  @doc "The whole buffer as text, rows joined by newlines. The tier 2 assertion surface."
  @spec to_text(t()) :: binary()
  def to_text(%Buffer{} = b), do: Enum.map_join(0..(b.h - 1), "\n", &row(b, &1))

  @doc "A horizontal slice of one row, for asserting a region without a whole frame."
  @spec text_at(t(), integer(), integer(), non_neg_integer()) :: binary()
  def text_at(%Buffer{} = b, x, y, width) do
    b |> row(y) |> String.graphemes() |> Enum.slice(x, width) |> Enum.join()
  end

  @doc "Every cell, as `{{x, y}, cell}`. For the renderer and its tests."
  @spec cells(t()) :: [{{integer(), integer()}, cell()}]
  def cells(%Buffer{} = b), do: Enum.sort(b.cells)

  # --- drawing helpers ------------------------------------------------------

  @doc "A horizontal run of `char`."
  @spec hline(t(), integer(), integer(), non_neg_integer(), binary(), style()) :: t()
  def hline(%Buffer{} = b, x, y, width, char \\ "─", style \\ []) do
    Enum.reduce(0..max(width - 1, 0), b, fn i, acc -> put(acc, x + i, y, char, style) end)
  end

  @doc """
  A single-line box, with an optional title inset into the top edge.

  The title is clipped to the inside of the box, so a long one cannot push the
  corner off the end and leave a frame that does not close.
  """
  @spec box(t(), integer(), integer(), pos_integer(), pos_integer(), keyword()) :: t()
  def box(%Buffer{} = b, x, y, w, h, opts \\ []) when w >= 2 and h >= 2 do
    style = Keyword.get(opts, :style, [])
    title = Keyword.get(opts, :title)

    b
    |> hline(x + 1, y, w - 2, "─", style)
    |> hline(x + 1, y + h - 1, w - 2, "─", style)
    |> put(x, y, "┌", style)
    |> put(x + w - 1, y, "┐", style)
    |> put(x, y + h - 1, "└", style)
    |> put(x + w - 1, y + h - 1, "┘", style)
    |> vline(x, y + 1, h - 2, style)
    |> vline(x + w - 1, y + 1, h - 2, style)
    |> title(x, y, w, title, style)
  end

  defp vline(b, x, y, height, style) do
    Enum.reduce(0..max(height - 1, 0), b, fn i, acc -> put(acc, x, y + i, "│", style) end)
  end

  defp title(b, _x, _y, _w, nil, _style), do: b

  defp title(b, x, y, w, text, style) do
    # Starts at x + 1, immediately after the corner, and the room it may occupy
    # is the box width less two corners and the two spaces around it.
    #
    # Those two numbers have to agree. Starting at x + 2 with the same room let
    # the trailing space land exactly on the closing corner and erase it, so a
    # long title produced a box that did not close -- caught by the test that
    # exists for that, which is the only reason it is not still there.
    room = max(w - 4, 0)
    write(b, x + 1, y, " " <> fit(text, min(String.length(text), room)) <> " ", style)
  end

  # --- the invariants -------------------------------------------------------

  defp inside?(%Buffer{w: w, h: h}, x, y), do: x >= 0 and x < w and y >= 0 and y < h

  # One grapheme in, one grapheme out, and never a control character. A cell
  # holds exactly one column, so a caller handing over a whole string gets its
  # first grapheme rather than a silently ragged row.
  defp safe(char) do
    cond do
      # Invalid encoding first, and before anything that inspects codepoints.
      # A device is not obliged to send well-formed UTF-8, and String functions
      # raise on bytes that are not -- so the check meant to defend against
      # hostile input crashed ON hostile input. Found by tier 7 within seconds
      # of pointing it here.
      #
      # Substituted rather than rendered: bytes that are not a character cannot
      # be shown as one, and guessing an encoding is how mojibake becomes
      # permanent.
      not String.valid?(char) ->
        @substitute

      true ->
        case String.graphemes(char) do
          [] -> " "
          [g | _] -> if control?(g) or combining?(g), do: @substitute, else: g
        end
    end
  end

  # A combining mark with no base character. Stored in a cell it attaches
  # itself to whatever is in the cell to its LEFT when the row is joined, so a
  # 21-cell row renders as 20 graphemes and everything after it shifts.
  #
  # The grid's whole premise is one cell, one column, and Unicode does not
  # agree unless it is made to. Detected behaviourally rather than by Unicode
  # category, because the behaviour IS the hazard: if appending this to a space
  # yields a single grapheme, it will merge with its neighbour on screen.
  #
  # A normal accented character is unaffected: "é" appended to a space is two
  # graphemes, because it has a base of its own.
  defp combining?(grapheme), do: String.length(" " <> grapheme) == 1

  # ANY codepoint in the grapheme, not just a lone one. A grapheme can be
  # several codepoints -- a base character and its combining marks -- and the
  # first version matched only the single-codepoint form, so an escape carrying
  # a combining mark would have been waved through by the very check that
  # exists to stop it. A sanitiser with an exception is not a sanitiser.
  defp control?(grapheme) do
    grapheme
    |> String.to_charlist()
    |> Enum.any?(fn c ->
      c < 0x20 or c == 0x7F or (c >= 0x80 and c <= 0x9F)
    end)
  end
end
