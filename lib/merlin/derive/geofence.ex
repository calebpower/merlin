defmodule Merlin.Derive.Geofence do
  @moduledoc """
  Turns a position into a zone.

  This is the module half of "modules are abstraction layers, rules are data".
  A rule never sees a coordinate; it says `person.caleb.zone == :home`. The
  geometry, the hysteresis and the staleness handling live here, and the zone
  definitions live in config -- which is exactly the split you asked for:
  *"modules prevent me from needing to say 'the state of the car is away when
  the GPS is <foo>', but in the data I want to say 'home is n feet around
  lat, long'"*.

  ## What it fixes

  `user_location.py` did this inline, and got three things wrong that mattered:

    * **the tri-state.** Line 124 produced `""` when the phone was outside
      every region, while `alerts.py` and `livingroom_lamps.py` both tested
      `is False`. `"" is False` is `False`, so the entire away path was dead
      code. Here the answer is `:unknown`, which is neither `:home` nor
      "not home" and cannot be mistaken for either.
    * **staleness.** Both GPS sources recorded a `checkin` timestamp that
      nothing ever read, so a phone that last reported three days ago counted
      as current. Here a stale position derives `:unknown`.
    * **flapping.** One hard threshold and no hysteresis. See `Merlin.Zones`.

  ## Recomputation

  Subscribes to its own position facts only. `user_location.py` recomputed on
  *every* state change from *every* hook -- door contacts, button presses,
  printer requests -- and then wrote its own outputs, so it re-entered itself
  and terminated only because the dedup happened to converge.
  """

  use GenServer
  require Logger

  alias Merlin.{Fact, World, Zones}

  defstruct [
    :id,
    :lat_path,
    :lon_path,
    :out_path,
    :out_position_path,
    :stale_after_ms,
    :accuracy_path,
    :max_accuracy_m
  ]

  @doc false
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.id))

  defp via(id), do: {:via, Registry, {Merlin.Derive.Registry, {__MODULE__, id}}}

  @impl true
  def init(spec) do
    state = %__MODULE__{
      id: spec.id,
      lat_path: spec.lat,
      lon_path: spec.lon,
      out_path: spec.out,
      out_position_path: spec[:out_position],
      stale_after_ms: spec[:stale_after_ms],
      accuracy_path: spec[:accuracy],
      max_accuracy_m: spec[:max_accuracy_m]
    }

    Merlin.Bus.subscribe(state.lat_path)
    Merlin.Bus.subscribe(state.lon_path)

    # Compute once at start so a restart does not leave the zone stale until
    # the next fix arrives.
    recompute(state)

    {:ok, state}
  end

  @impl true
  def handle_info({:merlin, %Merlin.Change{}}, state) do
    recompute(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Compute the zone for a position, without any process involved.

  Exposed because the truth table is worth testing as a pure function rather
  than by driving a GenServer and waiting.
  """
  @spec compute(Merlin.Geo.point() | :unknown, atom() | :unknown, %{atom() => Zones.zone()}) ::
          atom() | :unknown
  def compute(point, previous, zones), do: Zones.resolve(point, previous, zones)

  defp recompute(state) do
    previous = World.get(state.out_path, :unknown)
    point = read_point(state)

    zone = Zones.resolve(point, previous, Zones.all())

    if zone != previous do
      Logger.info("#{state.id}: #{inspect(previous)} -> #{inspect(zone)}")
    end

    World.put(state.out_path, zone, source: {:derive, state.id})

    # The position as a single point, so expressions can use distance/2 and
    # within?/3 without knowing it arrived as two separate facts. This is what
    # lets "is the car with my phone" be a line of config rather than a module.
    if state.out_position_path do
      World.put(state.out_position_path, point, source: {:derive, state.id})
    end
  end

  # A position is only usable if both components are present, fresh, and -- if
  # an accuracy fact is configured -- accurate enough. Any of those failing
  # yields :unknown rather than a confident wrong zone.
  defp read_point(state) do
    with {:ok, lat} <- fresh_value(state.lat_path, state.stale_after_ms),
         {:ok, lon} <- fresh_value(state.lon_path, state.stale_after_ms),
         :ok <- accurate_enough(state) do
      {lat, lon}
    else
      _ -> :unknown
    end
  end

  defp fresh_value(path, stale_after_ms) do
    case World.fetch(path) do
      {:ok, %Fact{value: value} = fact} when is_number(value) ->
        cond do
          Fact.stale?(fact) -> :stale
          is_integer(stale_after_ms) and Fact.age(fact) > stale_after_ms -> :stale
          true -> {:ok, value}
        end

      _ ->
        :absent
    end
  end

  defp accurate_enough(%{accuracy_path: nil}), do: :ok
  defp accurate_enough(%{max_accuracy_m: nil}), do: :ok

  defp accurate_enough(state) do
    # A 2km-accurate fix is not evidence of being anywhere in particular. The
    # Python captured gpsAccuracy and never looked at it.
    case World.get(state.accuracy_path) do
      n when is_number(n) and n <= state.max_accuracy_m -> :ok
      nil -> :ok
      _ -> :too_vague
    end
  end
end
