defmodule Merlin.SourceStalenessTest do
  @moduledoc """
  Tier 5: an MQTT source can declare how long its facts stay an answer.

  `stale_after` has existed on `Merlin.World.put/3` since the world was
  written, and `:http_poll` has passed one since M6. The MQTT ingress path
  never did -- `Merlin.MQTT.Connection.apply_emission/6` called `World.put/3`
  with a source, captures and an observation, and no horizon. The option was
  reachable from exactly the sources least likely to need it and unreachable
  from the ones most likely: a mains-powered HTTP poller could say "this goes
  stale in twenty minutes", and a battery-powered Zigbee sensor could not.

  The consequence is not subtle. A temperature sensor whose battery dies
  reports its last reading for ever, every guard reading it keeps answering as
  though the value were current, and a rule that runs a compressor on that
  reading goes on running it. The daemon looks healthy the entire time,
  because from the inside a fact that stopped changing is indistinguishable
  from a room that stopped changing.

  This tier and not tier 1 because the claim is about the ingress path -- the
  connection, an adapter and a real write -- rather than about `Fact.stale?/2`,
  which tier 1 already covers.
  """

  use ExUnit.Case, async: false

  @moduletag :tier5

  alias Merlin.{World, Fact}
  alias Merlin.Rules.Env

  setup do
    Merlin.Settle.finish()
    :ok
  end

  defp path, do: [:probe, "s#{System.unique_integer([:positive])}", :temp]

  # One declarative source, with or without a horizon, wired to a fake broker.
  defp start_source(fact_path, source_extra) do
    source =
      Map.merge(
        %{
          id: :probe,
          topic: "probe/climate",
          decode: :json,
          facts: [%{path: fact_path, from: [["temperature"]], codec: :float}]
        },
        source_extra
      )

    {:ok, pid} =
      GenServer.start_link(
        Merlin.MQTT.Connection,
        [
          client: Merlin.Test.FakeBroker,
          adapters: [{Merlin.Adapters.Declarative, [source: source]}],
          client_id: "stale-after-test-#{System.unique_integer([:positive])}",
          host: "fake",
          port: 0
        ],
        name: Merlin.MQTT.Connection
      )

    broker = Process.whereis(Merlin.Test.FakeBroker)
    Merlin.Test.FakeBroker.connect(broker)
    sync(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end)

    {pid, broker}
  end

  defp sync(pid) do
    :sys.get_state(pid, 1_000)
    Process.sleep(20)
    :sys.get_state(pid, 1_000)
  end

  defp send_reading(broker, pid, celsius) do
    Merlin.Test.FakeBroker.device_publish(
      broker,
      "probe/climate",
      ~s({"temperature":#{celsius}})
    )

    sync(pid)
  end

  describe "a source's declared horizon reaches the fact" do
    test "stale_after_ms is stamped on every fact the source writes" do
      p = path()
      {pid, broker} = start_source(p, %{stale_after_ms: 60_000})
      send_reading(broker, pid, 21.5)

      assert {:ok, %Fact{} = fact} = World.fetch(p)
      assert fact.value == 21.5
      assert fact.stale_after == 60_000
    end

    # The control. Without this, the test above passes on an implementation
    # that stamps every fact with a horizon whether or not one was asked for,
    # which would quietly make every MQTT fact expire.
    test "a source that declares nothing leaves the fact with no horizon" do
      p = path()
      {pid, broker} = start_source(p, %{})
      send_reading(broker, pid, 21.5)

      assert {:ok, %Fact{} = fact} = World.fetch(p)
      assert fact.value == 21.5
      assert fact.stale_after == nil, "a fact nobody gave a horizon must never go stale"
    end
  end

  describe "and it changes what a guard sees" do
    # Both halves, deliberately. Asserting only that an expired fact reads
    # :unknown would pass just as well against a fact that was never written
    # at all -- and an ingress path that silently dropped every message would
    # look identical.
    test "inside the horizon the guard reads the value" do
      p = path()
      {pid, broker} = start_source(p, %{stale_after_ms: 60_000})
      send_reading(broker, pid, 21.5)

      assert Env.read(p) == 21.5
    end

    test "past the horizon the guard reads :unknown, not the last reading" do
      p = path()
      {pid, broker} = start_source(p, %{stale_after_ms: 1})
      send_reading(broker, pid, 21.5)
      Process.sleep(25)

      assert Env.read(p) == :unknown,
             "a sensor that has stopped talking must not keep answering as though it had not"

      # ...and the value is still THERE. Staleness is a reading rule, not a
      # deletion: /facts.json and the TUI both show the last value with its
      # age, which is what makes a dead sensor diagnosable rather than absent.
      assert {:ok, %Fact{value: 21.5}} = World.fetch(p)
    end
  end
end
