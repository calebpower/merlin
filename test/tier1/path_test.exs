defmodule Merlin.PathTest do
  @moduledoc "Tier 1: path addressing. `prefixes/1` is what makes bus dispatch O(depth)."

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.Path

  describe "prefixes/1" do
    test "shortest first, including the empty path and the path itself" do
      assert Path.prefixes([:door, "office", :contact]) == [
               [],
               [:door],
               [:door, "office"],
               [:door, "office", :contact]
             ]
    end

    test "the empty path has exactly one prefix" do
      assert Path.prefixes([]) == [[]]
    end

    test "a single segment" do
      assert Path.prefixes([:a]) == [[], [:a]]
    end

    test "count is always depth + 1" do
      for depth <- 0..6 do
        path = Enum.map(1..depth//1, fn i -> "seg#{i}" end)
        assert length(Path.prefixes(path)) == depth + 1
      end
    end
  end

  describe "prefix?/2" do
    test "the empty path prefixes everything" do
      assert Path.prefix?([], [:a, :b])
      assert Path.prefix?([], [])
    end

    test "a path prefixes itself" do
      assert Path.prefix?([:a, :b], [:a, :b])
    end

    test "a longer candidate is not a prefix" do
      refute Path.prefix?([:a, :b, :c], [:a, :b])
    end

    test "a divergent segment is not a prefix" do
      refute Path.prefix?([:a, :x], [:a, :b, :c])
    end

    test "atoms and binaries do not cross-match" do
      # :office and "office" address different things, deliberately: atoms are
      # our closed vocabulary, binaries are values captured from devices.
      refute Path.prefix?([:door, :office], [:door, "office"])
      refute Path.prefix?([:door, "office"], [:door, :office])
    end
  end

  describe "to_string/1" do
    test "dotted, mixing atoms and binaries" do
      assert Path.to_string([:door, "office", :contact]) == "door.office.contact"
    end

    test "the empty path renders empty" do
      assert Path.to_string([]) == ""
    end
  end

  describe "parse/1" do
    test "keeps unknown segments as binaries rather than creating atoms" do
      # An unbounded stream of device names must never be able to exhaust the
      # atom table, so parse/1 interns only against atoms that already exist.
      path = Path.parse("door.definitely_not_an_existing_atom_xyzzy.contact")
      assert Enum.at(path, 1) == "definitely_not_an_existing_atom_xyzzy"
    end

    test "resolves segments that are already atoms" do
      # Force the atoms to exist first.
      _ = [:door, :contact]
      assert Path.parse("door.contact") == [:door, :contact]
    end
  end
end
