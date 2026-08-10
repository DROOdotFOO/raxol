defmodule Mix.Tasks.Mcp.Server do
  @shortdoc "Start the Raxol MCP server on stdio"
  @moduledoc """
  Starts the Raxol MCP server with stdio transport.

  This is the entry point for Claude Code and other MCP clients.
  Reads JSON-RPC messages from stdin, writes responses to stdout.

  ## Usage

      mix mcp.server

  ## .mcp.json Configuration

      {
        "mcpServers": {
          "raxol": {
            "type": "stdio",
            "command": "mix",
            "args": ["mcp.server"],
            "env": { "MIX_ENV": "dev" }
          }
        }
      }
  """

  use Mix.Task

  @impl true
  def run(_args) do
    # The client owns stdout: only JSON-RPC frames may appear there. Keep the
    # real stdio device for the transport, then point this process's group
    # leader at stderr so that everything writing to `:stdio` -- Mix's `==> app`
    # / `Compiling N files` banners and the `make` output from elixir_make --
    # lands on stderr instead of mid-stream.
    stdio = Process.group_leader()
    divert_group_leader_to_stderr()
    divert_logger_to_stderr()

    # Use lightweight MCP startup mode -- skip terminal driver, cache, Phoenix, etc.
    Application.put_env(:raxol, :skip_endpoint, true)
    Application.put_env(:raxol, :startup_mode, :mcp)

    # Start the application (includes MCP.Supervisor, Headless, etc.)
    Mix.Task.run("app.start")

    # `app.start` reloads config, which can restart :logger and reinstall the
    # default handler, so pin it to stderr again once the app is up.
    divert_logger_to_stderr()

    # Start stdio transport connected to the MCP server
    {:ok, transport} =
      Raxol.MCP.Transport.Stdio.start_link(
        server: Raxol.MCP.Server,
        name: Raxol.MCP.Transport.Stdio,
        io_device: stdio,
        output_device: stdio
      )

    # The transport stops when the client closes stdin. Exit with it rather
    # than leaving an orphaned VM holding the session's resources.
    await_exit(transport)
  end

  # Both halves matter: the application env is what a :logger restart during
  # `app.start` reads back, and the handler update is what takes effect for the
  # already-running handler.
  defp divert_logger_to_stderr do
    handler = Application.get_env(:logger, :default_handler, [])
    config = Keyword.get(handler, :config, %{})

    Application.put_env(
      :logger,
      :default_handler,
      Keyword.put(handler, :config, Map.put(config, :type, :standard_error)),
      persistent: true
    )

    _ = :logger.update_handler_config(:default, :config, %{type: :standard_error})
    :ok
  end

  defp divert_group_leader_to_stderr do
    case Process.whereis(:standard_error) do
      nil -> :ok
      pid -> Process.group_leader(self(), pid)
    end
  end

  defp await_exit(transport) do
    ref = Process.monitor(transport)

    receive do
      {:DOWN, ^ref, :process, ^transport, _reason} -> :ok
    end
  end
end
