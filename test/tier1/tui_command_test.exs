defmodule Merlin.TUICommandTest do
  @moduledoc """
  Tier 1: the command line.

  Parsing is pure and total, and that is the safety property, not a style
  choice. It resolves nothing, evaluates nothing and touches no daemon: the
  earliest a typed line can reach the house is after `Merlin.Control` has
  resolved it, described it back, and been handed its token. So a typo cannot
  actuate anything, and the whole language is assertable without a running
  system.

  Every input produces an action, including a bad one. There is no clause that
  can fail to match, because a command line that crashes the session on a
  fat-fingered word is a command line nobody will use while tired.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier1

  alias Merlin.TUI.Command

  describe "commands that change the house" do
    test "set names a group and a value" do
      # :living_room_lamps and :off both exist -- they are in the shipped
      # config -- so they resolve to atoms rather than staying text.
      assert {:control, {:set_group, :living_room_lamps, :off}} =
               Command.parse("set living_room_lamps off")
    end

    test "publish takes a topic and a payload verbatim" do
      assert {:control, {:publish, "z2m/x/set", "ON"}} = Command.parse("publish z2m/x/set ON")
    end

    test "fact takes a dotted path" do
      assert {:control, {:set_fact, [:person, :cal, :zone], :home}} =
               Command.parse("fact person.cal.zone :home")
    end

    test "parsing one arms nothing" do
      # The claim that matters. Parsing is not preparing, and preparing is not
      # committing. Asserted by the absence of any effect report.
      Merlin.Effects.Tap.clear()
      :ok = Merlin.Effects.Tap.subscribe()
      on_exit(&Merlin.Effects.Tap.clear/0)

      Command.parse("set living_room_lamps off")

      refute_receive {:merlin_effect, _}, 50
    end
  end

  describe "values" do
    test "a bare word is the atom, because a house speaks atoms" do
      assert Command.value("off") == :off
      assert Command.value("home") == :home
    end

    test "an explicit colon is the atom too" do
      assert Command.value(":off") == :off
    end

    test "a quoted value is the string, which is the only way to say so" do
      assert Command.value("\"off\"") == "off"
      refute Command.value("\"off\"") == :off
    end

    test "numbers are numbers" do
      assert Command.value("42") == 42
      assert Command.value("-7") == -7
      assert Command.value("1.5") == 1.5
    end

    test "a word this house has never used stays text, and mints no atom" do
      # The atom table is finite and never collected. A word nothing has ever
      # named is far likelier to be a typo than a new concept -- and the same
      # rule Merlin.Path.parse/1 already applies, so a command line and a fact
      # path agree about what a bare word means.
      novel = "zzz_no_atom_like_this_#{System.unique_integer([:positive])}"

      assert Command.value(novel) == novel
      assert is_binary(Command.value(novel))
    end
  end

  describe "the expression prefix" do
    test "a valid expression is carried through as its source" do
      assert {:expr, "1 == 1"} = Command.parse("= 1 == 1")
    end

    test "no space is needed after the equals" do
      assert {:expr, "1 == 1"} = Command.parse("=1 == 1")
    end

    test "an expression containing spaces survives whole" do
      assert {:expr, "if(1 == 1, :a, :b)"} = Command.parse("= if(1 == 1, :a, :b)")
    end

    test "a bad expression is refused at the keystroke" do
      # Rather than becoming :unknown later and looking like a house that had
      # nothing to say.
      assert {:error, message} = Command.parse("= 1 +")
      assert message =~ "expression"
    end

    test "it cannot reach the host system" do
      # The reason the prefix exists rather than an eval box: Merlin.Expr
      # parses without executing and interprets a closed whitelist. An
      # arbitrary-code prompt is bin/merlind remote with a nicer font.
      for hostile <- [
            "= System.halt()",
            "= File.read!(\"/etc/passwd\")",
            "= :os.cmd(~c\"id\")",
            "= spawn(fn -> :ok end)"
          ] do
        assert {:error, _} = Command.parse(hostile), "#{hostile} must not compile"
      end
    end
  end

  describe "view commands never leave the session" do
    test "filter narrows, bare filter clears" do
      assert {:view, {:filter, "door"}} = Command.parse("filter door")
      assert {:view, :clear_filter} = Command.parse("filter")
    end

    test "pane switches" do
      assert {:view, {:pane, :facts}} = Command.parse("pane facts")
      assert {:view, {:pane, :stream}} = Command.parse("pane stream")
    end

    test "an unknown pane says which ones exist" do
      assert {:error, message} = Command.parse("pane nonsense")
      assert message =~ "facts"
    end
  end

  describe "refusals are readable" do
    test "an unknown command suggests where to look" do
      assert {:error, message} = Command.parse("frobnicate")
      assert message =~ "help"
    end

    test "an incomplete set says its shape" do
      assert {:error, message} = Command.parse("set lamps")
      assert message =~ "set <group> <value>"
    end

    test "a group name that names no atom is refused, not minted" do
      novel = "zzz_group_#{System.unique_integer([:positive])}"
      assert {:error, message} = Command.parse("set #{novel} off")
      assert message =~ "group"
    end
  end

  describe "totality" do
    test "quit and help" do
      assert Command.parse("quit") == :quit
      assert Command.parse("q") == :quit
      assert Command.parse("help") == :help
      assert Command.parse("?") == :help
    end

    test "an empty line is not an error worth shouting about" do
      assert {:error, ""} = Command.parse("")
      assert {:error, ""} = Command.parse("     ")
    end

    property "every input produces one of the known actions, and none raise" do
      # A command line that crashes the session on a fat-fingered word is a
      # command line nobody will use while tired.
      #
      # The first version of this asserted `parse(line) != nil`, which asserts
      # nothing -- parse/1 cannot return nil, and the compiler said so. An
      # assertion that cannot fail is the thing this suite exists to avoid, so
      # it names the shapes instead.
      check all line <- string(:printable, max_length: 60) do
        assert match?(:quit, Command.parse(line)) or
                 match?(:help, Command.parse(line)) or
                 match?({:control, _}, Command.parse(line)) or
                 match?({:view, _}, Command.parse(line)) or
                 match?({:expr, _}, Command.parse(line)) or
                 match?({:error, _}, Command.parse(line)),
               "#{inspect(line)} produced #{inspect(Command.parse(line))}"
      end
    end

    property "no input is ever parsed as a control command by accident" do
      # Only three verbs reach the house. Anything else must be a view action,
      # an expression, or a refusal -- never something that actuates.
      check all line <- string(:alphanumeric, max_length: 20) do
        case Command.parse(line) do
          {:control, _} ->
            assert String.starts_with?(line, ["set", "publish", "fact"]),
                   "#{inspect(line)} became a control command"

          _ ->
            :ok
        end
      end
    end
  end

  # --- completion -----------------------------------------------------------

  describe "Tab completion" do
    defp fact(path) do
      %Merlin.Fact{
        path: path,
        value: :on,
        changed_at: 0,
        observed_at: 0,
        source: nil,
        seq: 1,
        stale_after: nil
      }
    end

    defp scene do
      %Merlin.TUI.Scene{
        facts: [
          fact([:person, :cal, :zone]),
          fact([:person, :cal, :lat]),
          fact([:door, :front_door, :contact])
        ],
        groups: %{living_room_lamps: %{members: []}, office_plugs: %{members: []}},
        now: 0
      }
    end

    test "a unique verb completes and adds a space" do
      assert {"publish ", ["publish"]} = Command.complete("pub", scene())
    end

    test "an ambiguous prefix advances only as far as the candidates agree" do
      # `filter` and `fact` share "f"; completing to either would be a guess.
      {completed, candidates} = Command.complete("f", scene())

      assert completed == "fa" or completed == "f",
             "completed to #{inspect(completed)}, past the point the candidates agree"

      assert "fact" in candidates and "filter" in candidates
    end

    test "no match leaves the line exactly as typed" do
      assert {"zzz", []} = Command.complete("zzz", scene())
    end

    test "set completes group names, which only the scene knows" do
      {completed, _candidates} = Command.complete("set living", scene())
      assert completed == "set living_room_lamps "
    end

    test "a bare verb and a space offers every argument" do
      {_completed, candidates} = Command.complete("set ", scene())
      assert Enum.sort(candidates) == ["living_room_lamps", "office_plugs"]
    end

    test "fact completes a path" do
      {completed, _} = Command.complete("fact person.cal.z", scene())
      assert completed == "fact person.cal.zone "
    end

    test "pane completes a pane name" do
      assert {"pane devices ", ["devices"]} = Command.complete("pane dev", scene())
    end

    test "an expression completes paths" do
      {completed, _} = Command.complete("= door.front", scene())
      assert completed == "= door.front_door.contact "
    end

    # A value is whatever the house calls it. Offering a guess would be worse
    # than offering nothing, because a completed wrong value looks deliberate.
    test "a value is not completed" do
      assert {"set living_room_lamps o", []} = Command.complete("set living_room_lamps o", scene())
    end

    # Completion and the parser read the same list, so this asserts they agree
    # about it: a verb offered must at worst produce a USAGE error, never "no
    # command". Being completed to a word the program then denies knowing is
    # the most confusing outcome available.
    test "every verb offered is a word the parser recognizes" do
      {_completed, verbs} = Command.complete("", scene())

      assert verbs != []

      for verb <- verbs do
        case Command.parse(verb) do
          {:error, message} ->
            refute String.starts_with?(message, "no command"),
                   "completion offers #{inspect(verb)}, and the parser answers #{inspect(message)}"

          _anything_else ->
            :ok
        end
      end
    end
  end
end
