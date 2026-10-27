# MCP as a Rendering Target

MCP is a rendering target alongside terminal, browser, and SSH. The Component tree is the source of truth, and MCP tools and resources are projections of it, so the same running module serves a human and an agent without either seeing a different truth. See [ADR-0012](https://github.com/DROOdotFOO/raxol/blob/master/docs/adr/0012-mcp-as-rendering-target.md) for the design rationale.

## Quick start

```bash
mix mcp.server
```

This starts an MCP server on stdio, with tools auto-derived from your app's Component tree and named per session (`<session>.<widget>.<action>`). Wire it into Claude Code or any MCP client.

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
| `Scrubber`   | `seek`, `play`, `pause`, `get_position`       |

A write action reaches your app's `update/2` as a plain message, such as `{:sort, "results", "stars", "desc"}` from a Table's `sort`, and the tool answers once `update/2` has run. An `update/2` that raises or returns an invalid result makes the call an error result. A call that times out (after 5 s) is an error result too, but `update/2` may still apply the message afterwards, so check the app's state before retrying it. Add `update/2` clauses for the messages your app acts on; `Raxol.MCP.ToolProvider` lists every action's message. A Button's `click` sends the node's `on_click` message as it was when the tool was derived: a later render that changes `on_click` does not change what `click` sends. A button whose `on_click` is missing or a function gives an error result.

Derived tools are named `<session>.<widget>.<action>`: `demo.results.sort` is the `sort` action of the Component with id `results` in the headless session `demo`. Two sessions of one app each get their own tools, and stopping one removes only its own. Each session also gets `<session>.discover_tools`, which searches that session's tools by keyword. The session id is the first segment of every name, so `Raxol.Headless.start/2` refuses an id that is not 1-32 characters of `[A-Za-z0-9_-]` (`Raxol.MCP.TreeWalker.id?/1`), and a `Raxol.MCP.ToolSynchronizer` started directly with one derives no tools at all, `discover_tools` included, registers none of its `raxol://session/<id>/...` resources, and a warning names the id: an id with a `.` (such as `t.v2`) would otherwise read as session `t`, and a control character would reach the client's tool and resource lists.

An MCP client may rename tools. OMP lowercases a name, turns every run of characters outside `[a-z0-9_]` into `_`, collapses and trims `_`, and uses `tool` if nothing is left, so `demo.x_y.click` and `demo.x-y.click` would reach it as one tool. `Raxol.MCP.Registry` computes that name (`Raxol.MCP.Registry.omp_name/1`) at registration and refuses a tool whose name is already taken there by another. The session logs the refusal and offers the tool again on every render, so it registers once the name is free. `raxol_start` and `Raxol.Headless.start/2` refuse to start a session any of whose first render's tools is refused, and stop it, so neither a client nor an Elixir caller holds a session it cannot fully drive: a client's session `s` started first holds the names of an Elixir caller's `S`, whose `start/2` answers `{:error, {:name_collisions, names}}`, naming only its own refused tools. OMP then strips an exact `<server>_` prefix once, which `omp_name/1` does not model: name the server `raxol` in your OMP config (the `raxol:raxol` plugin key, or the `.mcp.json` key `raxol`), which is why `raxol_start` refuses the session id `raxol` (its `raxol.nav_menu.click` would reach OMP as session `nav`'s `nav.menu.click`). The reservation covers only those keys. Under another key that a session id can spell, such as `dev`, session `dev`'s `dev.nav_menu.click` reaches OMP as `nav_menu_click`, the same name as session `nav`'s `nav.menu.click`, and OMP keeps only one of them.

A call to a derived name whose session is not running in this server answers a tool error that names the session and points to `raxol_list`, not an unknown-method error: OMP keeps the names from its last listing, even across runs. Headless decides this, not the generic server: `Raxol.Application` starts `Raxol.MCP.Server` with `unknown_tool_reply: &Raxol.Headless.McpTools.unknown_tool_reply/1`, which answers for a name of the derived shape whose session is not in `Raxol.Headless.list/0` and is not one of the reserved ids `raxol` and `agent`. A server started without that option answers every unknown name with `-32601`.

