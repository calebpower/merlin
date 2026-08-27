defmodule Merlin.Snapshot.Server do
  @moduledoc """
  Restores the fact snapshot at boot, and writes it back periodically and on
  shutdown.

  ## Where it sits in the tree

  Directly after the writer and before anything that can react. That ordering
  is what makes the restore quiet: the rules engine and the machines have not
  started yet, so nothing can observe a restored fact as a change. It is not
  merely that `Writer.restore/1` does not publish -- there is nobody to publish
  to.

  ## Why periodic *and* on shutdown

  `bin/merlin stop` runs `terminate/2` and the snapshot is current. A `kill -9`,
  a panic or a power cut does not, and loses at most one interval. Five seconds
  of latch state is an acceptable loss; the alternative -- writing on every
  fact change -- turns a door sensor into a disk write per report, and the
  facts that matter here change a handful of times a day.

  ## Failure is not fatal

  A snapshot that cannot be read is logged loudly and skipped. Refusing to boot
  because a state file is corrupt would mean a bad write during a power cut
  leaves the house with no automation at all, which is a far worse outcome than
  starting with an empty world and relearning it from retained messages.
  """

  use GenServer
  require Logger

  alias Merlin.{Config, Snapshot, World}

  # Five seconds. The bound on what a `kill -9` costs.
  @interval_ms 5_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The snapshot file's path."
  @spec path() :: binary()
  def path do
    System.get_env("MERLIN_SNAPSHOT") || Path.join(Config.state_dir(), "facts.snap")
  end

  @doc "Write the snapshot now. Returns the number of facts written."
  @spec save() :: {:ok, non_neg_integer()} | {:error, term()}
  def save, do: GenServer.call(__MODULE__, :save, 10_000)

  @impl true
  def init(opts) do
    # terminate/2 only runs for a trapped exit. Without this the graceful-stop
    # save silently never happens, which would look exactly like it working.
    Process.flag(:trap_exit, true)

    file = Keyword.get(opts, :path, path())
    interval = Keyword.get(opts, :interval_ms, @interval_ms)

    restore(file)
    if interval > 0, do: Process.send_after(self(), :save, interval)

    {:ok, %{path: file, interval_ms: interval, warned: MapSet.new()}}
  end

  @impl true
  def handle_call(:save, _from, state) do
    {result, state} = do_save(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:save, state) do
    {_result, state} = do_save(state)
    Process.send_after(self(), :save, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case do_save(state) do
      {{:ok, n}, _state} -> Logger.info("snapshot: wrote #{n} fact(s) on shutdown")
      {{:error, reason}, _state} -> Logger.error("snapshot: shutdown save failed: #{inspect(reason)}")
    end

    :ok
  end

  # --- restore --------------------------------------------------------------

  defp restore(file) do
    with {:ok, binary} <- File.read(file),
         {:ok, wall, entries} <- Snapshot.decode(binary) do
      {facts, dropped} =
        Snapshot.restore(
          entries,
          wall,
          System.os_time(:millisecond),
          System.monotonic_time(:millisecond)
        )

      count = World.Writer.restore(facts)

      age_s = div(Snapshot.elapsed_since(wall, System.os_time(:millisecond)), 1000)
      Logger.info("snapshot: restored #{count} fact(s) from a snapshot #{age_s}s old")

      for {path, reason} <- dropped do
        Logger.warning(
          "snapshot: dropped #{path} -- #{inspect(reason)}. This is what a removed " <>
            "rule or renamed fact looks like; if you did not remove it, something is wrong."
        )
      end
    else
      {:error, :enoent} ->
        Logger.info("snapshot: none at #{file} -- starting with an empty world")

      {:error, reason} ->
        Logger.error(
          "snapshot: could not restore from #{file}: #{inspect(reason)}. " <>
            "Continuing with an empty world; latches and desired settings are lost."
        )
    end
  end

  # --- save -----------------------------------------------------------------

  defp do_save(state) do
    facts = Enum.filter(World.dump(), &persisted?/1)

    {binary, skipped} =
      Snapshot.encode(
        facts,
        System.os_time(:millisecond),
        System.monotonic_time(:millisecond)
      )

    state = warn_about(skipped, state)

    case atomic_write(state.path, binary) do
      :ok -> {{:ok, length(facts) - length(skipped)}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # Once per path per daemon run, not once every five seconds. A repeating
  # warning is wallpaper; it stops being read, and takes the warnings that
  # matter down with it.
  defp warn_about(skipped, state) do
    Enum.reduce(skipped, state, fn {path, type}, state ->
      if MapSet.member?(state.warned, path) do
        state
      else
        Logger.warning(
          "snapshot: #{Merlin.Path.to_string(path)} holds a #{type}, which is not " <>
            "persistable -- it will not survive a restart. Persist the scalars it is " <>
            "derived from instead. (Reported once per run.)"
        )

        %{state | warned: MapSet.put(state.warned, path)}
      end
    end)
  end

  defp persisted?(fact) do
    Enum.any?(Config.persisted_prefixes(), &Merlin.Path.prefix?(&1, fact.path))
  end

  # Write-then-rename. A partial write under a power cut leaves the temporary
  # file damaged and the real one untouched, rather than truncating the only
  # copy of the state at the exact moment it is most needed. rename(2) within
  # a filesystem is atomic; the temp file is deliberately in the same directory
  # so it always is one.
  defp atomic_write(file, binary) do
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, binary, [:binary]),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @doc "The default interval between snapshots."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms
end
