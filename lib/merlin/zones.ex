defmodule Merlin.Zones do
  @moduledoc """
  Named places, with their own sizes.

      %{id: :home, center: {35.9606, -83.9207}, radius: {400, :ft}}

  ## Hysteresis, and why it is not optional

  A zone has two radii: you **enter** at `radius` and **leave** at
  `radius * hysteresis`. Without that gap, a phone sitting near the boundary
  with tens of metres of GPS uncertainty oscillates between "home" and "away"
  as the fix wanders.

  In the Python that oscillation was harmless only because the away path was
  dead code -- `user_location.py:124` produced `""` where `False` was meant,
  and every consumer tested `is False`. Fixing that bug turns the path on, and
  turning it on without hysteresis would mean the living-room lamps switching
  off and on repeatedly while you stand in the drive. The two changes belong
  in the same milestone precisely because one makes the other dangerous.

  ## Resolution

  `resolve/3` returns the **nearest** containing zone, so overlapping zones are
  permitted and the tightest one wins -- matching
  `_filter_containing_regions`, which sorted candidates by distance and took
  the head.
  """

  alias Merlin.Geo

  @default_hysteresis 1.25

  @type zone :: %{id: atom(), center: Geo.point(), radius_m: float(), exit_radius_m: float()}

  @doc "Zone definitions from config, keyed by id, with radii resolved to metres."
  @spec all() :: %{atom() => zone()}
  def all do
    Merlin.Config.loaded()
    |> Map.get(:zones, %{})
  end

  @doc "Compile raw zone data into resolved form. Called by the config validator."
  @spec compile([map()], number()) :: %{atom() => zone()}
  def compile(zones, default_hysteresis \\ @default_hysteresis) do
    Map.new(zones, fn z ->
      radius = Geo.to_meters(z.radius)
      hysteresis = Map.get(z, :hysteresis, default_hysteresis)

      {z.id,
       %{
         id: z.id,
         center: z.center,
         radius_m: radius,
         exit_radius_m: radius * hysteresis
       }}
    end)
  end

  @doc """
  The zone containing `point`, given what zone the subject was in previously.

  `previous` widens only its own zone's radius, so leaving requires travelling
  further than arriving did. Returns a zone id or `:unknown`.

  `:unknown` rather than `nil`, deliberately: it is the same value a stale or
  absent position produces, and it propagates through the expression language
  as "we do not know" rather than as "not home". That distinction is the whole
  point of the tri-state.
  """
  @spec resolve(Geo.point() | :unknown, atom() | :unknown, %{atom() => zone()}) ::
          atom() | :unknown
  def resolve(:unknown, _previous, _zones), do: :unknown

  def resolve({lat, lon}, previous, zones)
      when is_number(lat) and is_number(lon) do
    zones
    |> Map.values()
    |> Enum.map(fn zone ->
      radius = if zone.id == previous, do: zone.exit_radius_m, else: zone.radius_m
      {zone.id, Geo.distance({lat, lon}, zone.center), radius}
    end)
    |> Enum.filter(fn {_id, distance, radius} -> distance <= radius end)
    |> case do
      [] ->
        :unknown

      containing ->
        # Nearest wins; ties break toward the TIGHTER zone. Distance alone is
        # ambiguous for concentric zones -- at the shared centre both are zero
        # away and the answer would depend on map ordering. The smaller zone
        # is the more specific claim ("in the garage" over "at home"), so it
        # is the more useful answer.
        containing
        |> Enum.min_by(fn {_id, distance, radius} -> {distance, radius} end)
        |> elem(0)
    end
  end

  def resolve(_bad_point, _previous, _zones), do: :unknown

  @doc "The default hysteresis multiplier."
  def default_hysteresis, do: @default_hysteresis
end
