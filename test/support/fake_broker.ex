defmodule Merlin.Test.FakeBroker do
  @moduledoc """
  An MQTT broker that exists only in a test process.

  Implements `Merlin.MQTT.Client` so `Merlin.MQTT.Connection` cannot tell the
  difference, and adds the three things a real broker gives you that a mock
  usually does not:

    * **retained messages**, replayed on subscribe -- which is the entire
      mechanism the settle window exists to survive, and which cannot be
      exercised at all against a client that only records publishes;
    * **subscription filtering**, so a message published to a topic nobody
      subscribed to is not delivered, and a test cannot accidentally prove
      something through a subscription the daemon never asked for; and
    * **connection loss**, on demand.

  Deliberately not Mox. Mox verifies that calls were made; the question here is
  what the daemon *does over time* when messages arrive in a particular order,
  and that needs a thing that behaves like a broker rather than a thing that
  records expectations.
  """

  @behaviour Merlin.MQTT.Client

  use GenServer


  defstruct [:owner, subscriptions: [], retained: %{}, published: [], delivered: 0]

  # --- the client behaviour -------------------------------------------------

  @impl Merlin.MQTT.Client
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner)
    name = Keyword.get(opts, :name, __MODULE__)
    {:ok, pid} = GenServer.start_link(__MODULE__, owner, name: name)
    {:ok, pid}
  end

  @impl Merlin.MQTT.Client
  def subscribe(pid, subscriptions), do: GenServer.call(pid, {:subscribe, subscriptions})

  @impl Merlin.MQTT.Client
  def publish(pid, topic, payload, opts), do: GenServer.call(pid, {:publish, topic, payload, opts})

  @impl Merlin.MQTT.Client
  def stop(pid), do: GenServer.stop(pid)

  # --- what a test drives it with -------------------------------------------

  @doc "Bring the connection up, which replays retained messages to subscribers."
  @spec connect(pid()) :: :ok
  def connect(pid), do: GenServer.call(pid, :connect)

  @doc "Drop the connection, the way a wifi blip does."
  @spec disconnect(pid()) :: :ok
  def disconnect(pid), do: GenServer.call(pid, :disconnect)

  @doc """
  A device publishes. Delivered only if the daemon subscribed to a matching
  filter, and retained if asked -- exactly like the real thing.
  """
  @spec device_publish(pid(), binary(), binary(), keyword()) :: :ok
  def device_publish(pid, topic, payload, opts \\ []),
    do: GenServer.call(pid, {:device_publish, topic, payload, opts})

  @doc "Everything the daemon has published, oldest first."
  @spec published(pid()) :: [{binary(), binary()}]
  def published(pid), do: GenServer.call(pid, :published)

  @doc "Forget what the daemon published. For scoping an assertion to one step."
  @spec clear_published(pid()) :: :ok
  def clear_published(pid), do: GenServer.call(pid, :clear_published)

  @doc "Seed a retained message without delivering it, as a broker that was already running would hold."
  @spec preload_retained(pid(), binary(), binary()) :: :ok
  def preload_retained(pid, topic, payload),
    do: GenServer.call(pid, {:preload_retained, topic, payload})

  # --- implementation -------------------------------------------------------

  @impl GenServer
  def init(owner), do: {:ok, %__MODULE__{owner: owner}}

  @impl GenServer
  def handle_call({:subscribe, subscriptions}, _from, state) do
    state = %{state | subscriptions: state.subscriptions ++ subscriptions}

    # Retained replay, the moment the subscription lands -- which is what makes
    # the settle window testable, and what makes a daemon without one fire its
    # latch at 3am.
    for {filter, _qos} <- subscriptions,
        {topic, payload} <- state.retained,
        matches?(filter, topic) do
      send(state.owner, {:mqtt_message, topic, payload})
    end

    {:reply, :ok, state}
  end

  def handle_call({:publish, topic, payload, opts}, _from, state) do
    state = %{state | published: state.published ++ [{topic, payload}]}

    state =
      if Keyword.get(opts, :retain, false),
        do: %{state | retained: Map.put(state.retained, topic, payload)},
        else: state

    {:reply, :ok, state}
  end

  def handle_call(:connect, _from, state) do
    send(state.owner, {:mqtt_connection, :up})
    {:reply, :ok, state}
  end

  def handle_call(:disconnect, _from, state) do
    send(state.owner, {:mqtt_connection, :down})
    # A reconnect re-subscribes from scratch, so forget what was subscribed --
    # otherwise the retained replay on the next :up would fire once per
    # historical subscription and flatter the daemon.
    {:reply, :ok, %{state | subscriptions: []}}
  end

  def handle_call({:device_publish, topic, payload, opts}, _from, state) do
    state =
      if Keyword.get(opts, :retain, false),
        do: %{state | retained: Map.put(state.retained, topic, payload)},
        else: state

    delivered? =
      Enum.any?(state.subscriptions, fn {filter, _qos} -> matches?(filter, topic) end)

    if delivered?, do: send(state.owner, {:mqtt_message, topic, payload})

    {:reply, :ok, %{state | delivered: state.delivered + if(delivered?, do: 1, else: 0)}}
  end

  def handle_call(:published, _from, state), do: {:reply, state.published, state}
  def handle_call(:clear_published, _from, state), do: {:reply, :ok, %{state | published: []}}

  def handle_call({:preload_retained, topic, payload}, _from, state),
    do: {:reply, :ok, %{state | retained: Map.put(state.retained, topic, payload)}}

  # Wildcard matching, on the WIRE filter -- the string that was actually sent
  # to the broker, so `+room` capture syntax is not something this understands
  # any more than mosquitto would. Written here rather than borrowed from
  # Merlin.MQTT.Router on purpose: a fake broker that shares the daemon's
  # matcher cannot disagree with it, and a matcher that cannot disagree is not
  # an oracle.
  defp matches?(filter, topic) do
    do_match(String.split(filter, "/"), String.split(topic, "/"))
  end

  defp do_match(["#" | _], _topic), do: true
  defp do_match([], []), do: true
  defp do_match([], _), do: false
  defp do_match(_, []), do: false
  defp do_match(["+" | f], [_ | t]), do: do_match(f, t)
  defp do_match([same | f], [same | t]), do: do_match(f, t)
  defp do_match(_, _), do: false
end
