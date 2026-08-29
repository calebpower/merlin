defmodule Merlin.TUI.Session do
  @moduledoc """
  What one operator is looking at, and what a keypress means.

  `handle_key/3` is pure: it takes a session, a key and the current scene, and
  returns a new session plus a list of *actions* the loop should carry out. It
  performs nothing itself. That is what lets every keybinding in the program be
  asserted without a terminal, a daemon or a house -- including the ones that
  actuate.

  ## Three modes

    * `:normal`  -- navigation. No key here can change anything.
    * `:command` -- typing a line. Still nothing changes; Enter only *parses*.
    * `:confirm` -- a resolved command is on screen with its description, and
      the only keys that mean anything are yes, no, and the override.

  A command cannot skip a mode. `Merlin.Command.parse/1` produces a
  `{:control, _}`, which becomes a `{:prepare, _}` action, which comes back as
  something to confirm. Nothing typed reaches the house without passing through
  a screen that describes it first.

  ## The override is a different key on purpose

  While the daemon is in dry run, `y` confirms and the effect is logged and
  discarded. `!` confirms *and overrides dry run for that one command*. Two
  keys rather than a mode, because a mode can be left on: you cannot lean on
  `!` by habit the way you can leave a toggle flipped, and every live actuation
  during a soak is an individual act.
  """

  alias Merlin.TUI.{Command, Scene, View}

  @panes [:facts, :rules, :stream, :devices]

  @type action ::
          :quit
          | {:prepare, Merlin.Control.command()}
          | {:commit, binary(), keyword()}
          | {:cancel, binary()}
          | {:evaluate, binary()}

  @type mode :: :normal | :command | :confirm

  @type t :: %__MODULE__{
          pane: atom(),
          selected: non_neg_integer(),
          scroll: non_neg_integer(),
          filter: binary() | nil,
          mode: mode(),
          input: binary(),
          pending: map() | nil,
          status: binary() | nil,
          size: {pos_integer(), pos_integer()},
          who: binary()
        }

  defstruct pane: :facts,
            selected: 0,
            scroll: 0,
            filter: nil,
            mode: :normal,
            input: "",
            pending: nil,
            status: nil,
            size: {80, 24},
            who: "unknown"

  @doc "The panes, in the order their number keys select them."
  @spec panes() :: [atom()]
  def panes, do: @panes

  @doc """
  Interpret one key.

  Returns `{session, actions}`. Actions are the only way anything happens.
  """
  @spec handle_key(t(), Merlin.TUI.Keys.key(), Scene.t()) :: {t(), [action()]}
  def handle_key(%__MODULE__{mode: :confirm} = s, key, _scene), do: confirm(s, key)
  def handle_key(%__MODULE__{mode: :command} = s, key, _scene), do: command(s, key)
  def handle_key(%__MODULE__{mode: :normal} = s, key, scene), do: normal(s, key, scene)

  # --- normal ---------------------------------------------------------------

  defp normal(s, {:char, "q"}, _scene), do: {s, [:quit]}
  defp normal(s, {:ctrl, "c"}, _scene), do: {s, [:quit]}
  defp normal(s, {:char, ":"}, _scene), do: {%{s | mode: :command, input: "", status: nil}, []}
  defp normal(s, {:char, "/"}, _scene) do
    {%{s | mode: :command, input: "filter ", status: nil}, []}
  end

  defp normal(s, {:char, digit}, _scene) when digit in ~w(1 2 3 4) do
    pane = Enum.at(@panes, String.to_integer(digit) - 1)
    {%{s | pane: pane, selected: 0, scroll: 0, status: nil}, []}
  end

  defp normal(s, key, scene) when key in [:down, {:char, "j"}], do: {move(s, 1, scene), []}
  defp normal(s, key, scene) when key in [:up, {:char, "k"}], do: {move(s, -1, scene), []}
  defp normal(s, :page_down, scene), do: {move(s, page(s), scene), []}
  defp normal(s, :page_up, scene), do: {move(s, -page(s), scene), []}
  defp normal(s, :home, scene), do: {move_to(s, 0, scene), []}
  defp normal(s, :end, scene), do: {move_to(s, count(s, scene) - 1, scene), []}
  defp normal(s, {:char, "g"}, scene), do: {move_to(s, 0, scene), []}
  defp normal(s, {:char, "G"}, scene), do: {move_to(s, count(s, scene) - 1, scene), []}
  defp normal(s, :escape, _scene), do: {%{s | filter: nil, status: nil}, []}
  defp normal(s, _key, _scene), do: {s, []}

  # --- command line ---------------------------------------------------------

  defp command(s, :escape), do: {%{s | mode: :normal, input: ""}, []}
  defp command(s, :backspace), do: {%{s | input: String.slice(s.input, 0..-2//1)}, []}
  defp command(s, {:char, c}), do: {%{s | input: s.input <> c}, []}

  defp command(s, :enter) do
    session = %{s | mode: :normal, input: ""}

    case Command.parse(s.input) do
      :quit ->
        {session, [:quit]}

      :help ->
        {%{session | status: help_line()}, []}

      {:control, command} ->
        # Parsed, not armed. The loop asks Control to resolve and describe it,
        # and the answer comes back as something to confirm.
        {session, [{:prepare, command}]}

      {:expr, source} ->
        {session, [{:evaluate, source}]}

      {:view, {:filter, text}} ->
        {%{session | filter: text, selected: 0, scroll: 0}, []}

      {:view, :clear_filter} ->
        {%{session | filter: nil, selected: 0, scroll: 0}, []}

      {:view, {:pane, pane}} ->
        {%{session | pane: pane, selected: 0, scroll: 0}, []}

      {:error, ""} ->
        {session, []}

      {:error, message} ->
        {%{session | status: message}, []}
    end
  end

  defp command(s, _key), do: {s, []}

  # --- confirmation ---------------------------------------------------------

  defp confirm(%{pending: nil} = s, _key), do: {%{s | mode: :normal}, []}

  defp confirm(s, {:char, "y"}) do
    {clear(s), [{:commit, s.pending.token, [who: s.who]}]}
  end

  # The override. A separate key rather than a mode, because a mode can be left
  # on and this must be chosen every single time.
  defp confirm(s, {:char, "!"}) do
    {clear(s), [{:commit, s.pending.token, [who: s.who, dry_run: false]}]}
  end

  defp confirm(s, {:char, "n"}), do: {clear(s), [{:cancel, s.pending.token}]}
  defp confirm(s, :escape), do: {clear(s), [{:cancel, s.pending.token}]}

  # Anything else is ignored rather than treated as "no". A stray keystroke
  # should not silently discard a command the operator is still reading.
  defp confirm(s, _key), do: {s, []}

  defp clear(s), do: %{s | mode: :normal, pending: nil}

  # --- transitions the loop drives -----------------------------------------

  @doc "Put a resolved command on screen and wait for an answer."
  @spec awaiting(t(), map()) :: t()
  def awaiting(%__MODULE__{} = s, prepared) do
    %{s | mode: :confirm, pending: prepared, status: nil}
  end

  @doc "Say something in the status line."
  @spec say(t(), binary()) :: t()
  def say(%__MODULE__{} = s, message), do: %{s | status: message}

  @doc "A resize. Selection is kept; the view re-derives its own scroll."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{} = s, w, h), do: %{s | size: {w, h}}

  @doc "The session as the views want it: a plain map, so a view needs no struct."
  @spec to_view(t()) :: map()
  def to_view(%__MODULE__{} = s) do
    %{filter: s.filter, selected: s.selected, scroll: s.scroll, pane: s.pane}
  end

  # --- selection ------------------------------------------------------------

  defp move(s, delta, scene), do: move_to(s, s.selected + delta, scene)

  defp move_to(s, index, scene) do
    last = max(count(s, scene) - 1, 0)
    selected = index |> max(0) |> min(last)

    %{s | selected: selected, scroll: View.Facts.scroll_for(selected, s.scroll, rows(s))}
  end

  # How many rows the body has, which is what a page-worth means and what the
  # scroll window is measured against.
  defp rows(%{size: {_w, h}}), do: max(h - Merlin.TUI.Layout.chrome_rows() - 2, 1)
  defp page(s), do: rows(s)

  defp count(%{pane: :facts} = s, scene), do: length(Scene.facts(scene, s.filter))
  defp count(%{pane: :rules}, scene), do: length(scene.rules)
  defp count(%{pane: :stream}, scene), do: length(scene.stream)
  defp count(%{pane: :devices}, scene), do: map_size(scene.groups)

  defp help_line do
    Command.help() |> Enum.map_join("  ", fn {form, _} -> form end)
  end
end
