defmodule Merlin.GeofenceProcessTest do
  @moduledoc """
  Tier 1: the geofence as a running process, not as a pure function.

  `Merlin.Zones.resolve/3` -- the truth table, the radii, the hysteresis -- is
  covered thoroughly elsewhere. What had no coverage at all was the *process*
  wrapping it: when it recomputes, and on what.

  That gap is where the phantom-position defect lived. One phone message
  becomes three fact writes (lat, lon, accuracy) and the geofence recomputed
  after each, so the world briefly held positions that never existed -- a new
  latitude beside the previous longitude, or new coordinates beside a stale
  accuracy. Every one of those is an edge, and edge-triggered rules act on
  edges. Tier 9 found it as an intruder latch re-arming itself.
  """

  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.{Derive, World, Zones}

  @home {35.9606, -83.9207}
  @work {35.9132, -84.3110}

  setup do
    Merlin.Config.put(%{
      zones: Zones.compile([%{id: :home, center: @home, radius: {400, :ft}, hysteresis: 1.25}]),
      rules: [],
      groups: %{},
      sources: [],
      derived: []
    })

    id = :"fence_#{System.unique_integer([:positive])}"

    paths = %{
      lat: [id, :lat],
      lon: [id, :lon],
      accuracy: [id, :accuracy],
      out: [id, :zone]
    }

    %{id: id, paths: paths}
  end

  defp start_fence(id, paths, opts \\ []) do
    spec = %{
      id: id,
      kind: :geofence,
      lat: paths.lat,
      lon: paths.lon,
      accuracy: Keyword.get(opts, :accuracy_path, paths.accuracy),
      max_accuracy_m: Keyword.get(opts, :max_accuracy_m, 100),
      out: paths.out
    }

    {:ok, pid} = Derive.Geofence.start_link(spec)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # A whole observation, the way one message arrives: several writes, close
  # together in time.
  defp observe(paths, {lat, lon}, accuracy) do
    World.put(paths.lat, lat)
    World.put(paths.lon, lon)
    World.put(paths.accuracy, accuracy)
    settle()
  end

  # Long enough to cover the geofence's deferred recheck, which is armed
  # whenever an observation arrives in pieces -- which is every observation.
  # Sleeping less asserts on a zone that was still going to change: a flake
  # indistinguishable from a real failure.
  defp settle do
    :sys.get_state(Merlin.World.Writer, 1_000)
    Process.sleep(Derive.Geofence.recheck_ms() + 40)
    :sys.get_state(Merlin.World.Writer, 1_000)
  end

  defp zone(paths), do: World.get(paths.out)

  describe "a complete observation" do
    test "resolves the zone", %{id: id, paths: paths} do
      start_fence(id, paths)
      observe(paths, @home, 5)
      assert zone(paths) == :home
    end

    test "a position outside every zone is :unknown", %{id: id, paths: paths} do
      start_fence(id, paths)
      observe(paths, @work, 5)
      assert zone(paths) == :unknown
    end

    # The accuracy gate, judged on the fix that carries it rather than on the
    # one before it. The geofence did not subscribe to the accuracy fact at
    # all, so `max_accuracy_m` was permanently one message behind and a 500m
    # fix was placed as confidently as a 5m one.
    test "a fix too vague to place is :unknown, not a confident zone", %{id: id, paths: paths} do
      start_fence(id, paths)
      observe(paths, @home, 500)
      assert zone(paths) == :unknown
    end

    test "a vague fix does not place, even arriving after a precise one", %{id: id, paths: paths} do
      start_fence(id, paths)

      observe(paths, @home, 5)
      assert zone(paths) == :home

      # Same coordinates, now with a fix that cannot support the claim.
      observe(paths, @home, 800)

      assert zone(paths) == :unknown,
             "a fix too vague to place anyone kept them placed"
    end

    test "accuracy improving re-places without needing new coordinates", %{id: id, paths: paths} do
      start_fence(id, paths)

      observe(paths, @home, 800)
      assert zone(paths) == :unknown

      observe(paths, @home, 5)

      assert zone(paths) == :home,
             "a fix that became usable again never triggered a recompute"
    end
  end

  describe "partial observations do not produce phantom positions" do
    # THE REGRESSION.
    #
    # The phone was at work; it arrives home with a fix too vague to use. The
    # coordinates land before the accuracy does, and for that instant the world
    # holds home's coordinates beside the PREVIOUS accuracy of 5m -- a position
    # that never existed, inside the home zone. The old code published
    # `zone = :home` there, `{:enters, zone, :home}` fired, and the accuracy
    # then arrived and dropped it to :unknown.
    #
    # The visible damage was the intruder latch re-arming while the phone was
    # nowhere identifiable.
    test "new coordinates are not paired with a stale accuracy", %{id: id, paths: paths} do
      start_fence(id, paths)

      observe(paths, @work, 5)
      assert zone(paths) == :unknown

      # The accuracy on record is now demonstrably from an earlier fix.
      Process.sleep(Derive.Geofence.coherence_ms() + 100)

      # Coordinates arrive; the accuracy for THIS fix has not.
      World.put(paths.lat, elem(@home, 0))
      World.put(paths.lon, elem(@home, 1))
      settle()

      refute zone(paths) == :home,
             "the geofence placed the phone at home using an accuracy from a different fix"

      # And when it does arrive, it is the one that decides.
      World.put(paths.accuracy, 500)
      settle()
      assert zone(paths) == :unknown
    end

    test "a new latitude is not paired with the previous longitude", %{id: id, paths: paths} do
      start_fence(id, paths)

      # Somewhere far away, sharing home's longitude.
      World.put(paths.lat, 36.5000)
      World.put(paths.lon, elem(@home, 1))
      World.put(paths.accuracy, 5)
      settle()

      assert zone(paths) == :unknown

      # Only the latitude updates, and only much later. Pairing it with the
      # old longitude would put the phone exactly at home.
      Process.sleep(Derive.Geofence.coherence_ms() + 100)
      World.put(paths.lat, elem(@home, 0))
      settle()

      refute zone(paths) == :home,
             "the geofence paired a fresh latitude with a longitude from a previous fix"
    end

    # Holding, specifically -- NOT falling back to :unknown. Writing :unknown
    # on an incomplete update is itself an edge, and `{:leaves, zone, :home}`
    # fires on it exactly as a real departure would.
    test "an incoherent update holds the previous zone rather than clearing it", %{
      id: id,
      paths: paths
    } do
      start_fence(id, paths)

      observe(paths, @home, 5)
      assert zone(paths) == :home

      Process.sleep(Derive.Geofence.coherence_ms() + 100)
      World.put(paths.lat, 36.5000)
      settle()

      assert zone(paths) == :home,
             "an incomplete update cleared the zone, which is an edge rules will act on"
    end

    test "the components realigning resolves normally", %{id: id, paths: paths} do
      start_fence(id, paths)

      observe(paths, @home, 5)
      assert zone(paths) == :home

      Process.sleep(Derive.Geofence.coherence_ms() + 100)
      World.put(paths.lat, elem(@work, 0))
      settle()
      # Held.
      assert zone(paths) == :home

      World.put(paths.lon, elem(@work, 1))
      World.put(paths.accuracy, 5)
      settle()

      assert zone(paths) == :unknown,
             "once the whole observation arrived the zone did not update"
    end
  end

  describe "a source with no accuracy fact" do
    test "still resolves, and still requires lat and lon to agree in time", %{
      id: id,
      paths: paths
    } do
      start_fence(id, paths, accuracy_path: nil)

      World.put(paths.lat, elem(@home, 0))
      World.put(paths.lon, elem(@home, 1))
      settle()
      assert zone(paths) == :home

      Process.sleep(Derive.Geofence.coherence_ms() + 100)
      World.put(paths.lat, 36.5000)
      settle()

      assert zone(paths) == :home, "a two-component observation was crossed"
    end
  end
end
