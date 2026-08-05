# Provenance & attribution

This package is MIT-licensed. Its provenance is deliberately layered:

## Copied (MIT → MIT, with attribution)

- **Schema/type/serialization layer + wire-byte test fixtures** are ported from
  [`f1729/agent_client_protocol`](https://github.com/f1729/agent-client-protocol-elixir)
  (MIT License, Copyright (c) 2025 f1729), with defects fixed and modules
  restructured under `Raxol.AgentClientProtocol.*`. Files carrying ported code
  note this in their moduledoc.
- **Conformance case corpus** (`test/conformance/cases/*.json`) is ported from
  [`openclaw/acpx`](https://github.com/openclaw/acpx)
  (MIT License, Copyright (c) 2025 OpenClaw Team).

## Design references only (Apache-2.0: ideas, never code)

The OTP runtime (connection, supervision, sessions, transports) is a clean-room
implementation. The following Apache-2.0 projects were studied as *design
references*; no source code was copied from them:

- `agentclientprotocol/rust-sdk`, `typescript-sdk`, `python-sdk`,
  `java-sdk`/`kotlin-sdk` (the official ACP SDKs)
- `lostbean/acpex` (Elixir)
- `xai-org/grok-build`

## Dev/test oracle (not shipped)

`priv/schema-oracle/` contains the official ACP JSON Schema (Apache-2.0),
SHA256-pinned, used ONLY as a validation oracle in dev/test. It is excluded
from the published hex package (see `mix.exs` `:files`).
