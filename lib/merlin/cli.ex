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

  @doc """
  The `merlin` entry point: a TUI with no arguments, a one-shot tool with them.

  The shape `screen` has. Bare `merlin` opens the interface; `merlin key list`
  answers and exits. One binary, because "the thing I run" and "the thing I
  script" being two names is a distinction nobody remembers at 3am.

  Distribution is started here rather than by the release, because `eval` boots
  a node without it. That is the right default for `merlin-key` -- a separate
  VM, no cluster -- and the wrong one for a client that has to reach the
  daemon, so the client asks for what it needs instead of the release offering
  it to everything.
  """
  @spec run([binary()]) :: :ok | no_return()
  def run(argv \\ argv())

  def run([]), do: tui(&Merlin.TUI.main/1, [])
  def run(["--once" | rest]), do: tui(&Merlin.TUI.once/1, once_opts(rest))
  def run(["key" | rest]), do: key(rest)
  def run(["preflight" | _]), do: Merlin.Preflight.run!()
  def run(["--version" | _]), do: version()
  def run([help | _]) when help in ["--help", "-h", "help"], do: usage()
  def run([other | _]), do: die("unknown command #{inspect(other)}. Try: merlin --help")

  # Every branch halts: success, failure and an unstartable distribution. Said
  # in a spec rather than worked around by loosening dialyzer's flags, which
  # would stop it noticing the next function that unexpectedly does not return.
  @spec tui((keyword() -> :ok | {:error, term()}), keyword()) :: no_return()
  defp tui(fun, opts) do
    case start_distribution() do
      :ok ->
        case fun.(opts) do
          :ok -> System.halt(0)
          {:error, _} -> System.halt(1)
        end

      {:error, reason} ->
        die("could not start distribution: #{inspect(reason)}")
    end
  end

  # A unique node name per session, so two operators on one host do not
  # collide, and the release's cookie, because the daemon will not talk to a
  # node that cannot present it.
  defp start_distribution do
    name = :"merlin-tui-#{System.unique_integer([:positive])}@127.0.0.1"

    case Node.start(name, name_domain: :longnames) do
      {:ok, _} ->
        case System.get_env("RELEASE_COOKIE") do
          nil -> :ok
          cookie -> Node.set_cookie(String.to_atom(cookie))
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp once_opts(rest) do
    {parsed, _, _} =
      OptionParser.parse(rest, strict: [pane: :string, cols: :integer, rows: :integer])

    [] |> put_pane(parsed[:pane]) |> put_size(parsed[:cols], parsed[:rows])
  end

  defp put_pane(opts, nil), do: opts

  defp put_pane(opts, pane) do
    # Matched against Merlin.TUI.Session.panes/0 rather than converted.
    #
    # String.to_existing_atom/1 was wrong here and only failed once deployed: a
    # client boots with `eval`, which loads modules LAZILY, so :rules and
    # :devices did not exist yet in a VM that had not touched the view modules.
    # `--pane facts` worked purely because it is the Session struct's default.
    #
    # Comparing to_string/1 of the real list has neither problem: it forces the
    # module to load, it cannot create an atom, and the list of panes has one
    # definition instead of two that must agree.
    case Enum.find(Merlin.TUI.Session.panes(), &(to_string(&1) == pane)) do
      nil -> die("no pane #{inspect(pane)}. Try: facts, rules, stream, devices")
      found -> Keyword.put(opts, :pane, found)
    end
  end

  defp put_size(opts, cols, rows) when is_integer(cols) and is_integer(rows),
    do: Keyword.put(opts, :size, {cols, rows})

  defp put_size(opts, _cols, _rows), do: opts

  @spec version() :: no_return()
  defp version do
    IO.puts("merlin #{Application.spec(:merlin, :vsn)}")
    System.halt(0)
  end

  @spec usage() :: no_return()
  defp usage do
    IO.puts("""
    merlin -- the operator interface to a merlin daemon

      merlin                  open the terminal interface
      merlin --once [opts]    render one frame to stdout and exit
                              --pane facts|rules|stream|devices
                              --cols N --rows N
      merlin key ...          manage ingress keys (add, list, rm, import)
      merlin preflight        validate the configuration and exit
      merlin --version

    With no arguments it opens the interface; with any, it answers and exits.

    Inside:
      1-4     switch pane        j/k  move           /  filter
      :       command line       q    quit
      y       confirm            !    confirm AND override dry run
    """)

    System.halt(0)
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

  defp key(_) do
    die("""
    usage: merlin key <command>   (or the merlin-key alias)

      add --topic T [--label L] [--expires N]
      list
      rm (--id N | --prefix P | --key K)
      import --from PATH
    """)
  end

  defp stamp(nil), do: "never"

  defp stamp(unix) do
    unix |> DateTime.from_unix!() |> DateTime.to_string()
  end

  @spec die(binary()) :: no_return()
  defp die(message) do
    IO.puts(:stderr, "merlin: #{message}")
    System.halt(1)
  end
end
