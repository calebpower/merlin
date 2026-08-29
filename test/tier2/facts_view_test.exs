defmodule Merlin.FactsViewTest do
  @moduledoc """
  Tier 2: component conformance, on rendered output.

  This tier was declared not-applicable for the whole rewrite, with the reason
  "no rendered markup exists yet". A `Merlin.TUI.Buffer` is rendered markup --
  a deterministic character grid, with no cascade and no layout engine, so it
  is more amenable to conformance assertion than HTML ever was.

  Three techniques, because none covers what the others cannot:

    * **structural properties**, which hold for every scene and every size;
    * **the layout, asserted against the specification** rather than against
      what the code produced -- column widths are written here independently,
      so a renderer that changes them fails rather than redefining the truth;
    * **sensitivity**, which proves each datum is actually wired to the screen.

  And then `Merlin.Test.FrameMutations`, which proves the assertions above can
  fail at all. A golden captured from the implementation blesses whatever the
  implementation did; these do not.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier2

  alias Merlin.TUI.{Buffer, Scene}
  alias Merlin.TUI.View.Facts
  alias Merlin.Test.FrameMutations

  # The column layout, stated here as the specification rather than imported
  # from the module under test. If the view changes a width, this fails -- and
  # that is a specification change, which is exactly what should require a
  # deliberate edit in two places.
  @path_w 25
  @value_w 14
  @age_w 6
  @source_w 12
  @width 60

  @now 1_000_000

  defp fact(path, value, age_ms, opts \\ []) do
    %Merlin.Fact{
      path: path,
      value: value,
      changed_at: @now - age_ms,
      observed_at: @now - age_ms,
      source: Keyword.get(opts, :source),
      seq: 1,
      stale_after: Keyword.get(opts, :stale_after)
    }
  end

  defp scene(facts, opts \\ []) do
    %Scene{
      facts: facts,
      now: @now,
      dry_run?: Keyword.get(opts, :dry_run?, true),
      connected?: true
    }
  end

  defp default_scene do
    scene([
      fact([:door, "front", :contact], :open, 3_000, source: {:adapter, Merlin.Adapters.Echo}),
      fact([:person, :cal, :zone], :unknown, 120_000, source: {:derive, :cal_zone}),
      fact([:vehicle, :car, :lat], 42.4, 18_000_000, stale_after: 1_800_000)
    ])
  end

  defp render(scene, session \\ %{}, size \\ {@width, 6}) do
    Facts.render(scene, session, size)
  end

  # --- structural, for any scene and any size -------------------------------

  describe "structure" do
    property "a frame is always exactly the rect it was given" do
      check all w <- integer(20..120),
                h <- integer(3..30),
                count <- integer(0..12) do
        facts = for n <- 1..max(count, 1), do: fact([:x, "f#{n}"], n, n * 1000)
        buffer = render(scene(Enum.take(facts, count)), %{}, {w, h})

        assert buffer.w == w
        assert buffer.h == h

        for line <- String.split(Buffer.to_text(buffer), "\n") do
          assert String.length(line) == w
        end
      end
    end

    property "no cell ever holds a control character, whatever a device published" do
      # Fact values come from MQTT payloads. A tampered device publishing an
      # escape sequence must not be able to repaint the operator's screen.
      check all hostile <- string(:printable, max_length: 40) do
        buffer = render(scene([fact([:door, hostile], hostile, 1000)]))

        refute Buffer.to_text(buffer) =~ "\e"

        # Every codepoint of every cell. A cell holds one GRAPHEME, which can
        # be several codepoints -- a base character and its combining marks --
        # so checking only a lone one would miss an escape wearing an accent.
        for {_xy, {char, _style}} <- Buffer.cells(buffer),
            code <- String.to_charlist(char) do
          assert code >= 0x20 and code != 0x7F,
                 "a control character reached a cell inside #{inspect(char)}"
        end
      end
    end

    test "an empty house renders a frame, not a crash" do
      buffer = render(scene([]))

      assert buffer.h == 6
      assert Buffer.row(buffer, 0) =~ "0 facts"
    end
  end

  # --- the layout, against the written specification ------------------------

  describe "layout" do
    test "the column header sits where the specification says" do
      buffer = render(default_scene())

      assert Buffer.text_at(buffer, 0, 1, @path_w) == Buffer.fit("PATH", @path_w)
      assert Buffer.text_at(buffer, @path_w + 1, 1, @value_w) == Buffer.fit("VALUE", @value_w)

      assert Buffer.text_at(buffer, @path_w + @value_w + 2, 1, @age_w) ==
               Buffer.fit("AGE", @age_w)

      assert Buffer.text_at(buffer, @path_w + @value_w + @age_w + 3, 1, @source_w) ==
               Buffer.fit("SOURCE", @source_w)
    end

    test "a fact's columns line up with its header" do
      buffer = render(default_scene())

      assert Buffer.text_at(buffer, 0, 2, @path_w) == Buffer.fit("door.front.contact", @path_w)
      assert Buffer.text_at(buffer, @path_w + 1, 2, @value_w) == Buffer.fit(":open", @value_w)
      assert Buffer.text_at(buffer, @path_w + @value_w + 2, 2, @age_w) == Buffer.fit("3s", @age_w)
    end

    test "facts are in path order, not insertion order" do
      buffer = render(default_scene())

      assert Buffer.text_at(buffer, 0, 2, 5) == "door."
      assert Buffer.text_at(buffer, 0, 3, 6) == "person"
      assert Buffer.text_at(buffer, 0, 4, 7) == "vehicle"
    end

    test "the count is stated, and it counts what is shown" do
      assert Buffer.row(render(default_scene()), 0) =~ "3 facts"
    end
  end

  # --- what the view claims to say ------------------------------------------

  describe "staleness is marked, never hidden" do
    test "a stale fact is still listed" do
      buffer = render(default_scene())
      assert Buffer.row(buffer, 4) =~ "vehicle.car.lat"
    end

    test "and its age carries a mark" do
      # The mark is in the AGE column, because age is what is wrong with it --
      # the value may be perfectly true, just too old to decide on.
      buffer = render(default_scene())
      age = Buffer.text_at(buffer, @path_w + @value_w + 2, 4, @age_w)

      assert age =~ "!"
      assert age =~ "5h"
    end

    test "a fresh fact carries no mark" do
      buffer = render(default_scene())
      refute Buffer.text_at(buffer, @path_w + @value_w + 2, 2, @age_w) =~ "!"
    end
  end

  describe "filtering" do
    test "narrows to matching paths and says so" do
      buffer = render(default_scene(), %{filter: "door"})

      assert Buffer.row(buffer, 0) =~ "1 facts"
      assert Buffer.row(buffer, 0) =~ "door"
      assert Buffer.row(buffer, 2) =~ "door.front.contact"
      refute Buffer.to_text(buffer) =~ "vehicle"
    end

    test "matches across segment boundaries, because a filter is typed in a hurry" do
      buffer = render(default_scene(), %{filter: "front.cont"})
      assert Buffer.row(buffer, 2) =~ "door.front.contact"
    end

    test "a filter matching nothing is an empty list, not an error" do
      buffer = render(default_scene(), %{filter: "nothing_like_this"})
      assert Buffer.row(buffer, 0) =~ "0 facts"
    end
  end

  # --- sensitivity: is each datum actually wired to the screen? -------------

  describe "every displayed datum changes the frame when it changes" do
    # A golden that was captured without the staleness marker will bless its
    # absence for ever. This is the answer: perturb one field at a time and
    # require the frame to move.
    test "the value" do
      a = render(scene([fact([:a, :b], :on, 1000)]))
      b = render(scene([fact([:a, :b], :off, 1000)]))

      refute Buffer.to_text(a) == Buffer.to_text(b)
    end

    test "the age" do
      a = render(scene([fact([:a, :b], :on, 1_000)]))
      b = render(scene([fact([:a, :b], :on, 400_000)]))

      refute Buffer.to_text(a) == Buffer.to_text(b)
    end

    test "staleness" do
      a = render(scene([fact([:a, :b], :on, 400_000, stale_after: 1_000_000)]))
      b = render(scene([fact([:a, :b], :on, 400_000, stale_after: 1_000)]))

      refute Buffer.to_text(a) == Buffer.to_text(b)
    end

    test "the source" do
      a = render(scene([fact([:a, :b], :on, 1000, source: {:rule, :one})]))
      b = render(scene([fact([:a, :b], :on, 1000, source: {:rule, :two})]))

      refute Buffer.to_text(a) == Buffer.to_text(b)
    end

    test "the path" do
      a = render(scene([fact([:a, :b], :on, 1000)]))
      b = render(scene([fact([:a, :c], :on, 1000)]))

      refute Buffer.to_text(a) == Buffer.to_text(b)
    end

    test "the filter" do
      refute Buffer.to_text(render(default_scene(), %{})) ==
               Buffer.to_text(render(default_scene(), %{filter: "door"}))
    end

    test "the selection" do
      # Styling only, so the TEXT is deliberately unchanged -- which is why
      # this one asserts on cells rather than on to_text/1. A sensitivity test
      # that could not see a style change would quietly stop covering it.
      a = render(default_scene(), %{selected: 0})
      b = render(default_scene(), %{selected: 1})

      refute Buffer.cells(a) == Buffer.cells(b)
    end
  end

  # --- and the proof that all of the above can fail -------------------------

  describe "the assertions themselves can fail" do
    test "every mutation of a correct frame breaks at least one check" do
      correct = render(default_scene())

      for {name, _fun} <- FrameMutations.all() do
        mutated = FrameMutations.apply(correct, name)

        refute checks(mutated) == :ok,
               "the mutation #{inspect(name)} passed every check -- the checks are not " <>
                 "discriminating, and deleting the mutation would be the wrong repair"
      end
    end

    test "and the correct frame passes them all" do
      # The control. Without it, a checks/1 that rejected everything would
      # satisfy the test above and look rigorous.
      assert checks(render(default_scene())) == :ok
    end
  end

  # The same claims the tests above make, as a function, so a mutated frame can
  # be run through them without duplicating the assertions.
  defp checks(buffer) do
    cond do
      buffer.w != @width -> {:error, :width}
      buffer.h != 6 -> {:error, :height}
      # Row 0 is the count line. Omitting it here is what let the "blank the
      # header" mutation pass every check -- the harness caught that these
      # assertions were not discriminating, which is the entire reason it
      # exists. The repair is a better check, never a deleted mutation.
      not (Buffer.row(buffer, 0) =~ ~r/^\d+ facts/) -> {:error, :count_line}
      Buffer.to_text(buffer) =~ "\e" -> {:error, :control_character}
      Buffer.text_at(buffer, 0, 1, @path_w) != Buffer.fit("PATH", @path_w) -> {:error, :header}
      Buffer.text_at(buffer, 0, 2, @path_w) != Buffer.fit("door.front.contact", @path_w) ->
        {:error, :first_row}
      Buffer.text_at(buffer, @path_w + 1, 2, @value_w) != Buffer.fit(":open", @value_w) ->
        {:error, :first_value}
      Buffer.text_at(buffer, 0, 3, 6) != "person" -> {:error, :second_row}
      not (Buffer.text_at(buffer, @path_w + @value_w + 2, 4, @age_w) =~ "!") ->
        {:error, :stale_marker}
      true -> :ok
    end
  end
end
