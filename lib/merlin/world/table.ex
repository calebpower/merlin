defmodule Merlin.World.Table do
  @moduledoc """
  Owns the ETS table, and does nothing else.

  This process exists solely so that the table's lifetime is not tied to the
  writer's. ETS tables die with their owning process; if `Merlin.World.Writer`
  owned this one, every writer crash would destroy the entire world model and
  the restart would come up amnesiac.

  With the table owned here and the supervisor strategy set to `:rest_for_one`,
  a writer crash leaves the table intact and the restart is invisible; a table
  crash takes the writer down behind it, which is correct, because a writer
  holding a reference to a dead table has nothing useful to do.

  The table is `:public` rather than `:protected` so the writer can write
  without a copy through the owner. Single-writer discipline is enforced by
  the API surface -- `Merlin.World` exposes no direct write -- not by ETS
  permissions.
  """

  use GenServer

  @table :merlin_world
  @seq_key :"$seq"

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The ETS table name. Readers use this directly."
  def table, do: @table

  @doc "The key under which the monotonic sequence counter lives."
  def seq_key, do: @seq_key

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(@table, {@seq_key, 0})
    {:ok, %{}}
  end
end
