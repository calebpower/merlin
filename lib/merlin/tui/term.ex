defmodule Merlin.TUI.Term do
  @moduledoc """
  The terminal. The only module here that does I/O, and deliberately small.

  Raw mode is not set here -- the wrapper script does it, before this BEAM
  starts, because the tty belongs to the wrapper's process and because a `trap`
  in the shell is the only thing that still runs when the VM dies badly. A
  terminal left in raw mode with the cursor hidden is the worst failure this
  program has: the operator's shell still works and looks broken.

  ## Reading

  A reader process does the blocking read and forwards bytes to the loop, so
  the loop can also receive tap batches, timers and monitors. It reads one byte
  at a time: `IO.getn/3` waits for *exactly* the count asked for, so a larger
  read would sit on a full keystroke waiting for a buffer that will never fill.
  `Merlin.TUI.Keys` reassembles, which is what it is for.

  ## Size

  From `stty`, with a fallback chain that exists because the obvious call is
  not reliable: on this project's own host `stty size` answered `0 0` under a
  pty with no controlling terminal while `tput` answered correctly. Guessing
  80x24 silently would draw a frame the wrong shape and corrupt every cursor
  position below the fold.
  """

  require Logger

  alias Merlin.TUI.Render

  @default {80, 24}

  @doc "Enter the alternate screen. Pairs with `leave/0` on every exit path."
  @spec enter() :: :ok
  def enter do
    :ok = :io.setopts(:standard_io, binary: true, encoding: :latin1)
    write(Render.enter())
  end

  @doc """
  Restore the terminal.

  Called from the loop's exit path *and* from the wrapper's trap, because
  either one alone leaves a case uncovered: the loop cannot run after a VM
  crash, and the trap cannot know what the loop had drawn.
  """
  @spec leave() :: :ok
  def leave, do: write(Render.leave())

  @doc "Write bytes. One call per frame -- see `Merlin.TUI` for why."
  @spec write(iodata()) :: :ok
  def write(iodata), do: IO.binwrite(iodata)

  @doc """
  Start a process that forwards stdin to `parent` as `{:input, bytes}`.

  Returns the pid so the loop can stop it. Linked deliberately: if the reader
  dies the session is over, and a TUI that has stopped accepting keys while
  still painting is worse than one that exits.
  """
  @spec start_reader(pid()) :: pid()
  def start_reader(parent) do
    spawn_link(fn -> read_loop(parent) end)
  end

  defp read_loop(parent) do
    case IO.binread(:stdio, 1) do
      :eof ->
        send(parent, :input_closed)

      {:error, reason} ->
        send(parent, {:input_error, reason})

      data ->
        send(parent, {:input, data})
        read_loop(parent)
    end
  end

  @doc """
  The terminal size, as `{columns, rows}`.

  Tries `stty`, then `tput`, then the environment, then a default. Each step
  exists because an earlier one has been observed to fail on this project's own
  hardware, not on principle.
  """
  @spec size() :: {pos_integer(), pos_integer()}
  def size do
    with :error <- stty_size(),
         :error <- tput_size(),
         :error <- env_size() do
      @default
    end
  end

  defp stty_size do
    case System.cmd("stty", ["-f", "/dev/tty", "size"], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> String.split(~r/\s+/) do
          # rows first, columns second -- the opposite order to everything else
          # here, which is exactly the sort of thing that produces a transposed
          # frame nobody can explain.
          [rows, cols] -> parse_pair(cols, rows)
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp tput_size do
    with {cols, 0} <- System.cmd("tput", ["cols"], stderr_to_stdout: true),
         {rows, 0} <- System.cmd("tput", ["lines"], stderr_to_stdout: true) do
      parse_pair(String.trim(cols), String.trim(rows))
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp env_size, do: parse_pair(System.get_env("COLUMNS"), System.get_env("LINES"))

  # Zero is not a size. `stty size` answers "0 0" under a pty with no
  # controlling terminal, and taking it at face value would ask Buffer.new/2
  # for a zero-column grid.
  defp parse_pair(cols, rows) when is_binary(cols) and is_binary(rows) do
    with {c, _} <- Integer.parse(cols),
         {r, _} <- Integer.parse(rows),
         true <- c > 0 and r > 0 do
      {c, r}
    else
      _ -> :error
    end
  end

  defp parse_pair(_, _), do: :error
end
