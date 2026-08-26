defmodule Merlin.Preflight do
  @moduledoc """
  Refuse to start rather than flap.

  This runs from the rc.d script's `start_precmd`, as the `merlin` user, before
  the supervision tree exists. If it exits non-zero, `service merlin-ex start`
  prints the reason and returns non-zero -- instead of the daemon dying in a
  loop under `daemon -R 5` while you read logs to work out why.

  Checks not yet implemented are reported as **pending**, never as passes. A
  preflight whose unimplemented half reads as green is worse than no preflight,
  because it converts an unknown into a false assurance.
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
    [
      crypto(),
      toolchain(),
      state_dir(),
      {:pending, "config", "lands with the boot validator (M2)"},
      {:pending, "rules", "lands with the rules engine (M2)"},
      {:pending, "secrets", "lands with the secrets file (M2)"},
      {:pending, "database", "lands with the key store (M3)"},
      {:pending, "broker", "lands with the MQTT adapter (M1)"},
      {:pending, "listeners", "lands with the HTTP listeners (M3)"}
    ]
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