OMP's `tools.approval` deny and prompt entries also match a digit-free legacy form of each name, so sessions `a1` and `a2` share legacy names and one legacy entry applies to both.

Session ids are not secret from a connected client. Gating `raxol_list` hides only the list itself: ids still show up in tool and resource names (`tools/list`, `resources/list`, completion), in `raxol_start`'s refusals and in the stale-session reply. Per-connection session ownership (a client sees and controls only the sessions it started) is planned as the single rule for this; until then, treat every session in a server as visible to every client of that server.

Add `@mcp_exclude true` to a Component's attrs to suppress tool derivation, useful for internal scaffolding Components that shouldn't show up in the agent's action menu.

## Focus lens

A Component tree with 50 Components generates 100+ tools. That's too many for an LLM to reason about. `Raxol.MCP.FocusLens.filter/2` cuts a tool list to about 15 based on:

- The focused Component (`:focused_id`)
- The hovered Component (`:hover_id`, in `:hover` mode)

```elixir
tools =
  Raxol.MCP.FocusLens.filter(all_tools,
    mode: :focused,
    session_id: "demo",
    focused_id: "search_input",
    max_tools: 15
  )

length(tools) # ~15, not ~100
```

Nothing filters what a client lists for you: the server lists every registered tool, and the lens is for code that builds its own tool list. It works within one session: a tool belongs to the session whose id is exactly the first `.` segment of its name, so another session's tools for a Component with the same id never leak in, and the session's `discover_tools` searches only that session.

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

The third argument is the authorization context: `%{conn_id: term(), transport: :stdio | :sse | :unknown}`, both server-derived. `conn_id` is the connection the request arrived on (`:default` for stdio and direct callers, a per-session value for SSE); `transport` is what the embedder declared the server fronts, via `transport:` on `Raxol.MCP.Server.start_link/1` or `Raxol.MCP.Supervisor`, and reads `:unknown` when nobody declared one. Nothing the client asserts is in there, and nothing should be added: a policy keyed on a client-declared name or version is bypassed by declaring a different one.

**In a release, the fun form only works from `config/runtime.exs`.** `config/config.exs` is evaluated at build time and its result is written to `sys.config`, which holds serializable terms only; an anonymous function is not one. Name the function instead, which survives into `sys.config`:

```elixir
# config/config.exs, or runtime.exs: either works for this form.
config :raxol, mcp_authorizer: {MyApp.McpPolicy, :authorize}
```

The module and its 3-arity function are checked when the authorizer is resolved, so a typo is a boot failure naming the module rather than a tool that denies for a reason nobody can see.

### Defaults

Configuration binds in every environment. `mcp_allowed_tools` restricts the tools in dev exactly as it does in production; the environment decides only what happens when nothing is configured.

Unconfigured outside production resolves to `Raxol.MCP.Authorizer.allow_all/0`: what the implicit `nil` already did, now visible at the call site so `mix mcp.server` keeps working.

Unconfigured in production resolves to a deny-by-default allowlist:

```elixir
config :raxol,
  mcp_allowed_tools: ["raxol_screenshot"],
  # Defaults to the three LISTING methods. prompts/get returns prompt content
  # rather than names, and completion/complete is an enumeration primitive, so
  # neither is a default; resources/read and the subscribe pair stream live
  # model state and are likewise absent.
  mcp_allowed_read_methods: ~w(tools/list resources/list prompts/list)
```

Empty is the default for tools, so nothing runs until a deployment names it. That is tighter than the `nil` it replaced, not merely more explicit: `Authorizer.decide/4` treats `nil` as allow, so a production server previously ran any tool nobody had annotated sensitive.

