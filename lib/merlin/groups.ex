defmodule Merlin.Groups do
  @moduledoc """
  Named sets of devices that are commanded together.

      %{
        id: :living_room_lamps,
        members: [[:lamp, :living_room, 1, :power], [:lamp, :living_room, 2, :power]],
        set_topic: "zigbee2mqtt/living_room_lamps/set",
        encode: {:json_state, %{on: "ON", off: "OFF"}}
      }

  A group is the thing `livingroom_lamps.py` had implicitly: two per-lamp
  state topics it tracked, and one zigbee2mqtt *group* topic it published to.
  Making it explicit means the toggle rule generalises to N lamps for free,
  and -- more importantly -- means the rule never names a topic or a payload
  shape. It says `set_group(:living_room_lamps, :off)`; this module knows that
  becomes `{"state":"OFF"}` on a particular topic.
  """

  require Logger

  @doc "Group definitions, keyed by id."
  @spec all() :: %{atom() => map()}
  def all, do: Merlin.Config.groups()

  @doc "Member fact paths of `id`, or `[]` if there is no such group."
  @spec members(atom()) :: [Merlin.Path.t()]
  def members(id) do
    case Map.fetch(all(), id) do
      {:ok, group} -> Map.get(group, :members, [])
      :error -> []
    end
  end

  @doc """
  Command a group to `value`.

  Encoding lives here, so a rule never writes JSON.
  """
  @spec set(atom(), term()) :: :ok | {:error, term()}
  def set(id, value) do
    case Map.fetch(all(), id) do
      {:ok, group} ->
        payload = encode(Map.get(group, :encode, :raw), value)
        Merlin.MQTT.Connection.publish(group.set_topic, payload, qos: 0)

      :error ->
        {:error, {:unknown_group, id}}
    end
  end

  @doc """
  A `group` resolver for the expression environment.

  `all_eq?(:living_room_lamps, :on)` needs member paths; this is how it gets
  them without the evaluator knowing what a group is.
  """
  @spec resolver() :: (atom() -> [Merlin.Path.t()])
  def resolver, do: &members/1

  # zigbee2mqtt's convention: {"state": "ON"}. Named rather than inlined so the
  # next device family that wants a different shape adds a clause here instead
  # of leaking its wire format into rule data.
  defp encode({:json_state, mapping}, value) do
    Jason.encode!(%{"state" => Map.get(mapping, value, to_string(value))})
  end

  defp encode(:raw, value) when is_binary(value), do: value
  defp encode(:raw, value) when is_atom(value), do: Atom.to_string(value)
  defp encode(:raw, value), do: to_string(value)
  defp encode({:json, shape}, value), do: Jason.encode!(interpolate(shape, value))

  defp interpolate(shape, value) when is_map(shape) do
    Map.new(shape, fn
      {k, :__value__} -> {k, value}
      {k, v} -> {k, v}
    end)
  end
end
