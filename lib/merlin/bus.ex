defmodule Merlin.Bus do
  @moduledoc """
  Prefix-addressed publish/subscribe over `Registry`.

  Subscribers name a path prefix and receive everything beneath it:

      Merlin.Bus.subscribe([:door])                     # every door
      Merlin.Bus.subscribe([:door, "office"])           # one door
      Merlin.Bus.subscribe([:door, "office", :contact]) # exactly one fact
      Merlin.Bus.subscribe_events([:button])            # every button event

  Messages arrive as `{:merlin, %Merlin.Change{}}` or `{:merlin, %Merlin.Event{}}`.

  ## Why this replaces the Python dispatch

  `main.py` subscribed to `#` and handed every message on the broker to every
  hook, each of which then re-checked the topic with a string comparison. The
  filtering existed, but it lived in twelve places and could not be reasoned
  about centrally. Here a subscriber is only ever sent what it asked for, and
  a publish costs one `Registry` lookup per path segment -- no scanning, no
  pattern matching against every registration.

  ## Mid-path wildcards are deliberately absent

  There is no way to subscribe to `[:door, :_, :contact]`. Supporting it means
  either generating every combination on publish or falling back to a scan.
  Order path segments most-general-first instead, so that a prefix covers what
  a wildcard would: "every door" is `[:door]`. If you ever genuinely want one
  attribute across many entities, that is a derived aggregate fact, not a
  subscription pattern.

  ## Delivery

  Delivery is `send/2` and nothing more. This is what structurally prevents
  the re-entrant callback cascade that made `GlobalState.set/2` fragile: a
  subscriber reacting by writing another fact does so from its own process,
  on its own stack, after the writer has already returned.
  """

  require Logger

  alias Merlin.{Change, Event, Path}

  @registry __MODULE__.Registry

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :duplicate,
      name: @registry,
      partitions: System.schedulers_online()
    )
  end

  @doc "Subscribe the calling process to fact changes at or beneath `prefix`."
  @spec subscribe(Path.t()) :: :ok
  def subscribe(prefix) when is_list(prefix) do
    {:ok, _} = Registry.register(@registry, {:fact, prefix}, nil)
    :ok
  end

  @doc "Subscribe the calling process to events at or beneath `prefix`."
  @spec subscribe_events(Path.t()) :: :ok
  def subscribe_events(prefix) when is_list(prefix) do
    {:ok, _} = Registry.register(@registry, {:event, prefix}, nil)
    :ok
  end

  @doc "Stop receiving fact changes for `prefix`."
  @spec unsubscribe(Path.t()) :: :ok
  def unsubscribe(prefix) when is_list(prefix) do
    Registry.unregister(@registry, {:fact, prefix})
  end

  @doc "Stop receiving events for `prefix`."
  @spec unsubscribe_events(Path.t()) :: :ok
  def unsubscribe_events(prefix) when is_list(prefix) do
    Registry.unregister(@registry, {:event, prefix})
  end

  @doc """
  Deliver a change to every subscriber whose prefix covers its path.

  Returns the number of processes messaged, which is what lets a test assert
  that a subscription is actually wired rather than merely registered.
  """
  @spec publish(Change.t()) :: non_neg_integer()
  def publish(%Change{path: path} = change) do
    deliver(:fact, path, {:merlin, change})
  end

  @doc "Deliver an event to every subscriber whose prefix covers its path."
  @spec emit(Event.t()) :: non_neg_integer()
  def emit(%Event{path: path} = event) do
    deliver(:event, path, {:merlin, event})
  end

  # One lookup per prefix, then dedupe before sending. A process subscribed at
  # two depths must receive one message, not two -- otherwise a rule watching
  # both [:door] and [:door, "office"] would act twice on one change.
  defp deliver(kind, path, message) do
    pids =
      path
      |> Path.prefixes()
      |> Enum.flat_map(fn prefix -> Registry.lookup(@registry, {kind, prefix}) end)
      |> Enum.map(fn {pid, _value} -> pid end)
      |> Enum.uniq()

    Enum.each(pids, &send(&1, message))
    length(pids)
  end
end