The default must not be `allow_all` in production, and a non-nil default must not by itself open the network. `Raxol.MCP.Server.authorization_configured?/1` is therefore **not** `authorizer != nil`; it is `authorizer != nil and authorizer_source == :configured`, and the SSE boot gate (`Raxol.MCP.Deployment.enforce_authorization!/2`) reads that.

`:authorizer_source` is what separates a policy an operator wrote from a fallback raxol picked. **Naming `:mcp_authorizer` or `:mcp_allowed_tools` is what makes a network transport bootable**, including `mcp_allowed_tools: []`, since exposing a transport that serves nothing is a coherent choice and it is the operator's to make. The two READ keys deliberately do not count, because this gate is about running tools; the read seam has its own boot gate instead (see below). A framework fallback never counts, however strict it is: otherwise the gate stops being a forcing function, which is the whole reason it exists.

Embedding `Raxol.MCP.Server` or `Raxol.MCP.Supervisor` directly? `:authorizer_source` defaults to `:default`, so forgetting the option leaves the gate shut rather than satisfying it by omission. Pass `authorizer_source: :configured` when your own configuration decided the policy.

Reads cannot take the same empty default: `tools/list` is a read, so denying every read would leave an allowlisted tool undiscoverable and the server unusable rather than closed. The split is by what a method discloses. Listing methods reveal names the server already advertises, while `resources/read` streams state.

`logging/setLevel` goes through the read seam too, with the method name and `%{"level" => level}`. It is not in the default list, so a production deployment whose clients set the level adds `"logging/setLevel"` to `mcp_allowed_read_methods`.

`tools/list` is filtered per entry as well as gated as a method. Each tool goes through the same authorizer `tools/call` would consult, and only `:allow` is advertised; `{:ask, _}` hides exactly like `{:deny, _}`, since an entry needing an approval the caller has not got is not callable, and a policy that raises costs that tool its listing rather than failing the whole listing. A nil authorizer advertises everything.

The read seam itself still answers `:allow` when no read authorizer is configured, which is what stdio embedders have always had, so the fail-closed pressure sits at boot instead: `Raxol.MCP.Deployment.enforce_read_authorization!/2` refuses to mount the SSE transport without a `:read_authorizer`, naming `:mcp_read_authorizer` in the refusal, and a server started with `transport: :sse` runs the same check at its own boot. Satisfying the tool gate alone used to be enough to serve live model state, through `resources/read`, to any client that connected.

### Annotations

A tool annotated `destructiveHint: true` or `sensitive: true` never runs without an authorizer, enforced twice: the server refuses to boot when such a tool is already registered, and refuses the call itself for one registered afterwards. The runtime half needs the tool registry to be reachable to classify a tool, and fails closed when it is not, so a call during a registry restart is refused rather than treated as non-sensitive. Of the headless tools, `raxol_start`, `raxol_send_key`, `raxol_stop` and `raxol_get_model` carry the annotation; `raxol_screenshot` and `raxol_list` do not. `raxol_get_model` is a read, but it returns the whole model, and an app keeps its secrets there.

