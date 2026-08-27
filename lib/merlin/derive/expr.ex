defmodule Merlin.Derive.Expr do
  @moduledoc """
  A fact computed from an expression over other facts.

      %{
        id: :vehicle_away_from_home,
        out: [:vehicle, :car, :away_from_home?],
        compute: "person.owner.zone == :home and vehicle.car.zone != :home"
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

  ## hold: sustained-for windows

      hold: {:true_for, {2, :minute}}

  The fact only becomes true once the expression has been continuously true
  for that long. A single bad GPS fix cannot fire an alarm.

  This matters specifically for the vehicle. `alerts.py` fired
  ":warning: Vehicle has gone AWOL" on the first false-edge of a flag derived
  from one GPS reading -- so one bounced fix at the edge of a zone was an alert
  at 3am. A hold turns a momentary blip into nothing at all, because the timer
  is cancelled the instant the condition stops holding.

  Note the asymmetry: the window delays becoming **true**, and going false is
  immediate. An alarm should be slow to fire and quick to clear, not the
  reverse.
  """

  use GenServer
  require Logger

  alias Merlin.{Expr, Fact, Groups, World}

  defstruct [:id, :out_path, :expr, :hold_ms, :pending_ref]

  @doc false
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.id))

  defp via(id), do: {:via, Registry, {Merlin.Derive.Registry, {__MODULE__, id}}}

  @impl true
  def init(spec) do
    expr = Expr.compile!(spec.compute)

    hold_ms =
      case spec[:hold] do
        nil -> nil
        {:true_for, duration} -> elem(Merlin.Machine.to_ms(duration), 1)
      end

    state = %__MODULE__{id: spec.id, out_path: spec.out, expr: expr, hold_ms: hold_ms}

    for path <- Expr.deps(expr), do: Merlin.Bus.subscribe(path)

    {:ok, recompute(state)}
  end

  @impl true
  def handle_info({:merlin, %Merlin.Change{path: path}}, state) do
    # Never react to our own output. A derived fact that depends on itself is
    # a config error caught at boot, but this is the cheap structural guard --
    # user_location.py re-entered itself on every write and terminated only
    # because the dedup happened to converge.
    if path == state.out_path, do: {:noreply, state}, else: {:noreply, recompute(state)}
  end

  # The hold elapsed. Re-evaluate rather than trusting the value that armed
  # the timer: the point of a sustained-for window is that the condition is
  # still true NOW, not that it was true when the clock started.
  def handle_info({:hold_elapsed, ref}, %{pending_ref: ref} = state) do
    env = %{read: &read/1, group: Groups.resolver()}

    if Expr.eval(state.expr, env) == true do
      World.put(state.out_path, true, source: {:derive, state.id})
    end

    {:noreply, %{state | pending_ref: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp recompute(%{hold_ms: nil} = state) do
    World.put(state.out_path, evaluate(state), source: {:derive, state.id})
    state
  end

  defp recompute(state) do
    case evaluate(state) do
      true ->
        # Arm the window if one is not already running. Re-arming on every
        # intermediate change would mean the window never elapses while the
        # inputs are noisy -- which is the opposite of what it is for.
        if state.pending_ref do
          state
        else
          ref = make_ref()
          Process.send_after(self(), {:hold_elapsed, ref}, state.hold_ms)
          %{state | pending_ref: ref}
        end

      other ->
        # Falling is immediate, and cancels any armed window. An alarm should
        # be slow to fire and quick to clear.
        World.put(state.out_path, other, source: {:derive, state.id})
        %{state | pending_ref: nil}
    end
  end

  defp evaluate(state) do
    Expr.eval(state.expr, %{read: &read/1, group: Groups.resolver()})
  end

  defp read(path) do
    case World.fetch(path) do
      {:ok, fact} -> if Fact.stale?(fact), do: :unknown, else: fact.value
      :error -> :unknown
    end
  end
end
