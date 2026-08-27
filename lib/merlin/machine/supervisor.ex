defmodule Merlin.Machine.Supervisor do
  @moduledoc """
  One process per stateful rule.

  A `:one_for_one` DynamicSupervisor rather than a static list, and a
  deliberately generous restart intensity: machines are cheap to restart and
  hold little state, so a crash-looping one should be quarantined rather than
  escalate to the supervision tree and take the broker connection with it.

  Per-machine isolation is most of the reason these get processes. In the
  Python a raise inside one hook's `on_state_change` was a lost task exception
  that left every other hook untouched but also left nobody informed. Here a
  crash restarts that machine alone, loudly.
  """

  use Supervisor

  alias Merlin.{Config, Machine}

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    machines =
      Config.rules()
      |> Enum.filter(&match?(%Machine{}, &1))
      |> Enum.filter(& &1.enabled)

    children =
      Enum.map(machines, &Machine.Server.child_spec/1)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 20, max_seconds: 60)
  end
end
