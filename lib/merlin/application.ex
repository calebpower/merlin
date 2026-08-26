defmodule Merlin.Application do
  @moduledoc """
  The supervision tree.

  Only the spine exists at this milestone. The ordering below is the whole
  design and is not incidental: the dependency chain is strictly linear and
  one-directional --

      Config <- Store <- World <- Adapters <- Rules

  which is why the strategy is `:rest_for_one`. Under `:one_for_one`, a World
  restart would leave every adapter holding a dead writer pid and a dead ETS
  reference. Under `:one_for_all`, a single crashing rule would tear down the
  MQTT connection and force a reconnect. `:rest_for_one` restarts exactly the
  downstream half and nothing upstream.

  `max_restarts` is deliberately low. Repeated failure at this level means the
  environment or the configuration is broken, and the right response is for the
  VM to exit so `daemon(8)`'s `-R 5` restarts the OS process with fresh port
  bindings and fresh NIF state -- rather than thrashing inside the BEAM.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []

    opts = [
      strategy: :rest_for_one,
      max_restarts: 3,
      max_seconds: 30,
      name: Merlin.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end
end
