defmodule Merlin.Settle do
  @moduledoc """
  A window after boot and after every broker reconnect during which merlin
  learns the state of the house without acting on it.

  ## Bug 8, and the 3am false alarm

  MQTT retained messages replay on connect. Every door, plug and sensor
  re-announces its current state within a second or two, and from the daemon's
  point of view that burst is indistinguishable from the whole house changing
  at once. Edge-triggered rules fire on it: the intruder latch sees doors
  "moving", the lamps see an arrival, the load shed sees the printer start.

  The Python never noticed because the rules it would have tripped were
  unreachable behind bug 2. Fixing that bug is what makes this window
  mandatory rather than tidy -- it turns three dormant code paths on, and two
  of them alert.

  This is also why the window re-arms on **reconnect** and not only at boot. A
  broker restart, a wifi blip at 3am, a `service mosquitto reload` -- each one
  replays the retained set into a daemon that has been running for weeks.
  Arming only at startup would leave exactly the case that wakes you.

  ## What is suppressed, and what is not

  Outward effects only: publishing to the broker, commanding a group,
  notifying. Facts still apply and logs still write, because the entire point
  of the window is to *learn* the state of the house -- a settle period that
  discarded observations would leave the daemon ignorant when it ended, which
  is worse than the disease.

  So a door that opens during the window is recorded as open, the latch
  observes it, and nothing is sent. When the window closes the world is
  correct and merlin acts on what happens next.

  ## Deliberately not a fact

  This lives in `:persistent_term` rather than in the world model. Reads are
  on the hot path of every effect, and more importantly a settle window that
  was itself a fact could be watched by a rule, which invites exactly the
  cleverness this is meant to remove.
  """

  require Logger

  @key {__MODULE__, :until}

  @default_ms 15_000

  @doc """
  Open a settle window.

  Idempotent in the useful direction: a reconnect during an existing window
  extends it rather than shortening it, because the second retained burst is
  as much of a problem as the first.
  """
  @spec begin(binary(), non_neg_integer() | nil) :: :ok
  def begin(reason, ms \\ nil) do
    ms = ms || configured_ms()
    until = System.monotonic_time(:millisecond) + ms

    if ms > 0 do
      until =
        case :persistent_term.get(@key, nil) do
          nil -> until
          previous -> max(until, previous)
        end

      :persistent_term.put(@key, until)
      Logger.info("settle: #{reason} -- suppressing outward effects for #{ms}ms")
    end

    :ok
  end

  @doc "Whether a settle window is currently open."
  @spec settling?() :: boolean()
  def settling?, do: remaining_ms() > 0

  @doc "Milliseconds left in the window, or 0."
  @spec remaining_ms() :: non_neg_integer()
  def remaining_ms do
    # `nil` for "no window", NOT 0.
    #
    # `System.monotonic_time/1` has an arbitrary origin and is routinely
    # NEGATIVE -- on a freshly booted machine it can be hours below zero. With
    # 0 as the "closed" sentinel, `0 - monotonic_now` is positive and the
    # daemon reports itself as settling forever: every publish, every group
    # command and every notification suppressed indefinitely, on exactly the
    # machines that had just restarted. Silent, and indistinguishable from a
    # daemon that has simply stopped acting.
    case :persistent_term.get(@key, nil) do
      nil -> 0
      until -> max(until - System.monotonic_time(:millisecond), 0)
    end
  end

  @doc "Close the window immediately. For tests and for the CLI."
  @spec finish() :: :ok
  def finish, do: :persistent_term.put(@key, nil)

  @doc """
  Whether this effect is one the settle window holds back.

  The policy in one function, so it can be tested directly rather than
  inferred from what a daemon did or did not publish.

    * `:publish`, `:set_group` -- outward actuation. Held.
    * `:notify` -- outward alerting. Held; this is the one that wakes you.
    * `:set_fact` -- the world model. Allowed: learning is the point.
    * `:log` -- allowed, and how you see what the window absorbed.
  """
  @spec suppresses?(tuple()) :: boolean()
  def suppresses?({:publish, _topic, _payload, _opts}), do: true
  def suppresses?({:set_group, _group, _value}), do: true
  def suppresses?({:notify, _channel, _message}), do: true
  def suppresses?({:set_fact, _path, _value}), do: false
  def suppresses?({:log, _level, _message}), do: false
  def suppresses?(_other), do: true

  @doc "The configured window length in milliseconds."
  @spec configured_ms() :: non_neg_integer()
  def configured_ms do
    case System.get_env("MERLIN_SETTLE_MS") do
      nil -> Merlin.Config.loaded()[:settle_ms] || Application.get_env(:merlin, :settle_ms, @default_ms)
      raw -> String.to_integer(raw)
    end
  end

  @doc "The default window length when nothing is configured."
  @spec default_ms() :: pos_integer()
  def default_ms, do: @default_ms
end
