defmodule Merlin.ZonesTest do
  @moduledoc """
  Tier 1: zone resolution, hysteresis, and the truth table.

  The eight-row table in `user_location.py:81-90` is a specification, written
  by hand in a comment block and never executed. It is transcribed here as
  assertions, which is the difference between a design note and a guarantee.

  The tri-state is the other half. `:unknown` must never be mistakable for
  "not home", because the entire away path of the Python daemon was dead code
  on exactly that confusion.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.{Geo, Zones}

  @home {35.9606, -83.9207}
  @work {35.9132, -84.3110}

  defp zones do
    Zones.compile([
      %{id: :home, center: @home, radius: {400, :ft}, hysteresis: 1.25},
      %{id: :work, center: @work, radius: {0.25, :mi}}
    ])
  end

  # A point `metres` north of `center`. One degree of latitude is one degree of
  # arc, so this is exact for the sphere the geometry uses.
  defp north_of({lat, lon}, metres) do
    {lat + metres / (Geo.earth_radius_m() * :math.pi() / 180.0), lon}
  end

  describe "compile/2" do
    test "resolves per-zone radii to metres" do
      z = zones()
      assert_in_delta z[:home].radius_m, 121.92, 0.01
      assert_in_delta z[:work].radius_m, 402.34, 0.01
    end

    test "the exit radius is wider than the entry radius" do
      z = zones()
      assert z[:home].exit_radius_m > z[:home].radius_m
      assert_in_delta z[:home].exit_radius_m, 121.92 * 1.25, 0.01
    end

    test "a zone without an explicit hysteresis gets the default" do
      z = zones()
      assert_in_delta z[:work].exit_radius_m, 402.34 * Zones.default_hysteresis(), 0.01
    end

    test "zones may be different sizes — the whole point of per-zone radii" do
      z = zones()
      refute z[:home].radius_m == z[:work].radius_m
    end
  end

  describe "resolution" do
    test "a point at the centre is in the zone" do
      assert Zones.resolve(@home, :unknown, zones()) == :home
    end

    test "a point well outside every zone is :unknown, not nil and not false" do
      # The tri-state. `nil` or `false` here would be indistinguishable from
      # "not home", which is the exact confusion that killed the Python's away
      # detection.
      assert Zones.resolve({0.0, 0.0}, :unknown, zones()) == :unknown
    end

    test "an absent position is :unknown" do
      assert Zones.resolve(:unknown, :home, zones()) == :unknown
    end

    test "the nearest containing zone wins when zones overlap" do
      # Matches _filter_containing_regions, which sorted by distance and took
      # the head. Offset so the two are genuinely at different distances.
      overlapping =
        Zones.compile([
          %{id: :far, center: north_of(@home, 300), radius: {1, :mi}},
          %{id: :near, center: @home, radius: {1, :mi}}
        ])

      assert Zones.resolve(@home, :unknown, overlapping) == :near
    end

    test "concentric zones break the tie toward the tighter one" do
      # Equidistant -- both centres are the same point -- so distance cannot
      # decide. Without an explicit tie-break this depended on map ordering,
      # which is to say it was arbitrary and would have changed under you.
      concentric =
        Zones.compile([
          %{id: :big, center: @home, radius: {1, :mi}},
          %{id: :small, center: @home, radius: {100, :ft}}
        ])

      assert Zones.resolve(@home, :unknown, concentric) == :small
    end

    test "an empty zone set yields :unknown for any point" do
      assert Zones.resolve(@home, :unknown, %{}) == :unknown
    end
  end

  describe "hysteresis" do
    test "entering requires the tighter radius" do
      # 130m out: beyond the 121.92m entry radius, inside the 152.4m exit one.
      point = north_of(@home, 130)

      assert Zones.resolve(point, :unknown, zones()) == :unknown,
             "entered the zone from outside at a distance only the exit radius covers"
    end

    test "leaving requires the wider radius" do
      point = north_of(@home, 130)

      assert Zones.resolve(point, :home, zones()) == :home,
             "left the zone at a distance inside the exit radius"
    end

    test "the gap between the radii is where flapping would live" do
      # The same point resolves differently depending only on where you were.
      # That asymmetry IS the anti-flap, so it is asserted directly.
      point = north_of(@home, 130)

      assert Zones.resolve(point, :unknown, zones()) == :unknown
      assert Zones.resolve(point, :home, zones()) == :home
    end

    test "beyond the exit radius you are out regardless of history" do
      point = north_of(@home, 200)
      assert Zones.resolve(point, :home, zones()) == :unknown
      assert Zones.resolve(point, :unknown, zones()) == :unknown
    end

    test "a jittering fix does not oscillate" do
      # Simulate a phone sitting near the boundary with metres of noise. With
      # hysteresis the answer is stable; without it this alternates, and the
      # lamps switch with it.
      results =
        for offset <- [118, 125, 119, 130, 122, 128, 121, 126] do
          Zones.resolve(north_of(@home, offset), :home, zones())
        end

      assert Enum.uniq(results) == [:home],
             "the zone flapped across a jittering fix: #{inspect(results)}"
    end
  end

  describe "the truth table from user_location.py:81-90" do
    # m_loc | v_loc | v_m_nearby || user_loc | v_safe
    # transcribed as executable assertions. `?` is :unknown.
    #
    # v_safe in the original was `v_loc is not None or v_m_nearby` -- the
    # vehicle is accounted for if it is in ANY known zone, or if it is with the
    # phone. The label-comparison branch of v_m_nearby never affected the
    # result, which is recorded here because it is the kind of thing that looks
    # load-bearing until you check.
    defp v_safe(v_loc, v_m_nearby), do: v_loc != :unknown or v_m_nearby

    test "row 1: both in zone A, assumed together -> safe" do
      assert v_safe(:home, true)
    end

    test "row 2: phone in A, vehicle in B, assumed apart -> still safe" do
      # The car being at work while you are at home is not theft.
      assert v_safe(:work, false)
    end

    test "rows 3 and 4: phone in A, vehicle abroad" do
      assert v_safe(:unknown, true), "with the phone -> safe"
      refute v_safe(:unknown, false), "away from the phone -> not safe"
    end

    test "rows 5 and 6: phone abroad, vehicle in A -> safe either way" do
      assert v_safe(:home, true)
      assert v_safe(:home, false)
    end

    test "rows 7 and 8: both abroad" do
      assert v_safe(:unknown, true), "together -> safe"
      refute v_safe(:unknown, false), "apart -> not safe"
    end

    test "only one row in eight is unsafe by proximity alone" do
      rows =
        for v_loc <- [:home, :work, :unknown], nearby <- [true, false] do
          {v_loc, nearby, v_safe(v_loc, nearby)}
        end

      unsafe = Enum.filter(rows, fn {_, _, safe} -> not safe end)

      assert Enum.all?(unsafe, fn {v_loc, nearby, _} -> v_loc == :unknown and nearby == false end),
             "something other than abroad-and-alone was judged unsafe: #{inspect(unsafe)}"
    end
  end
end
