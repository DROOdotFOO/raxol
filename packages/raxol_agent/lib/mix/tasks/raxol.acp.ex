defmodule Mix.Tasks.Raxol.Acp do
  @shortdoc "Serve the coding agent over the Agent Client Protocol on stdio"

  @moduledoc """
  Boot the coding agent as an [ACP](https://agentclientprotocol.com) agent
  on this process's own stdio, so an ACP-speaking editor can spawn and
  drive it.

      mix raxol.acp
      mix raxol.acp --backend anthropic --model claude-sonnet-5

  stdout carries newline-delimited JSON-RPC; every log line is rerouted to
  stderr. The provider resolves like every other coding-agent entrypoint
  (explicit `--backend`, else `Raxol.Agent.Backend.Resolver` auto-detect);
  with nothing configured the task exits 1 with a setup hint. Turns run the
  FULL toolset, every sensitive call gated on a `session/request_permission`
  round trip — see `Raxol.Agent.ClientProtocol.StdioAgent`.

  Note that a native-CLI backend (`--backend claude_native` and friends) runs
  its own tool loop instead, so none of that gating applies; the task says so
  on stderr at boot.

  ## Editor wiring (Zed)

  Point the editor at the `bin/raxol-acp` shim, not `mix` directly: `mix`
  prints compile output to stdout on first run, which would corrupt the
  NDJSON wire. The shim compiles quietly first, then serves. Set the
  editor's `cwd` to your project so the file tools scope there.

      // settings.json
      "agent_servers": {
        "Raxol": {
          "command": "/path/to/raxol/bin/raxol-acp",
          "args": [],
          "cwd": "/path/to/your/project"
        }
      }

  Each session's file tools scope to the `cwd` the editor sends in
  `session/new` (the field shown above), so one server can drive projects in
  different directories and each tool call is contained under its own session
  root. When a client sends a blank `cwd`, the process working directory
  (`RAXOL_CLI_CWD`, which the shim sets to its own cwd) applies.

  ## Availability

  This is a repo-checkout feature. The ACP protocol package
  (`raxol_agent_client_protocol`) is a dev/test path dependency, so
  `Raxol.Agent.ClientProtocol.StdioAgent` compiles only when raxol_agent is
  built from source with that package present. A Hex install of raxol_agent
  is compiled without it, so the module is absent and this task exits 1 with
  an explanation — adding the dep downstream does not retroactively enable
  it. Build raxol_agent from the repo to use ACP.

  ## Options

    * `--backend NAME` — LLM backend (auto-detected if omitted; `--harness`
      is a deprecated alias)
    * `--model NAME`   — model override
    * `-h`/`--help`    — print usage and exit
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # stdout is the wire, so nothing may print to it before the transport binds.
    # `app.start` reloads config and restarts :logger, which reinstates a
    # stdout-bound default handler; seed :logger's env so the restarted handler
    # comes up on stderr instead of putting every startup log line on the wire.
    # (`Serve` re-asserts this after boot.) Mix's own `==> dep` announcements go
    # to stdout too, hence the quiet shell and the skipped checks.
    Application.put_env(:logger, :default_handler, config: %{type: :standard_error})

    Application.put_env(:raxol, :skip_endpoint, true)
    Application.put_env(:raxol, :startup_mode, :mcp)
    System.put_env("RAXOL_SKIP_TERMINAL_INIT", "true")
    Mix.shell(Mix.Shell.Quiet)

    # Boot without recompiling (bin/raxol-acp precompiles silently), then hand
    # off to the shared runner -- `Raxol.Agent.ClientProtocol.Serve` contains no
    # Mix calls, so the same code path serves the Burrito-packaged `raxol acp`
    # where Mix does not exist. `--help`, usage errors, and provider resolution
    # are answered by the runner, so every entrypoint agrees.
    Mix.Task.run("app.start", [
      "--no-compile",
      "--no-deps-check",
      "--no-archives-check",
      "--no-elixir-version-check"
    ])

    exit({:shutdown, Raxol.Agent.ClientProtocol.Serve.run(argv)})
  end
end
