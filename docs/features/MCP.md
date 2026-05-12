# MCP as a Rendering Target

Most frameworks bolt MCP on as a side channel. Raxol treats it as a first-class rendering target alongside terminal, browser, and SSH. The widget tree is the source of truth; MCP tools and resources are projections of it. See [ADR-0012](../adr/0012-mcp-as-rendering-target.md) for the design rationale.

## Quick Start

```bash
mix mcp.server
```

This starts an MCP server on stdio, with tools auto-derived from your app's widget tree. Wire it into Claude Code or any MCP client.

```elixir
# In your app
defmodule MyApp do
  use Raxol.Core.Runtime.Application
  # ... your normal init/update/view ...
end

# In an MCP client
session = Raxol.MCP.Test.start_session(MyApp)
session
|> type_into("search", "elixir")
|> click("submit")
|> assert_widget("results", fn w -> w[:content] != nil end)
```

The agent sees a structured widget tree, not a flat screenshot. It picks the action it wants from a typed schema.

## Tool Derivation

Each interactive widget implements `Raxol.MCP.ToolProvider`. The protocol exposes semantic actions per widget:

| Widget       | Actions                                       |
| ------------ | --------------------------------------------- |
| `Button`     | `click`                                       |
| `TextInput`  | `type_into`, `clear`, `get_value`             |
| `SelectList` | `select`, `get_selected`                      |
| `Checkbox`   | `toggle`, `check`, `uncheck`                  |
| `Modal`      | `open`, `close`, `is_open`                    |
| `Table`      | `select_row`, `sort_by`, `filter`             |
| `Tree`       | `expand`, `collapse`, `select_node`           |

Add `@mcp_exclude true` to a widget's attrs to suppress tool derivation -- useful for internal scaffolding widgets that shouldn't show up in the agent's action menu.

## Focus Lens

A widget tree with 50 widgets generates 100+ tools. That's too many for an LLM to reason about. The focus lens filters to ~15 tools per interaction based on:

- Current focused widget
- Mouse hover (in `:hover` focus mode)
- Modal stack (modals shadow background widgets)
- Recently interacted-with widgets

```elixir
{:ok, tools} = Raxol.MCP.FocusLens.relevant_tools(session)
length(tools) # ~15, not ~100
```

The lens is attention-aware: agents see what a human would see, not a flat dump of every possible action.

## Resources

Model state is exposed as MCP resources via projections declared on the app:

```elixir
defmodule MyApp do
  use Raxol.Core.Runtime.Application

  @mcp_resource "myapp://state/cart"
  def project_cart(model), do: %{items: model.cart, total: cart_total(model)}
end
```

The MCP client can read `myapp://state/cart` to inspect what the agent is working with. Updates stream as diffs through `Raxol.MCP.Diff` -- the agent doesn't need to re-fetch the full state every turn.

## Test Harness

`Raxol.MCP.Test` is a pipe-friendly test harness:

```elixir
import Raxol.MCP.Test
import Raxol.MCP.Test.Assertions

test "submit flow" do
  session = start_session(MyApp)

  session
  |> type_into("email", "user@example.com")
  |> type_into("password", "secret")
  |> click("submit")
  |> assert_widget("status", fn w -> w.content == "Logged in" end)
  |> stop_session()
end
```

The harness goes through the same MCP transport as a real client, so what your tests exercise is what an agent will hit.

## Context Tree

`Raxol.MCP.ContextTree` assembles a unified view of state from:

- TEA model
- Widget tree (with focus lens applied)
- Active agents (`Raxol.Agent.Registry`)
- Swarm state (when distributed)
- Pending notifications

The tree is streamed as diffs over the MCP connection -- agents track changes incrementally rather than polling.

## Property Tests

`Raxol.MCP.ToolProvider` is functor-law-tested: tool derivation commutes with widget composition. If you compose two widgets, the derived tools are the same as the tools you'd get by deriving them separately and merging. This catches bugs where a wrapping widget would accidentally hide tools from a child.

## What This Enables

The same TEA module the human uses, the agent uses too. Same source of truth, different projections. That's the pitch a framework can only make if MCP is a first-class rendering target rather than an afterthought.

## See Also

- [ADR-0012](../adr/0012-mcp-as-rendering-target.md) -- design rationale
- [Agent Framework](AGENT_FRAMEWORK.md) -- agents that consume MCP
- [Symphony](SYMPHONY.md) -- orchestrator that exposes its own MCP surface
