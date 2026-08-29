defmodule Merlin.Test.FrameMutations do
  @moduledoc """
  Deliberate corruptions of a correct frame.

  A golden frame captured from the implementation is self-certifying: if the
  staleness marker was never rendered, the golden was captured without it and
  will bless its absence for ever. That is the UI form of an invariant that
  never fires, and this is the answer to it -- every mutation below must make
  at least one tier 2 assertion fail.

  If a mutation passes, the assertions are not discriminating and the fault is
  in the tests, not in the mutation. Deleting the mutation would be the wrong
  repair.

  The same shape as the "invariants themselves fire" block in
  `test/tier9/simulated_house_test.exs`: prove the check can complain before
  trusting it when it does not.
  """

  alias Merlin.TUI.Buffer

  @type mutation :: {binary(), (Buffer.t() -> Buffer.t())}

  @doc "Every corruption, by name."
  @spec all() :: [mutation()]
  def all do
    [
      {"shift one column right", &shift_right/1},
      {"drop the last row", &drop_last_row/1},
      {"blank the header", &blank_header/1},
      {"blank the first data row", &blank_row(&1, 2)},
      {"truncate every row by one cell", &truncate/1},
      {"swap two rows", &swap_rows/1},
      {"inject a control character", &inject_control/1},
      {"replace a value with a plausible wrong one", &wrong_value/1}
    ]
  end

  @doc "Apply one named mutation."
  @spec apply(Buffer.t(), binary()) :: Buffer.t()
  def apply(buffer, name) do
    {^name, fun} = Enum.find(all(), fn {n, _} -> n == name end)
    fun.(buffer)
  end

  # Every cell moves one right, so the last column falls off. Catches any
  # assertion that looks at a column position.
  defp shift_right(%Buffer{} = b) do
    Enum.reduce(0..(b.h - 1), b, fn y, acc ->
      Buffer.write(acc, 1, y, Buffer.row(b, y))
    end)
  end

  defp drop_last_row(%Buffer{} = b) do
    %{b | h: b.h - 1, cells: Map.reject(b.cells, fn {{_x, y}, _} -> y == b.h - 1 end)}
  end

  defp blank_header(%Buffer{} = b), do: Buffer.write(b, 0, 0, String.duplicate(" ", b.w))

  defp blank_row(%Buffer{} = b, y), do: Buffer.write(b, 0, y, String.duplicate(" ", b.w))

  # One cell short on every row: the classic off-by-one that a length assertion
  # catches and an eyeball does not.
  defp truncate(%Buffer{} = b) do
    %{b | w: b.w - 1, cells: Map.reject(b.cells, fn {{x, _y}, _} -> x == b.w - 1 end)}
  end

  defp swap_rows(%Buffer{h: h} = b) when h >= 4 do
    a = Buffer.row(b, 2)
    c = Buffer.row(b, 3)

    b |> Buffer.write(0, 2, c) |> Buffer.write(0, 3, a)
  end

  defp swap_rows(b), do: b

  # Not through Buffer.put/5, which sanitises -- that is the point. This proves
  # the assertion would catch a control character if one ever reached a cell by
  # some route the sanitiser did not cover.
  defp inject_control(%Buffer{} = b) do
    %{b | cells: Map.put(b.cells, {0, 2}, {"\e", []})}
  end

  # The most dangerous corruption, because it looks entirely reasonable: a
  # value that is well-formed, correctly placed, and wrong.
  defp wrong_value(%Buffer{} = b), do: Buffer.write(b, 26, 2, "WRONG")
end
