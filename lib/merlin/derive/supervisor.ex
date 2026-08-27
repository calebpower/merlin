defmodule Merlin.Derive.Supervisor do
  @moduledoc """
  The derived-fact layer: modules that turn raw observations into semantics.

  Started after the world and before the rules engine, because rules read what
  these produce. Each derived fact is its own process, so a geofence raising on
  a malformed coordinate restarts itself rather than taking the presence of
  every other entity with it.
  """

  use Supervisor

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      Enum.map(Merlin.Config.derived(), &child_spec_for/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_spec_for(spec) do
    module =
      case spec.kind do
        :geofence -> Merlin.Derive.Geofence
        :expr -> Merlin.Derive.Expr
        :sun -> Merlin.Derive.Sun
        :http_poll -> Merlin.Source.HttpPoll
      end

    Supervisor.child_spec({module, spec}, id: {module, spec.id})
  end
end
