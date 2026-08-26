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

  @doc "The mean Earth radius used, in metres. Exposed so tests can derive expectations."
  @spec earth_radius_m() :: float()
  def earth_radius_m, do: @earth_radius_m

  defp rad(deg), do: deg * :math.pi() / 180.0
end
