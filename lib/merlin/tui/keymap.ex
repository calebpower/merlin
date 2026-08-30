defmodule Merlin.TUI.Keymap do
  @moduledoc """
  Every key this program answers to, written down once.

  `Merlin.TUI.View.Help` renders this list and `Merlin.TUI.Session` implements
  it. Those are two things that must agree, and two things that must agree and
  are written down separately is how most of the defects in this codebase got
  in -- so a tier 1 test feeds every entry's `keys` to `Session.handle_key/3`
  and fails if a documented key does nothing at all.

  Help that lies is worse than no help. An operator who reads that `e` explains
  a rule, presses it, and sees nothing happen goes looking for a fault in the
  house, when the fault is in the manual.

  ## Why `?` is help and not something more useful

  It was Explain, briefly, on the reasoning that the rules pane exists to
  answer that question. That was wrong: `?` is the near-universal help key, so
  binding it to anything else means the first key an operator tries silently
  does nothing in three panes out of four -- which is exactly what happened.
  Explain moved to `e`.
  """

  @type entry :: %{
          shown: binary(),
          keys: [Merlin.TUI.Keys.key()],
          does: binary(),
          mode: :normal | :command | :confirm | :help,
          pane: atom() | :any
        }

  @entries [
    %{
      shown: "1 2 3 4",
      keys: [{:char, "1"}, {:char, "2"}, {:char, "3"}, {:char, "4"}],
      does: "facts, rules, stream, devices",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "j k",
      keys: [{:char, "j"}, {:char, "k"}, :down, :up],
      does: "move the selection",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "g G",
      keys: [{:char, "g"}, {:char, "G"}, :home, :end],
      does: "first row, last row",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "PgUp PgDn",
      keys: [:page_up, :page_down],
      does: "a screenful at a time",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "e",
      keys: [{:char, "e"}],
      does: "explain the selected rule -- why it would or would not fire",
      mode: :normal,
      pane: :rules
    },
    %{
      shown: "/",
      keys: [{:char, "/"}],
      does: "filter this pane",
      mode: :normal,
      pane: :any
    },
    %{
      shown: ":",
      keys: [{:char, ":"}],
      does: "open the command line",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "?",
      keys: [{:char, "?"}],
      does: "this help",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "Esc",
      keys: [:escape],
      does: "clear the filter and any message",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "q",
      keys: [{:char, "q"}],
      does: "quit, restoring the terminal",
      mode: :normal,
      pane: :any
    },
    %{
      shown: "Tab",
      keys: [:tab],
      does: "complete the word you are typing",
      mode: :command,
      pane: :any
    },
    %{
      shown: "Enter",
      keys: [:enter],
      does: "parse it -- nothing that changes the house runs yet",
      mode: :command,
      pane: :any
    },
    %{
      shown: "Esc",
      keys: [:escape],
      does: "abandon the line",
      mode: :command,
      pane: :any
    },
    %{
      shown: "y",
      keys: [{:char, "y"}],
      does: "yes -- in dry run this logs the effect and discards it",
      mode: :confirm,
      pane: :any
    },
    %{
      shown: "!",
      keys: [{:char, "!"}],
      does: "yes, AND override dry run for this one command",
      mode: :confirm,
      pane: :any
    },
    %{
      shown: "n Esc",
      keys: [{:char, "n"}, :escape],
      does: "no",
      mode: :confirm,
      pane: :any
    },
    %{
      shown: "j k",
      keys: [{:char, "j"}, {:char, "k"}],
      does: "scroll this help",
      mode: :help,
      pane: :any
    },
    %{
      shown: "any other key",
      keys: [{:char, "x"}],
      does: "close this help",
      mode: :help,
      pane: :any
    }
  ]

  @doc "Every documented key, in the order help shows them."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The entries for one mode."
  @spec for_mode(atom()) :: [entry()]
  def for_mode(mode), do: Enum.filter(@entries, &(&1.mode == mode))

  @doc """
  The one-line hint for a pane, built from the entries themselves.

  Derived rather than written out again, so a binding that changes cannot
  leave a hint behind describing what it used to do.
  """
  @spec hint(atom()) :: binary()
  def hint(pane) do
    :normal
    |> for_mode()
    |> Enum.filter(&(&1.pane == :any or &1.pane == pane))
    |> Enum.filter(&(&1.shown in ["j k", "/", ":", "e", "?"]))
    |> Enum.map_join("  ", fn e -> "#{e.shown} #{short(e.does)}" end)
  end

  # The hint row has one line; the help overlay has room for the sentence.
  defp short(does), do: does |> String.split(" -- ") |> hd() |> String.split(",") |> hd()
end
