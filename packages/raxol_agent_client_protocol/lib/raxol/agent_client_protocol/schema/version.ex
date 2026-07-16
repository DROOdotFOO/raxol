defmodule Raxol.AgentClientProtocol.Schema.Version do
  @moduledoc """
  Protocol version identifier for ACP (`protocolVersion` on the wire).

  Only bumped for breaking changes to the protocol surface. The wire value
  is a plain integer (`1` is the current stable ACP v1 surface) — never a
  semver string.

  ## Legacy date-string handshakes

  Some ACP-adjacent clients (notably Zed, in older releases) sent a
  date-formatted `protocolVersion` inherited from MCP's `"2024-11-05"`-style
  versioning instead of ACP's integer scheme. `from_json/1` is strict and
  rejects that shape; `coerce/1` is the tolerant counterpart that accepts it
  (and any other legacy string) by mapping it to `latest/0`, so a handshake
  from an older/foreign client degrades gracefully instead of failing the
  connection outright. Callers doing the initial `initialize` handshake
  should prefer `coerce/1`; callers validating an already-negotiated,
  spec-conformant value should use the stricter `from_json/1`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t :: non_neg_integer()

  @v0 0
  @v1 1
  @latest @v1

  @doc "The initial (pre-stabilization) protocol version."
  @spec v0() :: t()
  def v0, do: @v0

  @doc "The current stable ACP v1 protocol version."
  @spec v1() :: t()
  def v1, do: @v1

  @doc "The latest protocol version this library implements."
  @spec latest() :: t()
  def latest, do: @latest

  @doc """
  Deserialize `protocolVersion` from an already-decoded JSON value.

  Strict: only non-negative integers are accepted. Never raises — always
  returns a result tuple, even for malformed input.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_protocol_version}
  def from_json(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def from_json(_value), do: {:error, :invalid_protocol_version}

  @doc """
  Tolerant deserialize for `protocolVersion`, for handshakes with clients
  that may not speak the current integer scheme.

  Non-negative integers pass through unchanged. Any string (including a
  legacy MCP-style date string such as `"2024-11-05"`) is coerced to
  `latest/0` rather than rejected — a recon caveat: we don't attempt to
  parse or validate the string's shape, we simply treat "sent a string at
  all" as "speaks a version we don't recognize, negotiate down to what we
  know". Anything else is rejected. Never raises.
  """
  @spec coerce(term()) :: {:ok, t()} | {:error, :invalid_protocol_version}
  def coerce(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def coerce(value) when is_binary(value), do: {:ok, @latest}
  def coerce(_value), do: {:error, :invalid_protocol_version}
end
