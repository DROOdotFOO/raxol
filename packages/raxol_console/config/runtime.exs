import Config

# Runtime configuration for a released Console runtime. Applied only to a prod
# release boot: in :test the app is a passive dependency driven by the suite, and
# in :dev the mix session should not self-boot a runtime. Guarding on
# `config_env() == :prod` also avoids hijacking main raxol's `:test` startup mode
# (`determine_startup_mode/1` consults `Application.get_env(:raxol, :startup_mode)`
# before its `:test` fallback).
if config_env() == :prod do
  # Headless: a managed runtime has no tty, so main raxol must not start terminal
  # drivers. `:minimal` selects the ultra-minimal, driver-free supervision tree.
  config :raxol, startup_mode: :minimal

  # Locate the provisioned agent package. The Console injects this path; the OTP
  # `mod:` callback (`Raxol.Console.Application`) also falls back to it directly.
  if package = System.get_env("RAXOL_CONSOLE_PACKAGE") do
    config :raxol_console, package_dir: package
  end

  # Workspace root: the filesystem MCP server's allowed scope and the agent's cwd.
  if workspace = System.get_env("RAXOL_CONSOLE_WORKSPACE") do
    config :raxol_console, workspace: workspace
  end

  # Default delivery target for scheduled-task output ("platform:chat_id").
  if target = System.get_env("RAXOL_CONSOLE_DEFAULT_TARGET") do
    config :raxol_console, default_target: target
  end

  # Bundle the default MCP server set (filesystem, fetch, git, time, sequential
  # thinking) at boot unless explicitly disabled.
  config :raxol_console,
    bundle_default_mcp: System.get_env("RAXOL_CONSOLE_BUNDLE_MCP", "true") == "true"

  # Inference resolves through the agent runtime's provider chain (op-ref ->
  # provider-env -> AI_API_KEY); unresolved falls through to Mock, so a boot with
  # no credentials is safe. Channels and their bot-token credentials are
  # deployment-supplied and injected by the Console's acp-cli; wiring them maps to
  # the `:channels` key here (ADR-0031, open injection seam).
  config :raxol_console, agent_opts: [auto_provider: true]
end
