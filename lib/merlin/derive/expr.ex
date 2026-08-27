defmodule Merlin.Derive.Expr do
  @moduledoc """
  A fact computed from an expression over other facts.

      %{
        id: :vehicle_away_from_home,
        out: [:vehicle, :car, :away_from_home?],
        compute: "person.caleb.zone == :home and vehicle.car.zone != :home"
      }

  ## Why derived facts are first class

  Your "my car should be considered stolen if I am home and my car is not" is
  a *predicate about the world*, not an action. Making it a fact rather than
  burying it in a rule's guard means it can be read on `/facts.json`, referred
  to by other rules, and -- most usefully -- inspected when you want to know
  why an alert did or did not fire, without reading logs.

  It also means the question and the response are separable: the fact says the
  car is unaccounted for, and a rule decides whether that is worth a Discord
  message at 3am.

  ## Subscriptions are derived

  The watched paths come from `Merlin.Expr.deps/1`, so there is no list to
  keep in step with the expression. Change the expression and the
  subscriptions follow.

  ## What it will not do yet

  No `hold:` / sustained-for window. "True for two minutes before it counts"
  needs a timer, and timers arrive with the `:gen_statem` executors at M5.
  Until then a derived fact reflects the world as it is this instant, which is
  correct but twitchier than the vehicle rules ultimately want.
  """

  use GenServer
  require Logger

  alias Merlin.{Expr, Fact, Groups, World}

  defstruct [:id, :out_path, :expr]

  @doc false
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.id))

  defp via(id), do: {:via, Registry, {Merlin.Derive.Registry, {__MODULE__, id}}}

  @impl true
  def init(spec) do
    expr = Expr.compile!(spec.compute)
    state = %__MODULE__{id: spec.id, out_path: spec.out, expr: expr}

    for path <- Expr.deps(expr), do: Merlin.Bus.subscribe(path)

    recompute(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:merlin, %Merlin.Change{path: path}}, state) do
    # Never react to our own output. A derived fact that depends on itself is
    # a config error caught at boot, but this is the cheap structural guard --
    # user_location.py re-entered itself on every write and terminated only
    # because the dedup happened to converge.
    unless path == state.out_path, do: recompute(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp recompute(state) do
    env = %{read: &read/1, group: Groups.resolver()}
    value = Expr.eval(state.expr, env)

    World.put(state.out_path, value, source: {:derive, state.id})
  end

  defp read(path) do
    case World.fetch(path) do
      {:ok, fact} -> if Fact.stale?(fact), do: :unknown, else: fact.value
      :error -> :unknown
    end
  end
end
