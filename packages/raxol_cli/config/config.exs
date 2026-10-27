import Config

# The CLI's stdout is the user interface (agent replies, TUI). Keep framework
# info/debug logs off it; surface warnings and errors only.
config :logger, level: :warning

# Logs go to stderr for every subcommand: on `raxol mcp` stdout is the JSON-RPC
# wire, and `logger_std_h` bound to standard_io writes to `user` directly, past
# any group leader. Build time, so it lands in sys.config before :logger starts.
# (The wire's encoding is set in rel/vm.args.eex: Mix refuses :kernel config.)
config :logger, :default_handler, config: [type: :standard_error]
