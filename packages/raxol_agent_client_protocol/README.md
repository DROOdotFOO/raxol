# Raxol Agent Client Protocol

Elixir/OTP implementation of [ACP (Agent Client Protocol)](https://agentclientprotocol.com) —
the JSON-RPC 2.0 protocol between code editors and AI coding agents (the protocol
Zed and a growing ecosystem of editors/agents speak).

**Status: pre-alpha (`0.1.0-rc.0`), not yet published to Hex.**

## What this is

- Full ACP v1 surface, both roles (agent **and** client), bidirectional:
  `initialize`, `session/*`, `fs/*`, `terminal/*` — including the agent→client
  request direction (`session/request_permission`, `fs/*`, `terminal/*`).
- OTP-native runtime: one supervised process per connection, per-session
  processes under `DynamicSupervisor` + `Registry`, supervised per-request
  dispatch, fail-closed permission flow.
- Pluggable transports: `stdio` (newline-delimited JSON-RPC, the stock ACP
  wire) and an in-process paired transport (test backbone / BEAM-local).
- **Durable resumable sessions** (vendor extension, `_meta["raxol.io"]` +
  `_raxol/*` methods): offset-based reattach/replay with a
  register-before-high-watermark seam — no gap, no dup — plus offline-verifiable
  capability tokens and taint annotation.

## Provenance

See `NOTICE.md`: schema/serialization layer ported from the MIT
`f1729/agent_client_protocol`; conformance corpus from MIT `openclaw/acpx`;
runtime clean-room (Apache SDKs studied as design references only). The
official ACP JSON Schema is a SHA256-pinned dev/test oracle in
`priv/schema-oracle/`, never shipped.

## Testing

```bash
cd packages/raxol_agent_client_protocol && MIX_ENV=test mix test
mix acp.schema.verify   # oracle drift gate
```
