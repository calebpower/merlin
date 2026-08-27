defmodule Merlin.MQTT.RouterTest do
  @moduledoc """
  Tier 1: the topic matcher.

  This replaces the hand-rolled `+` matcher in `home_doors.py`, which bailed
  when segment counts differed and had no `#` support at all. The boundaries
  that matter here are the ones that matcher got wrong or never faced.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.MQTT.Router

  defp router(filters) do
    Enum.reduce(filters, Router.new(), fn {f, v}, r -> Router.add!(r, f, v) end)
  end

  defp values(matches), do: matches |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  describe "literal filters" do
    test "exact match, and nothing else" do
      r = router([{"test/ping", :ping}])

      assert [{:ping, %{}}] = Router.match(r, "test/ping")
      assert [] = Router.match(r, "test/pong")
      assert [] = Router.match(r, "test")
      assert [] = Router.match(r, "test/ping/extra")
    end

    test "segment counts must agree" do
      # The specific defect in the Python matcher's sibling case: a filter
      # must not match a longer or shorter topic.
      r = router([{"a/b/c", :abc}])

      assert [{:abc, _}] = Router.match(r, "a/b/c")
      assert [] = Router.match(r, "a/b")
      assert [] = Router.match(r, "a/b/c/d")
    end
  end

  describe "+ single-level wildcard" do
    test "matches exactly one level" do
      r = router([{"home/+/sensor/contact", :door}])

      assert [{:door, _}] = Router.match(r, "home/office/sensor/contact")
      assert [] = Router.match(r, "home/sensor/contact")
      assert [] = Router.match(r, "home/upstairs/office/sensor/contact")
    end

    test "named capture" do
      r = router([{"home/+room/sensor/contact", :door}])

      assert [{:door, %{"room" => "office"}}] = Router.match(r, "home/office/sensor/contact")
      assert [{:door, %{"room" => "garage"}}] = Router.match(r, "home/garage/sensor/contact")
    end

    test "an unnamed + captures nothing" do
      r = router([{"home/+/sensor/contact", :door}])
      assert [{:door, captures}] = Router.match(r, "home/office/sensor/contact")
      assert captures == %{}
    end

    test "several captures in one filter, in order" do
      r = router([{"z/+room/+device/state", :dev}])

      assert [{:dev, %{"room" => "office", "device" => "lamp"}}] =
               Router.match(r, "z/office/lamp/state")
    end

    test "named and unnamed wildcards share a trie node without colliding" do
      # Both filters occupy the same position; the names live with the entry,
      # not the node, precisely so this works.
      r = router([{"a/+x/c", :named}, {"a/+/c", :anon}])

      matches = Router.match(r, "a/b/c")
      assert values(matches) == [:anon, :named]

      captures = Map.new(matches, fn {v, c} -> {v, c} end)
      assert captures[:named] == %{"x" => "b"}
      assert captures[:anon] == %{}
    end
  end

  describe "# multi-level wildcard" do
    test "matches one or more trailing levels" do
      r = router([{"sport/#", :sport}])

      assert [{:sport, _}] = Router.match(r, "sport/tennis")
      assert [{:sport, _}] = Router.match(r, "sport/tennis/player1/ranking")
    end

    test "matches zero levels — the parent itself" do
      # MQTT says "sport/#" matches "sport". Easy to get wrong, and the Python
      # matcher did not implement # at all.
      r = router([{"sport/#", :sport}])
      assert [{:sport, _}] = Router.match(r, "sport")
    end

    test "# alone matches everything" do
      r = router([{"#", :all}])

      assert [{:all, _}] = Router.match(r, "a")
      assert [{:all, _}] = Router.match(r, "a/b/c/d/e")
    end

    test "# is refused anywhere but the end" do
      assert {:error, reason} = Router.add(Router.new(), "a/#/b", :bad)
      assert reason =~ "final segment"
    end

    test "# is refused inside a segment" do
      assert {:error, reason} = Router.add(Router.new(), "a/b#/c", :bad)
      assert reason =~ "whole segment"
    end

    test "an empty filter is refused" do
      assert {:error, _} = Router.add(Router.new(), "", :bad)
    end

    test "add! raises on an invalid filter" do
      assert_raise ArgumentError, fn -> Router.add!(Router.new(), "a/#/b", :bad) end
    end
  end

  describe "multiple matches" do
    test "a topic matching several filters returns all of them" do
      r =
        router([
          {"home/+room/sensor/contact", :by_room},
          {"home/office/sensor/contact", :exact},
          {"home/#", :everything}
        ])

      matches = Router.match(r, "home/office/sensor/contact")
      assert values(matches) == [:by_room, :everything, :exact]
    end

    test "the same filter added twice yields both values" do
      r = router([{"a/b", :first}, {"a/b", :second}])
      assert values(Router.match(r, "a/b")) == [:first, :second]
    end
  end

  describe "wire_filter/1 — what the broker is allowed to see" do
    # `+room` is this module's own notation. MQTT requires `+` to occupy a
    # whole level, so sending `home/+room/...` in a SUBSCRIBE makes mosquitto
    # answer "Invalid subscription string" and drop the connection as a
    # malformed packet -- which at the client looks like an unexplained
    # connect/subscribe/disconnect loop. It cost six runs to find.
    test "strips capture names from wildcards" do
      assert Router.wire_filter("home/+room/sensor/contact") == "home/+/sensor/contact"
      assert Router.wire_filter("z/+room/+device/state") == "z/+/+/state"
    end

    test "leaves already-legal filters untouched" do
      assert Router.wire_filter("home/+/sensor/contact") == "home/+/sensor/contact"
      assert Router.wire_filter("test/ping") == "test/ping"
      assert Router.wire_filter("sport/#") == "sport/#"
      assert Router.wire_filter("#") == "#"
    end

    test "the result never contains a named wildcard" do
      for filter <- [
            "home/+room/sensor/contact",
            "a/+x/b/+y/c",
            "+leading/rest",
            "test/ping",
            "sport/#"
          ] do
        wire = Router.wire_filter(filter)

        for segment <- String.split(wire, "/") do
          assert segment == "+" or not String.starts_with?(segment, "+"),
                 "#{filter} produced illegal wire segment #{inspect(segment)}"
        end
      end
    end

    test "matching still uses the authored filter, captures intact" do
      # The wire form is for the broker only; routing must keep the names.
      r = router([{"home/+room/sensor/contact", :door}])
      assert [{:door, %{"room" => "office"}}] = Router.match(r, "home/office/sensor/contact")
    end
  end

  describe "boundaries" do
    test "an empty router matches nothing" do
      assert [] = Router.match(Router.new(), "anything/at/all")
    end

    test "single-segment topics" do
      r = router([{"ping", :ping}])
      assert [{:ping, _}] = Router.match(r, "ping")
      assert [] = Router.match(r, "ping/pong")
    end

    test "empty segments are ordinary segments" do
      # "a//b" has a genuinely empty middle level, which MQTT permits.
      r = router([{"a//b", :empty_mid}])
      assert [{:empty_mid, _}] = Router.match(r, "a//b")
      assert [] = Router.match(r, "a/b")
    end
  end
end
