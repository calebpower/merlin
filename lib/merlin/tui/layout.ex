defmodule Merlin.TUI.Layout do
  @moduledoc """
  Where things go. Rectangles, and nothing else.

  Pure arithmetic over `{x, y, w, h}`, so the awkward cases -- a terminal too
  short for the chrome, a split that would leave a pane zero rows high -- are
  decided once here and testable without rendering anything.

  A frame that assumes it has room is a frame that draws off the bottom of an
  80x10 window, and the result is not a squashed layout but a corrupted one:
  every cursor position after the overflow is wrong.
  """

  @type rect :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  # Header, status and command are one row each. The body gets the rest, and
  # never less than nothing.
  @chrome_rows 3

  @doc "The chrome rows a screen spends before the body sees any."
  @spec chrome_rows() :: pos_integer()
  def chrome_rows, do: @chrome_rows

  @doc """
  The whole screen, divided.

  Returns `%{header:, body:, status:, command:}`. On a terminal too short for
  the chrome the body collapses to zero rows rather than going negative --
  a negative height would reach `Buffer.new/2`'s guard and take the session
  down over a window somebody dragged too small.
  """
  @spec screen(pos_integer(), pos_integer()) :: %{atom() => rect()}
  def screen(w, h) when w > 0 and h > 0 do
    body_h = max(h - @chrome_rows, 0)

    %{
      header: {0, 0, w, min(1, h)},
      body: {0, 1, w, body_h},
      status: {0, 1 + body_h, w, min(1, max(h - 1 - body_h, 0))},
      command: {0, min(h - 1, 2 + body_h), w, min(1, max(h - 2 - body_h, 0))}
    }
  end

  @doc """
  Divide `rect` into columns by weight.

  Remainder goes to the last column, so the parts always sum to the whole. A
  layout that loses a column to rounding leaves an unpainted stripe, which
  looks exactly like a rendering bug in whatever is next to it.
  """
  @spec columns(rect(), [pos_integer()]) :: [rect()]
  def columns({x, y, w, h}, weights) when weights != [] do
    total = Enum.sum(weights)
    {rects, used} =
      weights
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {weight, index}, taken ->
        width =
          if index == length(weights) - 1 do
            w - taken
          else
            div(w * weight, total)
          end

        {{x + taken, y, max(width, 0), h}, taken + width}
      end)

    _ = used
    rects
  end

  @doc "Divide `rect` into rows by weight. Remainder to the last, as with columns/2."
  @spec rows(rect(), [pos_integer()]) :: [rect()]
  def rows({x, y, w, h}, weights) when weights != [] do
    total = Enum.sum(weights)

    weights
    |> Enum.with_index()
    |> Enum.map_reduce(0, fn {weight, index}, taken ->
      height =
        if index == length(weights) - 1 do
          h - taken
        else
          div(h * weight, total)
        end

      {{x, y + taken, w, max(height, 0)}, taken + height}
    end)
    |> elem(0)
  end

  @doc "The size of a rect, as `render/3` wants it."
  @spec size(rect()) :: {non_neg_integer(), non_neg_integer()}
  def size({_x, _y, w, h}), do: {w, h}
end
