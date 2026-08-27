defmodule Merlin.GeoTest do
  @moduledoc """
  Tier 1: pure unit.

  The question this tier answers and no cheaper one can: does the isolated
  logic hold at its boundaries. So the cases below are chosen as boundaries --
  zero distance, the antipode, the poles, the sign flip across the equator and
  the meridian, and the inclusive edge of `within?/3` -- rather than as a
  scatter of plausible coordinates.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tier1

  alias Merlin.Geo

  # One degree of arc on the sphere this module uses. Derived from the module's
  # own constant rather than hard-coded, so that changing the radius updates the
  # expectation instead of turning this into a test of a magic number.
  @one_degree_m Geo.earth_radius_m() * :math.pi() / 180.0

  defp close(a, b, tol), do: abs(a - b) <= tol

  describe "unit constructors" do
    test "convert to metres" do
      assert Geo.m(1) == 1.0
      assert close(Geo.ft(400), 121.92, 0.001)
      assert close(Geo.mi(0.25), 402.336, 0.001)
      assert close(Geo.km(1), 1000.0, 0.001)
    end

    test "the two thresholds this system actually uses" do
      # A 400 ft geofence and the 0.25 mile co-location distance. Named here
      # because the Python conflated them into one 0.25 mile constant serving
      # both jobs, and separating them is a decision worth pinning down.
      assert close(Geo.ft(400), 121.92, 0.01)
      assert close(Geo.mi(0.25), 402.34, 0.01)
      refute Geo.ft(400) == Geo.mi(0.25)
    end
  end

  describe "distance/2 boundaries" do
    test "identical points are exactly zero" do
      assert Geo.distance({35.9606, -83.9207}, {35.9606, -83.9207}) == 0.0
    end

    test "one degree of latitude at the equator" do
      assert close(Geo.distance({0.0, 0.0}, {1.0, 0.0}), @one_degree_m, 0.5)
    end

    test "one degree of longitude at the equator equals one of latitude" do
      # True on a sphere, and a useful check that latitude and longitude are
      # not transposed -- the single most likely defect in this function.
      assert close(Geo.distance({0.0, 0.0}, {0.0, 1.0}), @one_degree_m, 0.5)
    end

    test "one degree of longitude at 60N is half of one at the equator" do
      # cos(60) = 0.5 exactly. This is the assertion that fails if the cosine
      # terms are dropped, which a latitude-only test would not catch.
      assert close(Geo.distance({60.0, 0.0}, {60.0, 1.0}), @one_degree_m / 2, 1.0)
    end

    test "antipodal points on the equator and through the poles" do
      # Note what these two do NOT cover: at both of these the haversine `a`
      # evaluates to exactly 1.0 (cos(0)*cos(0)*sin^2(90) and sin^2(-90)
      # respectively), so neither reaches the clamp. Mutation testing caught
      # that -- defeating the clamp left both of these passing. The clamp is
      # covered by the antipodal property below instead.
      half_circumference = :math.pi() * Geo.earth_radius_m()
      assert close(Geo.distance({0.0, 0.0}, {0.0, 180.0}), half_circumference, 1.0)
      assert close(Geo.distance({90.0, 0.0}, {-90.0, 0.0}), half_circumference, 1.0)
    end

    test "antipodal pairs at intermediate latitudes" do
      # Where both haversine terms are fractional, their sum can round above
      # 1.0 -- and :math.sqrt/1 on a negative raises :badarith rather than
      # returning NaN. These are the inputs that actually exercise the clamp.
      half_circumference = :math.pi() * Geo.earth_radius_m()

      for lat <- [15.0, 30.0, 45.0, 60.0, 75.0], lon <- [-120.0, -60.0, 0.0, 37.5] do
        d = Geo.distance({lat, lon}, {-lat, lon + 180.0})
        assert close(d, half_circumference, 1.0),
               "antipodal pair at lat #{lat}, lon #{lon} gave #{d}"
      end
    end

    test "crossing the equator and the meridian" do
      assert close(Geo.distance({-0.5, 0.0}, {0.5, 0.0}), @one_degree_m, 0.5)
      assert close(Geo.distance({0.0, -0.5}, {0.0, 0.5}), @one_degree_m, 0.5)
    end

    test "the poles are one half-circumference apart regardless of longitude" do
      a = Geo.distance({90.0, 0.0}, {-90.0, 0.0})
      b = Geo.distance({90.0, 137.0}, {-90.0, -42.0})
      assert close(a, b, 1.0)
    end

    test "accepts integer coordinates" do
      assert close(Geo.distance({0, 0}, {1, 0}), @one_degree_m, 0.5)
    end
  end

  describe "within?/3 boundary" do
    # Inclusive at the edge. Asserted rather than assumed, because every zone
    # decision in the system reduces to this comparison.
    @home {35.9606, -83.9207}

    test "exactly at the radius is inside" do
      # Construct a point whose distance is known, then use that distance as
      # the radius -- so the boundary is exact rather than approximate.
      other = {35.9706, -83.9207}
      d = Geo.distance(@home, other)
      assert Geo.within?(@home, other, d)
    end

    test "a hair inside and a hair outside" do
      other = {35.9706, -83.9207}
      d = Geo.distance(@home, other)
      assert Geo.within?(@home, other, d + 0.001)
      refute Geo.within?(@home, other, d - 0.001)
    end

    test "zero radius admits only the point itself" do
      assert Geo.within?(@home, @home, 0)
      refute Geo.within?(@home, {35.9607, -83.9207}, 0)
    end
  end

  describe "properties" do
    property "distance is non-negative, commutative, and zero only on identity" do
      check all lat1 <- StreamData.float(min: -90.0, max: 90.0),
                lon1 <- StreamData.float(min: -180.0, max: 180.0),
                lat2 <- StreamData.float(min: -90.0, max: 90.0),
                lon2 <- StreamData.float(min: -180.0, max: 180.0) do
        a = {lat1, lon1}
        b = {lat2, lon2}

        d = Geo.distance(a, b)

        assert d >= 0.0
        assert close(d, Geo.distance(b, a), 1.0e-6)
        assert Geo.distance(a, a) == 0.0
      end
    end

    property "antipodal pairs never raise" do
      # This is the assertion that kills a defeated clamp. Exact antipodes are
      # mathematically a == 1.0, but at intermediate latitudes the two
      # fractional terms can round to just above it, and sqrt of a negative
      # raises. Run wide, because the overshoot depends on rounding and only
      # some pairs produce it.
      half = :math.pi() * Geo.earth_radius_m()

      check all lat <- StreamData.float(min: -89.9, max: 89.9),
                lon <- StreamData.float(min: -180.0, max: 0.0),
                max_runs: 500 do
        d = Geo.distance({lat, lon}, {-lat, lon + 180.0})
        assert close(d, half, 1.0)
      end
    end

    property "no pair of points is further apart than half the circumference" do
      half = :math.pi() * Geo.earth_radius_m()

      check all lat1 <- StreamData.float(min: -90.0, max: 90.0),
                lon1 <- StreamData.float(min: -180.0, max: 180.0),
                lat2 <- StreamData.float(min: -90.0, max: 90.0),
                lon2 <- StreamData.float(min: -180.0, max: 180.0) do
        assert Geo.distance({lat1, lon1}, {lat2, lon2}) <= half + 1.0
      end
    end
  end
end
