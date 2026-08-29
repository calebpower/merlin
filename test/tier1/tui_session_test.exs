defmodule Merlin.TUISessionTest do
  @moduledoc """
  Tier 1: what a keypress means.

  `handle_key/3` is pure -- session, key and scene in; new session and a list
  of *actions* out. It performs nothing. That is what lets every keybinding,
  including the ones that actuate a house, be asserted without a terminal, a
  daemon or a device.

  The claim that matters most: **no key in normal or command mode can produce a
  commit**. A command reaches the house only by passing through a confirmation
  that describes the resolved effects, and the tests below try to find a way
  round that rather than assuming there is not one.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier1

  alias Merlin.TUI.{Scene, Session}

  defp fact(path), do: %Merlin.Fact{
    path: path,
    value: :on,
    changed_at: 0,
    observed_at: 0,
    source: nil,
    seq: 1,
    stale_after: nil
  }

  defp scene(n \\ 5) do
    %Scene{facts: for(i <- 1..n, do: fact([:f, "a#{i}"])), now: 0}
  end

  defp session(overrides \\ []), do: struct(%Session{}, overrides)

  defp press(session, keys, scene \\ nil) do
    scene = scene || scene()

    Enum.reduce(keys, {session, []}, fn key, {s, acc} ->
      {s, actions} = Session.handle_key(s, key, scene)
      {s, acc ++ actions}
    end)
  end

  # --- the safety claim -----------------------------------------------------

  describe "nothing reaches the house without a confirmation" do
    property "no key in normal mode ever produces a commit" do
      check all key <- key_generator() do
        {_s, actions} = Session.handle_key(session(), key, scene())

        refute Enum.any?(actions, &match?({:commit, _, _}, &1)),
               "#{inspect(key)} committed from normal mode"
      end
    end

    property "no key in command mode ever produces a commit" do
      # Not even Enter. Enter parses; parsing yields {:prepare, _} at most.
      check all key <- key_generator() do
        s = session(mode: :command, input: "set living_room_lamps off")
        {_s, actions} = Session.handle_key(s, key, scene())

        refute Enum.any?(actions, &match?({:commit, _, _}, &1)),
               "#{inspect(key)} committed from the command line"
      end
    end

    test "a control command becomes a prepare, never an act" do
      {_s, actions} =
        press(session(mode: :command, input: "set living_room_lamps off"), [:enter])

      assert [{:prepare, {:set_group, :living_room_lamps, :off}}] = actions
    end

    test "only a confirmation commits" do
      s = Session.awaiting(session(), %{token: "tok", description: ["set group lamps -> :off"]})

      assert {_s, [{:commit, "tok", opts}]} = Session.handle_key(s, {:char, "y"}, scene())
      refute Keyword.get(opts, :dry_run) == false, "y must not override dry run"
    end
  end

  describe "the dry-run override" do
    test "is a different key, and says so in the options" do
      s = Session.awaiting(session(), %{token: "tok", description: []})

      assert {_s, [{:commit, "tok", opts}]} = Session.handle_key(s, {:char, "!"}, scene())
      assert Keyword.get(opts, :dry_run) == false
    end

    test "y and ! are not the same action" do
      s = Session.awaiting(session(), %{token: "tok", description: []})

      {_, [{:commit, _, plain}]} = Session.handle_key(s, {:char, "y"}, scene())
      {_, [{:commit, _, override}]} = Session.handle_key(s, {:char, "!"}, scene())

      refute plain == override
    end

    test "a stray key while confirming does nothing at all" do
      # Not treated as "no": a keystroke landing while the operator is still
      # reading must not silently discard the command.
      s = Session.awaiting(session(), %{token: "tok", description: []})

      assert {returned, []} = Session.handle_key(s, {:char, "z"}, scene())
      assert returned.mode == :confirm
      assert returned.pending.token == "tok"
    end

    test "n and escape cancel" do
      s = Session.awaiting(session(), %{token: "tok", description: []})

      assert {a, [{:cancel, "tok"}]} = Session.handle_key(s, {:char, "n"}, scene())
      assert {b, [{:cancel, "tok"}]} = Session.handle_key(s, :escape, scene())
      assert a.mode == :normal and b.mode == :normal
      assert a.pending == nil
    end
  end

  # --- navigation -----------------------------------------------------------

  describe "moving about" do
    test "j and k move within bounds" do
      {s, []} = press(session(), [{:char, "j"}, {:char, "j"}])
      assert s.selected == 2

      {s, []} = press(s, [{:char, "k"}])
      assert s.selected == 1
    end

    test "the selection cannot leave the list" do
      {top, []} = press(session(), List.duplicate({:char, "k"}, 10))
      assert top.selected == 0

      {bottom, []} = press(session(), List.duplicate({:char, "j"}, 50))
      assert bottom.selected == 4, "five facts means the last index is four"
    end

    test "an empty pane has no selection to move" do
      empty = %Scene{facts: [], now: 0}
      {s, []} = press(session(), [{:char, "j"}, {:char, "G"}], empty)
      assert s.selected == 0
    end

    property "the selection is always a valid index, whatever is pressed" do
      # The bug this forbids: a scroll offset that outruns the list renders a
      # blank pane, which looks exactly like a house with nothing in it.
      check all keys <- list_of(key_generator(), max_length: 20) do
        {s, _actions} = press(session(), keys)

        assert s.selected >= 0
        assert s.selected <= 4
        assert s.scroll >= 0
      end
    end

    test "number keys switch panes and reset the cursor" do
      {s, []} = press(session(), [{:char, "j"}, {:char, "j"}, {:char, "3"}])

      assert s.pane == :stream
      assert s.selected == 0, "a new pane starts at the top, not at the old index"
    end
  end

  # --- the command line -----------------------------------------------------

  describe "typing" do
    test "characters accumulate and backspace removes" do
      {s, []} = press(session(mode: :command), [{:char, "s"}, {:char, "e"}, {:char, "t"}])
      assert s.input == "set"

      {s, []} = press(s, [:backspace])
      assert s.input == "se"
    end

    test "escape abandons the line without running it" do
      {s, actions} = press(session(mode: :command, input: "set lamps off"), [:escape])

      assert actions == []
      assert s.mode == :normal
      assert s.input == ""
    end

    test "slash opens the line pre-filled to filter" do
      {s, []} = press(session(), [{:char, "/"}])
      assert s.mode == :command
      assert s.input == "filter "
    end

    test "a filter is applied locally and never leaves the session" do
      {s, actions} = press(session(mode: :command, input: "filter door"), [:enter])

      assert actions == []
      assert s.filter == "door"
    end

    test "a bad command explains itself in the status line" do
      {s, actions} = press(session(mode: :command, input: "frobnicate"), [:enter])

      assert actions == []
      assert s.status =~ "help"
    end
  end

  describe "quitting" do
    test "q from normal, and ctrl-c" do
      assert {_s, [:quit]} = Session.handle_key(session(), {:char, "q"}, scene())
      assert {_s, [:quit]} = Session.handle_key(session(), {:ctrl, "c"}, scene())
    end

    test "q while typing is a q, not a quit" do
      {s, actions} = press(session(mode: :command), [{:char, "q"}])

      assert actions == []
      assert s.input == "q"
    end
  end

  defp key_generator do
    one_of([
      tuple({constant(:char), member_of(~w(a j k q y n ! 1 2 3 4 : / g G))}),
      tuple({constant(:ctrl), member_of(~w(a c d))}),
      member_of([:up, :down, :page_up, :page_down, :home, :end]),
      member_of([:enter, :escape, :backspace, :tab])
    ])
  end
end
