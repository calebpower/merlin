defmodule Merlin.MQTT.Connection do
  @moduledoc """
  Owns the broker connection and routes inbound messages to adapters.

  At start it asks every configured adapter which topics it wants, subscribes
  to exactly that union, and builds a `Merlin.MQTT.Router` mapping filters back
  to adapters. Nothing subscribes to `#`.

  ## Malformed payloads must not crash this process

  Every adapter call is wrapped. This is not defensive habit, it is a specific
  failure mode: if `handle_ingress/4` raises, this process dies, tortoise
  reconnects, the broker **replays the retained message**, and it raises
  again. One retained message with an unexpected shape -- a device firmware
  update changing a JSON field -- becomes an unkillable crash loop that takes
  the supervision tree's restart intensity with it.

  So a raising adapter is logged and dropped, and the connection keeps
  serving. "Let it crash" is right for our own invariants; it is wrong for
  everything arriving off a home network.
  """

  use GenServer
  require Logger

  alias Merlin.MQTT.Router
  alias Merlin.World

  defstruct [:client, :handle, :router, :adapters, :subscriptions, :connected?]

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Publish through the live connection. Returns `{:error, :disconnected}` if there isn't one."
  @spec publish(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(topic, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:publish, topic, payload, opts})
  end

  @doc """
  Inject a payload as though it had arrived on `topic`.

  The HTTP ingress path. It routes through the same router and the same
  adapters as a broker message, so a source binding cannot tell the two apart
  -- which is what lets the phone's `http/mobile/ariia/state` be an ordinary
  declarative source rather than a special case.
  """
  @spec inject(binary(), binary(), keyword()) :: non_neg_integer()
  def inject(topic, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:inject, topic, payload, opts})
  end

  @doc "Whether the broker connection is currently up."
  @spec connected?() :: boolean()
  def connected?, do: GenServer.call(__MODULE__, :connected?)

  @doc """
  The topic filters actually subscribed to, as `[{filter, qos}]`.

  Exposed so a test can assert what was asked of the broker -- specifically
  that it is the adapters' declared union and not `#`.
  """
  @spec subscriptions() :: [{binary(), 0..2}]
  def subscriptions, do: GenServer.call(__MODULE__, :subscriptions)

  @impl true
  def init(opts) do
    client = Keyword.get(opts, :client, Merlin.MQTT.Tortoise)
    adapters = Keyword.get(opts, :adapters, Merlin.Config.adapters())

    {router, subscriptions} = build_routes(adapters)

    start_opts = [
      client_id: Keyword.get(opts, :client_id, Merlin.Config.client_id()),
      host: Keyword.get(opts, :host, Merlin.Config.broker_host()),
      port: Keyword.get(opts, :port, Merlin.Config.broker_port()),
      owner: self()
    ]

    case client.start(start_opts) do
      {:ok, handle} ->
        Logger.info(
          "mqtt connecting to #{start_opts[:host]}:#{start_opts[:port]} as " <>
            "#{start_opts[:client_id]}, #{length(subscriptions)} subscription(s)"
        )

        {:ok,
         %__MODULE__{
           client: client,
           handle: handle,
           router: router,
           adapters: adapters,
           subscriptions: subscriptions,
           connected?: false
         }}

      {:error, reason} ->
        {:stop, {:mqtt_start_failed, reason}}
    end
  end

  @impl true
  def handle_call({:publish, topic, _payload, _opts}, _from, %{connected?: false} = state) do
    Logger.warning("dropping publish to #{topic}: not connected")
    {:reply, {:error, :disconnected}, state}
  end

  def handle_call({:publish, topic, payload, opts}, _from, state) do
    {:reply, state.client.publish(state.handle, topic, payload, opts), state}
  end

  def handle_call({:inject, topic, payload, opts}, _from, state) do
    matches = Router.match(state.router, topic)

    Enum.each(matches, fn {{module, adapter_opts}, captures} ->
      dispatch(module, adapter_opts, topic, payload, captures, state)
    end)

    if matches == [] do
      # Not an error: a key may be minted for a topic no source binds yet.
      # Reporting the count lets the caller notice, which the Python could not.
      Logger.debug("injected #{topic} matched no source (#{inspect(opts[:source])})")
    end

    {:reply, length(matches), state}
  end

  def handle_call(:connected?, _from, state), do: {:reply, state.connected?, state}

  def handle_call(:subscriptions, _from, state), do: {:reply, state.subscriptions, state}

  @impl true
  def handle_info({:mqtt_message, topic, payload}, state) do
    case Router.match(state.router, topic) do
      [] ->
        # The broker sent something no filter asked for. Not fatal, but it
        # means a subscription is wider than the router knows about.
        Logger.debug("unrouted message on #{topic}")

      matches ->
        Enum.each(matches, fn {{module, opts}, captures} ->
          dispatch(module, opts, topic, payload, captures, state)
        end)
    end

    {:noreply, state}
  end

  def handle_info({:mqtt_connection, :up}, state) do
    # BEFORE subscribing, not after. The broker starts replaying retained
    # messages the instant the subscription lands, so a window opened
    # afterwards is a race -- and the messages that lose it are exactly the
    # door reports the intruder latch is watching for.
    #
    # Every :up, not just the first. A wifi blip at 3am replays the whole
    # retained set into a daemon that has been running for weeks, which is the
    # case a boot-only window would miss entirely.
    Merlin.Settle.begin("broker connected -- retained messages replay now")

    # Subscribe here, not at connect. Every :up re-establishes the set, so a
    # reconnect needs no special handling.
    case state.client.subscribe(state.handle, state.subscriptions) do
      :ok ->
        Logger.info("mqtt connected; #{length(state.subscriptions)} subscription(s) established")

      {:error, reason} ->
        Logger.warning("mqtt connected but subscribe failed: #{inspect(reason)}")
    end

    {:noreply, %{state | connected?: true}}
  end

  def handle_info({:mqtt_connection, :down}, state) do
    Logger.warning("mqtt disconnected")
    {:noreply, %{state | connected?: false}}
  end

  def handle_info({:mqtt_connection, other}, state) do
    Logger.debug("mqtt connection status: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_info({:mqtt_subscription, status, filter}, state) do
    Logger.debug("mqtt subscription #{inspect(status)}: #{filter}")
    {:noreply, state}
  end

  def handle_info({:mqtt_terminated, reason}, state) do
    Logger.warning("mqtt handler terminated: #{inspect(reason)}")
    {:noreply, %{state | connected?: false}}
  end

  def handle_info(other, state) do
    Logger.debug("unexpected message: #{inspect(other)}")
    {:noreply, state}
  end

  # --- routing --------------------------------------------------------------

  defp build_routes(adapters) do
    Enum.reduce(adapters, {Router.new(), []}, fn {module, opts}, {router, subs} ->
      module.subscriptions(opts)
      |> Enum.reduce({router, subs}, fn {:mqtt, filter, qos}, {r, s} ->
        # Route on the authored filter (captures intact); subscribe with the
        # wire-legal form. See Router.wire_filter/1.
        {Router.add!(r, filter, {module, opts}), [{Router.wire_filter(filter), qos} | s]}
      end)
    end)
    |> then(fn {router, subs} -> {router, Enum.uniq(subs) |> Enum.reverse()} end)
  end

  defp dispatch(module, opts, topic, payload, captures, state) do
    # One id for this payload, shared by every fact it writes.
    #
    # A message carrying a position becomes three separate fact writes, and
    # between them the world holds a position that never existed. Timestamps
    # cannot separate two arrivals that land close together; an id taken from
    # the arrival itself can. See `Merlin.Derive.Geofence`.
    observation = System.unique_integer([:monotonic, :positive])

    # How long a fact from this source stays an answer.
    #
    # Read here rather than returned by the adapter, because it is a write
    # policy and not a fact about the payload -- and `Merlin.Adapter` is
    # explicit that the framework, not the adapter, decides how to write.
    # Every adapter gets this for free and none of them can forget it.
    #
    # Without it a battery-powered sensor that has gone flat reports its last
    # reading for ever and every guard reading it keeps answering as though
    # the value were current. `:http_poll` has had `stale_after_ms` since M6;
    # the MQTT path simply never passed one, so the horizon was unreachable
    # for exactly the sources most likely to go quiet.
    stale_after = source_stale_after(opts)

    case module.handle_ingress(topic, payload, captures, opts) do
      {:ok, emissions} ->
        Enum.each(
          emissions,
          &apply_emission(&1, module, captures, observation, stale_after, state)
        )

      {:error, reason} ->
        Logger.warning("#{inspect(module)} rejected #{topic}: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning(
        "#{inspect(module)} raised on #{topic}: #{Exception.message(e)} " <>
          "-- payload dropped (#{byte_size(payload)} bytes)"
      )
  catch
    kind, reason ->
      Logger.warning("#{inspect(module)} threw #{kind} on #{topic}: #{inspect(reason)}")
  end

  # The captures come from the router, not from the adapter, so an adapter
  # cannot forget to pass them on and every source gets them for free.
  defp apply_emission({:fact, path, value}, module, captures, observation, stale_after, _state) do
    World.put(path, value,
      source: {:adapter, module},
      captures: captures,
      observation: observation,
      stale_after: stale_after
    )
  end

  defp apply_emission({:event, path, payload}, module, captures, _observation, _stale, _state) do
    # Events carry no horizon. An edge is delivered once and never read back,
    # so there is nothing for staleness to describe.
    World.emit(path, payload, source: {:adapter, module}, captures: captures)
  end

  # Adapters reach the broker without going through Merlin.Effects, so the
  # settle window has to be applied here as well or it has a hole exactly the
  # width of every adapter. An adapter emitting a publish in response to a
  # retained message is the same event the window exists to absorb.
  #
  # This does mean the ping/pong liveness harness goes unanswered for the first
  # few seconds, which is not a bug being tolerated -- it is the daemon saying
  # truthfully that it is not acting yet. `/healthz` and `bin/merlin rpc` both
  # answer throughout.
  defp apply_emission(
         {:publish, topic, payload, opts} = emission,
         module,
         _captures,
         _observation,
         _stale_after,
         state
       ) do
    if Merlin.Settle.settling?() and Merlin.Settle.suppresses?(emission) do
      Logger.info(
        "[settling #{Merlin.Settle.remaining_ms()}ms] held: publish #{topic} " <>
          "from #{inspect(module)}"
      )
    else
      do_publish(topic, payload, opts, state)
    end
  end

  # nil when the source declares nothing, which leaves World.put/3's existing
  # behaviour untouched: a fact with no horizon never goes stale, exactly as
  # before this option existed.
  defp source_stale_after(opts) do
    case Keyword.get(opts, :source) do
      %{} = source -> Map.get(source, :stale_after_ms)
      _ -> nil
    end
  end

  defp do_publish(topic, payload, opts, state) do
    if state.connected? do
      state.client.publish(state.handle, topic, payload, opts)
    else
      Logger.warning("dropping publish to #{topic}: not connected")
    end
  end
end
