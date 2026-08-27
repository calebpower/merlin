defmodule Merlin.MixProject do
  use Mix.Project

  @version "0.4.0-dev"

  def project do
    [
      app: :merlin,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      elixirc_options: [warnings_as_errors: true],
      test_paths: ["test"]
    ]
  end

  def application do
    [
      # :inets is not used by the daemon. It is included so that
      # `bin/merlin eval` has an HTTP client available -- which is how the
      # smoke tier posts to /snitch as a genuinely external process, without
      # depending on curl or python being present on the guest. Both were
      # assumed and neither was there.
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Merlin.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP ingress. Bandit over Cowboy: pure Elixir, no ranch/cowboy Erlang
      # tree, and Phoenix for one POST route would be absurd.
      {:bandit, "~> 1.7"},
      {:plug, "~> 1.16"},

      # HTTP client for the pollers and the Discord notifier. Req.Test is what
      # lets tier 5 inject transport failures without a network.
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},

      # MQTT, always behind Merlin.MQTT.Client so the choice is one file deep.
      # tortoise311 is a community fork with a small bus factor; that risk is
      # accepted here and mitigated by the behaviour, not by the package.
      {:tortoise311, "~> 0.12"},

      # API keys. exqlite rather than Ecto: one table, six queries. It is a NIF
      # that compiles bundled SQLite C, which is the single largest FreeBSD
      # build risk in this project -- which is why it is in the dependency list
      # from the first build rather than the milestone that needs it.
      {:exqlite, "~> 0.27"},

      # Config validation. Chosen specifically because it rejects UNKNOWN keys,
      # which is the typo defect the Python config had no defence against.
      {:nimble_options, "~> 1.1"},

      {:mox, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp releases do
    [
      merlin: [
        include_executables_for: [:unix],
        # Self-contained. This is what makes the daemon immune to a `pkg
        # upgrade` moving a runtime out from under it -- the exact failure that
        # took the Python version down when python3 moved 3.11 -> 3.12.
        include_erts: true,
        strip_beams: true,
        steps: [:assemble, :tar],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
