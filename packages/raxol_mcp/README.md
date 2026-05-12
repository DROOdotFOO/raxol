# Raxol MCP

MCP (Model Context Protocol) server and client for Elixir. JSON-RPC 2.0 protocol, tool/resource registry, stdio and SSE transports. Auto-derives agent tools from your widget tree.

## Install

```elixir
{:raxol_mcp, "~> 2.4"}
```

## Features

- **MCP Server** -- GenServer routing tool/resource requests via JSON-RPC 2.0
- **MCP Client** -- stdio JSON-RPC 2.0 client for consuming external MCP servers
- **Registry** -- ETS-backed tool/resource/prompt registration (no GenServer bottleneck)
- **Transports** -- stdio (CLI tools) and HTTP/SSE (Plug-based, no Phoenix)
- **ToolProvider** -- auto-derive MCP tools from widget trees (15 widgets)
- **FocusLens** -- attention-aware tool filtering (focused/all/hover modes)
- **ResourceProvider** -- expose TEA model state as MCP resources
- **Test Harness** -- pipe-friendly API (`click`, `type_into`, `assert_component`), functor law property tests
- **Circuit Breaker** -- 3-state ETS machine for flaky tool callbacks

## Quick Start

```elixir
# Register a tool
Raxol.MCP.Registry.register_tool(%{
  name: "my_tool",
  description: "Does a thing",
  input_schema: %{type: "object", properties: %{}}
})

# Start MCP server on stdio
mix mcp.server
```

## Architecture

- `Raxol.MCP.Server` -- GenServer handling JSON-RPC dispatch
- `Raxol.MCP.Registry` -- ETS-backed registration (tools, resources, prompts)
- `Raxol.MCP.Protocol` -- JSON-RPC 2.0 encode/decode
- `Raxol.MCP.Transport.Stdio` -- stdio transport for CLI
- `Raxol.MCP.Transport.SSE` -- HTTP/SSE transport (Plug)
- `Raxol.MCP.Client` -- consume external MCP servers
- `Raxol.MCP.ToolProvider` -- widget-to-tool derivation behaviour
- `Raxol.MCP.Test` -- test harness with assertions

See [main docs](../../README.md) for full examples.
