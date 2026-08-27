defmodule Merlin.HTTP.Supervisor do
  @moduledoc """
  Two Bandit listeners with deliberately different exposure.

  Bandit rather than Cowboy: pure Elixir, no ranch/cowboy Erlang tree to build
  on FreeBSD, and Phoenix for two routers would be absurd.
  """

  use Supervisor

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Merlin.HTTP.RateLimit,
      {Bandit,
       plug: Merlin.HTTP.PublicRouter,
       scheme: :http,
       ip: Merlin.Config.public_ip(),
       port: Merlin.Config.public_port(),
       startup_log: false},
      {Bandit,
       plug: Merlin.HTTP.LocalRouter,
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: Merlin.Config.local_port(),
       startup_log: false}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
