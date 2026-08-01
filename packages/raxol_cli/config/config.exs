import Config

# The CLI's stdout is the user interface (agent replies, TUI). Keep framework
# info/debug logs off it; surface warnings and errors only.
config :logger, level: :warning
