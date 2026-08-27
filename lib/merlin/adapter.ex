defmodule Merlin.Adapter do
  @moduledoc """
  The abstraction layer: raw protocol in, semantic facts and events out.

  An adapter is the **only** place in the system where a topic string, a JSON
  field name, or a unit conversion may appear. Everything above it speaks in
  paths and values: a rule says `person.owner.zone == :home`, never
  `zigbee2mqtt/...` and never a GPS coordinate.

  ## Emissions, not writes

  `c:handle_ingress/4` returns a list of emissions rather than writing to the
  world itself. Two reasons, and the second is the important one:

    * Adapters become nearly pure functions. You test one by feeding it a
      captured payload and asserting on the returned list -- no broker, no
      ETS, no supervision tree. The Python hooks could not be tested at all
      without standing up the whole daemon.

    * The framework, not the adapter, decides how to write. An adapter cannot
      accidentally bypass the causal depth guard, cannot forget to stamp a
      source, and cannot conflate a level with an edge, because it does not
      perform the write.

  ## Scope at this milestone

  Adapters are stateless modules. The full design gives each one a supervised
  process with its own state and a `handle_intent/2` for the outbound
  direction; that arrives when the first adapter needs it (HAPN, and its OAuth
  token lifecycle, at M6). Declaring it now would be inventing a shape before
  anything has pushed back on it.
  """

  @typedoc """
  What an adapter produces from one inbound message.

    * `{:fact, path, value}`  -- a level; deduplicated, notifies on change
    * `{:event, path, payload}` -- an edge; never deduplicated, always delivered
    * `{:publish, topic, payload, opts}` -- talk back to the broker
  """
  @type emission ::
          {:fact, Merlin.Path.t(), term()}
          | {:event, Merlin.Path.t(), term()}
          | {:publish, binary(), binary(), keyword()}

  @typedoc "A topic filter this adapter wants, and the QoS to request."
  @type subscription :: {:mqtt, binary(), 0..2}

  @doc """
  The topics this adapter wants.

  The connection subscribes to the union of these across every enabled
  adapter, and to nothing else. This is what replaces the Python's blanket
  `#` subscription: interest is declared as data and the network subscription
  is derived from it, rather than every hook receiving everything and
  filtering for itself.
  """
  @callback subscriptions(opts :: keyword()) :: [subscription()]

  @doc """
  Translate one inbound message into emissions.

  `captures` holds any named wildcard segments from the matched filter, so an
  adapter handling `home/+room/sensor/contact` receives `%{"room" => "office"}`
  rather than re-parsing the topic.

  Returning `{:error, reason}` is logged and dropped. It must not raise on
  malformed input -- see `Merlin.MQTT.Connection` for why a crash here is a
  crash loop.
  """
  @callback handle_ingress(
              topic :: binary(),
              payload :: binary(),
              captures :: %{optional(binary()) => binary()},
              opts :: keyword()
            ) :: {:ok, [emission()]} | {:error, term()}
end
