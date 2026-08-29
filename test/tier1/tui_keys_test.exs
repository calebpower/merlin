defmodule Merlin.TUIKeysTest do
  @moduledoc """
  Tier 1: bytes from a terminal, turned into keys.

  A read returns whatever has arrived, aligned to nothing. An arrow key is
  three bytes and they can turn up in three reads; a multi-byte character can
  be split down the middle; a paste arrives as one lump. A decoder that gets
  this right on whole sequences and wrong on split ones fails only under load
  or over a slow link, which is the worst kind of bug to reproduce -- so the
  central assertion here is the split-anywhere property, not the happy path.

  The other claim: a lone escape is never resolved by `decode/2`. It is
  genuinely ambiguous in the byte stream -- Escape, and the first byte of every
  arrow key -- and only *time* separates them. That decision lives in
  `resolve_pending/2`, which takes elapsed milliseconds as an argument rather
  than reading a clock, so it is testable without one.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier1

  alias Merlin.TUI.Keys

  describe "single keys" do
    test "printable characters" do
      assert {[{:char, "a"}, {:char, "b"}], ""} = Keys.decode("ab")
    end

    test "arrows" do
      assert {[:up, :down, :right, :left], ""} = Keys.decode("\e[A\e[B\e[C\e[D")
    end

    test "navigation" do
      assert {[:home, :end, :page_up, :page_down, :delete], ""} =
               Keys.decode("\e[H\e[F\e[5~\e[6~\e[3~")
    end

    test "enter, tab and backspace" do
      assert {[:enter, :enter, :tab, :backspace, :backspace], ""} =
               Keys.decode("\r\n\t" <> <<0x7F>> <> <<0x08>>)
    end

    test "control keys" do
      assert {[{:ctrl, "c"}], ""} = Keys.decode(<<3>>)
      assert {[{:ctrl, "q"}], ""} = Keys.decode(<<17>>)
    end

    test "a multi-byte character is one key, not several" do
      assert {[{:char, "é"}], ""} = Keys.decode("é")
      assert {[{:char, "→"}], ""} = Keys.decode("→")
    end
  end

  describe "a lone escape is never resolved by decode" do
    test "it is carried, not guessed" do
      assert {[], "\e"} = Keys.decode("\e")
    end

    test "resolve_pending keeps it while the rest may still be in flight" do
      assert {[], "\e"} = Keys.resolve_pending("\e", 0)
      assert {[], "\e"} = Keys.resolve_pending("\e", Keys.escape_ms() - 1)
    end

    test "and calls it Escape once the window has passed" do
      assert {[:escape], ""} = Keys.resolve_pending("\e", Keys.escape_ms())
    end

    test "an escape followed by its sequence is the sequence, not Escape" do
      {[], carry} = Keys.decode("\e")
      assert {[:up], ""} = Keys.decode("[A", carry)
    end
  end

  describe "split reads" do
    test "an arrow split across three reads is still one key" do
      {keys1, c1} = Keys.decode("\e")
      {keys2, c2} = Keys.decode("[", c1)
      {keys3, c3} = Keys.decode("A", c2)

      assert keys1 == []
      assert keys2 == []
      assert keys3 == [:up]
      assert c3 == ""
    end

    test "a multi-byte character split down the middle is carried, not mangled" do
      # The failure this prevents: String.next_grapheme/1 hands back the
      # partial byte rather than saying it is incomplete, so a character split
      # across two reads would arrive as mojibake.
      <<first, second>> = "é"

      {keys, carry} = Keys.decode(<<first>>)
      assert keys == []
      assert carry == <<first>>

      assert {[{:char, "é"}], ""} = Keys.decode(<<second>>, carry)
    end

    property "any key sequence survives being split at arbitrary points" do
      # The assertion that catches a decoder which works on whole sequences and
      # falls apart when one is split.
      check all keys <- list_of(key_generator(), max_length: 12),
                split_at <- list_of(integer(0..40), max_length: 5) do
        encoded = Keys.encode(keys)

        {decoded, carry} =
          encoded
          |> chunks(Enum.sort(split_at))
          |> Enum.reduce({[], ""}, fn chunk, {acc, carry} ->
            {got, carry} = Keys.decode(chunk, carry)
            {acc ++ got, carry}
          end)

        # A trailing lone escape is legitimately unresolved -- that is the
        # whole point of resolve_pending/2 -- so it is settled before comparing.
        {tail, _} = Keys.resolve_pending(carry, Keys.escape_ms())

        assert decoded ++ tail == keys
      end
    end
  end

  describe "hostile and unknown input" do
    test "an unknown CSI is consumed, not spat out as characters" do
      # A mouse report or a bracketed-paste marker must not become a screenful
      # of stray characters in a command line.
      assert {[{:char, "x"}], ""} = Keys.decode("\e[<35;40;12Mx")
    end

    test "an unfinished CSI is carried whole" do
      assert {[], "\e[12"} = Keys.decode("\e[12")
    end

    test "malformed bytes are dropped, not decoded as something" do
      assert {[{:char, "a"}], ""} = Keys.decode(<<0xFF, 0xFE, 0xFD, 0xFC, ?a>>)
    end

    test "a large paste decodes without loss" do
      text = String.duplicate("abc", 400)
      {keys, ""} = Keys.decode(text)

      assert length(keys) == 1200
      assert Enum.all?(keys, &match?({:char, _}, &1))
    end

    test "an illegal lead byte is dropped, not carried for ever" do
      # 0xFD can never begin a valid character, so carrying it as "might still
      # be in flight" would wedge the decoder and swallow everything behind it.
      assert {[{:char, "a"}], ""} = Keys.decode(<<0xFD, ?a>>)
    end

    property "the carry stays small, whatever arrives" do
      # The real invariant behind the bug above: a decoder that carries what it
      # cannot decode must still make progress, or a fuzzed stream grows the
      # carry without bound. Nothing legitimately pends beyond three bytes of a
      # part-arrived character or an unfinished escape sequence.
      check all bytes <- binary(max_length: 300) do
        {_keys, carry} = Keys.decode(bytes)

        assert byte_size(carry) < 4 or String.starts_with?(carry, "\e"),
               "carry grew to #{byte_size(carry)} bytes: #{inspect(carry)}"
      end
    end

    property "decoding never crashes, whatever the bytes" do
      check all bytes <- binary(max_length: 200) do
        assert {keys, carry} = Keys.decode(bytes)
        assert is_list(keys)
        assert is_binary(carry)
      end
    end
  end

  # Ctrl-h, -i, -j and -m are excluded deliberately: on the wire they ARE
  # backspace, tab, newline and carriage return, so no decoder can tell them
  # apart and a round trip through them is not a claim anyone can make.
  defp key_generator do
    one_of([
      tuple({constant(:char), string(:alphanumeric, min_length: 1, max_length: 1)}),
      tuple({constant(:ctrl), member_of(~w(a b c d e f g k l n o p q r s t u v w x y z))}),
      member_of([:up, :down, :left, :right, :home, :end, :page_up, :page_down]),
      member_of([:delete, :enter, :tab, :backspace])
    ])
  end

  defp chunks(binary, []), do: [binary]

  defp chunks(binary, [at | rest]) do
    at = min(at, byte_size(binary))
    <<head::binary-size(at), tail::binary>> = binary
    [head | chunks(tail, Enum.map(rest, &(&1 - at)) |> Enum.map(&max(&1, 0)))]
  end
end
