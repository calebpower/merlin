defmodule Merlin.Adapters.Declarative do
  @moduledoc """
  One adapter, driven entirely by config data.

  This is what replaces most of the Python's `hooks/` directory. `echo`,
  `mobile_device`, `livingroom_button`, `livingroom_lamps`' state tracking,
  `home_doors`, `klipper_monitor` and `office_aircond`'s state tracking were
  seven modules that between them did one thing: match a topic, decode a
  payload, and write a fact or emit an event. That is a table, not seven
  classes.

  What stays a real module is anything with an algorithm in it -- the
  geofence, the proximity heuristic, the OAuth token lifecycle. Those are M4
  and M6, and drawing that line is the point of the whole layering.

  ## A source

      %{
        id: :doors,
        topic: "home/+room/sensor/contact",
        decode: :json,
        facts: [
          %{path: [:door, {:capture, "room"}, :contact],
            from: [["contact"], ["state"]],
            codec: {:truthy, :closed, :open}}
        ]
      }

  `{:capture, "room"}` interpolates a named wildcard from the topic, so one
  source covers every door in the house -- which is what `home_doors.py`
  hand-rolled a topic matcher to achieve.

  One adapter instance holds exactly one source, so the router resolves a
  message straight to it and this module never re-matches a topic it was
  already handed.
  """

  @behaviour Merlin.Adapter

  require Logger

  alias Merlin.Codec

  @impl Merlin.Adapter
  def subscriptions(opts) do
    source = Keyword.fetch!(opts, :source)
    [{:mqtt, source.topic, Map.get(source, :qos, 0)}]
  end

  @impl Merlin.Adapter
  def handle_ingress(_topic, payload, captures, opts) do
    source = Keyword.fetch!(opts, :source)

    facts = Map.get(source, :facts, [])
    events = Map.get(source, :events, [])

    emissions =
      Enum.flat_map(facts, &emission(:fact, &1, payload, captures, source)) ++
        Enum.flat_map(events, &emission(:event, &1, payload, captures, source))

    {:ok, emissions}
  end

  defp emission(kind, spec, payload, captures, source) do
    case value_for(spec, payload, source) do
      {:ok, value} ->
        [{kind, resolve_path(spec.path, captures), value}]

      :error ->
        # Dropped, logged, and never raised. A device changing its payload
        # shape in a firmware update must not become a crash loop against a
        # retained message -- see Merlin.MQTT.Connection.
        Logger.debug(fn ->
          "source #{inspect(source.id)}: undecodable payload #{inspect(truncate(payload))}"
        end)

        []
    end
  end

  # Two shapes: pull a field out of a decoded body (`:from`), or decode the
  # whole payload (`:codec` alone).
  defp value_for(spec, payload, source) do
    decode_spec = Map.get(source, :decode, :raw)

    case Map.get(spec, :from) do
      nil ->
        Codec.decode(payload, Map.get(spec, :codec, decode_spec))

      paths ->
        with {:ok, decoded} <- Codec.decode(payload, decode_spec) do
          Codec.dig(decoded, paths, Map.get(spec, :codec))
        end
    end
  end

  defp resolve_path(path, captures) do
    Enum.map(path, fn
      {:capture, name} -> Map.get(captures, name, "unknown")
      segment -> segment
    end)
  end

  defp truncate(payload) when byte_size(payload) > 60,
    do: binary_part(payload, 0, 60) <> "..."

  defp truncate(payload), do: payload
end
