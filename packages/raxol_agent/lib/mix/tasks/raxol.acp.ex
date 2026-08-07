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
  read-only toolset — see `Raxol.Agent.ClientProtocol.StdioAgent`.

  ## Editor wiring (Zed)

      // settings.json
      "agent_servers": {
        "Raxol": {
          "command": "mix",
          "args": ["raxol.acp"],
          "cwd": "/path/to/raxol/packages/raxol_agent"
        }
      }

  ## Availability

  The ACP protocol package (`raxol_agent_client_protocol`) is a dev/test
  path dependency of raxol_agent: this task works from a repo checkout.
  A Hex install of raxol_agent must add `:raxol_agent_client_protocol` to
  its own deps to use it; without the package the task exits 1 with this
  explanation.

  ## Options

    * `--backend NAME` — LLM backend (auto-detected if omitted; `--harness`
      is a deprecated alias)
    * `--model NAME`   — model override
    * `-h`/`--help`    — print usage and exit
  """

  use Mix.Task

  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Transport.Stdio,
              Raxol.AgentClientProtocol.Agent,
              Raxol.Agent.ClientProtocol.StdioAgent
            ]}

  @switches [backend: :string, harness: :string, model: :string, help: :boolean]
  @aliases [h: :help]

  @usage """
  Usage: mix raxol.acp [options]

  Serve the coding agent over the Agent Client Protocol on stdio
  (for ACP-speaking editors such as Zed).

  Options:
    --backend NAME   LLM backend (auto-detected if omitted; --harness is a
                     deprecated alias)
    --model NAME     model override
    -h, --help       print this help

  Full docs: mix help raxol.acp
  """

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) ->
        IO.puts(@usage)

      invalid != [] ->
        usage_error("unknown options: #{inspect(invalid)}")

      not acp_available?() ->
        IO.puts(
          :stderr,
          "raxol.acp: the ACP package is not available in this build; " <>
            "run from the raxol repo (packages/raxol_agent), or add " <>
            ":raxol_agent_client_protocol to your deps"
        )

        exit({:shutdown, 1})

      true ->
        serve(opts)
    end
  end

  defp acp_available? do
    Code.ensure_loaded?(Raxol.Agent.ClientProtocol.TurnRunner) and
      Raxol.Agent.ClientProtocol.TurnRunner.available?() and
      Code.ensure_loaded?(Raxol.Agent.ClientProtocol.StdioAgent)
  end

  defp serve(opts) do
    # Provider first: a config problem exits 1 before anything binds stdio.
    executor =
      case Raxol.Agent.Backend.Cli.resolve_executor(opts, nil) do
        {:ok, executor, _source} -> executor
        {:error, message} -> config_error(message)
      end

    # stdout is the wire: NDJSON only. Logs to stderr, no terminal driver,
    # no web endpoint — the same boot moves as `mix mcp.server`.
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
    Application.put_env(:raxol, :skip_endpoint, true)
    Application.put_env(:raxol, :startup_mode, :mcp)
    System.put_env("RAXOL_SKIP_TERMINAL_INIT", "true")
    Mix.Task.run("app.start")

    {:ok, handle} = Raxol.AgentClientProtocol.Transport.Stdio.start_self()

    {:ok, _sup} =
      Raxol.AgentClientProtocol.Agent.start_link(
        Raxol.Agent.ClientProtocol.StdioAgent,
        transport: {Raxol.AgentClientProtocol.Transport.Stdio, handle},
        handler_arg: %{turn_opts: turn_opts(executor)}
      )

    Process.sleep(:infinity)
  end

  # Read-only toolset, matching the StdioAgent contract.
  defp turn_opts(executor) do
    [
      executor: executor,
      actions: Raxol.Agent.Actions.Fs.all() ++ Raxol.Agent.Actions.Code.read_only(),
      system_prompt:
        "You are a coding assistant driven by an editor over ACP. Use the " <>
          "available read-only tools to inspect files. Be concise."
    ]
  end

  defp usage_error(message) do
    IO.puts(:stderr, "raxol.acp: #{message}\n\n#{@usage}")
    exit({:shutdown, 64})
  end

  defp config_error(message) do
    IO.puts(:stderr, "raxol.acp: #{message}")
    exit({:shutdown, 1})
  end
end
