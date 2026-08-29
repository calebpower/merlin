defmodule Merlin.TUI.Remote do
  @moduledoc """
  The only module in the TUI permitted to talk to the daemon.

  Every other `Merlin.TUI.*` module is pure. That is not tidiness -- it is the
  thing standing between an operator and a lie.

  A TUI client boots with `--boot start_clean`, which *loads* every `Merlin.*`
  module but starts no application. So on the client:

    * `Merlin.Config.dry_run?()` reads an empty config and answers `false`;
    * `Merlin.World.fetch/1` raises on an ETS table that does not exist.

  The first is the dangerous one. A view calling it directly would paint LIVE
  while the daemon was in dry run, and an operator who believes they are only
  asking questions would command a house. Nothing about that failure is
  visible: the banner would be confident and wrong.

  So the rule is mechanical rather than remembered, and a tier 1 test reads the
  compiled beams to enforce it: no module under `Merlin.TUI` except this one
  may reference `Merlin.World`, `Merlin.Config`, `Merlin.Groups` or
  `Merlin.Rules.Engine`.

  ## The handshake

  The release on disk can be newer than the daemon still running from the
  previous one. Struct fields that do not line up produce a wrong render rather
  than an error, so the version is checked before anything is drawn and a
  mismatch refuses to start.
  """

  require Logger

  @timeout 5_000

  @doc """
  Connect to the daemon node and attach a tap.

  Returns `{:ok, %{node:, tap:, version:}}` or `{:error, reason}`. Every
  failure names what to do about it, because this is the first thing an
  operator sees when it does not work.
  """
  @spec attach(node()) :: {:ok, map()} | {:error, binary()}
  def attach(node) do
    with :ok <- connect(node),
         {:ok, version} <- handshake(node),
         {:ok, tap} <- do_attach(node) do
      {:ok, %{node: node, tap: tap, version: version}}
    end
  end

  defp connect(node) do
    if Node.connect(node) do
      :ok
    else
      {:error,
       "cannot reach #{node}. Is merlind running? `service merlind status`. " <>
         "Distribution is bound to loopback, so this must run on the same host."}
    end
  end

  defp handshake(node) do
    case call(node, Merlin.Tap, :version, []) do
      {:ok, remote} ->
        local = to_string(Application.spec(:merlin, :vsn) || "unknown")

        if remote == local do
          {:ok, remote}
        else
          {:error,
           "version mismatch: this client is #{local}, the daemon is #{remote}. " <>
             "The release on disk is newer than the running daemon -- restart it, " <>
             "or run the client from the same release."}
        end

      {:error, reason} ->
        {:error, "handshake failed: #{inspect(reason)}"}
    end
  end

  defp do_attach(node) do
    case call(node, Merlin.Tap, :attach, [self()]) do
      {:ok, {:ok, %{pid: tap}}} -> {:ok, tap}
      {:ok, {:error, reason}} -> {:error, "the daemon refused a tap: #{inspect(reason)}"}
      {:error, reason} -> {:error, "could not attach: #{inspect(reason)}"}
    end
  end

  @doc "The current scene, built on the daemon where the world actually is."
  @spec scene(node()) :: {:ok, Merlin.TUI.Scene.t()} | {:error, term()}
  def scene(node), do: call(node, Merlin.Tap, :scene, [])

  @doc "Resolve a command and mint a confirmation token. Performs nothing."
  @spec prepare(node(), tuple()) :: {:ok, term()} | {:error, term()}
  def prepare(node, command) do
    case call(node, Merlin.Control, :prepare, [command, self()]) do
      {:ok, result} -> result
      error -> error
    end
  end

  @doc "Run a prepared command."
  @spec commit(node(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def commit(node, token, opts) do
    case call(node, Merlin.Control, :commit, [token, self(), opts]) do
      {:ok, result} -> result
      error -> error
    end
  end

  @doc "Discard a prepared command."
  @spec cancel(node(), binary()) :: :ok
  def cancel(node, token) do
    call(node, Merlin.Control, :cancel, [token, self()])
    :ok
  end

  @doc "Why a rule would or would not act on a change to `path`."
  @spec explain(node(), atom(), Merlin.Path.t()) :: {:ok, term()} | {:error, term()}
  def explain(node, rule_id, path) do
    case call(node, Merlin.Tap, :explain, [rule_id, path]) do
      {:ok, result} -> result
      error -> error
    end
  end

  @doc "Evaluate a merlin expression against the live world, on the daemon."
  @spec evaluate(node(), binary()) :: {:ok, term()} | {:error, term()}
  def evaluate(node, source), do: call(node, Merlin.Tap, :evaluate, [source])

  @doc "Detach cleanly, so the daemon does not wait for a monitor to notice."
  @spec detach(node(), pid()) :: :ok
  def detach(node, tap) do
    call(node, Merlin.Tap, :detach, [tap])
    :ok
  end

  # One place that does :erpc, so one place to read when the daemon is
  # unreachable -- and one thing for the boundary test to allow.
  defp call(node, module, function, args) do
    {:ok, :erpc.call(node, module, function, args, @timeout)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
