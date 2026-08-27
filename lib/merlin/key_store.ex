defmodule Merlin.KeyStore do
  @moduledoc """
  API keys, in SQLite.

  ## The capability model, preserved

  `api.py` had a genuinely tidy idea buried in it: **the key is the topic**.
  There is no topic parameter in a `/snitch` request -- looking the key up
  *resolves* which topic the payload is injected as, so a key can only ever
  write to the one topic it was minted for. A leaked key is a capability to
  publish one thing, not an account.

  That is kept exactly. What changes is everything around it.

  ## What changed, and why

  `main.py:112` stored raw `uuid4()` strings in plaintext. These are 128-bit
  random tokens, so a plain SHA-256 is the right primitive -- Argon2 would be
  theatre against an input with that much entropy -- but storing them
  reversibly was not. Keys are now `sha256` hex, compared with
  `Plug.Crypto.secure_compare/2`, and the plaintext exists exactly once: on
  stdout, at mint time.

  Rows also gain a prefix (for identification without the secret), a label, and
  created/last-used/expiry/revoked timestamps. `--rm-key` in the Python
  reported success unconditionally, whether or not a row matched.

  ## Connection per operation, deliberately

  Every function opens and closes its own connection. That sounds wasteful and
  is not: `/snitch` fires when a phone reports GPS, so this is microseconds on
  a table with fewer than ten rows.

  What it buys is the requirement outright: the CLI must mint keys while the
  daemon is **stopped**, and the running daemon must see CLI changes **without
  a restart**. With WAL and a busy timeout both hold with no cache, no
  invalidation, and no staleness window. This is how the Python worked too, and
  it was the one thing about its key handling worth keeping.
  """

  alias Exqlite.Sqlite3

  @schema_version 1

  @type key_row :: %{
          id: integer(),
          prefix: binary(),
          topic: binary(),
          label: binary() | nil,
          created_at: integer(),
          last_used_at: integer() | nil,
          expires_at: integer() | nil,
          revoked_at: integer() | nil
        }

  # --- lifecycle ------------------------------------------------------------

  @doc "Open the database, applying migrations. Returns a connection to close."
  @spec open(binary()) :: {:ok, term()} | {:error, term()}
  def open(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Sqlite3.open(path) do
      # WAL is what allows the CLI and the daemon to hold the file at the same
      # time. busy_timeout handles lock contention but NOT a write-write
      # conflict, which SQLite reports immediately and which only a rollback
      # and retry can resolve -- see the retry around exec/query below.
      :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
      :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
      migrate(conn)
      {:ok, conn}
    end
  end

  @doc "Run `fun` with an open connection, closing it afterwards."
  @spec with_db(binary() | nil, (term() -> result)) :: result when result: term()
  def with_db(path \\ nil, fun) do
    path = path || Merlin.Config.db_path()
    {:ok, conn} = open(path)

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp migrate(conn) do
    case user_version(conn) do
      v when v >= @schema_version ->
        :ok

      0 ->
        :ok =
          Sqlite3.execute(conn, """
          CREATE TABLE IF NOT EXISTS api_key (
            id           INTEGER PRIMARY KEY,
            key_hash     TEXT NOT NULL UNIQUE,
            key_prefix   TEXT NOT NULL,
            topic        TEXT NOT NULL,
            label        TEXT,
            created_at   INTEGER NOT NULL,
            last_used_at INTEGER,
            expires_at   INTEGER,
            revoked_at   INTEGER
          )
          """)

        :ok = Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS api_key_hash ON api_key(key_hash)")
        :ok = Sqlite3.execute(conn, "PRAGMA user_version=#{@schema_version}")
        :ok
    end
  end

  defp user_version(conn) do
    case query(conn, "PRAGMA user_version", []) do
      [[v]] -> v
      _ -> 0
    end
  end

  # --- minting and revoking -------------------------------------------------

  @doc """
  Mint a key for `topic`.

  Returns `{:ok, plaintext, row}`. The plaintext is returned exactly once and
  is not recoverable afterwards -- callers must show it to the operator or
  lose it.
  """
  @spec mint(term(), binary(), keyword()) :: {:ok, binary(), key_row()}
  def mint(conn, topic, opts \\ []) when is_binary(topic) do
    plaintext = generate()
    hash = hash(plaintext)
    prefix = binary_part(plaintext, 0, 8)
    now = System.os_time(:second)

    expires_at =
      case Keyword.get(opts, :expires_in_days) do
        nil -> nil
        days when is_integer(days) -> now + days * 86_400
      end

    :ok =
      exec(
        conn,
        """
        INSERT INTO api_key (key_hash, key_prefix, topic, label, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [hash, prefix, topic, Keyword.get(opts, :label), now, expires_at]
      )

    # last_insert_rowid/1 answers {:ok, integer}. Taking it unwrapped put
    # `id: {:ok, 5}` into every row mint/3 returned, against a key_row() type
    # that says `id: integer()` -- so `merlin-key add` reported a tuple as the
    # key's id, and any caller comparing ids compared the wrong thing.
    {:ok, id} = Sqlite3.last_insert_rowid(conn)

    {:ok, plaintext,
     %{
       id: id,
       prefix: prefix,
       topic: topic,
       label: Keyword.get(opts, :label),
       created_at: now,
       last_used_at: nil,
       expires_at: expires_at,
       revoked_at: nil
     }}
  end

  @doc "Every key, newest first. Never includes anything secret."
  @spec list(term()) :: [key_row()]
  def list(conn) do
    conn
    |> query(
      """
      SELECT id, key_prefix, topic, label, created_at, last_used_at, expires_at, revoked_at
      FROM api_key ORDER BY id DESC
      """,
      []
    )
    |> Enum.map(fn [id, prefix, topic, label, created, used, expires, revoked] ->
      %{
        id: id,
        prefix: prefix,
        topic: topic,
        label: label,
        created_at: created,
        last_used_at: used,
        expires_at: expires,
        revoked_at: revoked
      }
    end)
  end

  @doc """
  Delete a key by id, prefix, or full plaintext.

  Returns `{:ok, count}`. Unlike the Python's `--rm-key`, which printed
  "Removed key" whether or not a row matched, a count of zero is visible to
  the caller.
  """
  @spec delete(term(), {:id, integer()} | {:prefix, binary()} | {:key, binary()}) ::
          {:ok, non_neg_integer()}
  def delete(conn, selector) do
    before = count(conn)

    case selector do
      {:id, id} -> exec(conn, "DELETE FROM api_key WHERE id = ?", [id])
      {:prefix, p} -> exec(conn, "DELETE FROM api_key WHERE key_prefix = ?", [p])
      {:key, k} -> exec(conn, "DELETE FROM api_key WHERE key_hash = ?", [hash(k)])
    end

    {:ok, before - count(conn)}
  end

  @doc "Number of keys."
  @spec count(term()) :: non_neg_integer()
  def count(conn) do
    case query(conn, "SELECT COUNT(*) FROM api_key", []) do
      [[n]] -> n
      _ -> 0
    end
  end

  # --- the hot path ---------------------------------------------------------

  @doc """
  Resolve a presented key to the topic it may write to.

  Returns `{:ok, topic, id}`, or `:error` for unknown, revoked and expired
  keys alike -- the caller must not be able to tell those apart, and neither
  must the client.
  """
  @spec resolve(term(), binary()) :: {:ok, binary(), integer()} | :error
  def resolve(_conn, key) when not is_binary(key), do: :error
  def resolve(_conn, ""), do: :error

  def resolve(conn, key) do
    presented = hash(key)
    now = System.os_time(:second)

    rows =
      query(
        conn,
        "SELECT id, key_hash, topic, expires_at, revoked_at FROM api_key WHERE key_hash = ?",
        [presented]
      )

    case rows do
      [[id, stored, topic, expires_at, revoked_at]] ->
        cond do
          # Constant-time even though the lookup already used the hash as an
          # index. Cheap, and it keeps the comparison honest if the query ever
          # changes shape.
          not Plug.Crypto.secure_compare(stored, presented) -> :error
          not is_nil(revoked_at) -> :error
          is_integer(expires_at) and expires_at <= now -> :error
          true -> {:ok, topic, id}
        end

      _ ->
        :error
    end
  end

  @doc """
  Record that a key was used.

  Throttled by the caller, not here: a phone reporting every 30 seconds would
  otherwise turn a read path into a write on every request.
  """
  @spec touch(term(), integer()) :: :ok
  def touch(conn, id) do
    exec(conn, "UPDATE api_key SET last_used_at = ? WHERE id = ?", [System.os_time(:second), id])
  end

  # --- migration from the Python database -----------------------------------

  @doc """
  Import keys from the Python daemon's `API_Key(topic, key)` table.

  The old database is opened **read-only** and never written, so it remains a
  complete rollback artifact. Existing keys keep working: your phone is not
  reconfigured during the cutover window, which is exactly when you do not
  want another moving part.
  """
  @spec import_legacy(term(), binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import_legacy(conn, legacy_path) do
    if File.exists?(legacy_path) do
      # `mode: :readonly`, a keyword -- NOT `[:readonly]`, which is a list of
      # bare atoms that exqlite does not accept. Dialyzer caught it: the call
      # could not succeed. The docstring above and the line the CLI prints to
      # the operator both promise the legacy database is untouched, and during
      # a cutover that promise is the rollback plan.
      {:ok, old} = Sqlite3.open(legacy_path, mode: :readonly)

      try do
        rows = query(old, "SELECT topic, key FROM API_Key", [])
        now = System.os_time(:second)

        imported =
          Enum.count(rows, fn [topic, key] ->
            prefix = binary_part(key, 0, min(8, byte_size(key)))

            case exec(
                   conn,
                   """
                   INSERT OR IGNORE INTO api_key
                     (key_hash, key_prefix, topic, label, created_at)
                   VALUES (?, ?, ?, 'imported', ?)
                   """,
                   [hash(key), prefix, topic, now]
                 ) do
              :ok -> true
              _ -> false
            end
          end)

        {:ok, imported}
      after
        Sqlite3.close(old)
      end
    else
      {:error, {:missing, legacy_path}}
    end
  end

  # --- primitives -----------------------------------------------------------

  @doc "Hash a key for storage and comparison."
  @spec hash(binary()) :: binary()
  def hash(key) when is_binary(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  @doc "A fresh key. 192 bits of entropy, URL-safe."
  @spec generate() :: binary()
  def generate, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  # `PRAGMA busy_timeout` is necessary and NOT sufficient.
  #
  # SQLite's busy handler cannot resolve a write-write conflict in WAL mode:
  # when two connections have both begun writing, one gets SQLITE_BUSY
  # immediately and no amount of waiting inside SQLite will help, because the
  # only resolution is for the loser to roll back and start again. exqlite
  # surfaces that as `:busy`, and matching it against `:done` turns ordinary
  # contention into a crash.
  #
  # That is precisely the case merlin is built around: `merlin-key add` runs
  # while the daemon is serving. It is rare enough to have passed tier 8 eight
  # times in a row and real enough to lose someone their phone key at the
  # moment they are minting one.
  @busy_attempts 8
  @busy_backoff_ms 25

  defp exec(conn, sql, args), do: exec(conn, sql, args, 1)

  defp exec(conn, sql, args, attempt) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, args)

    case Sqlite3.step(conn, stmt) do
      :done ->
        :ok = Sqlite3.release(conn, stmt)
        :ok

      :busy ->
        :ok = Sqlite3.release(conn, stmt)
        retry(conn, sql, args, attempt, &exec/4)
    end
  end

  defp query(conn, sql, args), do: query(conn, sql, args, 1)

  defp query(conn, sql, args, attempt) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, args)

    case Sqlite3.fetch_all(conn, stmt) do
      {:ok, rows} ->
        :ok = Sqlite3.release(conn, stmt)
        rows

      {:error, :busy} ->
        :ok = Sqlite3.release(conn, stmt)
        retry(conn, sql, args, attempt, &query/4)
    end
  end

  # Bounded, and it gives up loudly. An unbounded retry against a genuinely
  # stuck writer is a hang, which is harder to diagnose than a crash.
  defp retry(_conn, sql, _args, attempt, _fun) when attempt >= @busy_attempts do
    raise RuntimeError,
          "sqlite stayed busy through #{@busy_attempts} attempts: #{sql}. " <>
            "Another process is holding a write transaction open."
  end

  defp retry(conn, sql, args, attempt, fun) do
    # Jittered, so two contending writers do not retry in lockstep forever.
    Process.sleep(@busy_backoff_ms * attempt + :rand.uniform(@busy_backoff_ms))
    fun.(conn, sql, args, attempt + 1)
  end

  @doc "Attempts made against a busy database before giving up. Exposed for tests."
  def busy_attempts, do: @busy_attempts
end
