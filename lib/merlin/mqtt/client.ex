defmodule Merlin.MQTT.Client do
  @moduledoc """
  The seam between merlin and whichever MQTT library it happens to use.

  Three callbacks. That narrowness is the point: `tortoise311` is a community
  fork of an abandoned project with a small bus factor, and the mitigation for
  that risk is not the package -- it is that replacing it is a one-file change
  plus a stub update, rather than a search through a dozen call sites.

  It is also what makes tier 5 possible: a `Mox` stub of this behaviour lets
  the daemon be driven with deliberate transport failures -- a broker that
  accepts a connection and then drops it mid-publish -- without a network.
  """

  @typedoc "Whatever the implementation needs to identify a connection."
  @type handle :: term()

  @doc """
  Open a connection.

  Options carry `:client_id`, `:host`, `:port` and `:owner` (the process that
  receives inbound messages).

  Subscriptions are NOT given here. tortoise311 sends a connect-time
  subscription set with `identifier: nil`, and MQTT 3.1.1 requires a non-zero
  packet identifier on SUBSCRIBE -- mosquitto rejects the packet and drops the
  TCP connection, producing a connect/subscribe/close loop that reads like a
  network fault. Subscribing after the connection is up assigns an identifier
  properly. See `c:subscribe/2`.
  """
  @callback start(opts :: keyword()) :: {:ok, handle()} | {:error, term()}

  @doc """
  Subscribe once the connection is up.

  Called on every `:up` transition, so a reconnect re-establishes the set
  without the caller tracking connection state itself.
  """
  @callback subscribe(handle(), [{binary(), 0..2}]) :: :ok | {:error, term()}

  @doc "Publish. `opts` carries `:qos` and `:retain`."
  @callback publish(handle(), topic :: binary(), payload :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Close the connection."
  @callback stop(handle()) :: :ok
end
