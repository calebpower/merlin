defmodule Merlin.Derive.SunTest do
  @moduledoc """
  Tier 1: solar position.

  `elevation/3` takes its clock as an argument, so these are deterministic
  assertions about known instants rather than a test that waits for the sun to
  move. The boundaries that matter are the ones where a naive implementation
  is wrong: the poles in midsummer and midwinter, the equator at the
  equinoxes, and the hemispheres being opposite.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.Derive.Sun

  defp utc(y, m, d, h, min \\ 0) do
    {:ok, dt} = DateTime.new(Date.new!(y, m, d), Time.new!(h, min, 0), "Etc/UTC")
    dt
  end

  # Knoxville, roughly.
  @home_lat 35.9606
  @home_lon -83.9207

  describe "elevation" do
    test "the sun is up at local noon and down at local midnight" do
      # -83.92 is about UTC-5.6 in solar terms, so local noon is ~17:35 UTC.
      assert Sun.elevation(@home_lat, @home_lon, utc(2026, 6, 21, 17, 30)) > 0
      assert Sun.elevation(@home_lat, @home_lon, utc(2026, 6, 21, 5, 30)) < 0
    end

    test "higher at the summer solstice than the winter solstice, at local noon" do
      summer = Sun.elevation(@home_lat, @home_lon, utc(2026, 6, 21, 17, 30))
      winter = Sun.elevation(@home_lat, @home_lon, utc(2026, 12, 21, 17, 30))

      assert summer > winter
      # ~47 degrees apart: twice the 23.44-degree axial tilt.
      assert_in_delta summer - winter, 46.9, 3.0
    end

    test "midnight sun above the arctic circle at the summer solstice" do
      # The sun never sets at the pole in June. A sign error in the declination
      # shows up here immediately and almost nowhere else.
      for hour <- [0, 6, 12, 18] do
        assert Sun.elevation(89.0, 0.0, utc(2026, 6, 21, hour)) > 0,
               "the sun set at the north pole in June, at #{hour}:00 UTC"
      end
    end

    test "polar night above the arctic circle at the winter solstice" do
      for hour <- [0, 6, 12, 18] do
        assert Sun.elevation(89.0, 0.0, utc(2026, 12, 21, hour)) < 0,
               "the sun rose at the north pole in December, at #{hour}:00 UTC"
      end
    end

    test "the hemispheres are opposite" do
      # South pole in June is the mirror of north pole in June.
      assert Sun.elevation(-89.0, 0.0, utc(2026, 6, 21, 12)) < 0
      assert Sun.elevation(-89.0, 0.0, utc(2026, 12, 21, 12)) > 0
    end

    test "near the zenith at the equator at the equinox, local noon" do
      # Longitude 0, so local noon is 12:00 UTC.
      elevation = Sun.elevation(0.0, 0.0, utc(2026, 3, 20, 12))
      assert elevation > 85.0, "expected near-overhead sun, got #{elevation}"
    end

    test "elevation stays within the physically possible range" do
      for lat <- [-89.0, -45.0, 0.0, 45.0, 89.0],
          lon <- [-180.0, -90.0, 0.0, 90.0, 179.0],
          month <- [1, 4, 7, 10],
          hour <- [0, 6, 12, 18] do
        e = Sun.elevation(lat, lon, utc(2026, month, 15, hour))
        assert e >= -90.5 and e <= 90.5, "elevation #{e} out of range at #{lat},#{lon}"
      end
    end
  end

  describe "state_at" do
    test "day and night at the expected times" do
      assert Sun.state_at(@home_lat, @home_lon, utc(2026, 6, 21, 17, 30)) == :day
      assert Sun.state_at(@home_lat, @home_lon, utc(2026, 6, 21, 5, 30)) == :night
    end

    test "the horizon threshold accounts for refraction and solar radius" do
      # -0.833 rather than 0: the disc appears to touch the horizon while its
      # centre is still below it. A naive `elevation > 0` would call the last
      # few minutes of visible daylight "night".
      assert Sun.horizon_deg() < 0.0
      assert_in_delta Sun.horizon_deg(), -0.833, 0.001
    end

    test "only ever returns :day or :night" do
      for month <- 1..12, hour <- [0, 6, 12, 18] do
        assert Sun.state_at(@home_lat, @home_lon, utc(2026, month, 15, hour)) in [:day, :night]
      end
    end
  end
end
