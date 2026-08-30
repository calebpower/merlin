defmodule Merlin.TUI.View.Help do
  @moduledoc """
  What the keys do and what the command line accepts, on one screen.

  Built from `Merlin.TUI.Keymap.entries/0` and `Merlin.TUI.Command.help/0`,
  never from a list written out again here. Help is only worth having if it
  cannot drift from the thing it describes, and the way it drifts is somebody
  changing a binding and not knowing there was a second copy.

  ## Why this exists at all

  The command vocabulary used to be reachable only by typing `:help` blind,
  and the reward was every command form joined onto one line and then clipped
  by the width of the status row -- syntax with the explanations discarded, cut
  off in the middle. An operator who does not already know the answer could not
  get it from the program.
  """

  alias Merlin.TUI.{Buffer, Command, Keymap, Scene}

  @key_w 14
  @form_w 26

  @doc "The overlay, filling the body rect."
  @spec render(Scene.t(), map(), {non_neg_integer(), non_neg_integer()}) :: Buffer.t()
  # Too small to frame. Rendering a box here would ask Buffer.box/6 for a
  # negative interior; saying so plainly beats drawing a broken frame.
  def render(%Scene{}, _session, {w, h}) when w < 8 or h < 4 do
    Buffer.write(Buffer.new(max(w, 1), max(h, 1)), 0, 0, Buffer.fit("? help", max(w, 1)), [:faint])
  end

  def render(%Scene{}, session, {w, h}) do
    all = lines()
    rows = max(h - 2, 0)
    scroll = clamp(session[:help_scroll] || 0, length(all), rows)

    Buffer.new(w, h)
    |> Buffer.box(0, 0, w, h, title: title(length(all), rows), style: [:faint])
    |> write_lines(all, scroll, rows, w)
  end

  @doc """
  Every line of the overlay, as `{text, style}`.

  Public because tier 2 asserts on the content without a geometry, and because
  a sensitivity test needs to know that changing a command's description
  changes this.
  """
  @spec lines() :: [{binary(), [atom()]}]
  def lines do
    keys(:normal, "KEYS") ++
      [blank()] ++
      commands() ++
      [blank()] ++
      keys(:command, "WHILE TYPING A COMMAND") ++
      [blank()] ++
      keys(:confirm, "WHEN CONFIRMING") ++
      [blank()] ++
      # Its own keys, which it did not list -- caught by the tier 2 test that
      # requires every documented key to appear somewhere on this screen. The
      # one panel whose job is to say what the keys do was silent about the
      # keys you need while looking at it.
      keys(:help, "IN THIS HELP")
  end

  defp keys(mode, heading) do
    [{heading, [:bright]}] ++
      Enum.map(Keymap.for_mode(mode), fn entry ->
        {"  " <> pad(entry.shown, @key_w) <> entry.does <> where(entry), []}
      end)
  end

  defp commands do
    [{"COMMAND LINE  --  press : first, then Tab completes", [:bright]}] ++
      Enum.map(Command.help(), fn {form, does} ->
        {"  " <> pad(form, @form_w) <> does, []}
      end)
  end

  # Named, because "e explains the selected rule" is wrong three panes out of
  # four and an operator pressing it there deserves to know why nothing moved.
  defp where(%{pane: :any}), do: ""
  defp where(%{pane: pane}), do: "  (#{pane} pane only)"

  defp blank, do: {"", []}

  defp title(total, rows) when total > rows,
    do: "help -- j/k to scroll, any other key closes"

  defp title(_total, _rows), do: "help -- any key closes"

  defp write_lines(buffer, all, scroll, rows, w) do
    all
    |> Enum.drop(scroll)
    |> Enum.take(rows)
    |> Enum.with_index()
    |> Enum.reduce(buffer, fn {{text, style}, i}, acc ->
      Buffer.write(acc, 1, 1 + i, Buffer.fit(text, max(w - 2, 0)), style)
    end)
  end

  # Scrolling past the end leaves an empty box that looks like a rendering
  # fault, so the window stops where the text does.
  defp clamp(scroll, total, rows) do
    scroll |> max(0) |> min(max(total - rows, 0))
  end

  defp pad(text, width), do: String.pad_trailing(text, width)
end
