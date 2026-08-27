defmodule Merlin.Derive.Sun do
  @moduledoc """
  Whether the sun is up, as a fact.

  Needed for *"turn the lamps on when I arrive home, but only after dark"*.
  There is no sensor for this and no service worth depending on: the sun's
  position is a function of latitude, longitude and time, and the arithmetic
  is forty lines. Adding an HTTP dependency for something computable is the
  kind of thing that turns into a 3am outage when someone else's API changes.

  ## The algorithm

  Low-precision solar position, from the US Naval Observatory's Astronomical
  Almanac. Accurate to about one arcminute for the years 1950-2050, which is
  several orders of magnitude better than a decision that only cares whether
  the sun is above the horizon.

  `:day` when the solar elevation exceeds -0.833 degrees. That threshold is
  the standard sunrise/sunset definition: -0.833 rather than 0 accounts for
  atmospheric refraction (about 34 arcminutes) plus the sun's apparent radius
  (about 16 arcminutes), which together mean the disc appears to touch the
  horizon while its centre is still below it.

  ## Recomputation

  On a timer, because time passes whether or not any fact changes. Every five
  minutes: the sun crosses the horizon at roughly 0.25 degrees per minute at
  temperate latitudes, so five minutes is well inside any reasonable tolerance
  for "is it dark yet" and costs nothing.
  """

  use GenServer
  require Logger

  alias Merlin.World

  @interval_ms :timer.minutes(5)

  # Standard sunrise/sunset elevation: refraction plus solar semi-diameter.
  @horizon_deg -0.833

  defstruct [:id, :lat, :lon, :out_path, :interval_ms]

  @doc false
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.id))

  defp via(id), do: {:via, Registry, {Merlin.Derive.Registry, {__MODULE__, id}}}

  @impl true
  def init(spec) do
    state = %__MODULE__{
      id: spec.id,
      lat: spec.lat,
      lon: spec.lon,
      out_path: spec.out,
      interval_ms: spec[:interval_ms] || @interval_ms
    }

    recompute(state)
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    recompute(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(state), do: Process.send_after(self(), :tick, state.interval_ms)

  defp recompute(state) do
    value = if elevation(state.lat, state.lon, DateTime.utc_now()) > @horizon_deg, do: :day, else: :night
    World.put(state.out_path, value, source: {:derive, state.id})
  end

  @doc """
  Solar elevation in degrees above the horizon.

  Pure, and takes its clock as an argument, so the tests can assert known
  positions at known instants rather than waiting for the sun to move.
  """
  @spec elevation(number(), number(), DateTime.t()) :: float()
  def elevation(lat, lon, %DateTime{} = utc) do
    n = julian_day(utc) - 2_451_545.0

    # Mean solar anomaly and mean longitude, degrees.
    g = norm_deg(357.529 + 0.98_560_028 * n)
    q = norm_deg(280.459 + 0.98_564_736 * n)

    # Geocentric apparent ecliptic longitude, corrected for the equation of
    # centre.
    l = norm_deg(q + 1.915 * sin_d(g) + 0.020 * sin_d(2 * g))

    # Obliquity of the ecliptic.
    e = 23.439 - 0.00_000_036 * n

    declination = asin_d(sin_d(e) * sin_d(l))

    # Right ascension, in hours, resolved into the correct quadrant.
    ra = norm_hours(atan2_d(cos_d(e) * sin_d(l), cos_d(l)) / 15.0)

    # Local hour angle: how far the sun is from the local meridian.
    gmst = norm_hours(18.697_374_558 + 24.06_570_982_441_908 * n)
    lmst = norm_hours(gmst + lon / 15.0)

    hour_angle =
      case (lmst - ra) * 15.0 do
        h when h > 180.0 -> h - 360.0
        h when h < -180.0 -> h + 360.0
        h -> h
      end

    asin_d(
      sin_d(lat) * sin_d(declination) +
        cos_d(lat) * cos_d(declination) * cos_d(hour_angle)
    )
  end

  @doc "`:day` or `:night` for a position and instant. Pure."
  @spec state_at(number(), number(), DateTime.t()) :: :day | :night
  def state_at(lat, lon, utc) do
    if elevation(lat, lon, utc) > @horizon_deg, do: :day, else: :night
  end

  @doc "The elevation treated as the horizon, in degrees."
  def horizon_deg, do: @horizon_deg

  # --- trigonometry in degrees ---------------------------------------------

  defp julian_day(%DateTime{} = dt), do: DateTime.to_unix(dt) / 86_400.0 + 2_440_587.5

  defp norm_deg(d), do: d - 360.0 * Float.floor(d / 360.0)
  defp norm_hours(h), do: h - 24.0 * Float.floor(h / 24.0)

  defp rad(d), do: d * :math.pi() / 180.0
  defp deg(r), do: r * 180.0 / :math.pi()

  defp sin_d(d), do: :math.sin(rad(d))
  defp cos_d(d), do: :math.cos(rad(d))
  defp asin_d(x), do: deg(:math.asin(x |> max(-1.0) |> min(1.0)))
  defp atan2_d(y, x), do: deg(:math.atan2(y, x))
end
