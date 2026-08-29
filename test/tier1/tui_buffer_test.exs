defmodule Merlin.TUIBufferTest do
  @moduledoc """
  Tier 1: the grid, and the bytes it becomes.

  Two claims worth the whole file.

  **The grid cannot be misshapen.** Every write is clipped, so a frame is
  always exactly `h` rows of exactly `w` cells. A frame one column too wide
  wraps on a real terminal, and a wrapped frame corrupts every cursor position
  after it -- so this is not tidiness, it is the difference between a readable
  screen and a scrambled one.

  **The grid cannot hold a control character.** Fact values come from MQTT
  payloads, so a tampered device can publish `\\e[2J\\e[1;1H ALL CLEAR` and, if
  that reached a cell, repaint the operator's screen with a lie. The same
  defect class as `test/tier7/fuzz_test.exs`, one layer further out.

  And the round trip: what `Render` emits, fed to an independent model of a
  terminal, must reproduce the buffer it came from. That is the only assertion
  that checks the *bytes* rather than checking the renderer against itself.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier1

  alias Merlin.TUI.{Buffer, Render}
  alias Merlin.Test.TermModel

  describe "shape" do
    test "a new buffer is exactly w by h, all blank" do
      b = Buffer.new(10, 3)

      assert length(Buffer.cells(b)) == 30
      assert Buffer.to_text(b) == String.duplicate(" ", 10) <> "\n" <>
                                    String.duplicate(" ", 10) <> "\n" <>
                                    String.duplicate(" ", 10)
    end

    property "any write leaves the grid exactly w by h" do
      check all w <- integer(4..60),
                h <- integer(2..20),
                x <- integer(-10..80),
                y <- integer(-10..30),
                text <- string(:printable, max_length: 40) do
        b = Buffer.new(w, h) |> Buffer.write(x, y, text)

        assert length(Buffer.cells(b)) == w * h
        assert b |> Buffer.to_text() |> String.split("\n") |> length() == h

        for line <- String.split(Buffer.to_text(b), "\n") do
          assert String.length(line) == w
        end
      end
    end

    test "text longer than the row is truncated, not wrapped" do
      b = Buffer.new(5, 2) |> Buffer.write(0, 0, "abcdefghij")

      assert Buffer.row(b, 0) == "abcde"
      assert Buffer.row(b, 1) == "     ", "an over-long write must not spill onto the next row"
    end

    test "a write starting off the right edge lands nowhere" do
      b = Buffer.new(5, 1) |> Buffer.write(7, 0, "xy")
      assert Buffer.row(b, 0) == "     "
    end

    test "a write starting left of the origin keeps only what lands on screen" do
      # a and b fall off the left edge; c d e f land at columns 0..3.
      b = Buffer.new(5, 1) |> Buffer.write(-2, 0, "abcdef")
      assert Buffer.row(b, 0) == "cdef "
    end

    test "writing to a row that does not exist is dropped" do
      b = Buffer.new(5, 2) |> Buffer.write(0, 9, "xxxxx")
      assert Buffer.to_text(b) == "     \n     "
    end
  end

  describe "control characters cannot enter a cell" do
    test "an escape sequence in a value is substituted, not honoured" do
      hostile = "\e[2J\e[1;1H ALL CLEAR"
      b = Buffer.new(30, 1) |> Buffer.write(0, 0, hostile)

      text = Buffer.row(b, 0)
      refute text =~ "\e"
      assert text =~ "ALL CLEAR", "the text is still shown -- it is the escapes that are defanged"
    end

    property "no cell ever holds a control character, whatever is written" do
      check all text <- string(:ascii, max_length: 60) do
        b = Buffer.new(20, 2) |> Buffer.write(0, 0, text) |> Buffer.write(0, 1, text)

        for {_xy, {char, _style}} <- Buffer.cells(b) do
          <<code::utf8>> = char
          assert code >= 0x20, "a control character reached a cell: #{inspect(char)}"
          assert code != 0x7F
        end
      end
    end

    test "a lone combining mark cannot merge with its neighbour" do
      # Found by the shape property, not by reading: a combining mark with no
      # base attaches to the cell on its LEFT when the row is joined, so the
      # row renders one grapheme short and everything after it shifts.
      b = Buffer.new(5, 1) |> Buffer.write(1, 0, "\u1DF8")

      assert String.length(Buffer.row(b, 0)) == 5
      assert Buffer.row(b, 0) == " ·   "
    end

    test "but an accented character is left alone" do
      # The control: it has a base of its own and occupies one column honestly.
      b = Buffer.new(5, 1) |> Buffer.write(0, 0, "é")

      assert String.length(Buffer.row(b, 0)) == 5
      assert Buffer.row(b, 0) == "é    "
    end

    test "invalid UTF-8 is substituted, not raised on" do
      # The sanitiser inspects codepoints, and String functions raise on bytes
      # that are not a character -- so the guard against hostile input crashed
      # on hostile input. A device is under no obligation to send well-formed
      # UTF-8, and tier 7 found this within seconds of being pointed here.
      b = Buffer.new(5, 1) |> Buffer.write(0, 0, <<0xBC, 0xBD, ?a>>)

      assert String.length(Buffer.row(b, 0)) == 5
      assert Buffer.row(b, 0) =~ "·"
    end

    test "fit/2 survives invalid UTF-8, because it is also a door" do
      # The first fix hardened put/5 and fit/2 still crashed -- it calls
      # String.graphemes/1 before any text reaches a cell. Tier 7 found the
      # second door within one run of the first being shut.
      assert Buffer.fit(<<0xDF, 0xFF, ?a>>, 5) |> String.length() == 5
    end

    test "a valid run either side of a bad byte survives" do
      # Replaced byte by byte rather than discarding the string: a device name
      # with one corrupt byte is still mostly readable, and mostly readable is
      # what an operator needs at 3am.
      assert Buffer.printable(<<?a, 0xFF, ?b>>) == "a·b"
    end

    test "substitution, not deletion" do
      # A name that silently loses a character is a name you will misread.
      b = Buffer.new(5, 1) |> Buffer.write(0, 0, "a\tb")
      assert Buffer.row(b, 0) == "a·b  "
    end
  end

  describe "fit/2" do
    test "pads short text to exactly the width" do
      assert Buffer.fit("ab", 5) == "ab   "
    end

    test "truncates long text to exactly the width" do
      assert Buffer.fit("abcdefgh", 3) == "abc"
    end

    test "is grapheme-wise, not byte-wise" do
      assert Buffer.fit("héllo", 3) == "hél"
    end
  end

  describe "boxes" do
    test "a box closes on every corner" do
      b = Buffer.new(6, 3) |> Buffer.box(0, 0, 6, 3)

      assert Buffer.row(b, 0) == "┌────┐"
      assert Buffer.row(b, 1) == "│    │"
      assert Buffer.row(b, 2) == "└────┘"
    end

    test "a title is inset into the top edge" do
      b = Buffer.new(12, 3) |> Buffer.box(0, 0, 12, 3, title: "facts")
      assert Buffer.row(b, 0) == "┌ facts ───┐"
    end

    test "a long title cannot push the corner off the end" do
      b = Buffer.new(10, 3) |> Buffer.box(0, 0, 10, 3, title: "an extremely long title")

      assert String.length(Buffer.row(b, 0)) == 10
      assert String.ends_with?(Buffer.row(b, 0), "┐"), "the frame must still close"
    end
  end

  # --- the round trip -------------------------------------------------------

  describe "what Render emits reproduces the buffer" do
    test "a painted buffer round-trips through a model terminal" do
      b =
        Buffer.new(20, 4)
        |> Buffer.box(0, 0, 20, 4, title: "merlin")
        |> Buffer.write(2, 1, "door.front  open", [:bright])
        |> Buffer.write(2, 2, "cal         home")

      screen = TermModel.apply(TermModel.blank(20, 4), Render.paint(b))

      assert Buffer.to_text(screen) == Buffer.to_text(b)
    end

    property "any buffer round-trips" do
      # The assertion that checks the BYTES. A golden file compares the buffer
      # to itself and blesses whatever the renderer did with it; this does not.
      check all w <- integer(4..40),
                h <- integer(2..10),
                writes <-
                  list_of(
                    tuple({integer(0..39), integer(0..9), string(:alphanumeric, max_length: 12)}),
                    max_length: 8
                  ) do
        b =
          Enum.reduce(writes, Buffer.new(w, h), fn {x, y, text}, acc ->
            Buffer.write(acc, x, y, text)
          end)

        screen = TermModel.apply(TermModel.blank(w, h), Render.paint(b))
        assert Buffer.to_text(screen) == Buffer.to_text(b)
      end
    end

    test "styling changes no character's position" do
      plain = Buffer.new(10, 1) |> Buffer.write(0, 0, "hello")
      fancy = Buffer.new(10, 1) |> Buffer.write(0, 0, "hello", [:bright, :red])

      assert render_text(plain) == render_text(fancy)
    end

    test "an unknown style attribute is ignored, not applied by name" do
      # Styles arrive from view code, and a dynamic apply(IO.ANSI, atom, [])
      # is a code path nobody intended.
      b = Buffer.new(6, 1) |> Buffer.write(0, 0, "hi", [:definitely_not_a_real_attribute])

      assert render_text(b) == "hi    "
    end
  end

  describe "screen control" do
    test "leaving restores everything entering changed" do
      # The worst TUI failure is an operator's shell that still works and looks
      # broken: alternate screen up, cursor hidden, colour stuck.
      leave = IO.iodata_to_binary(Render.leave())

      assert leave =~ "\e[?1049l", "must leave the alternate screen"
      assert leave =~ "\e[?25h", "must show the cursor"
      assert leave =~ "\e[0m", "must reset styling"
    end
  end

  defp render_text(buffer) do
    TermModel.blank(buffer.w, buffer.h)
    |> TermModel.apply(Render.paint(buffer))
    |> Buffer.to_text()
  end
end
