# Editor Agent Client Protocol

> **Two protocols share the letters "ACP".** This page is the **Agent Client Protocol**
> ([agentclientprotocol.com](https://agentclientprotocol.com)): the JSON-RPC protocol
> between a code editor and an AI coding agent, implemented in `raxol_agent_client_protocol`
> (module root `Raxol.AgentClientProtocol`). It is unrelated to the
> [Agent Commerce Protocol](ACP.md) (`Raxol.ACP`, the Virtuals on-chain payments protocol).
> Different acronym expansion, different domain.

The Agent Client Protocol is to agentic coding what LSP is to language tooling: a JSON-RPC
2.0 protocol between a **client** (an editor or CLI host such as Zed) and an **agent** (the
AI coding process), spoken over a byte stream, almost always the agent's stdio. Raxol's
implementation (`raxol_agent_client_protocol`, pre-alpha `0.1.0-rc.0`) has zero raxol
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
