import Config

# Runtime config for the released `raxol` command. Keep logs quiet on the
# user-facing stdout at runtime too (compile config can be overridden by a host
# LOGGER level otherwise).
if config_env() == :prod do
  config :logger, level: :warning
end

# `raxol mcp`. The release starts every application before `Raxol.CLI.main/1`
# sees its arguments, and this file runs after kernel and before all of them,
# so this is the one place that decides how `raxol mcp` boots. It fires on
# `RAXOL_MODE=mcp` (the plugin's env sets it), or in the Burrito binary when
# the plain arguments, past the npm launcher's `--no-halt --`, start with
# `mcp`. Outside Burrito the plain arguments are Mix's or `erl`'s, not ours.
mcp_argv? = fn ->
  args = Enum.map(:init.get_plain_arguments(), &List.to_string/1)

  case Enum.drop_while(args, &(&1 == "--no-halt")) do
    ["--", "mcp" | _] -> true
    ["mcp" | _] -> true
    _ -> false
  end
end

if System.get_env("RAXOL_MODE") == "mcp" or
     (System.get_env("__BURRITO") != nil and mcp_argv?.()) do
  # The authorizers return only :allow or {:deny, _}: an {:ask, _} hides the
  # tool from tools/list, and OMP never answers an elicitation.
  config :raxol,
    startup_mode: :mcp,
    mcp_authorizer: {Raxol.CLI.MCP, :authorize},
    mcp_read_authorizer: {Raxol.CLI.MCP, :authorize_read},
    mcp_harness_tools: false,
    mcp_server_version: Raxol.CLI.version()

  config :raxol_cli, mcp_boot: true

  # Every application master started from here on takes its group leader from
  # application_controller, so stray `IO.puts`/`IO.write` from any app (an
  # OSC sequence a demo writes, a banner) goes to stderr, not onto the wire.
  # The wire itself writes to `user` directly.
  Process.group_leader(
    Process.whereis(:application_controller),
    Process.whereis(:standard_error)
  )
end
