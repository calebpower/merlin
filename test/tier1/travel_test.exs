defmodule Merlin.TravelTest do
  @moduledoc """
  Tier 1: how long a fix stays an answer.

  A flat `stale_after` is a guess. Thirty minutes is neither generous enough to
  be useful nor short enough to be safe, and it knows nothing about geography:
  it treats "last seen next door" and "last seen fifty miles away" identically.

  The question a rule actually asks is *could he be somewhere else by now*, and
  that is answerable — distance to the nearest other zone, divided by the
  fastest he could plausibly travel.

  This is not hypothetical. A phone went flat at a workshop at 23:23, its owner
  drove home, and at 00:27 the intruder latch fired on him opening his own
  front door, because the zone still read `workshop` an hour after anyone could
  possibly have known that.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.Geo

  describe "speed units" do
    test "metres per second are themselves" do
      assert Geo.to_mps({10, :mps}) == 10.0
      assert Geo.to_mps(10) == 10.0
    end

    test "kph converts" do
      assert_in_delta Geo.to_mps({36, :kph}), 10.0, 0.0001
      assert_in_delta Geo.to_mps({120, :kph}), 33.333, 0.001
    end

    test "mph converts" do
      assert_in_delta Geo.to_mps({60, :mph}), 26.8224, 0.0001
    end
  end

  describe "min_travel_ms/3 is a genuine lower bound" do
    # Straight-line, so no route can beat it. That is the property that makes
    # it safe to reason with: if it says four minutes and two have passed, he
    # certainly has not arrived, whatever road he took.
    # The example house's own zones, not a real pair. A test fixture that is
    # somebody's address is a test fixture that leaks one, and this file is
    # the platform's -- it must not know where anybody lives.
    @home {51.4779, -0.0015}
    @workshop {51.5537, -0.0708}

    test "a known distance at a known speed" do
      # 1 km apart at 36 kph (10 m/s) is 100 seconds.
      a = {0.0, 0.0}
      b = {0.0, 1.0 / 111.320}

      ms = Geo.min_travel_ms(a, b, {36, :kph})
      assert_in_delta ms, 100_000, 2_000
    end

    test "the real pair, at motorway speed" do
      ms = Geo.min_travel_ms(@home, @workshop, {120, :kph})
      minutes = ms / 60_000

      # ~9.7 km at 120 kph is a shade under five minutes. The point is the
      # order of magnitude: it is minutes and not seconds, so an hour is
      # plenty of time to have arrived and ninety seconds is not.
      assert minutes > 3.0
      assert minutes < 8.0
    end

    test "the same point is reachable immediately" do
      assert Geo.min_travel_ms(@home, @home, {120, :kph}) == 0
    end

    test "faster travel shortens the bound, and never lengthens it" do
      slow = Geo.min_travel_ms(@home, @workshop, {30, :kph})
      fast = Geo.min_travel_ms(@home, @workshop, {120, :kph})

      assert fast < slow
      assert_in_delta slow / fast, 4.0, 0.01
    end

    test "a subject that cannot move never arrives" do
      assert Geo.min_travel_ms(@home, @workshop, {0, :kph}) == :infinity
    end

    # The bound must never claim someone arrived sooner than physics allows,
    # for any pair of points and any positive speed.
    test "it is never optimistic" do
      points = [
        {0.0, 0.0},
        {51.4779, -0.0015},
        {40.7128, -74.0060},
        {-33.8688, 151.2093},
        {89.0, 179.0}
      ]

      for a <- points, b <- points, a != b, kph <- [5, 50, 500] do
        ms = Geo.min_travel_ms(a, b, {kph, :kph})
        implied_m = Geo.to_mps({kph, :kph}) * ms / 1_000

        assert implied_m >= Geo.distance(a, b) - 1.0,
               "claimed #{inspect(a)} to #{inspect(b)} reachable in #{ms}ms at #{kph}kph, " <>
                 "which is faster than a straight line"
      end
    end
  end
end
