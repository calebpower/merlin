defmodule Merlin.HTTP.RateLimit do
  @moduledoc """
  A fixed-window limiter over ETS. Roughly thirty lines, and no dependency.

  `hammer` would do this properly, with sliding windows and a supervision tree,
  and would be the right answer for a service. `/snitch` is one endpoint on a
  home network whose only legitimate caller is a phone reporting every thirty
  seconds; a fixed window is sufficient and a dependency is not worth its
  upgrade cadence.

  Over-limit requests are dropped, not rejected: the caller still receives 200,
  because `/snitch` must never behave differently in a way an attacker can
  observe.
  """

  use GenServer

  @table :merlin_rate_limit
  @window_ms 60_000
  @max_per_window 60

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether this peer may proceed. Counts the request as it does so."
  @spec allow?(term()) :: boolean()
  def allow?(peer) do
    window = div(System.monotonic_time(:millisecond), @window_ms)
    key = {peer, window}

    count =
      try do
        :ets.update_counter(@table, key, 1, {key, 0})
      rescue
        # No table yet (tests, or before start). Never fail closed on the
        # limiter -- a broken limiter must not take the endpoint down with it.
        ArgumentError -> 1
      end

    count <= @max_per_window
  end

  @doc "Requests permitted per window, exposed for tests."
  def max_per_window, do: @max_per_window

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Windows are monotonic integers, so anything older than the current one
    # can never be written to again.
    current = div(System.monotonic_time(:millisecond), @window_ms)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)
end