Derived tools keep two annotations of their tool spec, and only when `true`: `sensitive` and `destructiveHint`. They can only add the authorizer requirement. Any other key or value (`title`, `readOnlyHint`, `sensitive: false`) is dropped, because it is the provider's own claim and a client acts on it (OMP's plan mode reads `readOnlyHint`). Every built-in action that changes app state is `sensitive: true`: `click`, `type_into`, `clear`, `toggle`, `select`, `select_row`, `select_node`, `select_tab`, `sort`, `expand`, `collapse`, `dismiss`, `confirm`, `seek`, `play`, `pause` and `scroll_to`. The `get_*` reads are not, and a `TextInput` with a `mask_char` derives no `get_value`, as `PasswordField` derives none. No MCP channel a client can use without an authorizer returns either value: `raxol://session/<id>/widgets` reports no value for them, `raxol://session/<id>/context` drops the `value` of a password field or a node with a `mask_char`, the layout engine draws a masked `:text_input` as its mask, so `raxol_screenshot` shows the mask, and `raxol_get_model` and `agent.get_model`, which return the model the plaintext lives in, are `sensitive`. An authorizer that allows those two hands the client the plaintext. The context resource also includes the model projections the app declares in `mcp_resources/0`, so a secret an app projects there is readable. So a server embedded with no authorizer (`Raxol.MCP.Supervisor` or `Raxol.MCP.Server` without `:authorizer`) still lists and reads widgets, but refuses to drive them, or to return a model, with `sensitive_tool_unguarded`. The boot refusal scans static tools only: derived tools come and go with the view, and a Server restarted while sessions are live must still boot, so for them the `tools/call` refusal is what holds. A tool counts as derived by origin, not by a dotted name or a key in its tool map: only `Raxol.MCP.ToolSynchronizer` registers a session's tools as derived (`Raxol.MCP.Registry.register_tools/3` with `derived: true`), so a static tool such as `agent.send`, or one whose map carries `derived: true`, is still checked at boot. `Raxol.MCP.AgentBridge` follows the same rules: an Action declared `sensitive: true` becomes a `sensitive` tool, `agent.send`, which types into any headless session, is `sensitive` like `raxol_send_key`, and an Action's name, description and input schema go through the same checks and cleaning as a widget provider's spec.

A network deployment needs a function authorizer, not just a name allowlist. Derived tool names come and go with the view, so a fixed `mcp_allowed_tools` list cannot name them, and `allow_all` hands every widget to every client. A name the list does hold ties the tool to a session id the client picks, not to an app: `s1.form.click` authorizes that name for whatever startable app a client starts as `s1`. SSE connections also share sessions: every connection reaches every headless session and its derived tools, and the connection id comes from the client's `mcp-session-id` header, so it is not an identity to authorize on.

Derived tool descriptions are static per provider and action. App text (labels, titles, tab names) and widget ids never appear in them, only in tool results such as `get_tabs`. `Raxol.MCP.TreeWalker` strips control, format (bidi overrides, zero-width characters, BOM, tag characters), line/paragraph separator and private-use characters, variation selectors, the combining grapheme joiner, the Hangul fillers and the braille blank from every description, and from every string and every key inside a tool's `inputSchema` (titles, enums, defaults, examples, property names). An atom is cleaned as its name. A model reads the tool list as part of its instructions, so app text there would be a prompt injection with the app's authority.

A widget id and an action name both become part of the tool name. A provider widget whose id is not 1-32 characters of `[A-Za-z0-9_-]` derives no tools, an action whose name is not a lowercase letter followed by up to 31 of `[a-z0-9_]` derives no tool, and a warning names each. So does a spec whose description is neither a string nor an atom, whose `inputSchema` holds a term JSON cannot encode (a tuple, a struct, a pid, a function, an improper list, a key that is neither a string nor an atom), whose map has two keys equal once cleaned (`:amount` and `"amount"`), or whose `inputSchema` nests maps and lists deeper than 32 levels or holds more than 10,000 values (each map, list and leaf counts one): one such spec would otherwise make every client's `tools/list` unencodable, let one property definition replace another, or hold up every render while it is cleaned.

### Startable modules

`raxol_start` starts a module for whichever client called it, so it only starts a module on `Raxol.Headless.McpTools.startable/0`. That is the list under `:headless_startable` when it is set, and otherwise the playground demos except `Raxol.Playground.Demos.ReplDemo` (it evaluates Elixir) and `Raxol.Playground.Demos.BeamDashboardDemo` (it sets the VM-wide `:scheduler_wall_time` flag and shows VM internals). The default set is pinned in a test, so a new demo becomes startable only through a reviewed change. A set list replaces the demos, so a deployment names exactly what clients may start by module:

```elixir
config :raxol, :headless_startable, [MyApp]
```

