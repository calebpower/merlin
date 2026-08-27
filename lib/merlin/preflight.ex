defmodule Merlin.Preflight do
  @moduledoc """
  Refuse to start rather than flap.

  This runs from the rc.d script's `start_precmd`, as the `merlin` user, before
  the supervision tree exists. If it exits non-zero, `service merlin-ex start`
  prints the reason and returns non-zero -- instead of the daemon dying in a
  loop under `daemon -R 5` while you read logs to work out why.

  Checks not yet implemented are reported as **pending**, never as passes. A
  preflight whose unimplemented half reads as green is worse than no preflight,
  because it converts an unknown into a false assurance. As of the deployment
  survey there are none left pending -- six of the nine were still stubs from
  the skeleton, which meant `merlin-preflight` exited 0 having verified almost
  nothing: not the config, not the secrets, not the database, not the broker,
  not the ports.
  """

  require Logger

  @type result ::
          {:ok, String.t(), String.t()}
          | {:error, String.t(), String.t()}
          | {:pending, String.t(), String.t()}

  @doc """
  Run every check, print a report, and halt non-zero on any failure.

  Invoked as `bin/merlin eval 'Merlin.Preflight.run!()'`.
  """
  @spec run!() :: no_return()
  def run! do
    results = run()

    Enum.each(results, fn
      {:ok, name, detail} -> IO.puts("ok       #{pad(name)} #{detail}")
      {:pending, name, why} -> IO.puts("pending  #{pad(name)} #{why}")
      {:error, name, why} -> IO.puts("FAIL     #{pad(name)} #{why}")
    end)

    failed = Enum.count(results, &match?({:error, _, _}, &1))
    pending = Enum.count(results, &match?({:pending, _, _}, &1))
    ok = Enum.count(results, &match?({:ok, _, _}, &1))

    IO.puts("")
    IO.puts("#{ok} ok, #{failed} failed, #{pending} not yet implemented")

    if failed > 0 do
      IO.puts(:stderr, "preflight failed; refusing to start")
      System.halt(1)
    else
      System.halt(0)
    end
  end

  @doc "Run every check and return the results, without halting."
  @spec run() :: [result()]
  def run do
    # Secrets before config: the config references them, and a config error
    # caused by an absent secret should say "the secrets file is missing"
    # rather than listing every reference as unresolved.
    secrets = secrets()
    config = config()

    [
      crypto(),
      toolchain(),
      state_dir(),
      secrets,
      config,
      rules(config),
      database(),
      broker(),
      listeners()
    ]
  end

  # --- the config ------------------------------------------------------------

  # Parses and fully validates, which means every check the daemon does at boot
  # runs here first, as the merlin user, before anything is started. A config
  # error found here costs a message; found at boot it costs a restart loop
  # under `daemon -R 5` while you read logs to work out why.
  defp config do
    path = Merlin.Config.path()

    cond do
      not File.exists?(path) ->
        {:error, "config", "#{path} does not exist"}

      true ->
        case Merlin.Config.File.load(path) do
          {:ok, loaded} ->
            {:ok, "config", "#{path} (#{map_size(loaded.groups)} group(s), #{length(loaded.sources)} source(s))"}

          {:error, errors} ->
            {:error, "config", "#{path}\n" <> indent(Merlin.Config.File.format_errors(errors))}
        end
    end
  rescue
    e -> {:error, "config", Exception.message(e)}
  end

  # A config that loads but has no rules is a daemon that will start, connect,
  # subscribe to nothing and do nothing -- which is exactly the failure
  # main.py:135 produced by falling back to `{}` on a bad config, and the
  # single worst outcome available to a home daemon because everything looks
  # healthy.
  defp rules({:ok, "config", _}) do
    case Merlin.Config.File.load(Merlin.Config.path()) do
      {:ok, loaded} ->
        rules = Map.get(loaded, :rules, [])
        machines = Enum.count(rules, &match?(%Merlin.Machine{}, &1))

        if rules == [] do
          {:error, "rules", "the config declares no rules at all; the daemon would do nothing"}
        else
          {:ok, "rules", "#{length(rules)} rule(s), #{machines} machine(s)"}
        end

      {:error, _} ->
        {:error, "rules", "config did not load"}
    end
  end

  defp rules(_config_result), do: {:error, "rules", "not checked: the config did not load"}

  # --- secrets ---------------------------------------------------------------

  defp secrets do
    path = Merlin.Secrets.path()

    case Merlin.Secrets.load(path) do
      :ok ->
        missing = missing_secrets()

        cond do
          not File.exists?(path) and missing != [] ->
            {:error, "secrets", "#{path} does not exist, and the config references #{inspect(missing)}"}

          missing != [] ->
            {:error, "secrets", "#{path} does not define #{inspect(missing)}"}

          not File.exists?(path) ->
            {:ok, "secrets", "none needed and none present"}

          true ->
            {:ok, "secrets", "#{path} (#{map_size(Merlin.Secrets.loaded())} entr(ies), mode 0600)"}
        end

      {:error, {:permissions, file, mode}} ->
        {:error, "secrets",
         "#{file} is mode #{inspect(mode, base: :octal)}; it must not be readable by " <>
           "group or other. Run: chmod 600 #{file}"}

      {:error, reason} ->
        {:error, "secrets", inspect(reason)}
    end
  end

  # Read from the raw config term rather than the validated one, so that a
  # missing secret is reported HERE -- as a missing secret -- rather than as a
  # validation failure two lines further down.
  defp missing_secrets do
    path = Merlin.Config.path()

    if File.exists?(path) do
      {term, _} = Code.eval_file(path)
      Merlin.Secrets.missing(term)
    else
      []
    end
  rescue
    _ -> []
  end

  # --- the key database ------------------------------------------------------

  # NOTE: this creates the state directory if it is missing, because KeyStore
  # opens with mkdir_p -- a fresh install should not have to pre-create
  # /var/db/merlin by hand. It is the one check here with a side effect, which
  # is worth saying out loud rather than leaving to be discovered.
  defp database do
    path = Merlin.Config.db_path()

    Merlin.KeyStore.with_db(path, fn conn ->
      count = Merlin.KeyStore.count(conn)
      {:ok, "database", "#{path} (#{count} key(s))"}
    end)
  rescue
    e -> {:error, "database", "#{Merlin.Config.db_path()}: #{Exception.message(e)}"}
  end

  # --- the broker ------------------------------------------------------------

  # Resolves AND connects. A hostname that resolves to a machine with nothing
  # listening is the common case after a broker restart, and it is
  # indistinguishable from a healthy broker until the first publish.
  defp broker do
    host = Merlin.Config.broker_host()
    port = Merlin.Config.broker_port()

    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 3_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:ok, "broker", "#{host}:#{port} accepting connections"}

      {:error, :nxdomain} ->
        {:error, "broker", "#{host} does not resolve"}

      {:error, reason} ->
        {:error, "broker", "#{host}:#{port}: #{:inet.format_error(reason)}"}
    end
  end

  # --- the listeners ---------------------------------------------------------

  # Bound ports are checked by trying to bind them, which is the only answer
  # that is not a guess. A port that another process holds means the daemon
  # would start, fail to listen, and take its supervision tree down -- after
  # the config was already loaded and the broker already connected.
  defp listeners do
    checks =
      for {name, port} <- [
            {"public", Merlin.Config.public_port()},
            {"local", Merlin.Config.local_port()}
          ] do
        case :gen_tcp.listen(port, [:binary, reuseaddr: true]) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            {:ok, "#{name} #{port}"}

          {:error, reason} ->
            {:error, "#{name} #{port} is not bindable (#{:inet.format_error(reason)})"}
        end
      end

    case Enum.filter(checks, &match?({:error, _}, &1)) do
      [] ->
        {:ok, "listeners", checks |> Enum.map_join(", ", &elem(&1, 1))}

      errors ->
        {:error, "listeners", errors |> Enum.map_join("; ", &elem(&1, 1))}
    end
  end

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("           " <> &1))
  end

  # The single highest-value check here. `include_erts: true` bundles the build
  # host's ERTS, which dynamically links that host's libcrypto. Deploy a
  # release built against a different OpenSSL major and this is the first thing
  # that breaks -- and without this check it surfaces as an opaque boot crash
  # somewhere inside key hashing rather than as one clear line.
  defp crypto do
    _ = :crypto.hash(:sha256, "preflight")
    {:ok, "crypto", format_lib(:crypto.info_lib())}
  rescue
    # `rescue` alone is sufficient: a NIF that will not load raises, and both
    # UndefinedFunctionError and a bare :erlang.error/1 term arrive here as
    # exceptions. An additional `catch :error, _` clause is unreachable.
    e ->
      {:error, "crypto", "cannot load :crypto (#{Exception.message(e)}) -- ERTS/OpenSSL mismatch"}
  end

  defp toolchain do
    otp = List.to_string(:erlang.system_info(:otp_release))
    erts = List.to_string(:erlang.system_info(:version))
    {:ok, "toolchain", "OTP #{otp}, ERTS #{erts}"}
  end

  defp state_dir do
    dir = System.get_env("MERLIN_STATE_DIR", "/var/db/merlin")

    cond do
      not File.dir?(dir) ->
        {:error, "state dir", "#{dir} does not exist"}

      not writable?(dir) ->
        {:error, "state dir", "#{dir} is not writable by #{System.get_env("USER", "this user")}"}

      true ->
        {:ok, "state dir", dir}
    end
  end

  defp writable?(dir) do
    probe = Path.join(dir, ".preflight-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      _ ->
        false
    end
  end

  defp format_lib([{name, _ver, str} | _]), do: "#{name} #{str}"
  defp format_lib(other), do: inspect(other)

  defp pad(s), do: String.pad_trailing(s, 12)
end
