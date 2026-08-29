defmodule Merlin.TapTest do
  @moduledoc """
  Tier 5: the session feed, against the real bus and a fake client.

  The question this tier answers that no cheaper one can: does a live daemon
  actually deliver, and does it survive the things a live daemon does -- a
  retained burst, a client that dies without saying goodbye.

  The client is faked because the real one is a terminal, and a test that needs
  a terminal is a test nobody runs. Everything else here is real: the real
  `Merlin.Bus`, the real `Merlin.Effects.Tap`, the real supervisor.

  ## What this tier does not prove

  Anything about rendering, and anything about distribution. The client is a
  local pid; a genuinely remote one needs two nodes and belongs to tier 6.
  What is asserted here is the contract a remote client would rely on.
  """

  use ExUnit.Case, async: false

  @moduletag :tier5

  alias Merlin.{Bus, Change, Event, Tap}
  alias Merlin.Effects.Report

  defp uniq, do: "tap-#{System.unique_integer([:positive])}"

  defp change(path, new \\ :open) do
    %Change{
      path: path,
      old: :closed,
      new: new,
      at: 0,
      source: nil,
      seq: System.unique_integer([:positive]),
      first?: false
    }
  end

  # A generous flush window, so a burst published by the test lands inside one
  # batch rather than racing the timer. The coalescing claim is about what
  # arrives together, not about how fast.
  defp attach!(opts \\ []) do
    {:ok, %{pid: pid}} = Tap.attach(self(), Keyword.put_new(opts, :flush_ms, 200))
    on_exit(fn -> stop(pid) end)
    pid
  end

  # A tap attached to the TEST process dies when the test does -- its monitor
  # fires -- so cleanup races the thing it is cleaning up. An already-gone tap
  # is the correct outcome here, not an error.
  defp stop(pid) do
    Tap.detach(pid)
  catch
    :exit, _ -> :ok
  end

  # --- the handshake --------------------------------------------------------

  describe "attach" do
    test "returns the daemon's version, so a client can refuse a mismatch" do
      {:ok, %{pid: pid, version: version}} = Tap.attach(self())
      on_exit(fn -> stop(pid) end)

      assert is_pid(pid)
      assert version == to_string(Application.spec(:merlin, :vsn))
      refute version == "unknown"
    end

    test "two sessions each get their own tap and their own feed" do
      parent = self()
      other = spawn_link(fn -> relay(parent) end)

      mine = attach!()
      {:ok, %{pid: theirs}} = Tap.attach(other, flush_ms: 200)
      on_exit(fn -> stop(theirs) end)

      refute mine == theirs

      Bus.publish(change([uniq(), "contact"]))

      assert_receive {:merlin_tap, [{:change, %Change{}}]}, 1_000
      assert_receive {:relayed, {:merlin_tap, [{:change, %Change{}}]}}, 1_000
    end
  end

  # --- what arrives ---------------------------------------------------------

  describe "forwarding" do
    test "a fact change arrives" do
      attach!()
      root = uniq()

      Bus.publish(change([root, "contact"]))

      assert_receive {:merlin_tap, [{:change, %Change{path: [^root, "contact"]}}]}, 1_000
    end

    test "an event arrives -- the thing that leaves no other trace" do
      attach!()
      root = uniq()

      Bus.emit(%Event{path: [root, "pressed"], payload: :double, at: 0, source: nil})

      assert_receive {:merlin_tap, [{:event, %Event{payload: :double}}]}, 1_000
    end

    test "an effect outcome arrives" do
      attach!()
      Merlin.Effects.perform([{:log, :info, "hello"}], rule: :r, dry_run: true)

      assert_receive {:merlin_tap, [{:effect, %Report{outcome: :dry_run}}]}, 1_000
    end

    test "items arrive oldest first" do
      attach!()
      root = uniq()

      for n <- 1..5, do: Bus.publish(change([root, "n"], n))

      assert_receive {:merlin_tap, items}, 1_000
      assert Enum.map(items, fn {:change, c} -> c.new end) == [1, 2, 3, 4, 5]
    end
  end

  # --- backpressure ---------------------------------------------------------

  describe "a burst" do
    test "fifty changes arrive as ONE batch, not fifty messages" do
      # A broker reconnect replays every retained message in about a second.
      # Forwarding each separately would flood the link and render fifty frames
      # nobody sees.
      attach!()
      root = uniq()

      for n <- 1..50, do: Bus.publish(change([root, "n"], n))

      assert_receive {:merlin_tap, items}, 1_000
      assert length(items) == 50
      refute_receive {:merlin_tap, _}, 300
    end

    test "past the bound the OLDEST are dropped, and the count is reported" do
      attach!(max_pending: 5)
      root = uniq()

      for n <- 1..10, do: Bus.publish(change([root, "n"], n))

      assert_receive {:merlin_tap, [{:dropped, dropped} | rest]}, 1_000

      assert dropped == 5
      assert length(rest) == 5

      # Drop-oldest, not drop-newest. In a live view the newest state is the
      # one worth having: a viewer who has fallen behind wants to know where
      # the house is NOW, not where it was five hundred changes ago.
      assert Enum.map(rest, fn {:change, c} -> c.new end) == [6, 7, 8, 9, 10]
    end

    test "the drop count resets with the batch it was reported in" do
      # It rides with the batch it applies to, so a client can say "42 dropped"
      # against the moment rather than as a running total it has to diff.
      tap = attach!(max_pending: 2, flush_ms: 50)
      root = uniq()

      for n <- 1..6, do: Bus.publish(change([root, "n"], n))
      assert_receive {:merlin_tap, [{:dropped, _} | _]}, 1_000

      Bus.publish(change([root, "later"], 99))
      assert_receive {:merlin_tap, items}, 1_000

      refute Enum.any?(items, &match?({:dropped, _}, &1)),
             "a batch with no drops must not carry the previous batch's count"

      assert Tap.stats(tap).dropped == 0
    end
  end

  # --- lifetime -------------------------------------------------------------

  describe "the client going away" do
    test "a dead client takes its tap with it" do
      # The case that matters: an SSH session dropped without a goodbye. A
      # leaked tap would stay subscribed at Bus.subscribe([]) -- every fact
      # change in the house -- for ever.
      client = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: tap}} = Tap.attach(client)
      ref = Process.monitor(tap)

      Process.exit(client, :kill)

      assert_receive {:DOWN, ^ref, :process, ^tap, :normal}, 1_000
    end

    test "and unsubscribes from the effects tap on the way out" do
      # Bus unsubscribes itself -- Registry monitors its entries. The effects
      # tap holds pids in a :persistent_term and does not, so a tap that failed
      # to say so would leak a subscriber that outlived its client.
      client = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: tap}} = Tap.attach(client)
      assert tap in Merlin.Effects.Tap.subscribers()

      ref = Process.monitor(tap)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^ref, :process, ^tap, :normal}, 1_000

      refute tap in Merlin.Effects.Tap.subscribers()
    end

    test "detach stops it deliberately" do
      client = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: tap}} = Tap.attach(client)

      assert :ok = Tap.detach(tap)
      refute Process.alive?(tap)
      refute tap in Merlin.Effects.Tap.subscribers()

      Process.exit(client, :kill)
    end

    test "attaching a client that is already gone does not join the firehose" do
      client = spawn(fn -> :ok end)
      ref = Process.monitor(client)
      assert_receive {:DOWN, ^ref, :process, ^client, _}

      {:ok, %{pid: tap}} = Tap.attach(client)

      # The monitor is taken before subscribing, so it fires immediately and
      # this exits without ever having joined.
      tap_ref = Process.monitor(tap)
      assert_receive {:DOWN, ^tap_ref, :process, ^tap, :normal}, 1_000
      refute tap in Merlin.Effects.Tap.subscribers()
    end
  end

  defp relay(parent) do
    receive do
      msg ->
        send(parent, {:relayed, msg})
        relay(parent)
    end
  end
end
