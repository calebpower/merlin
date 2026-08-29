defmodule Merlin.TUI.Keys do
  @moduledoc """
  Bytes from a terminal, turned into keys. Incrementally, and without blocking.

  A read from a terminal returns *whatever has arrived*. It is not aligned to
  anything: an arrow key is three bytes and they can turn up in three separate
  reads, a pasted line arrives as one four-kilobyte lump, and a multi-byte
  character can be split down the middle. So `decode/2` takes what it has,
  returns the keys it can be sure of, and hands back a carry containing the
  bytes it cannot yet interpret.

  Anything that guesses instead of carrying produces a bug that only appears
  under load or over a slow link, which is the worst kind to reproduce.

  ## The escape problem

  A lone `\\e` is genuinely ambiguous: it is the Escape key, and it is also the
  first byte of every arrow, function and navigation key. Nothing in the byte
  stream distinguishes them -- only *time* does. A terminal sends the rest of a
  sequence immediately; a human pressing Escape does not follow it with
  anything.

  So `decode/2` never resolves a lone `\\e`: it carries it. `resolve_pending/2`
  is where the timing decision lives, and it takes the elapsed milliseconds as
  an argument rather than reading a clock -- which is what makes the decision
  testable without one.
  """

  @typedoc "A decoded keypress."
  @type key ::
          {:char, binary()}
          | {:ctrl, binary()}
          | :up
          | :down
          | :left
          | :right
          | :home
          | :end
          | :page_up
          | :page_down
          | :delete
          | :enter
          | :tab
          | :backspace
          | :escape

  # How long a lone escape waits for the rest of a sequence before it is taken
  # to be the Escape key. Terminals send the remainder within microseconds; a
  # human cannot press two keys this close together.
  @escape_ms 50

  @doc "The window a lone escape waits before being read as the Escape key."
  @spec escape_ms() :: pos_integer()
  def escape_ms, do: @escape_ms

  @doc """
  Decode what has arrived, carrying what cannot yet be decided.

  Returns `{keys, carry}`. Feed the carry back in with the next read.
  """
  @spec decode(binary(), binary()) :: {[key()], binary()}
  def decode(bytes, carry \\ "") when is_binary(bytes) and is_binary(carry) do
    take(carry <> bytes, [])
  end

  @doc """
  Decide what a carried escape meant, given how long it has been waiting.

  Below the window the carry is kept -- the rest of the sequence may still be
  in flight. At or past it, a lone escape is the Escape key. A carry that is
  not an escape is an incomplete character and is always kept: bytes do not
  become more decodable by being late, but they do by being joined.
  """
  @spec resolve_pending(binary(), non_neg_integer()) :: {[key()], binary()}
  def resolve_pending("\e", elapsed_ms) when elapsed_ms >= @escape_ms, do: {[:escape], ""}
  def resolve_pending(carry, _elapsed_ms), do: {[], carry}

  @doc """
  Render keys back into the bytes a terminal would have sent.

  Exists for the round-trip property: encode a list of keys, split it at
  arbitrary points, fold `decode/2` over the pieces, and get the same list
  back. That is the assertion that catches a decoder which happens to work on
  whole sequences and falls apart when one is split.
  """
  @spec encode([key()]) :: binary()
  def encode(keys), do: Enum.map_join(keys, &encode_one/1)

  defp encode_one({:char, c}), do: c
  defp encode_one({:ctrl, letter}), do: <<:binary.first(letter) - ?a + 1>>
  defp encode_one(:up), do: "\e[A"
  defp encode_one(:down), do: "\e[B"
  defp encode_one(:right), do: "\e[C"
  defp encode_one(:left), do: "\e[D"
  defp encode_one(:home), do: "\e[H"
  defp encode_one(:end), do: "\e[F"
  defp encode_one(:page_up), do: "\e[5~"
  defp encode_one(:page_down), do: "\e[6~"
  defp encode_one(:delete), do: "\e[3~"
  defp encode_one(:enter), do: "\r"
  defp encode_one(:tab), do: "\t"
  defp encode_one(:backspace), do: <<0x7F>>
  defp encode_one(:escape), do: "\e"

  # --- decoding -------------------------------------------------------------

  defp take(<<>>, acc), do: {Enum.reverse(acc), ""}

  # Complete escape sequences.
  defp take(<<"\e[A", rest::binary>>, acc), do: take(rest, [:up | acc])
  defp take(<<"\e[B", rest::binary>>, acc), do: take(rest, [:down | acc])
  defp take(<<"\e[C", rest::binary>>, acc), do: take(rest, [:right | acc])
  defp take(<<"\e[D", rest::binary>>, acc), do: take(rest, [:left | acc])
  defp take(<<"\e[H", rest::binary>>, acc), do: take(rest, [:home | acc])
  defp take(<<"\e[F", rest::binary>>, acc), do: take(rest, [:end | acc])
  defp take(<<"\e[5~", rest::binary>>, acc), do: take(rest, [:page_up | acc])
  defp take(<<"\e[6~", rest::binary>>, acc), do: take(rest, [:page_down | acc])
  defp take(<<"\e[3~", rest::binary>>, acc), do: take(rest, [:delete | acc])

  # A CSI that is complete but not one we know. Consumed rather than emitted as
  # garbage: a mouse report or a bracketed-paste marker must not turn into a
  # screenful of stray characters in a command line.
  defp take(<<"\e[", rest::binary>> = all, acc) do
    case csi_end(rest, 0) do
      nil -> {Enum.reverse(acc), all}
      length -> take(binary_part(rest, length, byte_size(rest) - length), acc)
    end
  end

  # A lone escape, or an escape whose sequence has not finished arriving. Never
  # resolved here -- only resolve_pending/2 knows how long it has waited.
  defp take(<<"\e">> = carry, acc), do: {Enum.reverse(acc), carry}

  defp take(<<"\e", rest::binary>> = all, acc) do
    if String.starts_with?(rest, "[") or byte_size(rest) == 0 do
      {Enum.reverse(acc), all}
    else
      # Alt-<key> on most terminals. Decoded as the key itself rather than
      # dropped, so Alt-x at least does what x does.
      take(rest, acc)
    end
  end

  defp take(<<"\r", rest::binary>>, acc), do: take(rest, [:enter | acc])
  defp take(<<"\n", rest::binary>>, acc), do: take(rest, [:enter | acc])
  defp take(<<"\t", rest::binary>>, acc), do: take(rest, [:tab | acc])
  defp take(<<0x7F, rest::binary>>, acc), do: take(rest, [:backspace | acc])
  defp take(<<0x08, rest::binary>>, acc), do: take(rest, [:backspace | acc])

  defp take(<<c, rest::binary>>, acc) when c >= 1 and c <= 26 do
    take(rest, [{:ctrl, <<c + ?a - 1>>} | acc])
  end

  defp take(<<c, rest::binary>>, acc) when c < 0x20, do: take(rest, acc)

  defp take(binary, acc) do
    case utf8(binary) do
      # An incomplete character. Carried, not guessed: these bytes become
      # decodable by being JOINED to the next read, never by waiting -- which
      # is why this is not resolve_pending/2's business.
      :incomplete -> {Enum.reverse(acc), binary}
      # Before the general clause: {char, rest} matches any two-tuple, so a
      # malformed byte would otherwise be decoded as the character :invalid.
      {:invalid, rest} -> take(rest, acc)
      {char, rest} -> take(rest, [{:char, char} | acc])
    end
  end

  # String.next_grapheme/1 cannot be used here: on a truncated multi-byte
  # sequence it hands back the partial byte rather than saying it is
  # incomplete, so a character split across two reads would arrive as mojibake
  # instead of being carried.
  defp utf8(<<c::utf8, rest::binary>>), do: {<<c::utf8>>, rest}

  # Incompleteness is decided by the LEAD BYTE, not by how many bytes happen to
  # have arrived. A first attempt used "fewer than four bytes means it may
  # still be in flight", which is wrong for a byte like 0xFD that is not a
  # legal lead at all and can never become valid: it was carried for ever, and
  # every valid character behind it was swallowed. On a fuzzed stream the carry
  # grew without bound.
  #
  # So: a legal lead says how many bytes the character needs. Fewer than that
  # and the rest may still arrive. Anything else is malformed, and one byte is
  # dropped so decoding always makes progress.
  defp utf8(<<lead, _::binary>> = binary) do
    case needs(lead) do
      n when is_integer(n) and byte_size(binary) < n -> :incomplete
      _ -> {:invalid, binary_part(binary, 1, byte_size(binary) - 1)}
    end
  end

  defp needs(b) when b >= 0xC2 and b <= 0xDF, do: 2
  defp needs(b) when b >= 0xE0 and b <= 0xEF, do: 3
  defp needs(b) when b >= 0xF0 and b <= 0xF4, do: 4
  defp needs(_not_a_lead_byte), do: nil

  # A CSI runs until a byte in 0x40..0x7E. Returns the length including the
  # final byte, or nil if the sequence has not finished arriving.
  defp csi_end(<<>>, _n), do: nil

  defp csi_end(<<byte, rest::binary>>, n) do
    if byte >= 0x40 and byte <= 0x7E, do: n + 1, else: csi_end(rest, n + 1)
  end
end
