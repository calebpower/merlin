defmodule Merlin.Ingress do
  @moduledoc """
  The single door through which external payloads enter the world model.

  MQTT messages and `/snitch` posts arrive here identically. That is not
  tidiness for its own sake: a declarative source binding works the same
  whether its "topic" came off the broker or was resolved from an API key, and
  an adapter cannot tell which. `api.py` achieved the same by calling the very
  same `h.on_message(topic, payload)` the MQTT loop used, and it is the one
  structural idea in that file worth carrying over intact.

  This is a behaviour with a swappable implementation so that tier 4 can assert
  *what was injected* rather than inferring it from a side effect three
  processes away. A contract test that cannot see the outcome it is asserting
  about is not testing the contract.
  """

  @callback inject(topic :: binary(), payload :: binary(), opts :: keyword()) ::
              non_neg_integer()

  @doc """
  Inject `payload` as though it had arrived on `topic`.

  Returns the number of sources that matched, so a caller can distinguish
  "delivered" from "nothing is bound to that topic" -- which the Python could
  not, since every hook received everything.
  """
  @spec inject(binary(), binary(), keyword()) :: non_neg_integer()
  def inject(topic, payload, opts \\ []) when is_binary(topic) and is_binary(payload) do
    impl().inject(topic, payload, opts)
  end

  defp impl, do: Application.get_env(:merlin, :ingress, Merlin.Ingress.MQTT)
end

defmodule Merlin.Ingress.MQTT do
  @moduledoc "The real ingress: routes through the broker connection's router."

  @behaviour Merlin.Ingress

  @impl true
  def inject(topic, payload, opts), do: Merlin.MQTT.Connection.inject(topic, payload, opts)
end
