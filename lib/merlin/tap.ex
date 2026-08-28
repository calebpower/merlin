defmodule Merlin.Tap do
  @moduledoc """
  One attached session's view of the house, as it happens.

  A client -- the TUI, running in its own BEAM on the same host -- calls
  `attach/2` over distribution. That starts one of these *inside the daemon*,
  where the bus actually is, and it forwards changes, events and effect
  outcomes back to the client.

  ## Why a process per session rather than one shared feed

  Lifetime. `Merlin.Bus` is a `Registry`, which unsubscribes on process death,
  and `Merlin.Effects.Tap` is a `:persistent_term` list, which does not. A
  shared feed would have to track which of its subscribers had gone away and
  when to stop forwarding -- deadman logic, hand-rolled, in the daemon that
  runs a house.

  Instead this process monitors the client and exits when it goes. One
  `Process.monitor/1` replaces all of it, and the exit unsubscribes everything
  by construction. That matters more than it sounds: a session that dies
  ungracefully over a dropped SSH connection is the normal case, not the
  exception, and a leaked subscriber at `Bus.subscribe([])` would be receiving
  every fact change in the house for ever.

  ## Backpressure is here, not in the client

  A broker reconnect replays every retained message in about a second --
  hundreds of changes. Forwarding each as its own distributed message would
  turn a wifi blip into a flood across the link and a client that renders
  hundreds of frames nobody sees.

  So items accumulate and flush on a timer at roughly 20 Hz, and the pending
  buffer is bounded. Past the bound the OLDEST are dropped, because in a live
  view the newest state is the one worth having -- and the count of what was
  dropped is sent with the batch. A stream that silently drops is worse than
  one that says "42 dropped": the first invents a quiet house, the second
  tells you to go and read the log.

  ## What it does not do

  It holds no history. A session attaching at 09:00 sees what happens from
  09:00, not what happened at 08:00. Retaining the past would mean an always-on
  ring in the daemon whose memory is spent whether or not anyone ever looks --
  a decision about the house's daemon, not about its UI.
  """

  use GenServer

  require Logger

  alias Merlin.{Bus, Change, Event}
  alias Merlin.Effects.Report

  # ~20 Hz. Fast enough that a door feels instant, slow enough that a retained
  # burst is one batch rather than three hundred messages.
  @flush_ms 50

  # Chosen against the thing that actually produces a burst: a retained replay
  # of every device in the house. Comfortably above that, and small enough that
  # a wedged client cannot grow the daemon.
  @max_pending 500

  defstruct [
    :client,
    :monitor,
    :max_pending,
    :flush_ms,
    pending: [],
    dropped: 0,
    timer: nil,
    sent: 0
  ]

  @typedoc "What a client receives, oldest first, inside `{:merlin_tap, items}`."
  @type item ::
          {:change, Change.t()}
          | {:event, Event.t()}
          | {:effect, Report.t()}
          | {:dropped, pos_integer()}

  # --- the client-facing API, called over distribution ----------------------

  @doc """
  Attach `client` to this daemon's feed.

  Returns the daemon's version alongside the tap's pid. The client is expected
  to refuse to run on a mismatch: the release on disk can be newer than the
  daemon still running from the previous one, and struct fields that do not
  line up produce a wrong render rather than an error.
  """
  @spec attach(pid(), keyword()) ::
          {:ok, %{pid: pid(), version: binary()}} | {:error, term()}
  def attach(client, opts \\ []) when is_pid(client) do
    case DynamicSupervisor.start_child(
           Merlin.Tap.Supervisor,
           {__MODULE__, Keyword.put(opts, :client, client)}
         ) do
      {:ok, pid} -> {:ok, %{pid: pid, version: version()}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop forwarding and shut this tap down."
  @spec detach(pid()) :: :ok
  def detach(tap), do: GenServer.stop(tap, :normal)

  @doc "Counters for this tap. For tests and for the client's own status line."
  @spec stats(pid()) :: %{
          pending: non_neg_integer(),
          dropped: non_neg_integer(),
          sent: non_neg_integer()
        }
  def stats(tap), do: GenServer.call(tap, :stats)

  @doc "The daemon's version, for the handshake."
  @spec version() :: binary()
  def version do
    case Application.spec(:merlin, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  @doc "How many items may be pending before the oldest are dropped."
  @spec max_pending() :: pos_integer()
  def max_pending, do: @max_pending

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :client)},
      start: {__MODULE__, :start_link, [opts]},
      # Temporary, not transient. A tap exists only for the client that asked
      # for it; restarting one whose client has gone would recreate a
      # subscriber with nobody to send to.
      restart: :temporary
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    client = Keyword.fetch!(opts, :client)

    # Before subscribing to anything. If the client is already gone -- an SSH
    # session that died between the erpc and here -- the monitor fires
    # immediately and this exits without ever having joined the firehose.
    monitor = Process.monitor(client)

    Bus.subscribe([])
    Bus.subscribe_events([])
    Merlin.Effects.Tap.subscribe()

    Logger.info("tap attached for #{inspect(client)} on #{inspect(node(client))}")

    {:ok,
     %__MODULE__{
       client: client,
       monitor: monitor,
       pending: [],
       max_pending: Keyword.get(opts, :max_pending, @max_pending),
       flush_ms: Keyword.get(opts, :flush_ms, @flush_ms)
     }}
  end

  @impl true
  def handle_info({:merlin, %Change{} = change}, state), do: enqueue({:change, change}, state)

  def handle_info({:merlin, %Event{} = event}, state), do: enqueue({:event, event}, state)

  def handle_info({:merlin_effect, %Report{} = report}, state),
    do: enqueue({:effect, report}, state)

  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  # The client is gone. Covers a clean exit, a crash, and :noconnection when
  # the node itself goes -- which is the one that matters, because an SSH
  # session dying does not tell this process anything by any other route.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state) do
    Logger.info("tap detaching: client went away (#{inspect(reason)})")
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{pending: length(state.pending), dropped: state.dropped, sent: state.sent}
    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Bus unsubscribes itself when this process dies -- Registry monitors its
    # entries. Merlin.Effects.Tap holds pids in a :persistent_term and does
    # not, so it is told explicitly. It also prunes dead subscribers lazily,
    # which is the belt to this braces rather than a substitute for it.
    Merlin.Effects.Tap.unsubscribe()
    :ok
  end

  # --- batching -------------------------------------------------------------

  defp enqueue(item, state) do
    state =
      if length(state.pending) >= state.max_pending do
        # Drop the OLDEST. In a live view the newest state is the one worth
        # having; a viewer who has fallen behind wants to know where the house
        # is now, not where it was five hundred changes ago.
        %{state | pending: tl(state.pending) ++ [item], dropped: state.dropped + 1}
      else
        %{state | pending: state.pending ++ [item]}
      end

    {:noreply, arm(state)}
  end

  # One timer per batch, armed by the first item and cleared by the flush.
  # Re-arming per item would move the flush further away the busier it got,
  # which is exactly backwards.
  defp arm(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}

  defp arm(state), do: state

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    # The drop count rides with the batch it applies to, so a client can say
    # "42 dropped" against the moment it happened rather than as a running
    # total it has to diff.
    items =
      case state.dropped do
        0 -> state.pending
        n -> [{:dropped, n} | state.pending]
      end

    send(state.client, {:merlin_tap, items})

    %{state | pending: [], dropped: 0, sent: state.sent + length(items)}
  end
end
