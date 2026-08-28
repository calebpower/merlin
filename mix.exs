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
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test"],
      dialyzer: dialyzer()
    ]
  end

  # The PLT is minutes to build and seconds to reuse, so it lives on the reaper
  # pool with the other caches rather than on the guest's root disk -- which
  # has ~3.3 GiB free and would not survive it.
  defp dialyzer do
    cache = System.get_env("REAPER_CACHE_BUILD") || "_build"

    [
      plt_local_path: Path.join(cache, "plt"),
      plt_core_path: Path.join(cache, "plt"),
      # The test tree is checked too. test/support is ordinary code that the
      # simulated house depends on, and a shadow model with a type error is a
      # shadow model that is wrong about the thing it exists to check.
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :unknown]
    ]
  end

  # Tier 9's simulated house needs a fake broker and a shadow model, and they
  # are ordinary modules rather than something defined inside a test file --
  # the shadow model in particular has to be readable on its own, because a
  # shadow nobody can read is just a second implementation of the same bug.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # `merlind`, not `merlin`. The release's boot script is the daemon control
  # interface -- start, stop, rpc -- and the plain name is reserved for the
  # command-line tool. The OTP application stays `:merlin`; only the release
  # and its bin/ script are named for the daemon.
  defp releases do
    [
      merlind: [
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
