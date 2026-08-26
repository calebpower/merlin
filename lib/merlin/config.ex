defmodule Merlin.Config do
  @moduledoc """
  Runtime configuration.

  Deliberately thin at this milestone. The real thing -- a validated `.exs`
  data file with zones, adapters, derived facts and rules, rejected loudly on
  an unknown key -- lands with the config layer at M2. Until then this reads
  the application environment with environment-variable overrides, which is
  enough to point the daemon at a broker and no more.

  The override order is environment variable, then application environment,
  then a default. Environment variables win because that is what an rc.d
  script and a reaper session can both set without editing a file.
  """

  @doc "Broker hostname."
  @spec broker_host() :: binary()
  def broker_host, do: get("MERLIN_BROKER_HOST", :broker_host, "localhost")

  @doc "Broker port."
  @spec broker_port() :: pos_integer()
  def broker_port do
    case get("MERLIN_BROKER_PORT", :broker_port, 1883) do
      port when is_integer(port) -> port
      port when is_binary(port) -> String.to_integer(port)
    end
  end

  @doc """
  MQTT client id.

  Distinct from the Python daemon's by default, so that both can be connected
  to the same broker during the cutover without evicting each other -- brokers
  disconnect an existing session when a second client presents the same id.
  """
  @spec client_id() :: binary()
  def client_id, do: get("MERLIN_CLIENT_ID", :client_id, "merlin-ex")

  @doc "The adapters to run, as `[{module, opts}]`."
  @spec adapters() :: [{module(), keyword()}]
  def adapters do
    Application.get_env(:merlin, :adapters, [{Merlin.Adapters.Echo, []}])
  end

  @doc "Whether to open a broker connection at boot. False under test."
  @spec start_mqtt?() :: boolean()
  def start_mqtt?, do: Application.get_env(:merlin, :start_mqtt, true)

  defp get(env_var, app_key, default) do
    case System.get_env(env_var) do
      nil -> Application.get_env(:merlin, app_key, default)
      "" -> Application.get_env(:merlin, app_key, default)
      value -> value
    end
  end
end
