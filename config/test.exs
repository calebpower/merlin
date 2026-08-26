import Config

# Warnings are not noise in a test run; they are the thing tier 1 is for.
config :logger, level: :warning

# Tiers 1-4 are pure by definition. A unit suite that quietly requires a
# listening broker fails for reasons that have nothing to do with the code
# under test, and then gets marked flaky rather than fixed.
config :merlin, start_mqtt: false
