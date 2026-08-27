defmodule Merlin.CLI do
  @moduledoc """
  Key management, from the command line.

  Reached through `bin/merlin-key`, which is an overlay wrapping
  `bin/merlin eval`. That boots a fresh BEAM with the release's code paths and
  its applications loaded but *not started*, in a separate OS process -- which
  is what gives all three required properties at once: it works with the daemon
  stopped, it works with the daemon running (SQLite in WAL mode handles the
  concurrency), and it resolves config exactly as the daemon does.

  Not an escript: an escript needs Elixir's .beam files present on the target,
  and the entire point of `include_erts: true` is that the target needs nothing
  installed.

  ## The plaintext appears once

  Keys are stored hashed, so `list` cannot show them and `add` prints the
  secret exactly once, to stdout. That is a deliberate downgrade in convenience
  from the Python, which stored keys in plaintext and could therefore print
  them whenever asked -- which is also why a copy of every key sat in a
  gitignored database and, via the body logging in `api.py:31`, in the archived
  logs on your workstation.
  """

  alias Merlin.KeyStore

  @doc """
  Arguments, from the environment.

  `bin/merlin eval` evaluates an expression and does not fill `System.argv/0`
  from trailing shell arguments, so the overlay passes them in `MERLIN_ARGV`,
  one per line. That also keeps user input out of the evaluated expression --
  interpolating arguments into code is not a thing to do in a script whose
  whole job is handling credentials.
  """
  @spec argv() :: [binary()]
  def argv do
    case System.get_env("MERLIN_ARGV") do
      nil -> []
      "" -> []
      raw -> String.split(raw, "\n", trim: true)
    end
  end

  @doc "Entry point. `Merlin.CLI.main(:key, Merlin.CLI.argv())`."
  def main(:key, argv), do: key(argv)

  def main(other, _argv) do
    IO.puts(:stderr, "unknown command: #{inspect(other)}")
    System.halt(2)
  end

  defp key(["add" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest, strict: [topic: :string, label: :string, expires: :integer])

    case opts[:topic] do
      nil ->
        die("--topic is required when adding a key")

      topic ->
        KeyStore.with_db(fn db ->
          {:ok, plaintext, row} =
            KeyStore.mint(db, topic,
              label: opts[:label],
              expires_in_days: opts[:expires]
            )

          IO.puts("")
          IO.puts("  key:    #{plaintext}")
          IO.puts("  topic:  #{row.topic}")
          IO.puts("  prefix: #{row.prefix}")
          IO.puts("")
          IO.puts("  This is the only time the key will be shown. It is stored hashed.")
          IO.puts("")
        end)
    end
  end

  defp key(["list" | _]) do
    KeyStore.with_db(fn db ->
      rows = KeyStore.list(db)

      if rows == [] do
        IO.puts("no keys")
      else
        IO.puts(
          String.pad_trailing("ID", 5) <>
            String.pad_trailing("PREFIX", 10) <>
            String.pad_trailing("TOPIC", 34) <>
            String.pad_trailing("LABEL", 14) <> "LAST USED"
        )

        for r <- rows do
          IO.puts(
            String.pad_trailing(to_string(r.id), 5) <>
              String.pad_trailing(r.prefix, 10) <>
              String.pad_trailing(r.topic, 34) <>
              String.pad_trailing(r.label || "-", 14) <> stamp(r.last_used_at)
          )
        end
      end
    end)
  end

  defp key(["rm" | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [id: :integer, prefix: :string, key: :string])

    selector =
      cond do
        opts[:id] -> {:id, opts[:id]}
        opts[:prefix] -> {:prefix, opts[:prefix]}
        opts[:key] -> {:key, opts[:key]}
        true -> nil
      end

    if is_nil(selector) do
      die("one of --id, --prefix or --key is required")
    else
      KeyStore.with_db(fn db ->
        {:ok, removed} = KeyStore.delete(db, selector)

        # The Python printed "Removed key" whether or not a row matched.
        case removed do
          0 -> die("no key matched #{inspect(selector)}")
          n -> IO.puts("removed #{n} key(s)")
        end
      end)
    end
  end

  defp key(["import" | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [from: :string])

    case opts[:from] do
      nil ->
        die("--from /path/to/old/merlin.db is required")

      legacy ->
        KeyStore.with_db(fn db ->
          case KeyStore.import_legacy(db, legacy) do
            {:ok, n} ->
              IO.puts("imported #{n} key(s) from #{legacy}")
              IO.puts("the source database was opened read-only and is unchanged")

            {:error, reason} ->
              die("import failed: #{inspect(reason)}")
          end
        end)
    end
  end

  defp key(_), do: die("usage: merlin-key (add --topic T [--label L] [--expires N] | list | rm (--id N|--prefix P|--key K) | import --from PATH)")

  defp stamp(nil), do: "never"

  defp stamp(unix) do
    unix |> DateTime.from_unix!() |> DateTime.to_string()
  end

  defp die(message) do
    IO.puts(:stderr, "merlin-key: #{message}")
    System.halt(1)
  end
end
