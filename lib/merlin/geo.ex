defmodule Merlin.Geo do
  @moduledoc """
  Spherical distance, and the unit constructors the config data uses.

  This replaces `geopy` outright. The Python used `geopy.distance.geodesic`,
  which solves the inverse geodesic problem on the WGS-84 ellipsoid; this uses
  the haversine formula on a sphere of the mean Earth radius.

  That substitution is deliberate and its error is bounded: the spherical
  approximation departs from the ellipsoidal solution by at most ~0.5%, so at
  the radii this system actually uses -- a 400 ft geofence, a 0.25 mile
  co-location distance -- the disagreement is on the order of a couple of feet.
  Every GPS fix feeding it carries tens of metres of uncertainty, and the zone
  logic applies hysteresis on top. The dependency was not worth it.

  What this module does *not* do, stated so nobody assumes otherwise: bearings,
  destination-point projection, polygon containment, or anything ellipsoidal.
  """

  # IUGG mean Earth radius, metres.
  @earth_radius_m 6_371_008.8

  @typedoc "A WGS-84 point as `{latitude, longitude}` in signed decimal degrees."
  @type point :: {number(), number()}

  @doc "Metres, unchanged. Present so config data can be explicit."
  @spec m(number()) :: float()
  def m(n) when is_number(n), do: n * 1.0

  @doc "Feet to metres."
  @spec ft(number()) :: float()
  def ft(n) when is_number(n), do: n * 0.3048

  @doc "Statute miles to metres."
  @spec mi(number()) :: float()
  def mi(n) when is_number(n), do: n * 1_609.344

  @doc "Kilometres to metres."
  @spec km(number()) :: float()
  def km(n) when is_number(n), do: n * 1_000.0

  @doc """
  Great-circle distance between two points, in metres.

  Commutative, and exactly zero for identical points.
  """
  @spec distance(point(), point()) :: float()
  def distance({lat1, lon1}, {lat2, lon2})
      when is_number(lat1) and is_number(lon1) and is_number(lat2) and is_number(lon2) do
    phi1 = rad(lat1)
    phi2 = rad(lat2)
    dphi = rad(lat2 - lat1)
    dlambda = rad(lon2 - lon1)

    a =
      :math.sin(dphi / 2) * :math.sin(dphi / 2) +
        :math.cos(phi1) * :math.cos(phi2) *
          :math.sin(dlambda / 2) * :math.sin(dlambda / 2)

    # Clamp before sqrt. Floating point can push `a` a hair above 1.0 for
    # antipodal points, and :math.sqrt/1 on a negative raises rather than
    # returning NaN -- a crash on the one input most likely to be a typo.
    a = a |> max(0.0) |> min(1.0)

    2 * :math.atan2(:math.sqrt(a), :math.sqrt(1.0 - a)) * @earth_radius_m
  end

  @doc """
  Whether two points are within `radius_m` metres of each other.

  Inclusive at the boundary: a point exactly `radius_m` away is inside. The
  zone logic layers hysteresis on top of this, so the boundary case is a
  definition rather than a decision.
  """
  @spec within?(point(), point(), number()) :: boolean()
  def within?(a, b, radius_m) when is_number(radius_m) do
    distance(a, b) <= radius_m
  end

  @doc """
  Resolve a `{magnitude, unit}` pair to metres.

      iex> Merlin.Geo.to_meters({400, :ft})
      121.92

  This is what lets a zone declare its own size in the units a person thinks
  in. The Python had one global 0.25-mile threshold serving as every geofence
  radius AND the phone-to-vehicle co-location distance -- two unrelated
  quantities sharing one constant, so a house and a car park were necessarily
  the same size.
  """
  @spec to_meters({number(), atom()} | number()) :: float()
  def to_meters({n, :m}), do: m(n)
  def to_meters({n, :ft}), do: ft(n)
  def to_meters({n, :mi}), do: mi(n)
  def to_meters({n, :km}), do: km(n)
  def to_meters(n) when is_number(n), do: m(n)

  @doc """
  A speed in metres per second, from a declared unit.

  Speeds are declared the way distances are -- `{120, :kph}` -- so a config
  says how fast someone could plausibly travel in the units a person thinks
  in, and nothing downstream has to know which.
  """
  @spec to_mps({number(), :mps | :kph | :mph} | number()) :: float()
  def to_mps({n, :mps}) when is_number(n), do: n * 1.0
  def to_mps({n, :kph}) when is_number(n), do: n * 1_000.0 / 3_600.0
  def to_mps({n, :mph}) when is_number(n), do: n * 1_609.344 / 3_600.0
  def to_mps(n) when is_number(n), do: n * 1.0

  @doc """
  The soonest someone travelling at `speed` could get from `a` to `b`, in
  milliseconds.

  Straight-line, so it is a genuine lower bound: no road is shorter than the
  great circle. That is the property that makes it safe to reason with -- if
  this says four minutes and only two have passed, they certainly have not
  arrived, whatever route they took.
  """
  @spec min_travel_ms(point(), point(), {number(), atom()} | number()) :: non_neg_integer()
  def min_travel_ms(a, b, speed) do
    mps = to_mps(speed)

    if mps <= 0 do
      # An unmoving subject never arrives. Represented as "not within any time
      # this system will run for" rather than as an error.
      :infinity
    else
      round(distance(a, b) / mps * 1_000)
    end
  end

  @doc "The mean Earth radius used, in metres. Exposed so tests can derive expectations."
  @spec earth_radius_m() :: float()
  def earth_radius_m, do: @earth_radius_m

  defp rad(deg), do: deg * :math.pi() / 180.0
end
