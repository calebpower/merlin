defmodule Merlin.Config do
  @moduledoc """
  Configuration: infrastructure from the environment, the house from a file.

  Two sources, deliberately kept apart:

    * **Infrastructure** -- broker address, client id, whether to dry-run --
      comes from environment variables and the application environment, because
      an rc.d script and a reaper session both need to set it without editing a
      file.
    * **The house** -- groups, sources and rules -- comes from the data file at
      `MERLIN_CONFIG`, validated at boot by `Merlin.Config.File`.

  The loaded config lives in `:persistent_term`: read on every message, written
  once at boot (and on an explicit reload), which is exactly what that store is
  for.
  """

  require Logger

  @key {__MODULE__, :loaded}

  # --- infrastructure -------------------------------------------------------

  @doc "Broker hostname."
  @spec broker_host() :: binary()
  def broker_host do
    env("MERLIN_BROKER_HOST") || dig([:mqtt, :host]) || app(:broker_host, "localhost")
  end

  @doc "Broker port."
  @spec broker_port() :: pos_integer()
  def broker_port do
    case env("MERLIN_BROKER_PORT") || dig([:mqtt, :port]) || app(:broker_port, 1883) do
      port when is_integer(port) -> port
      port when is_binary(port) -> String.to_integer(port)
    end
  end

  @doc """
  MQTT client id.

  Distinct from the Python daemon's by default, so both can be attached to the
  same broker during the cutover -- a broker evicts an existing session when a
  second client presents the same id.
  """
  @spec client_id() :: binary()
  def client_id, do: env("MERLIN_CLIENT_ID") || app(:client_id, "merlin-ex")

  @doc """
  Whether to log effects instead of performing them.

  `MERLIN_DRY_RUN=false` overrides the file, which is how the cutover flips it
  without editing config under time pressure.
  """
  @spec dry_run?() :: boolean()
  def dry_run? do
    case env("MERLIN_DRY_RUN") do
      "false" -> false
      "0" -> false
      "true" -> true
      "1" -> true
      _ -> loaded()[:dry_run] || app(:dry_run, false)
    end
  end

  @doc "Where the key database lives."
  @spec db_path() :: binary()
  def db_path do
    env("MERLIN_DB") || dig([:api, :db_path]) ||
      Path.join(state_dir(), "merlin.db")
  end

  @doc "State directory: the key database, and later the fact snapshot."
  @spec state_dir() :: binary()
  def state_dir, do: env("MERLIN_STATE_DIR") || app(:state_dir, "/var/db/merlin")

  @doc "Address the public listener binds. Defaults to all interfaces: the phone posts to it."
  @spec public_ip() :: :inet.ip_address()
  def public_ip do
    case env("MERLIN_PUBLIC_IP") do
      nil -> {0, 0, 0, 0}
      addr -> addr |> String.to_charlist() |> :inet.parse_address() |> elem(1)
    end
  end

  @doc "Public listener port: /snitch and /healthz."
  @spec public_port() :: pos_integer()
  def public_port, do: int(env("MERLIN_PUBLIC_PORT") || dig([:api, :port]) || app(:public_port, 8080))

  @doc "Loopback listener port: /facts.json and /rules.json."
  @spec local_port() :: pos_integer()
  def local_port, do: int(env("MERLIN_LOCAL_PORT") || app(:local_port, 8081))

  @doc "Whether to start the HTTP listeners. False under test."
  @spec start_http?() :: boolean()
  def start_http?, do: Application.get_env(:merlin, :start_http, true)

  @doc "Whether to open a broker connection at boot. False under test."
  @spec start_mqtt?() :: boolean()
  def start_mqtt?, do: Application.get_env(:merlin, :start_mqtt, true)

  # --- the house ------------------------------------------------------------

  @doc "Group definitions, keyed by id."
  @spec groups() :: %{atom() => map()}
  def groups, do: loaded()[:groups] || %{}

  @doc "Declarative source definitions."
  @spec sources() :: [map()]
  def sources, do: loaded()[:sources] || []

  @doc "Compiled rules."
  @spec rules() :: [Merlin.Rule.t()]
  def rules, do: loaded()[:rules] || []

  @doc """
  Adapters to run, derived from the sources.

  One adapter instance per source, so the router resolves a message straight to
  the source that asked for it.
  """
  @spec adapters() :: [{module(), keyword()}]
  def adapters do
    Enum.map(sources(), fn source -> {Merlin.Adapters.Declarative, [source: source]} end)
  end

  # --- loading --------------------------------------------------------------

  @doc "The path the config is read from."
  @spec path() :: binary()
  def path do
    env("MERLIN_CONFIG") || Application.get_env(:merlin, :config_path) ||
      Path.join(:code.priv_dir(:merlin) |> to_string(), "merlin.exs")
  end

  @doc """
  Load and install the config.

  Returns `:ok` or `{:error, errors}`. Callers at boot must treat an error as a
  refusal to start: `main.py` swallowed config errors and started a daemon that
  did nothing, which is the failure mode this exists to prevent.
  """
  @spec load(binary() | nil) :: :ok | {:error, [term()]}
  def load(from \\ nil) do
    file = from || path()

    case Merlin.Config.File.load(file) do
      {:ok, config} ->
        :persistent_term.put(@key, config)

        Logger.info(
          "config loaded from #{file}: #{map_size(config.groups)} group(s), " <>
            "#{length(config.sources)} source(s), #{length(config.rules)} rule(s)"
        )

        :ok

      {:error, errors} ->
        {:error, errors}
    end
  end

  @doc "Install an already-built config. For tests."
  @spec put(map()) :: :ok
  def put(config), do: :persistent_term.put(@key, config)

  @doc "The currently loaded config, or an empty one."
  @spec loaded() :: map()
  def loaded, do: :persistent_term.get(@key, %{})

  # --- helpers --------------------------------------------------------------

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp app(key, default), do: Application.get_env(:merlin, key, default)

  defp dig(keys), do: get_in(loaded(), keys)

  defp int(v) when is_integer(v), do: v
  defp int(v) when is_binary(v), do: String.to_integer(v)
end
