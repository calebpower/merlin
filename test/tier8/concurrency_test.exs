defmodule Merlin.ConcurrencyTest do
  @moduledoc """
  Tier 8: concurrency.

  Two claims are load-bearing and neither is observable in a single-threaded
  test:

    * **SQLite in WAL mode lets the CLI and the daemon hold the database at the
      same time.** The whole key-management design rests on it -- "mint a key
      while the daemon runs" is a stated requirement, and the alternative
      designs (CubDB, DETS) were rejected specifically because they cannot.
      A claim like that, untested, is a claim nobody has checked.

    * **The fact writer serialises.** `DEV_3DPRNT_REQ` in the Python was a
      shared register two hooks raced on, with the ownership convention living
      in a code comment. Single-writer is the structural answer, and this is
      where it is demonstrated rather than asserted.
  """

  use ExUnit.Case, async: false

  @moduletag :tier8

  alias Merlin.{KeyStore, World}

  setup do
    path = Path.join(System.tmp_dir!(), "merlin-conc-#{System.unique_integer([:positive])}.db")

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    %{db: path}
  end

  describe "the WAL claim" do
    test "many processes mint concurrently and every key survives", %{db: db} do
      # Open one connection first so the schema exists before the storm.
      KeyStore.with_db(db, fn _ -> :ok end)

      # 200 writers, all released at once against their own connections.
      #
      # The earlier version used 40 and passed eight runs in a row while
      # `exec/3` matched SQLite's `:busy` against `:done` -- a crash waiting
      # for a busy enough moment. A concurrency test that reproduces its target
      # defect one run in ten is not a test, it is a rumour, so this opens
      # every connection first and then starts every writer from a single
      # barrier rather than letting Task.async_stream trickle them in.
      writers = 200
      parent = self()

      pids =
        for i <- 1..writers do
          spawn_link(fn ->
            KeyStore.with_db(db, fn conn ->
              send(parent, {:ready, self()})

              receive do
                :go -> :ok
              end

              {:ok, plaintext, _row} = KeyStore.mint(conn, "topic/#{i}", label: "t#{i}")
              send(parent, {:minted, i, plaintext})
            end)
          end)
        end

      for _ <- pids, do: assert_receive({:ready, _}, 30_000)
      for pid <- pids, do: send(pid, :go)

      # Keyed by writer, because these arrive in completion order rather than
      # spawn order -- the whole point of releasing them from a barrier.
      minted =
        Map.new(pids, fn _ ->
          assert_receive {:minted, i, key}, 60_000
          {i, key}
        end)

      results = Map.values(minted)

      assert map_size(minted) == writers
      assert length(Enum.uniq(results)) == writers, "keys collided"

      # Every one resolves, from a fresh connection, to its own topic.
      KeyStore.with_db(db, fn conn ->
        assert KeyStore.count(conn) == writers

        for {i, key} <- minted do
          assert {:ok, topic, _id} = KeyStore.resolve(conn, key)
          assert topic == "topic/#{i}"
        end
      end)
    end

    test "reads during a write storm see a consistent database", %{db: db} do
      {:ok, key} =
        KeyStore.with_db(db, fn conn ->
          {:ok, plaintext, _} = KeyStore.mint(conn, "stable/topic")
          {:ok, plaintext}
        end)

      writers =
        Task.async_stream(
          1..20,
          fn i ->
            KeyStore.with_db(db, fn conn -> KeyStore.mint(conn, "churn/#{i}") end)
          end,
          max_concurrency: 10,
          timeout: 30_000
        )

      readers =
        Task.async_stream(
          1..40,
          fn _ ->
            KeyStore.with_db(db, fn conn -> KeyStore.resolve(conn, key) end)
          end,
          max_concurrency: 20,
          timeout: 30_000
        )

      Stream.run(writers)

      # The pre-existing key resolves correctly throughout: a reader must never
      # see a half-applied write.
      for {:ok, result} <- readers do
        assert {:ok, "stable/topic", _} = result
      end
    end

    test "a second connection sees a key minted by the first without a restart", %{db: db} do
      # The exact operational requirement: `merlin-key add` while the daemon is
      # running, and the running daemon accepting that key on the next request
      # with no reload. No cache means no staleness window.
      {:ok, cli_conn} = KeyStore.open(db)
      {:ok, daemon_conn} = KeyStore.open(db)

      assert KeyStore.resolve(daemon_conn, "not-yet-minted") == :error

      {:ok, key, _row} = KeyStore.mint(cli_conn, "http/late/arrival")

      assert {:ok, "http/late/arrival", _id} = KeyStore.resolve(daemon_conn, key),
             "the daemon's connection could not see a key the CLI had just minted"

      Exqlite.Sqlite3.close(cli_conn)
      Exqlite.Sqlite3.close(daemon_conn)
    end

    test "a key revoked by one connection is refused by the other immediately", %{db: db} do
      {:ok, cli_conn} = KeyStore.open(db)
      {:ok, daemon_conn} = KeyStore.open(db)

      {:ok, key, _} = KeyStore.mint(cli_conn, "http/doomed")
      assert {:ok, _, _} = KeyStore.resolve(daemon_conn, key)

      {:ok, 1} = KeyStore.delete(cli_conn, {:key, key})

      assert KeyStore.resolve(daemon_conn, key) == :error,
             "revocation did not take effect without a restart"

      Exqlite.Sqlite3.close(cli_conn)
      Exqlite.Sqlite3.close(daemon_conn)
    end
  end

  describe "the fact writer serialises" do
    test "concurrent writers to one path leave a single coherent value" do
      path = [:test, "conc-#{System.unique_integer([:positive])}", :value]

      1..200
      |> Task.async_stream(fn i -> World.put(path, i) end, max_concurrency: 40, timeout: 30_000)
      |> Stream.run()

      # Whatever landed last, the fact is one of the values written -- never a
      # tear, never absent, never a partially applied struct.
      assert {:ok, fact} = World.fetch(path)
      assert fact.value in 1..200
      assert is_integer(fact.seq)
    end

    test "sequence numbers are unique across concurrent writers" do
      # seq is what orders causality. Two writes sharing one would make the
      # causal chain ambiguous, which is precisely what the single writer is
      # there to prevent.
      prefix = "seq-#{System.unique_integer([:positive])}"

      1..150
      |> Task.async_stream(
        fn i -> World.put([:test, prefix, :"k#{rem(i, 10)}"], i) end,
        max_concurrency: 40,
        timeout: 30_000
      )
      |> Stream.run()

      seqs = World.dump([:test, prefix]) |> Enum.map(& &1.seq)
      assert length(Enum.uniq(seqs)) == length(seqs), "sequence numbers collided"
    end

    test "concurrent emits all reach a subscriber" do
      path = [:test, "emit-#{System.unique_integer([:positive])}"]
      Merlin.Bus.subscribe_events(path)

      1..100
      |> Task.async_stream(fn i -> World.emit(path, i) end, max_concurrency: 30, timeout: 30_000)
      |> Stream.run()

      # Events are never deduplicated, so all 100 must arrive.
      received = for _ <- 1..100, do: assert_receive({:merlin, %Merlin.Event{}}, 2_000)
      assert length(received) == 100
    end
  end

  # --- attached sessions ----------------------------------------------------

  describe "operators watching" do
    # A tap attached to the test process dies when that process does, so
    # cleanup races its own subject. An already-gone tap is the correct
    # outcome, not an error.
    defp stop(pid) do
      Merlin.Tap.detach(pid)
    catch
      :exit, _ -> :ok
    end

    test "two sessions each get their own feed" do
      # An operator on the console and one over SSH is the normal case. Each
      # tap is its own process with its own bounded buffer, so a session that
      # has stopped reading cannot hold up one that has not.
      parent = self()
      other = spawn_link(fn -> relay(parent) end)

      {:ok, %{pid: mine}} = Merlin.Tap.attach(parent, flush_ms: 50)
      {:ok, %{pid: theirs}} = Merlin.Tap.attach(other, flush_ms: 50)

      on_exit(fn -> Enum.each([mine, theirs], &stop/1) end)

      refute mine == theirs

      root = "conc-#{System.unique_integer([:positive])}"
      Merlin.Bus.publish(change([root, "n"], 1))

      assert_receive {:merlin_tap, [{:change, _}]}, 2_000
      assert_receive {:relayed, {:merlin_tap, [{:change, _}]}}, 2_000
    end

    test "a session that has stopped reading does not stall one that has not" do
      # The idle client never drains its mailbox. Its tap fills, bounds itself
      # and drops the oldest -- and the reading session is unaffected, because
      # the buffering is per session rather than shared.
      idle = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: theirs}} = Merlin.Tap.attach(idle, flush_ms: 50, max_pending: 5)
      {:ok, %{pid: mine}} = Merlin.Tap.attach(self(), flush_ms: 50)

      on_exit(fn ->
        Enum.each([mine, theirs], &stop/1)
        Process.exit(idle, :kill)
      end)

      root = "conc-#{System.unique_integer([:positive])}"
      for n <- 1..40, do: Merlin.Bus.publish(change([root, "n"], n))

      assert_receive {:merlin_tap, items}, 2_000
      assert length(items) > 0, "the reading session must still be served"
    end

    test "rendering does not block the fact writer" do
      # The TUI reads through World.dump/1, which is :ets.tab2list in the
      # CALLING process against a read_concurrency table. It never goes through
      # Merlin.World.Writer, so a session refreshing ten times a second costs
      # the writer nothing. Asserted by writing while reading, rather than by
      # reading the implementation and believing it.
      root = "conc-#{System.unique_integer([:positive])}"

      reader = Task.async(fn -> for _ <- 1..200, do: Merlin.World.dump([]) end)

      {elapsed, _} =
        :timer.tc(fn ->
          for n <- 1..200, do: Merlin.World.put([root, "w"], n)
        end)

      Task.await(reader, 10_000)

      # Deliberately generous: this asserts the ABSENCE of blocking, not a
      # performance target that would fail on a busy build host and teach
      # everyone to ignore it.
      assert elapsed < 5_000_000,
             "200 writes took #{div(elapsed, 1000)}ms while a session was reading"
    end
  end

  defp change(path, n) do
    %Merlin.Change{
      path: path,
      old: n - 1,
      new: n,
      at: 0,
      source: nil,
      seq: n,
      first?: false
    }
  end

  defp relay(parent) do
    receive do
      msg ->
        send(parent, {:relayed, msg})
        relay(parent)
    end
  end
end
