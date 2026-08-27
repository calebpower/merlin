defmodule Merlin.Adapters.Echo do
  @moduledoc """
  The liveness harness, carried over from the Python `echo` hook.

  Two behaviours, both preserved exactly:

    * a message on `ping_topic` produces the literal payload `"pong"` on
      `pong_topic`, whatever the inbound payload was; and
    * a message on `update_topic` becomes the fact `system.last_message`.

  It is the one hook worth porting verbatim, because it makes an end-to-end
  broker round-trip assertable: `mosquitto_pub -t test/ping` returning a
  `test/pong` proves the connection, the subscription, the router, the
  emission path and the publish path all work, in one command, with no
  application logic in the way.

  ## A layering note, stated rather than hidden

  Answering a ping is arguably policy, and policy belongs in a rule. It lives
  in an adapter here because the rules engine does not exist yet, and the
  alternative was to have no end-to-end proof at this milestone. This is a
  diagnostic responder, not a home-automation decision, which is what makes it
  tolerable; it converts to a declared rule when the engine lands at M2.

  The Python also logged every message it saw at INFO before filtering. With a
  `#` subscription that made it a firehose that logged, among other things,
  the `/snitch` API key. Not carried over.
  """

  @behaviour Merlin.Adapter

  @default_ping "test/ping"
  @default_pong "test/pong"
  @default_update "state/update"

  @impl Merlin.Adapter
  def subscriptions(opts) do
    [
      {:mqtt, ping_topic(opts), 0},
      {:mqtt, update_topic(opts), 0}
    ]
  end

  @impl Merlin.Adapter
  def handle_ingress(topic, payload, _captures, opts) do
    cond do
      topic == ping_topic(opts) ->
        {:ok,
         [
           {:event, [:diag, :ping], payload},
           {:publish, pong_topic(opts), "pong", qos: 0}
         ]}

      topic == update_topic(opts) ->
        {:ok, [{:fact, [:system, :last_message], payload}]}

      true ->
        # Reachable only if the router hands us something we did not ask for,
        # which would be a router bug. Return empty rather than raising: an
        # adapter that crashes on unexpected input is a crash loop waiting for
        # a retained message.
        {:ok, []}
    end
  end

  defp ping_topic(opts), do: Keyword.get(opts, :ping_topic, @default_ping)
  defp pong_topic(opts), do: Keyword.get(opts, :pong_topic, @default_pong)
  defp update_topic(opts), do: Keyword.get(opts, :update_topic, @default_update)
end
