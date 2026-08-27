defmodule Merlin.Test.SimHouse do
  @moduledoc """
  A whole merlin, running in this VM against a fake broker, driven by a seeded
  sequence of device events.

  Starts the real derived facts, the real rules engine, the real machines and
  the real MQTT connection against `Merlin.Test.FakeBroker`, using the
  **shipped** configuration. The only thing that is not real is the broker
  itself.

  ## What is excluded, and exactly what that costs

  The `:http_poll` derived facts are removed before the config is installed.
  They poll on a two-minute timer against endpoints that do not exist here, and
  their failure paths -- token lifecycle, transport errors, containment -- are
  tier 5's subject, asserted there with injected faults.

  The cost, stated precisely: `vehicle.*` facts never arrive, so the two
  vehicle rules (`unaccounted?` and `away_while_home?`) are not exercised by
  this tier. Nothing else changes; every other rule in the house runs.

  ## Synchronisation

  After each event the daemon is *flushed* rather than slept on: a synchronous
  call to each process in the delivery chain, in order, so that when the call
  to the last one returns, everything the event was going to cause has already
  happened. A `Process.sleep` here would be both slower and a source of the
  flakiness this tier exists to eliminate.
  """

  alias Merlin.Test.FakeBroker

  @config_path "priv/merlin.exs"

  # Long enough for a retained burst to land inside it, short enough that a
  # hundred-step run does not spend a minute waiting.
  @settle_ms 300

  defstruct [:broker, :seq, :timeline, :rand]

  # --- lifecycle ------------------------------------------------------------

  @doc """
  Start a house. Returns a handle; call `stop/1` when done.

  Installs the shipped config globally, so tier 9 must be `async: false`.
  """
  @spec start(keyword()) :: %__MODULE__{}
  def start(opts \\ []) do
    install_config()
    clear_world()

    {:ok, _} = start_supervised_or_link(Merlin.Derive.Supervisor)
    {:ok, _} = start_supervised_or_link(Merlin.Rules.Engine)
    {:ok, _} = start_supervised_or_link(Merlin.Machine.Supervisor)

    {:ok, _conn} =
      GenServer.start_link(
        Merlin.MQTT.Connection,
        [client: FakeBroker, client_id: "sim", host: "fake", port: 0],
        name: Merlin.MQTT.Connection
      )

    broker = Process.whereis(Merlin.Test.FakeBroker)

    for {topic, payload} <- Keyword.get(opts, :retained, []) do
      FakeBroker.preload_retained(broker, topic, payload)
    end

    Merlin.Settle.finish()
    FakeBroker.connect(broker)
    flush()

    %__MODULE__{
      broker: broker,
      seq: 0,
      timeline: [],
      rand: :rand.seed_s(:exsss, {Keyword.get(opts, :seed, 1), 0, 0})
    }
    |> record_step("house started")
  end

  @doc "Stop everything this house started."
  @spec stop(%__MODULE__{}) :: :ok
  def stop(_house) do
    for name <- [
          Merlin.MQTT.Connection,
          Merlin.Machine.Supervisor,
          Merlin.Rules.Engine,
          Merlin.Derive.Supervisor
        ] do
      case Process.whereis(name) do
        nil -> :ok
        pid -> stop_quietly(pid)
      end
    end

    Merlin.Settle.finish()
    :ok
  end

  defp stop_quietly(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> Process.exit(pid, :kill)
    end
  end

  defp start_supervised_or_link(mod) do
    case mod.start_link([]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # --- configuration --------------------------------------------------------

  defp install_config do
    Merlin.Secrets.put(%{
      hapn_auth_endpoint: "http://127.0.0.1:1/token",
      hapn_device_endpoint: "http://127.0.0.1:1/device",
      hapn_client_id: "sim",
      hapn_client_secret: "sim",
      weather_endpoint: "http://127.0.0.1:1/weather",
      weather_api_key: "sim",
      discord_webhook: "http://127.0.0.1:1/hook"
    })

    {raw, _} = Code.eval_file(@config_path)

    raw =
      raw
      |> Map.put(:dry_run, false)
      |> Map.put(:settle_ms, @settle_ms)
      |> Map.update!(:derived, fn derived ->
        Enum.reject(derived, &(Map.get(&1, :kind) == :http_poll))
      end)

    {:ok, config} = Merlin.Config.File.validate(raw)
    Merlin.Config.put(config)
  end

  defp clear_world do
    :ets.delete_all_objects(Merlin.World.Table.table())
    :ets.insert(Merlin.World.Table.table(), {Merlin.World.Table.seq_key(), 0})
  end

  # --- driving --------------------------------------------------------------

  @doc "Deliver one device message and record what the house did about it."
  @spec device(%__MODULE__{}, binary(), binary(), keyword()) :: %__MODULE__{}
  def device(house, topic, payload, opts \\ []) do
    FakeBroker.device_publish(house.broker, topic, payload, opts)
    flush()
    record_step(house, "#{topic} #{payload}")
  end

  @doc """
  Drop the connection and bring it back, replaying every retained message.

  The 3am case: a wifi blip replays the whole retained set into a daemon that
  has been running for weeks.
  """
  @spec reconnect(%__MODULE__{}) :: %__MODULE__{}
  def reconnect(house) do
    FakeBroker.disconnect(house.broker)
    flush()
    FakeBroker.connect(house.broker)
    flush()
    record_step(house, "broker reconnected")
  end

  @doc "Let real state timeouts elapse -- the printer's dwell is genuinely ten seconds."
  @spec wait(%__MODULE__{}, non_neg_integer()) :: %__MODULE__{}
  def wait(house, ms) do
    Process.sleep(ms)
    flush()
    record_step(house, "waited #{ms}ms")
  end

  @doc "The timeline so far, oldest first."
  @spec timeline(%__MODULE__{}) :: [map()]
  def timeline(%__MODULE__{timeline: t}), do: Enum.reverse(t)

  # --- recording ------------------------------------------------------------

  defp record_step(house, note) do
    published = FakeBroker.published(house.broker)
    FakeBroker.clear_published(house.broker)

    facts = facts_now()
    settling? = Merlin.Settle.settling?()

    step = %{
      seq: house.seq,
      kind: :step,
      topic: nil,
      payload: nil,
      note: note,
      settling?: settling?,
      facts: facts
    }

    {entries, seq} =
      Enum.reduce(published, {[step], house.seq + 1}, fn {topic, payload}, {acc, seq} ->
        entry = %{
          seq: seq,
          kind: :publish,
          topic: topic,
          payload: payload,
          note: nil,
          settling?: settling?,
          facts: facts
        }

        {[entry | acc], seq + 1}
      end)

    %{house | seq: seq, timeline: entries ++ house.timeline}
  end

  defp facts_now do
    Merlin.World.dump()
    |> Map.new(&{&1.path, &1.value})
  end

  # Flush the delivery chain in order, then wait out the one thing that is
  # genuinely asynchronous.
  #
  # The geofence arms a deferred recheck when an observation arrives in pieces,
  # which is every observation. Returning before it fires means the timeline
  # records a world that was still changing -- and an invariant reading a
  # half-updated snapshot reports transitions that never happened, which is
  # indistinguishable from finding a real defect and wastes the shrinker on
  # a ghost.
  #
  # This is the only sleep in the harness and it is not a guess: the duration
  # comes from the geofence itself.
  defp flush do
    call(Merlin.MQTT.Connection)
    call(Merlin.World.Writer)
    call(Merlin.Rules.Engine)
    Process.sleep(Merlin.Derive.Geofence.recheck_ms() + 30)
    call(Merlin.World.Writer)
    call(Merlin.Rules.Engine)

    for {id, pid, _, _} <- Supervisor.which_children(Merlin.Machine.Supervisor),
        is_pid(pid),
        id != :undefined do
      safe(fn -> :sys.get_state(pid, 500) end)
    end

    # Again: a machine's actions may have written facts, and those changes are
    # still in flight until the writer has drained.
    call(Merlin.World.Writer)
    call(Merlin.Rules.Engine)
    :ok
  end

  defp call(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> safe(fn -> :sys.get_state(pid, 1_000) end)
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end
end
