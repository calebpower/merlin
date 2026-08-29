defmodule Merlin.Test.TermModel do
  @moduledoc """
  A terminal, as a pure function. Enough of one to check our own output.

  Consumes the bytes `Merlin.TUI.Render` emits and reconstructs the grid a real
  terminal would show. That gives the strongest assertion available to a TUI:

      TermModel.apply(TermModel.blank(w, h), Render.paint(buffer)) == buffer

  ...asserted on text. It says the bytes actually sent produce the screen that
  was intended, which is the one thing a golden file can never check -- a
  golden compares the buffer to itself and blesses whatever the renderer did
  with it.

  It is the same shadow-model shape `test/support/invariants.ex` and
  `test/support/sim_house.ex` already use: model the outcome independently,
  then require the real thing to agree.

  ## What it models, and what it ignores

  Modelled: cursor addressing (CUP), erase-display, printable text with a
  cursor that advances, and newline. Ignored: SGR colour, alternate screen,
  cursor visibility -- none of which change *which character is where*, and
  modelling them would mean asserting our own colour choices against our own
  colour choices.

  It is deliberately strict about one thing: an escape sequence it does not
  recognise raises rather than being skipped. A renderer that started emitting
  something this does not understand would otherwise pass silently, which
  defeats the entire point of having a model.
  """

  alias Merlin.TUI.Buffer

  @doc "A blank screen."
  @spec blank(pos_integer(), pos_integer()) :: Buffer.t()
  def blank(w, h), do: Buffer.new(w, h)

  @doc "Feed bytes to the model and return the resulting screen."
  @spec apply(Buffer.t(), iodata()) :: Buffer.t()
  def apply(%Buffer{} = screen, iodata) do
    iodata |> IO.iodata_to_binary() |> walk(screen, {0, 0})
  end

  # --- the interpreter ------------------------------------------------------

  defp walk(<<>>, screen, _cursor), do: screen

  defp walk(<<"\e[", rest::binary>>, screen, cursor) do
    {params, final, tail} = csi(rest, "")
    {screen, cursor} = control(params, final, screen, cursor)
    walk(tail, screen, cursor)
  end

  defp walk(<<"\n", rest::binary>>, screen, {_x, y}), do: walk(rest, screen, {0, y + 1})
  defp walk(<<"\r", rest::binary>>, screen, {_x, y}), do: walk(rest, screen, {0, y})

  defp walk(binary, screen, {x, y}) do
    {grapheme, rest} = String.next_grapheme(binary)
    walk(rest, Buffer.put(screen, x, y, grapheme), {x + 1, y})
  end

  # A CSI runs until a byte in the final range. Parameters accumulate before it.
  defp csi(<<byte::utf8, rest::binary>>, acc) when byte >= 0x40 and byte <= 0x7E do
    {acc, <<byte::utf8>>, rest}
  end

  defp csi(<<byte::utf8, rest::binary>>, acc), do: csi(rest, acc <> <<byte::utf8>>)

  defp csi(<<>>, acc), do: raise("unterminated CSI: #{inspect(acc)}")

  # Cursor position. 1-based on the wire, 0-based here.
  defp control(params, "H", screen, _cursor) do
    case numbers(params) do
      [] -> {screen, {0, 0}}
      [row] -> {screen, {0, row - 1}}
      [row, col | _] -> {screen, {col - 1, row - 1}}
    end
  end

  # Erase display. Only the whole-screen form is emitted, so only that is
  # modelled -- and anything else raises rather than quietly doing nothing.
  defp control("2", "J", screen, cursor), do: {blank(screen.w, screen.h), cursor}

  # Styling changes no character's position. Modelling it would assert our
  # colour choices against our own colour choices.
  defp control(_params, "m", screen, cursor), do: {screen, cursor}

  # Private modes: alternate screen, cursor visibility. Neither moves a cell.
  defp control("?" <> _, final, screen, cursor) when final in ["h", "l"], do: {screen, cursor}

  defp control(params, final, _screen, _cursor) do
    raise """
    TermModel does not understand \e[#{params}#{final}.

    This is deliberately fatal. A renderer that starts emitting something the
    model cannot read would otherwise pass silently, and a shadow model that
    ignores what it does not recognise is not a model.
    """
  end

  defp numbers(""), do: []

  defp numbers(params) do
    params |> String.split(";") |> Enum.map(&String.to_integer/1)
  end
end