To keep the demos as well, list them alongside your app; `Raxol.Headless.McpTools.default_startable/0` returns them. Every entry must be a loadable module (`Code.ensure_loaded?/1`). A value that is not a list of loadable modules stops the boot with a config error (`Raxol.Headless.McpTools.register/1` raises), and if it is changed at runtime, `raxol_start` answers with that error and starts nothing. The error does not count against the tool's circuit breaker, so fixing the config is enough.

Anything else is refused before the name is resolved, so an unlisted name never becomes an atom. Elixir callers of `Raxol.Headless.start/2`, such as `Raxol.MCP.Test` and `Raxol.Recording.Video`, are trusted and are not limited by the list. The `path` argument is a separate opt-in (`RAXOL_HEADLESS_PATH_ROOT`) and does not consult the list, because the module is only known after the file is compiled.

`raxol_start` requires an `id` matching `^[a-z][a-z0-9]{0,6}$` and refuses any other id rather than substituting one. No `_` or `.` keeps the session boundary clear after OMP's renaming (`a_b.c` and `a.b_c` would both become `a_b_c`), and seven characters keep the longest demo tool name within OMP's 64. `raxol` (the server key, see Tool derivation) and `agent` (the agent bridge's `agent.*` tools) are reserved. Session ids are binaries only and never become atoms. Every session id, Elixir callers' included, is 1-32 characters of `[A-Za-z0-9_-]`, the rule a widget id follows: an id reaches every client verbatim through `raxol_list`, session-id completion, resource URIs and tool names, so `Raxol.Headless.start/2` answers any other `:id` (invalid UTF-8, a newline, a dot, 33 characters) with `{:error, {:invalid_session_id, id}}` and starts nothing. Its default id, the module's last segment underscored, is made to fit: a character outside the rule becomes `_`, and a name over 32 characters becomes its first 23, `_` and 8 hex digits of the module's hash.

OMP's 64 counts its `mcp__raxol_raxol_` prefix (17 characters, for the `raxol:raxol` plugin key), which leaves 47 for `<session>_<widget>_<action>`. A widget id may be 32 characters, so a 7-character session, a 32-character widget and the 17-character `get_visible_range` come to 58 characters, 75 with the prefix. Past 64 OMP lists the first 55 characters, `_` and a hash: still callable, but every action of such a widget can look alike to a reader. The session logs a warning, once per name, for each derived tool past 64 with the prefix; widget ids of at most 21 characters keep every built-in action readable under a 7-character session.

### Transports

stdio is exempt by design, since it already inherits the OS process boundary.

`Raxol.Headless.McpTools.inject_into_tidewave/1` is not exempt. Tidewave dispatches out of its own ETS map, so a raw callback written there would never reach `Raxol.MCP.Server`; what gets injected is a closure that re-enters through `tools/call` on the server named by `:server`. Both halves of the record are substituted (the dispatch map AND the advertised tool entries' own `:callback`), so a consumer reaching for `tool.callback` cannot bypass the authorizer either. A server that is down denies rather than falling back to the raw callback, and the wait is bounded so one slow tool cannot hold the surface open indefinitely.

That gates Raxol's tools, not Tidewave's. Tidewave ships its own, and nothing here constrains them: `project_eval` evaluates Elixir in the running node. Whether that endpoint may be reached at all is an endpoint-level decision: authentication and bind address, not tool policy.

## Property tests

`Raxol.MCP.ToolProvider` is functor-law-tested: tool derivation commutes with Component composition. If you compose two Components, the derived tools are the same as the tools you'd get by deriving them separately and merging. This catches bugs where a wrapping Component would accidentally hide tools from a child.

## See also

- [ADR-0012](https://github.com/DROOdotFOO/raxol/blob/master/docs/adr/0012-mcp-as-rendering-target.md): design rationale
- [Agent Framework](AGENT_FRAMEWORK.md): agents that consume MCP
- [Symphony](SYMPHONY.md): orchestrator that exposes its own MCP surface
