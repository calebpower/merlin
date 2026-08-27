import Config

config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:rule, :fact, :adapter]

import_config "#{config_env()}.exs"
