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
    # Configure logger to stderr so it doesn't corrupt the JSON-RPC stream
    :logger.update_handler_config(:default, :config, %{type: :standard_error})

    # Use lightweight MCP startup mode -- skip terminal driver, cache, Phoenix, etc.
    Application.put_env(:raxol, :skip_endpoint, true)
    Application.put_env(:raxol, :startup_mode, :mcp)

    # Start the application (includes MCP.Supervisor, Headless, etc.)
    Mix.Task.run("app.start")

    # Start stdio transport connected to the MCP server
    {:ok, _pid} =
      Raxol.MCP.Transport.Stdio.start_link(
        server: Raxol.MCP.Server,
        name: Raxol.MCP.Transport.Stdio
      )

    # Block forever -- the transport handles I/O in its reader process
    Process.sleep(:infinity)
  end
end
