# MCP as a Rendering Target

MCP is a rendering target alongside terminal, browser, and SSH. The Component tree is the source of truth, and MCP tools and resources are projections of it, so the same running module serves a human and an agent without either seeing a different truth. See [ADR-0012](https://github.com/DROOdotFOO/raxol/blob/master/docs/adr/0012-mcp-as-rendering-target.md) for the design rationale.

## Quick start

```bash
mix mcp.server
```

This starts an MCP server on stdio, with tools auto-derived from your app's Component tree. Wire it into Claude Code or any MCP client.

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
|> assert_component("results", fn c -> c[:content] != nil end)
```

The agent sees a structured Component tree, not a flat screenshot. It picks the action it wants from a typed schema.

## Tool derivation

Each interactive Component implements `Raxol.MCP.ToolProvider`. The protocol exposes semantic actions per Component:

| Component    | Actions                                       |
| ------------ | --------------------------------------------- |
| `Button`     | `click`                                       |
| `TextInput`  | `type_into`, `clear`, `get_value`             |
| `SelectList` | `select`, `get_selected`, `get_options`       |
| `Checkbox`   | `toggle`, `get_checked`                       |
| `Modal`      | `confirm`, `dismiss`                           |
| `Table`      | `select_row`, `sort`, `get_rows`              |
| `Tree`       | `expand`, `collapse`, `select_node`           |

Add `@mcp_exclude true` to a Component's attrs to suppress tool derivation, useful for internal scaffolding Components that shouldn't show up in the agent's action menu.

## Focus lens

A Component tree with 50 Components generates 100+ tools. That's too many for an LLM to reason about. The focus lens filters to ~15 tools per interaction based on:

- Current focused Component
- Mouse hover (in `:hover` focus mode)
- Modal stack (modals shadow background Components)
- Recently interacted-with Components

```elixir
tools =
  Raxol.MCP.FocusLens.filter(all_tools,
    mode: :focused,
    focused_id: "search_input",
    max_tools: 15
  )

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

The MCP client can read `myapp://state/cart` to inspect what the agent is working with. Updates stream as diffs through `Raxol.MCP.Diff`, so the agent doesn't need to re-fetch the full state every turn.

## Test harness

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
  |> assert_component("status", fn c -> c.content == "Logged in" end)
  |> stop_session()
end
```

The harness goes through the same MCP transport as a real client, so what your tests exercise is what an agent will hit.

## Context tree

`Raxol.MCP.ContextTree` assembles a unified view of state from:

- TEA model
- Component tree (with focus lens applied)
- Active agents (`Raxol.Agent.Registry`)
- Swarm state (when distributed)
- Pending notifications

The tree is streamed as diffs over the MCP connection, so agents track changes incrementally rather than polling.

## Authorization

`Raxol.MCP.Server` evaluates an authorizer before running a tool. It is a 3-arity fun returning `:allow`, `{:ask, prompt}`, or `{:deny, reason}`, and `Raxol.Application` supplies it explicitly:

```elixir
config :raxol,
  mcp_authorizer: fn tool, _args, _ctx ->
    if String.starts_with?(tool, "raxol_"), do: :allow, else: {:deny, :not_mine}
  end,
  # Guards resources/read, tools/list, prompts/get and the other read surfaces.
  # Receives the METHOD name in the tool-name position.
  mcp_read_authorizer: fn _method, _args, _ctx -> :allow end
```

A value that is not a 3-arity fun raises at boot rather than being ignored, so a deployment cannot believe it configured a policy while running without one.

### Defaults

Outside production, unconfigured resolves to `Raxol.MCP.Authorizer.allow_all/0`: what the implicit `nil` already did, now visible at the call site so `mix mcp.server` keeps working.

In production it resolves to a deny-by-default allowlist:

```elixir
config :raxol,
  mcp_allowed_tools: ["raxol_screenshot"],
  # Defaults to the listing methods; resources/read and the subscribe pair are
  # absent because they stream live model state.
  mcp_allowed_read_methods: ~w(tools/list resources/list prompts/list prompts/get completion/complete)
```

Empty is the default for tools, so nothing runs until a deployment names it. That is tighter than the `nil` it replaced, not merely more explicit: `Authorizer.decide/4` treats `nil` as allow, so a production server previously ran any tool nobody had annotated sensitive.

The default must not be `allow_all` in production. `Raxol.MCP.Server.authorization_configured?/1` is `authorizer != nil`, and the SSE transport's boot gate (`Raxol.MCP.Deployment.enforce_authorization!/2`) reads exactly that value, so a blanket allow would satisfy the gate and let a network transport serve every tool unguarded.

Reads cannot take the same empty default: `tools/list` is a read, so denying every read would leave an allowlisted tool undiscoverable and the server unusable rather than closed. The split is by what a method discloses. Listing methods reveal names the server already advertises, while `resources/read` streams state.

### Annotations

A tool annotated `destructiveHint: true` or `sensitive: true` never runs without an authorizer, enforced twice: the server refuses to boot when such a tool is already registered, and refuses the call itself for one registered afterwards. Of the headless tools, `raxol_start`, `raxol_send_key`, and `raxol_stop` carry the annotation; the three read tools do not.

### Transports

stdio is exempt by design, since it already inherits the OS process boundary.

`Raxol.Headless.McpTools.inject_into_tidewave/1` is not exempt. Tidewave dispatches out of its own ETS map, so a raw callback written there would never reach `Raxol.MCP.Server`; what gets injected is a closure that re-enters through `tools/call` on the server named by `:server`, so this surface inherits the same policy as every other. A server that is down denies rather than falling back to the raw callback.

That gates Raxol's tools, not Tidewave's. Tidewave ships its own, and nothing here constrains them: `project_eval` evaluates Elixir in the running node. Whether that endpoint may be reached at all is an endpoint-level decision: authentication and bind address, not tool policy.

## Property tests

`Raxol.MCP.ToolProvider` is functor-law-tested: tool derivation commutes with Component composition. If you compose two Components, the derived tools are the same as the tools you'd get by deriving them separately and merging. This catches bugs where a wrapping Component would accidentally hide tools from a child.

## See also

- [ADR-0012](https://github.com/DROOdotFOO/raxol/blob/master/docs/adr/0012-mcp-as-rendering-target.md): design rationale
- [Agent Framework](AGENT_FRAMEWORK.md): agents that consume MCP
- [Symphony](SYMPHONY.md): orchestrator that exposes its own MCP surface
