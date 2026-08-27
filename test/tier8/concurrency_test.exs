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

      results =
        1..40
        |> Task.async_stream(
          fn i ->
            KeyStore.with_db(db, fn conn ->
              {:ok, plaintext, _row} = KeyStore.mint(conn, "topic/#{i}", label: "t#{i}")
              plaintext
            end)
          end,
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, key} -> key end)

      assert length(results) == 40
      assert length(Enum.uniq(results)) == 40, "keys collided"

      # Every one resolves, from a fresh connection, to its own topic.
      KeyStore.with_db(db, fn conn ->
        assert KeyStore.count(conn) == 40

        for {key, i} <- Enum.with_index(results, 1) do
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
end
