import Config

# Warnings are not noise in a test run; they are the thing tier 1 is for.
config :logger, level: :warning

# Tiers 1-4 are pure by definition. A unit suite that quietly requires a
# listening broker fails for reasons that have nothing to do with the code
# under test, and then gets marked flaky rather than fixed.
config :merlin, start_mqtt: false

# Tier 3 validates the shipped file directly; tiers 1 and 2 install config
# per-test. Point the loader at the real file for anything that asks.
config :merlin, config_path: Path.expand("../priv/merlin.exs", __DIR__)
