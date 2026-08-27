defmodule Merlin.Adapters.EchoTest do
  @moduledoc """
  Tier 1: `echo` parity, and the shape of an adapter.

  These are the first parity cases: behaviour transcribed from
  `merlin/hooks/echo.py` and asserted against the Elixir. Because
  `handle_ingress/4` returns emissions rather than performing writes, the whole
  adapter is testable as a pure function -- no broker, no ETS, no supervision
  tree. The Python equivalent could not be tested without the daemon.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.Adapters.Echo

  describe "subscriptions/1" do
    test "declares only the two topics it needs" do
      # The point of declared subscriptions: this is what the connection asks
      # the broker for. The Python asked for `#`.
      subs = Echo.subscriptions([])

      assert {:mqtt, "test/ping", 0} in subs
      assert {:mqtt, "state/update", 0} in subs
      assert length(subs) == 2
      refute Enum.any?(subs, fn {:mqtt, filter, _} -> filter == "#" end)
    end

    test "topics are overridable, as in the Python config" do
      subs = Echo.subscriptions(ping_topic: "a/ping", update_topic: "a/update")

      assert {:mqtt, "a/ping", 0} in subs
      assert {:mqtt, "a/update", 0} in subs
    end
  end

  describe "ping/pong" do
    test "a ping produces the literal payload \"pong\"" do
      assert {:ok, emissions} = Echo.handle_ingress("test/ping", "anything", %{}, [])
      assert {:publish, "test/pong", "pong", [qos: 0]} in emissions
    end

    test "the inbound payload is ignored, exactly as in the Python" do
      for payload <- ["", "ping", "{\"json\":true}", <<0xFF, 0xFE>>] do
        assert {:ok, emissions} = Echo.handle_ingress("test/ping", payload, %{}, [])
        assert {:publish, "test/pong", "pong", [qos: 0]} in emissions
      end
    end

    test "a ping also emits a diagnostic event" do
      assert {:ok, emissions} = Echo.handle_ingress("test/ping", "hello", %{}, [])
      assert {:event, [:diag, :ping], "hello"} in emissions
    end

    test "pong topic is overridable" do
      assert {:ok, emissions} =
               Echo.handle_ingress("a/ping", "x", %{}, ping_topic: "a/ping", pong_topic: "a/pong")

      assert {:publish, "a/pong", "pong", [qos: 0]} in emissions
    end
  end

  describe "state/update" do
    test "becomes a fact, carrying the raw payload" do
      assert {:ok, [{:fact, [:system, :last_message], "hello"}]} =
               Echo.handle_ingress("state/update", "hello", %{}, [])
    end

    test "an empty payload is still a fact" do
      assert {:ok, [{:fact, [:system, :last_message], ""}]} =
               Echo.handle_ingress("state/update", "", %{}, [])
    end
  end

  describe "unexpected input" do
    test "an unrouted topic emits nothing rather than raising" do
      # An adapter that raises on unexpected input is a crash loop waiting for
      # a retained message; see Merlin.MQTT.Connection.
      assert {:ok, []} = Echo.handle_ingress("some/other/topic", "x", %{}, [])
    end

    test "binary payloads do not raise" do
      assert {:ok, _} = Echo.handle_ingress("state/update", <<0xC3, 0x28>>, %{}, [])
    end
  end
end
