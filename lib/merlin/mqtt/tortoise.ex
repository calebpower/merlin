defmodule Merlin.MQTT.Handler do
  @moduledoc """
  The `Tortoise311.Handler` implementation, which does nothing but forward.

  Tortoise delivers inbound publishes by invoking this behaviour inside its
  own connection process. Doing any work here would mean doing it on
  tortoise's stack, where a crash is a connection crash. So this forwards to
  the owning `Merlin.MQTT.Connection` and returns immediately -- the routing,
  the adapter call and the emission handling all happen in merlin's own
  process, where a failure is merlin's to handle.
  """

  @behaviour Tortoise311.Handler

  require Logger

  @impl true
  def init(opts) do
    {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
  end

  @impl true
  def connection(status, state) do
    send(state.owner, {:mqtt_connection, status})
    {:ok, state}
  end

  @impl true
  def subscription(status, topic_filter, state) do
    send(state.owner, {:mqtt_subscription, status, topic_filter})
    {:ok, state}
  end

  # Tortoise hands the topic in as a list of levels, which is convenient for
  # pattern matching but not what the router takes, so it is rejoined here.
  @impl true
  def handle_message(topic_levels, payload, state) do
    send(state.owner, {:mqtt_message, Enum.join(topic_levels, "/"), payload})
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    send(state.owner, {:mqtt_terminated, reason})
    :ok
  end
end

defmodule Merlin.MQTT.Tortoise do
  @moduledoc """
  `Merlin.MQTT.Client` over `tortoise311`.

  Everything library-specific in merlin's MQTT handling lives in this file and
  `Merlin.MQTT.Handler`. If tortoise is ever replaced, this is the blast
  radius.
  """

  @behaviour Merlin.MQTT.Client

  require Logger

  @impl true
  def start(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    owner = Keyword.fetch!(opts, :owner)
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 1883)
    subscriptions = Keyword.get(opts, :subscriptions, [])

    connection_opts = [
      client_id: client_id,
      server: {Tortoise311.Transport.Tcp, host: host, port: port},
      handler: {Merlin.MQTT.Handler, [owner: owner]},
      subscriptions: subscriptions,
      # Retained state on the broker is how device facts survive a restart, so
      # a durable session is wanted rather than a clean one.
      clean_session: false
    ]

    case Tortoise311.Connection.start_link(connection_opts) do
      {:ok, _pid} -> {:ok, client_id}
      {:error, {:already_started, _pid}} -> {:ok, client_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def publish(client_id, topic, payload, opts) do
    Tortoise311.publish(client_id, topic, payload, opts)
  end

  @impl true
  def stop(client_id) do
    Tortoise311.Connection.disconnect(client_id)
  catch
    # Disconnecting something already gone is not an error worth propagating
    # during shutdown.
    :exit, _ -> :ok
  end
end
