defmodule Raxol.AgentClientProtocol do
  @moduledoc """
  Elixir/OTP implementation of **ACP (Agent Client Protocol)** — the JSON-RPC
  2.0 protocol spoken between code editors ("clients") and AI coding agents
  ("agents"). See <https://agentclientprotocol.com>.

  This is the package root. The library is organized in orthogonal layers:

    * `Raxol.AgentClientProtocol.Schema.*` — the ACP data model (content
      blocks, session types, fs/terminal types, capabilities), ported from the
      MIT `f1729/agent_client_protocol` schema layer (see `NOTICE.md`).
    * `Raxol.AgentClientProtocol.Rpc.*` — JSON-RPC 2.0 envelope: id
      correlation (`null | integer | string`, type-preserving), error codes,
      total decoding.
    * `Raxol.AgentClientProtocol.Transport.*` — pluggable byte/message
      carriers: `stdio` (newline-delimited JSON) and an in-process paired
      transport for tests and BEAM-local wiring.
    * `Raxol.AgentClientProtocol.Connection` — one process per peer, either
      role (`:agent` or `:client`), bidirectional request correlation,
      supervised per-session processes.
    * Vendor extensions ride `_meta["raxol.io"]` and `_raxol/*` methods:
      durable resumable sessions (offset-based reattach/replay), capability
      tokens, and taint annotation.

  Protocol version: integer `1` (the stable ACP v1 surface).
  """

  @protocol_version 1

  @doc "The ACP protocol version this library implements (an integer, per spec)."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version
end
