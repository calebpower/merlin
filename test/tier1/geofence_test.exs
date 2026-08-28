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

  @home {51.4779, -0.0015}
  @elsewhere {51.5537, -0.0708}

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

    test "a position outside every zone is :away", %{id: id, paths: paths} do
      start_fence(id, paths)
      observe(paths, @elsewhere, 5)
      assert zone(paths) == :away
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

      observe(paths, @elsewhere, 5)
      assert zone(paths) == :away

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

      # :unknown, not :away -- there is no usable fix at all now.
      assert zone(paths) == :unknown
    end

    test "a new latitude is not paired with the previous longitude", %{id: id, paths: paths} do
      start_fence(id, paths)

      # Somewhere far away, sharing home's longitude.
      World.put(paths.lat, 43.5000)
      World.put(paths.lon, elem(@home, 1))
      World.put(paths.accuracy, 5)
      settle()

      assert zone(paths) == :away

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
      World.put(paths.lat, 43.5000)
      settle()

      assert zone(paths) == :home,
             "an incomplete update cleared the zone, which is an edge rules will act on"
    end

    test "the components realigning resolves normally", %{id: id, paths: paths} do
      start_fence(id, paths)

      observe(paths, @home, 5)
      assert zone(paths) == :home

      Process.sleep(Derive.Geofence.coherence_ms() + 100)
      World.put(paths.lat, elem(@elsewhere, 0))
      settle()
      # Held.
      assert zone(paths) == :home

      World.put(paths.lon, elem(@elsewhere, 1))
      World.put(paths.accuracy, 5)
      settle()

      assert zone(paths) == :away,
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
      World.put(paths.lat, 43.5000)
      settle()

      assert zone(paths) == :home, "a two-component observation was crossed"
    end
  end

  describe "a fix stops being an answer once somewhere else is reachable" do
    # THE OVERNIGHT REGRESSION.
    #
    # A phone went flat at a workshop at 23:23. Its owner drove home. At 00:27
    # a door opened and the intruder latch fired on him entering his own house,
    # because the zone still read `workshop` an hour after anyone could
    # possibly have known that.
    #
    # Staleness was checked when a position was READ, and nothing re-read it as
    # time passed -- so a dead phone's last zone stood for ever. The fix is a
    # scheduled wake-up: when the window lapses with no new fix, the geofence
    # publishes :unknown on its own.
    setup do
      # Two zones a known distance apart, and a speed that makes the window
      # short enough to test without waiting minutes.
      here = {51.4779, -0.0015}
      # ~450 m north.
      there = {51.4779 + 450.0 / 111_320.0, -0.0015}

      Merlin.Config.put(%{
        zones:
          Zones.compile([
            %{id: :here, center: here, radius: {50, :m}},
            %{id: :there, center: there, radius: {50, :m}}
          ]),
        rules: [],
        groups: %{},
        sources: [],
        derived: []
      })

      %{here: here, there: there}
    end

    defp start_with_speed(id, paths, speed) do
      spec = %{
        id: id,
        kind: :geofence,
        lat: paths.lat,
        lon: paths.lon,
        accuracy: paths.accuracy,
        max_accuracy_m: 100,
        max_speed: speed,
        out: paths.out
      }

      {:ok, pid} = Derive.Geofence.start_link(spec)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    test "the zone expires with NO new fix arriving", %{id: id, paths: paths, here: here} do
      # 400 m to the other zone's edge at 1 m/s is about 400 s... far too slow
      # to test. At 400 m/s it is one second.
      start_with_speed(id, paths, {400, :mps})

      observe(paths, here, 5)
      assert zone(paths) == :here

      # Nothing further is posted. The phone is dead.
      Process.sleep(1_400)

      assert zone(paths) == :unknown,
             "the zone stood after somewhere else became reachable -- a dead phone would " <>
               "keep asserting where its owner used to be"
    end

    test "it does NOT expire while nowhere else is reachable", %{
      id: id,
      paths: paths,
      here: here
    } do
      # 400 m at 1 m/s is 400 seconds; nothing should expire in one.
      start_with_speed(id, paths, {1, :mps})

      observe(paths, here, 5)
      assert zone(paths) == :here

      Process.sleep(1_200)

      assert zone(paths) == :here,
             "the zone expired while the subject could not have reached anywhere else"
    end

    test "a fresh fix restarts the window", %{id: id, paths: paths, here: here} do
      start_with_speed(id, paths, {400, :mps})

      observe(paths, here, 5)
      Process.sleep(600)
      # Still within the window, and a new fix arrives.
      observe(paths, here, 5)
      Process.sleep(600)

      assert zone(paths) == :here, "a fresh fix did not reset the certainty window"
    end

    test "with no max_speed declared, nothing expires", %{id: id, paths: paths, here: here} do
      # Backwards compatible: a geofence that does not declare a speed behaves
      # exactly as before.
      start_fence(id, paths)

      observe(paths, here, 5)
      assert zone(paths) == :here

      Process.sleep(1_400)
      assert zone(paths) == :here
    end
  end

  describe "recovering from :unknown without a change" do
    # THE REGRESSION THIS INTRODUCED.
    #
    # A parked car reports identical coordinates every two minutes.
    # `World.put/3` notifies on CHANGE, so those perfectly good fixes publish
    # nothing. Once the certainty window expired, the zone stayed :unknown for
    # ever -- a car in the drive, tracked correctly, reading as unlocatable for
    # four hours.
    #
    # Any design that only reacts to changes is blind to a value refreshed
    # without changing. The geofence must LOOK, not wait.
    setup do
      here = {51.4779, -0.0015}
      there = {51.4779 + 450.0 / 111_320.0, -0.0015}

      Merlin.Config.put(%{
        zones:
          Zones.compile([
            %{id: :here, center: here, radius: {50, :m}},
            %{id: :there, center: there, radius: {50, :m}}
          ]),
        rules: [],
        groups: %{},
        sources: [],
        derived: []
      })

      %{here: here}
    end

    test "a refreshed-but-identical fix restores the zone", %{id: id, paths: paths, here: here} do
      # A short recheck so the test does not wait a minute.
      spec = %{
        id: id,
        kind: :geofence,
        lat: paths.lat,
        lon: paths.lon,
        accuracy: paths.accuracy,
        max_accuracy_m: 100,
        max_speed: {400, :mps},
        # Milliseconds, so this proves the behaviour rather than the clock.
        unknown_recheck_ms: 200,
        out: paths.out
      }

      {:ok, pid} = Derive.Geofence.start_link(spec)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      observe(paths, here, 5)
      assert zone(paths) == :here

      # Let the certainty window lapse with nothing arriving.
      Process.sleep(1_400)
      assert zone(paths) == :unknown

      # Now the poller resumes -- with EXACTLY the same coordinates, which
      # publishes no change at all.
      observe(paths, here, 5)

      # The zone must come back. Waiting for a change would wait for ever.
      deadline = System.monotonic_time(:millisecond) + 3_000

      restored =
        Stream.repeatedly(fn ->
          Process.sleep(200)
          zone(paths)
        end)
        |> Enum.find(fn z ->
          z == :here or System.monotonic_time(:millisecond) > deadline
        end)

      assert restored == :here,
             "a fix that refreshed without changing never restored the zone -- exactly the " <>
               "case of a parked car reporting the same coordinates every two minutes"
    end

    test "it keeps looking while it cannot place the subject", %{id: id, paths: paths} do
      # With no position at all the geofence must still be re-reading, or a
      # source that comes back with an unchanged value is never noticed.
      start_fence(id, paths)
      assert zone(paths) == :unknown

      assert Derive.Geofence.unknown_recheck_ms() > 0

      assert Derive.Geofence.unknown_recheck_ms() <= 30_000,
             "the recheck is slow enough that the house would not know where someone is " <>
               "for long enough to make a wrong decision"
    end
  end
end
