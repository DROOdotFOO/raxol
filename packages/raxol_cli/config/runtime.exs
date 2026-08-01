import Config

# Runtime config for the released `raxol` command. Keep logs quiet on the
# user-facing stdout at runtime too (compile config can be overridden by a host
# LOGGER level otherwise).
if config_env() == :prod do
  config :logger, level: :warning
end
