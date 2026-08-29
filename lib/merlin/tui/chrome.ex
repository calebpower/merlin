defmodule Merlin.TUI.Chrome do
  @moduledoc """
  The three rows that are not a view: title, status, command line.

  The banner is the one thing on this screen that must never be wrong. An
  operator who believes the daemon is in dry run and is mistaken will command a
  house they think they are only asking questions of -- so the mode comes from
  `Merlin.TUI.Scene`, which is built on the daemon, and never from
  `Merlin.Config` on the client, where it would answer `false` because no
  application is running there.

  A DISCONNECTED banner outranks both. A frozen screen showing LIVE is worse
  than one admitting it has lost the daemon: the first invents a quiet house.
  """

  alias Merlin.TUI.{Buffer, Layout, Scene, Session}

  @doc "The title row: who we are, what mode, and which pane."
  @spec header(Scene.t(), Session.t(), Layout.rect()) :: Buffer.t()
  def header(%Scene{} = scene, %Session{} = session, {_x, _y, w, h}) do
    {mode, style} = Scene.mode(scene)
    buffer = Buffer.new(w, max(h, 1))
    tabs = tabs(session.pane)

    buffer
    |> Buffer.write(0, 0, "merlin " <> scene.version, [:bright])
    |> Buffer.write(max(div(w, 2) - div(String.length(tabs), 2), 0), 0, tabs)
    |> Buffer.write(max(w - String.length(mode) - 1, 0), 0, mode, style)
  end

  @doc """
  The status row: whatever was last worth saying, or the settle window.

  The settle window takes precedence over an old message, because "nothing is
  happening because merlin is still learning the house" is the answer to the
  question an operator is about to ask.
  """
  @spec status(Scene.t(), Session.t(), Layout.rect()) :: Buffer.t()
  def status(%Scene{} = scene, %Session{} = session, {_x, _y, w, h}) do
    buffer = Buffer.new(w, max(h, 1))

    cond do
      scene.settling_ms > 0 ->
        Buffer.write(buffer, 0, 0, "settling: outward effects held for #{scene.settling_ms}ms", [
          :yellow
        ])

      scene.dropped > 0 ->
        # Said, never swallowed. A stream that silently drops invents a quiet
        # house; one that says so sends you to the log.
        Buffer.write(buffer, 0, 0, "#{scene.dropped} dropped -- falling behind", [:yellow])

      session.status ->
        Buffer.write(buffer, 0, 0, session.status, [:faint])

      true ->
        Buffer.write(buffer, 0, 0, hint(session.pane), [:faint])
    end
  end

  @doc """
  The bottom row: the command line, or the confirmation.

  A confirmation shows what `Merlin.Effects.describe/1` would say about the
  *resolved* effects -- not the text that was typed. The description and the
  thing that runs come from the same place, which is the whole reason
  `Merlin.Control` resolves before it asks.
  """
  @spec command(Scene.t(), Session.t(), Layout.rect()) :: Buffer.t()
  def command(%Scene{} = scene, %Session{} = session, {_x, _y, w, h}) do
    buffer = Buffer.new(w, max(h, 1))

    case {session.mode, session.pending} do
      {:confirm, %{} = pending} -> confirmation(buffer, scene, pending)
      {:command, _} -> Buffer.write(buffer, 0, 0, ":" <> session.input <> "_", [:bright])
      _ -> Buffer.write(buffer, 0, 0, ": for a command, / to filter, q to quit", [:faint])
    end
  end

  defp confirmation(buffer, scene, pending) do
    described = Enum.join(pending.description, "; ")

    keys =
      if scene.dry_run? do
        "  [y] log it   [!] ACTUALLY DO IT   [n] cancel"
      else
        "  [y] do it   [n] cancel"
      end

    style = if scene.dry_run?, do: [:yellow], else: [:red, :bright]

    Buffer.write(buffer, 0, 0, described <> keys, style)
  end

  defp tabs(current) do
    Session.panes()
    |> Enum.with_index(1)
    |> Enum.map_join("  ", fn {pane, n} ->
      label = "#{n} #{pane}"
      if pane == current, do: String.upcase(label), else: label
    end)
  end

  defp hint(:facts), do: "j/k move, / filter, : command"
  defp hint(:rules), do: "j/k move -- why a rule did not fire"
  defp hint(:stream), do: "changes, events and what became of every effect"
  defp hint(:devices), do: "j/k move, : set <group> <value>"
end
