defmodule Merlin.TUIKeymapTest do
  @moduledoc """
  Tier 1: the help cannot describe a key that does nothing.

  `Merlin.TUI.Keymap` is what the help overlay renders and what
  `Merlin.TUI.Session` is supposed to implement. Two things that must agree,
  written down separately, is the shape of most of the defects in this
  codebase -- so the test below takes every key the help claims exists, presses
  it, and fails if the session neither changed nor asked for anything.

  This is the direction that matters. An undocumented key that works is a
  missed opportunity; a documented key that does nothing sends an operator
  looking for a fault in the house when the fault is in the manual.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.TUI.{Keymap, Scene, Session}

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

  # A rule as the session reads one: an id, and something it watches. The
  # session only ever does field access here, so this does not need to be a
  # %Merlin.Rule{} to be a faithful stand-in.
  defp rule(id), do: %{id: id, watches: [[:f, "a1"]], watch_groups: []}

  defp scene do
    %Scene{
      facts: for(i <- 1..5, do: fact([:f, "a#{i}"])),
      rules: [rule(:one), rule(:two), rule(:three)],
      groups: %{lamps: %{members: []}},
      now: 0
    }
  end

  # A session arranged so that every key in the mode has something visible to
  # do. Starting from a pristine session would make Esc a no-op (nothing to
  # clear) and `k` a no-op (already at the top), and the test would then be
  # asserting that the keymap is wrong rather than that the bindings are.
  defp ready(:normal, pane), do: %Session{pane: pane, selected: 1, filter: "x", status: "x"}
  defp ready(:command, _pane), do: %Session{mode: :command, input: "se"}
  defp ready(:help, _pane), do: %Session{mode: :help, help_scroll: 1}

  defp ready(:confirm, _pane) do
    %Session{mode: :confirm, pending: %{token: "tok", description: ["something"]}}
  end

  describe "every documented key does something" do
    test "pressing it changes the session or asks for an action" do
      for entry <- Keymap.entries(), key <- entry.keys do
        pane = if entry.pane == :any, do: :facts, else: entry.pane
        before = ready(entry.mode, pane)

        {after_press, actions} = Session.handle_key(before, key, scene())

        assert after_press != before or actions != [],
               "#{inspect(key)} is documented in #{entry.mode} mode as " <>
                 "#{inspect(entry.does)} and does nothing at all"
      end
    end

    # The control: if the assertion above could not fail, it would be proving
    # nothing. A key that is deliberately not bound must trip it.
    test "an unbound key would be caught" do
      before = ready(:normal, :facts)
      {after_press, actions} = Session.handle_key(before, {:char, "Z"}, scene())

      assert after_press == before and actions == [],
             "the Z key is bound to something now -- pick another unbound key for this control"
    end
  end

  describe "? is help, in every pane" do
    for pane <- [:facts, :rules, :stream, :devices] do
      test "from the #{pane} pane" do
        session = %Session{pane: unquote(pane)}
        {after_press, _actions} = Session.handle_key(session, {:char, "?"}, scene())

        assert after_press.mode == :help,
               "? did nothing in the #{unquote(pane)} pane, which is where an " <>
                 "operator who does not know the keys will press it first"
      end
    end
  end

  describe "the help overlay" do
    test "closes on a key that is not a scroll" do
      {closed, _} = Session.handle_key(%Session{mode: :help}, {:char, "z"}, scene())
      assert closed.mode == :normal
    end

    # q must close the overlay, not quit the program. Guessing q to dismiss a
    # panel and having the session exit instead is the kind of surprise that
    # stops people opening it again.
    test "q closes it without quitting" do
      {closed, actions} = Session.handle_key(%Session{mode: :help}, {:char, "q"}, scene())

      assert closed.mode == :normal
      assert actions == [], "q quit the program from the help overlay"
    end

    test "j and k scroll it, and it does not scroll above the top" do
      {down, _} = Session.handle_key(%Session{mode: :help}, {:char, "j"}, scene())
      assert down.help_scroll == 1

      {up, _} = Session.handle_key(%Session{mode: :help, help_scroll: 0}, {:char, "k"}, scene())
      assert up.help_scroll == 0
    end

    test "opening it always starts at the top" do
      session = %Session{pane: :facts, help_scroll: 9}
      {opened, _} = Session.handle_key(session, {:char, "?"}, scene())

      assert opened.help_scroll == 0,
             "the overlay reopened part-way down, where the first line is not visible"
    end
  end

  describe "explain moved to e" do
    test "e asks about the selected rule" do
      session = %Session{pane: :rules, selected: 1}
      {_s, actions} = Session.handle_key(session, {:char, "e"}, scene())

      assert [{:explain, :two, [:f, "a1"]}] = actions
    end

    test "e outside the rules pane does not explain" do
      {_s, actions} = Session.handle_key(%Session{pane: :facts}, {:char, "e"}, scene())
      assert actions == []
    end
  end
end
