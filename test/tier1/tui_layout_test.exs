defmodule Merlin.TUILayoutTest do
  @moduledoc """
  Tier 1: rectangles.

  Pure arithmetic, and worth its own file because the awkward cases are the
  ones that corrupt a screen rather than merely looking wrong. A body pane with
  a negative height reaches `Buffer.new/2`'s guard and takes the session down
  over a window somebody dragged too small; a split that loses a column to
  rounding leaves an unpainted stripe that reads as a bug in whatever is beside
  it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier1

  alias Merlin.TUI.Layout

  describe "the screen" do
    test "gives the body everything the chrome does not take" do
      %{header: h, body: b, status: s, command: c} = Layout.screen(80, 24)

      assert h == {0, 0, 80, 1}
      assert b == {0, 1, 80, 21}
      assert s == {0, 22, 80, 1}
      assert c == {0, 23, 80, 1}
    end

    property "no rect ever has a negative dimension, however small the window" do
      # Including terminals too short for the chrome at all.
      check all w <- integer(1..200), h <- integer(1..60) do
        for {_name, {x, y, rw, rh}} <- Layout.screen(w, h) do
          assert x >= 0 and y >= 0
          assert rw >= 0 and rh >= 0
        end
      end
    end

    property "the rows never exceed the screen" do
      check all w <- integer(1..200), h <- integer(1..60) do
        %{header: {_, hy, _, hh}, body: {_, _, _, bh}, command: {_, cy, _, ch}} =
          Layout.screen(w, h)

        assert hy + hh <= h
        assert cy + ch <= h
        assert bh <= h
      end
    end

    test "a window too short for the chrome collapses the body, not the program" do
      %{body: {_, _, _, bh}} = Layout.screen(80, 2)
      assert bh == 0
    end
  end

  describe "splitting" do
    property "columns always sum to the whole width" do
      # Rounding remainder goes to the last column. A layout that loses a
      # column leaves an unpainted stripe.
      check all w <- integer(1..200),
                weights <- list_of(integer(1..5), min_length: 1, max_length: 5) do
        rects = Layout.columns({0, 0, w, 10}, weights)

        assert length(rects) == length(weights)
        assert Enum.sum(Enum.map(rects, fn {_, _, rw, _} -> rw end)) == w
      end
    end

    property "rows always sum to the whole height" do
      check all h <- integer(1..80),
                weights <- list_of(integer(1..5), min_length: 1, max_length: 5) do
        rects = Layout.rows({0, 0, 40, h}, weights)

        assert Enum.sum(Enum.map(rects, fn {_, _, _, rh} -> rh end)) == h
      end
    end

    test "columns start where the previous one ended" do
      assert [{0, 0, 30, 10}, {30, 0, 30, 10}, {60, 0, 30, 10}] =
               Layout.columns({0, 0, 90, 10}, [1, 1, 1])
    end
  end
end
