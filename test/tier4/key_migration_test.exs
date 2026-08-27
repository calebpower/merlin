defmodule Merlin.KeyMigrationTest do
  @moduledoc """
  Tier 4: importing the Python daemon's key database.

  This path had no tests at all until dialyzer pointed at it, which is how
  `Sqlite3.open(path, [:readonly])` -- a list of bare atoms where a keyword
  list belongs -- survived. It would have failed at the moment it was used,
  which is during the cutover, with the phone's key as the thing at stake.

  The read-only claim matters beyond tidiness. `merlin-key import` prints "the
  source database was opened read-only and is unchanged" to the operator, and
  the rollback plan depends on it being true: the old daemon has to be able to
  keep serving from that exact file if the cutover is abandoned.
  """

  use ExUnit.Case, async: true

  @moduletag :tier4

  alias Exqlite.Sqlite3
  alias Merlin.KeyStore

  setup do
    dir = Path.join(System.tmp_dir!(), "merlin-migrate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    legacy = Path.join(dir, "legacy.db")
    new = Path.join(dir, "merlin.db")

    %{dir: dir, legacy: legacy, new: new}
  end

  # The Python's schema, exactly: api.py stored the plaintext key alongside the
  # topic it authorised, and the key WAS the capability.
  defp seed_legacy(path, pairs) do
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE API_Key (
        id    INTEGER PRIMARY KEY AUTOINCREMENT,
        topic TEXT NOT NULL,
        key   TEXT NOT NULL
      )
      """)

    for {topic, key} <- pairs do
      {:ok, stmt} = Sqlite3.prepare(db, "INSERT INTO API_Key (topic, key) VALUES (?1, ?2)")
      :ok = Sqlite3.bind(stmt, [topic, key])
      :done = Sqlite3.step(db, stmt)
      :ok = Sqlite3.release(db, stmt)
    end

    :ok = Sqlite3.close(db)
    :ok
  end

  describe "importing the legacy database" do
    test "the keys come across and still resolve", %{legacy: legacy, new: new} do
      seed_legacy(legacy, [
        {"http/mobile/ariia/state", "legacy-key-one"},
        {"other/topic", "legacy-key-two"}
      ])

      KeyStore.with_db(new, fn conn ->
        assert {:ok, 2} = KeyStore.import_legacy(conn, legacy)

        # The phone keeps working across the cutover without being
        # reconfigured -- which is the entire point of importing rather than
        # reminting.
        assert {:ok, "http/mobile/ariia/state", _id} =
                 KeyStore.resolve(conn, "legacy-key-one")

        assert {:ok, "other/topic", _id} = KeyStore.resolve(conn, "legacy-key-two")
      end)
    end

    # The Python stored plaintext. Importing must not carry that forward, or
    # the rewrite has migrated the defect along with the data.
    test "imported keys are stored hashed, not in plaintext", %{legacy: legacy, new: new} do
      seed_legacy(legacy, [{"a/topic", "super-secret-legacy-key"}])

      KeyStore.with_db(new, fn conn ->
        assert {:ok, 1} = KeyStore.import_legacy(conn, legacy)
      end)

      contents = File.read!(new)

      refute contents =~ "super-secret-legacy-key",
             "the plaintext key is sitting in the new database file"
    end

    # The rollback plan depends on this sentence being true.
    test "the legacy database is not modified", %{legacy: legacy, new: new} do
      seed_legacy(legacy, [{"a/topic", "k1"}, {"b/topic", "k2"}])

      before = File.read!(legacy)
      before_stat = File.stat!(legacy)

      KeyStore.with_db(new, fn conn ->
        assert {:ok, 2} = KeyStore.import_legacy(conn, legacy)
      end)

      assert File.read!(legacy) == before, "the legacy database was modified by the import"
      assert File.stat!(legacy).size == before_stat.size

      # Opening read-only must also leave no WAL or journal beside it: a
      # sidecar file is a write, and it is what the old daemon would trip over.
      refute File.exists?(legacy <> "-wal"), "the import created a WAL beside the legacy database"
      refute File.exists?(legacy <> "-journal"), "the import created a journal file"
    end

    test "importing twice does not duplicate", %{legacy: legacy, new: new} do
      seed_legacy(legacy, [{"a/topic", "k1"}])

      KeyStore.with_db(new, fn conn ->
        assert {:ok, 1} = KeyStore.import_legacy(conn, legacy)
        KeyStore.import_legacy(conn, legacy)

        assert KeyStore.count(conn) == 1,
               "a second import duplicated the keys -- a cutover that is retried should be safe"
      end)
    end

    test "a minted key's row carries a plain integer id", %{new: new} do
      # It carried {:ok, 5} -- last_insert_rowid/1 answers a tagged tuple and
      # it was taken unwrapped, against a key_row() type promising an integer.
      # `merlin-key add` printed the tuple, and an id comparison compared the
      # wrong thing.
      KeyStore.with_db(new, fn conn ->
        assert {:ok, _plaintext, row} = KeyStore.mint(conn, "a/topic", label: "l")

        assert is_integer(row.id), "row.id is #{inspect(row.id)}, not an integer"
        assert row.id > 0

        # And it must be the id the store actually uses, not merely an integer.
        assert Enum.any?(KeyStore.list(conn), &(&1.id == row.id)),
               "the id mint/3 returned does not match the one in the database"
      end)
    end

    test "a missing legacy database is an error, not a crash", %{dir: dir, new: new} do
      KeyStore.with_db(new, fn conn ->
        assert {:error, _} = KeyStore.import_legacy(conn, Path.join(dir, "nope.db"))
      end)
    end
  end
end
