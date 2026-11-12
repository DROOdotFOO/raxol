# Editor Agent Client Protocol

> **Two protocols share the letters "ACP".** This page is the **Agent Client Protocol**
> ([agentclientprotocol.com](https://agentclientprotocol.com)): the JSON-RPC protocol
> between a code editor and an AI coding agent, implemented in `raxol_agent_client_protocol`
> (module root `Raxol.AgentClientProtocol`). It is unrelated to the
> [Agent Commerce Protocol](ACP.md) (`Raxol.Earn`, the Virtuals on-chain payments protocol).
> Different acronym expansion, different domain.

The Agent Client Protocol is to agentic coding what LSP is to language tooling: a JSON-RPC
2.0 protocol between a **client** (an editor or CLI host such as Zed) and an **agent** (the
AI coding process), spoken over a byte stream, almost always the agent's stdio. Raxol's
implementation (`raxol_agent_client_protocol`, pre-alpha) has zero raxol
dependencies (only `jason`) and implements both roles.

## The protocol shape

A turn is bidirectional. The client drives the handshake (`initialize`, then `session/new`
or `session/load` to resume, then `session/prompt`). During a prompt the agent streams
`session/update` notifications back, and may itself become the caller mid-turn:
`session/request_permission`, `fs/read_text_file`, `fs/write_text_file`, `terminal/*`. That
agent-to-client request direction is why the protocol is bidirectional and why the package
implements both the `:agent` and `:client` roles behind one connection core.

## Three layers

- **`Schema.*`**: the ACP v1 data model (content blocks, session/fs/terminal types,
  capabilities). Decoding is total: malformed or unknown wire input never crashes and never
  mints an atom from wire data.
- **`Rpc.*` / `Transport.*`**: the JSON-RPC 2.0 envelope plus pluggable carriers.
  `Transport.Stdio` is newline-delimited JSON over a real or spawned stdio pipe;
  `Transport.Paired` is an in-process linked-mailbox pair for tests and BEAM-local wiring.
- **Runtime**: `Connection` (one GenServer per peer, either role, never blocks on a peer,
  dispatches each inbound request to a supervised task), `Session` (per-session turn state
  machine under a `DynamicSupervisor`), and the `Agent` / `Client` behaviours you `use`.

`MethodTable` is the single source of truth for the wire vocabulary. The `Agent` / `Client`
callback surfaces and the dispatcher are generated from it at compile time, so the callbacks
and the router cannot drift from the protocol. Adding or changing a method is one table-row
edit.

## Minimal agent

```elixir
defmodule MyAgent do
  use Raxol.AgentClientProtocol.Agent
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.{ContentChunk, TextContent}
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{InitializeResponse, NewSessionResponse, PromptResponse}

  def initialize(req, _ctx), do: {:ok, InitializeResponse.new(req.protocol_version)}
  def new_session(_p, _ctx), do: {:ok, NewSessionResponse.new("sess-1")}

  def prompt(%{session_id: sid, prompt: blocks}, ctx) do
    text = Enum.map_join(blocks, "", fn {:text, tc} -> tc.text; _ -> "" end)
    chunk = ContentChunk.new({:text, TextContent.new("echo: #{text}")})
    Connection.notify(ctx.conn, "session/update", SessionNotification.new(sid, {:agent_message_chunk, chunk}))
    {:ok, PromptResponse.new(:end_turn)}
  end
end

{:ok, handle} = Raxol.AgentClientProtocol.Transport.Stdio.start_self()
{:ok, _sup} = Raxol.AgentClientProtocol.Agent.start_link(MyAgent,
  transport: {Raxol.AgentClientProtocol.Transport.Stdio, handle})
```

A client spawns the agent with `Transport.Stdio.start_spawn("elixir", ["--no-halt", "my_agent.exs"])`,
resolves the connection pid, and calls `initialize` before any other request. For BEAM-local
wiring with no subprocess, swap in `Transport.Paired.create_pair/0`.

## Serving a Raxol agent

The sections above are about writing an agent with the package. This one is for
a host that spawns ACP agents, such as an editor, and wants to drive a Raxol
agent: a module that `use`s `Raxol.Agent`.

```bash
curl -fsSL https://raxol.io/install | bash
raxol doctor                                 # confirms "acp surface: available"
raxol acp --agent <app>[:<id>]
```

`<app>` is one of `config :raxol_agent, :mcp_spawnable_apps`. The default list
holds `Raxol.Agent.Reference.Counter`, a counter that shows the turn contract.
From a source checkout, `bin/raxol-acp` takes the same arguments.

Zed, and anything sharing its `agent_servers` shape:

```json
{
  "agent_servers": {
    "Raxol": {
      "command": "/usr/local/bin/raxol",
      "args": ["acp", "--agent", "Raxol.Agent.Reference.Counter:c1"]
    }
  }
}
```

What a host should know:

- **`initialize` always answers.** `agentInfo` names `raxol` and its version,
  `loadSession` is false, and `authMethods` offers a browser sign-in for each
  provider that has one. Without `--agent`, or with an app that is not listed,
  `session/new` is refused and the error lists the apps that are.
- **`session/new` starts the agent.** Its `cwd` must be absolute: it is the
  project root the agent's journal is bound to
  (`<sessions dir>/<first 8 hex of sha256(cwd)>/<id>`). The session id is the
  agent's id. With `:<id>`, a later run continues that journal while the
  agent's state starts fresh, and a second `session/new` is refused while the
  agent runs. Without it, every session starts a new agent under a random id.
- **A prompt is one turn of the agent.** The prompt's text reaches the agent as
  `{:acp_prompt, text, approver}` (see `Raxol.Agent.Comm`), and its reply comes
  back as one `agent_message_chunk`; there is no token streaming. Each tool
  call the agent runs past `approver` is announced as a `tool_call` update.
- **Sensitive actions ask.** A call to an action marked `sensitive` costs one
  `session/request_permission` offering allow-once and reject-once. A client
  that rejects, times out, disconnects, or does not implement the method denies
  the call.
- **`session/cancel` stops the turn.** The prompt is answered `cancelled` once
  the turn's process is down, and the journal records `turn_canceled`.
- **`session/load` is not offered.** A restarted agent has its journal and none
  of its state, so there is no transcript to replay into it.
- **The agent lives as long as the connection.** It is stopped, and its journal
  flushed, when the connection ends. `RAXOL_MAX_TURNS` and `RAXOL_MAX_COST_USD`
  cap the turns and spend of one connection.

Where the same BEAM also serves the `agent_*` MCP tools, they do not list, ask
or stop an agent an ACP session started; the two share only the id namespace.

### Verifying an integration

`scripts/acp_probe.py` is a dependency-free ACP client that runs the full
handshake, answers `session/request_permission`, and records every frame. Point
it at the same command your host will spawn:

```bash
PROBE_PROMPT=increment scripts/acp_probe.py \
  raxol acp --agent Raxol.Agent.Reference.Counter
```

A `__NON_JSON_STDOUT__` entry in the transcript means something wrote non-JSON
to the wire before a frame, which a strict NDJSON client would reject.

### A source-build feature

`raxol_agent_client_protocol` is a path dependency of `raxol_agent`, so a Hex
install of `raxol_agent` is compiled without
`Raxol.Agent.ClientProtocol.StdioAgent` and has no ACP surface; adding the
dependency downstream does not enable it. The packaged CLI (npm or the install
script) is built from source and has it. `raxol doctor` reports which you have.

## Durable resumable sessions

`Ext.*` is a vendor extension (carried on the standard `_meta["raxol.io"]` rider plus new
`_raxol/*` methods, ACP's own extension mechanism) that makes a session reattachable across
connections:

- An append-only, single-writer journal per session (write-then-publish: a subscriber sees a
  record only after it is durably written).
- Offset-based reattach and replay with no gap and no duplicate: a reattaching client
  registers as a live subscriber before reading the high watermark, then replays history up
  to it.
- `RXC1` capability tokens: detached Ed25519, offline-verifiable. There is no `alg` field;
  the literal `RXC1` prefix is the algorithm binding, so downgrade confusion is structurally
  unexpressible.
- Taint is annotated, never filtered, so `history ++ live` stays the durable stream.

The extension is opt-in rather than turnkey: you wire the journal, reattach, and attach
policy yourself. The current journal is in-memory (durable across connections within a node's
lifetime, not yet across restarts).

## Provenance and license discipline

The package is deliberately layered to stay pure MIT. The `Schema.*` layer is ported MIT to
MIT from `f1729/agent_client_protocol` with defects fixed; the conformance corpus is ported
MIT to MIT from `openclaw/acpx`; the OTP runtime is a clean-room implementation (the official
Apache-2.0 SDKs and other implementations were studied as design references only, no code
copied). The official ACP JSON Schema is vendored SHA256-pinned as a dev/test oracle and is
excluded from the published package, so Apache-2.0 terms never propagate downstream. See the
package `NOTICE.md`.

## See also

- [Agent Commerce Protocol](ACP.md): the unrelated on-chain payments ACP.
- [Coding Agent](CODING_AGENT.md): Raxol's own terminal coding agent.
- `scripts/acp_probe.py`: a minimal ACP client for verifying an integration.
