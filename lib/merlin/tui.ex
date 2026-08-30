defmodule Merlin.TUI do
  @moduledoc """
  The loop. Connect, draw, read a key, repeat.

  Everything interesting is elsewhere and pure: `Session` decides what a key
  means, the views decide what a frame looks like, `Render` decides what bytes
  say it. This is the part that cannot be tested without a terminal, so it is
  kept as close to nothing as it can be -- a `receive`, a dispatch table, and
  the discipline that the terminal is restored on every path out.

  ## One write per frame

  A frame is built as a single `Merlin.TUI.Buffer`, turned into one iolist, and
  written once. Per-row writes would be correct and would also turn a redraw
  into dozens of separate writes; on a slow link that is visible as tearing.

  ## Restoring the terminal

  Two independent mechanisms, because neither covers the other's case. This
  loop restores on its way out, which handles quitting and any error it can
  catch. The wrapper script's `trap` restores when the VM dies without running
  another line, which this cannot. A terminal left in the alternate screen with
  the cursor hidden is the worst outcome available: the shell still works and
  looks broken.
  """

  require Logger

  alias Merlin.TUI.{Chrome, Keys, Layout, Remote, Render, Scene, Session, Term, View}

  # Redraw at most this often. Between frames the loop still accepts input; it
  # simply does not repaint for every one of a hundred retained messages.
  @frame_ms 100

  # How many stream items a session keeps. Bounded, because a session left open
  # overnight must not grow.
  @stream_limit 500

  @doc """
  Run a session against `node`, returning when the operator quits.

  Blocks. `bin/merlin` invokes this and nothing else.
  """
  @spec main(keyword()) :: :ok | {:error, binary()}
  def main(opts \\ []) do
    node = Keyword.get(opts, :node, default_node())

    case Remote.attach(node) do
      {:ok, attached} -> run(attached, opts)
      {:error, message} -> fail(message)
    end
  end

  @doc """
  Render one frame to stdout and exit.

  The reason this exists is testability, not convenience. A full-screen program
  cannot be asserted on by a shell script, so tier 6 -- the tier that proves
  this works on a target with no compiler -- would have nothing to look at. It
  also makes the thing screenshot-able in a bug report: `merlin --once > frame`
  is a fault report that does not depend on anybody's terminal.

  No raw mode, no alternate screen, no reader. It draws and stops.
  """
  @spec once(keyword()) :: :ok | {:error, binary()}
  def once(opts \\ []) do
    node = Keyword.get(opts, :node, default_node())
    {w, h} = Keyword.get(opts, :size, Term.size())

    with {:ok, attached} <- Remote.attach(node),
         {:ok, scene} <- Remote.scene(node) do
      session = %Session{size: {w, h}, pane: Keyword.get(opts, :pane, :facts)}
      frame = compose(%{scene | version: attached.version}, session, w, h)

      IO.puts(Merlin.TUI.Buffer.to_text(frame))
      Remote.detach(node, attached.tap)
      :ok
    else
      {:error, message} when is_binary(message) -> fail(message)
      {:error, reason} -> fail(inspect(reason))
    end
  end

  defp run(attached, opts) do
    {w, h} = Term.size()

    session = %Session{
      size: {w, h},
      who: Keyword.get(opts, :who, whoami())
    }

    Term.enter()
    reader = Term.start_reader(self())

    state = %{
      node: attached.node,
      tap: attached.tap,
      reader: reader,
      session: session,
      scene: %Scene{version: attached.version},
      carry: "",
      stream: [],
      dropped: 0,
      dirty: true
    }

    try do
      state |> refresh() |> loop()
    after
      # Every path out, including an exception on the way through. The wrapper
      # trap covers what this cannot: a VM that stops without unwinding.
      Term.leave()
      Remote.detach(attached.node, attached.tap)
    end

    :ok
  end

  # --- the loop -------------------------------------------------------------

  defp loop(state) do
    state = if state.dirty, do: draw(state), else: state

    receive do
      {:input, bytes} ->
        state |> keys(bytes) |> continue()

      {:merlin_tap, items} ->
        state |> absorb(items) |> mark_dirty() |> continue()

      :tick ->
        state |> refresh() |> continue()

      :input_closed ->
        state

      {:input_error, reason} ->
        Logger.error("terminal read failed: #{inspect(reason)}")
        state

      {:nodedown, _node} ->
        # Draw it rather than exiting. An operator who walked away deserves to
        # come back to a screen that says what happened, not to a shell prompt
        # with no explanation.
        state |> put_in([:scene, Access.key(:connected?)], false) |> mark_dirty() |> continue()

      :quit ->
        state
    after
      @frame_ms ->
        send(self(), :tick)
        loop(state)
    end
  end

  defp continue(:quit), do: :ok
  defp continue(state), do: loop(state)

  # --- input ----------------------------------------------------------------

  defp keys(state, bytes) do
    {keys, carry} = Keys.decode(bytes, state.carry)
    {settled, carry} = Keys.resolve_pending(carry, Keys.escape_ms())

    Enum.reduce(keys ++ settled, %{state | carry: carry}, &apply_key/2)
  end

  defp apply_key(key, state) do
    {session, actions} = Session.handle_key(state.session, key, state.scene)
    Enum.reduce(actions, %{state | session: session, dirty: true}, &act/2)
  end

  defp act(:quit, state) do
    send(self(), :quit)
    state
  end

  defp act({:prepare, command}, state) do
    case Remote.prepare(state.node, command) do
      {:ok, prepared} ->
        %{state | session: Session.awaiting(state.session, prepared)}

      {:error, reason} ->
        %{state | session: Session.say(state.session, "refused: #{inspect(reason)}")}
    end
  end

  defp act({:commit, token, opts}, state) do
    case Remote.commit(state.node, token, opts) do
      {:ok, effects} ->
        %{state | session: Session.say(state.session, "done: #{length(effects)} effect(s)")}

      {:error, reason} ->
        %{state | session: Session.say(state.session, "refused: #{inspect(reason)}")}
    end
  end

  defp act({:cancel, token}, state) do
    Remote.cancel(state.node, token)
    %{state | session: Session.say(state.session, "cancelled")}
  end

  defp act({:explain, rule_id, path}, state) do
    case Remote.explain(state.node, rule_id, path) do
      {:ok, explanation} ->
        %{state | session: Session.explained(state.session, explanation)}

      {:error, reason} ->
        %{state | session: Session.say(state.session, "cannot explain: #{inspect(reason)}")}
    end
  end

  defp act({:evaluate, source}, state) do
    message =
      case Remote.evaluate(state.node, source) do
        {:ok, {:ok, value}} -> "#{source} = #{inspect(value)}"
        {:ok, {:error, reason}} -> "#{source}: #{inspect(reason)}"
        {:error, reason} -> "unreachable: #{inspect(reason)}"
      end

    %{state | session: Session.say(state.session, message)}
  end

  # --- the world ------------------------------------------------------------

  defp refresh(state) do
    {w, h} = Term.size()

    case Remote.scene(state.node) do
      {:ok, scene} ->
        %{
          state
          | scene: %{scene | stream: state.stream, dropped: state.dropped},
            session: Session.resize(state.session, w, h),
            dirty: true
        }

      {:error, _reason} ->
        %{state | scene: %{state.scene | connected?: false}, dirty: true}
    end
  end

  defp absorb(state, items) do
    {dropped, events} = Enum.split_with(items, &match?({:dropped, _}, &1))

    added = Enum.sum(for {:dropped, n} <- dropped, do: n)

    %{
      state
      | stream: Enum.take(Enum.reverse(events) ++ state.stream, @stream_limit),
        dropped: state.dropped + added
    }
  end

  defp mark_dirty(state), do: %{state | dirty: true}

  # --- drawing --------------------------------------------------------------

  defp draw(state) do
    {w, h} = state.session.size
    scene = %{state.scene | stream: state.stream, dropped: state.dropped}

    Term.write(Render.paint(compose(scene, state.session, w, h)))
    %{state | dirty: false}
  end

  # One frame, from a scene and a session. Shared with once/1 so a screenshot
  # is the same frame the operator sees rather than a second implementation
  # that can drift from it.
  defp compose(scene, session, w, h) do
    rects = Layout.screen(w, h)

    Merlin.TUI.Buffer.new(w, h)
    |> stamp(Chrome.header(scene, session, rects.header), rects.header)
    |> stamp(body(scene, session, rects.body), rects.body)
    |> stamp(Chrome.status(scene, session, rects.status), rects.status)
    |> stamp(Chrome.command(scene, session, rects.command), rects.command)
  end

  defp body(scene, session, rect) do
    view = Layout.size(rect)
    seen = Session.to_view(session)

    # Help takes the body rather than floating over it. A partial overlay would
    # need the pane underneath rendered as well and then composited, which is a
    # second way for a frame to come out wrong in exchange for nothing an
    # operator asked for.
    case session.mode do
      :help ->
        View.Help.render(scene, seen, view)

      _other ->
        case session.pane do
          :facts -> View.Facts.render(scene, seen, view)
          :rules -> View.Rules.render(scene, seen, view)
          :stream -> View.Stream.render(scene, seen, view)
          :devices -> View.Devices.render(scene, seen, view)
        end
    end
  end

  # Copy a rendered pane into the frame at its rect. Panes are rendered at
  # their own size and know nothing about where they sit, which is what keeps
  # each of them a function of its own inputs alone.
  defp stamp(frame, pane, {x, y, _w, _h}) do
    Enum.reduce(Merlin.TUI.Buffer.cells(pane), frame, fn {{px, py}, {char, style}}, acc ->
      Merlin.TUI.Buffer.put(acc, x + px, y + py, char, style)
    end)
  end

  # --- odds and ends --------------------------------------------------------

  defp default_node do
    System.get_env("MERLIN_NODE", "merlind@127.0.0.1") |> String.to_atom()
  end

  defp whoami do
    case System.cmd("id", ["-un"], stderr_to_stdout: true) do
      {name, 0} -> String.trim(name) <> "@" <> tty()
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp tty do
    case System.cmd("tty", [], stderr_to_stdout: true) do
      {path, 0} -> path |> String.trim() |> String.replace_prefix("/dev/", "")
      _ -> "?"
    end
  rescue
    _ -> "?"
  end

  defp fail(message) do
    IO.puts(:stderr, "merlin: " <> message)
    {:error, message}
  end
end
