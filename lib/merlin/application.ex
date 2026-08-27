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
    load_config!()

    children =
      [
        # Owns the ETS table, and only that. Separated from the writer so a
        # writer crash cannot take the world model with it.
        Merlin.World.Table,

        # Must precede the writer: the writer publishes through it.
        Merlin.Bus,

        # The sole process permitted to write facts.
        Merlin.World.Writer,

        # Registries for the named processes. Started unconditionally: tests
        # start individual machines and derived facts directly, without the
        # supervisors that would otherwise own these.
        {Registry, keys: :unique, name: Merlin.Machine.Registry},
        {Registry, keys: :unique, name: Merlin.Derive.Registry}
      ] ++ mqtt_children() ++ http_children()

    opts = [
      strategy: :rest_for_one,
      max_restarts: 3,
      max_seconds: 30,
      name: Merlin.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  # Tests must not reach for a broker. Tiers 1-4 are pure by definition, and a
  # suite that silently depends on a listening mosquitto is a suite that fails
  # for reasons unrelated to the code under test.
  defp mqtt_children do
    if Merlin.Config.start_mqtt?(),
      do: [
        Merlin.MQTT.Connection,
        # Derived facts sit between the adapters and the rules: they consume
        # raw observations and produce the semantics rules are written against.
        Merlin.Derive.Supervisor,
        Merlin.Rules.Engine,
        # Stateful rules, one :gen_statem each.
        Merlin.Machine.Supervisor
      ],
      else: []
  end

  # Started last, and after the world exists: /healthz answering 200 must mean
  # the daemon is actually able to serve, not merely that a port is bound.
  defp http_children do
    if Merlin.Config.start_http?(), do: [Merlin.HTTP.Supervisor], else: []
  end

  # A bad config is a refusal to start, not a warning.
  #
  # `main.py:135` wrapped its config load in `try/except Exception` and fell
  # back to `{}` -- so a typo produced a daemon that started cleanly, connected
  # to the broker, loaded no hooks and did nothing at all, with no error
  # anywhere. That is the single worst failure mode available to a home daemon,
  # because everything looks healthy.
  defp load_config! do
    if Merlin.Config.start_mqtt?() do
      case Merlin.Config.load() do
        :ok ->
          :ok

        {:error, errors} ->
          IO.puts(:stderr, """
          merlin: configuration is invalid, refusing to start

          #{Merlin.Config.File.format_errors(errors)}
          """)

          System.halt(2)
      end
    else
      # Under test the house config is installed per-test; there is no file.
      :ok
    end
  end
end
