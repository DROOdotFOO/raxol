defmodule Raxol.MCP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 message encoding/decoding for the Model Context Protocol.

  Handles both client-side (requests, notifications) and server-side
  (responses, error responses) message construction. All MCP communication
  flows through this module.
  """

  @jsonrpc_version "2.0"
  @mcp_protocol_version "2024-11-05"

  # Newest first. `negotiate/1` accepts membership, not order, but the order is
  # what a future "offer the best we both know" caller needs.
  @modern_version "2026-07-28"
  @legacy_version "2025-06-18"
  @supported_versions [@modern_version, @legacy_version, @mcp_protocol_version]

  # Standard JSON-RPC error codes
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  @type request :: %{
          jsonrpc: String.t(),
          id: pos_integer(),
          method: String.t(),
          params: map()
        }

  @type notification :: %{
          jsonrpc: String.t(),
          method: String.t(),
          params: map()
        }

  @type response :: %{
          jsonrpc: String.t(),
          id: pos_integer(),
          result: term()
        }

  @type error_response :: %{
          jsonrpc: String.t(),
          id: pos_integer() | nil,
          error: %{code: integer(), message: String.t()}
        }

  # -- Accessors for error codes -----------------------------------------------

  @doc "JSON-RPC parse error code (-32700)."
  @spec parse_error() :: integer()
  def parse_error, do: @parse_error

  @doc "JSON-RPC invalid request code (-32600)."
  @spec invalid_request() :: integer()
  def invalid_request, do: @invalid_request

  @doc "JSON-RPC method not found code (-32601)."
  @spec method_not_found() :: integer()
  def method_not_found, do: @method_not_found

  @doc "JSON-RPC invalid params code (-32602)."
  @spec invalid_params() :: integer()
  def invalid_params, do: @invalid_params

  @doc "JSON-RPC internal error code (-32603)."
  @spec internal_error() :: integer()
  def internal_error, do: @internal_error

  @doc """
  The protocol version this package's SERVER advertises.

  Unchanged at `2024-11-05`, deliberately. ADR-0037 negotiates a version per
  client CONNECTION and lists what the raxol server advertises under what it
  does not decide, so the two move independently.
  """
  @spec mcp_protocol_version() :: String.t()
  def mcp_protocol_version, do: @mcp_protocol_version

  @doc """
  Every revision the client side can speak, newest first.

  Three revisions rather than one because the upstreams disagree: the current
  specification (2026-07-28) is stateless, with no `initialize` and no
  `Mcp-Session-Id`, while the servers ADR-0033 measured on 2026-08-31 are
  stateful. A client that speaks only one of the two fails against the other,
  which is why `Raxol.MCP.Client.Transport.Http` probes an origin's era rather
  than assuming it.
  """
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc "The stateless revision: no handshake, no session, `server/discover` required."
  @spec modern_version() :: String.t()
  def modern_version, do: @modern_version

  @doc "The newest stateful revision, offered to a legacy-era origin."
  @spec legacy_version() :: String.t()
  def legacy_version, do: @legacy_version

  @doc """
  Accept a peer's protocol revision, or name it as unsupported.

  The per-connection half of ADR-0037 decision 2: the revision in force is
  whatever the peer answered `initialize` with, not a module constant.
  """
  @spec negotiate(term()) :: {:ok, String.t()} | {:error, {:unsupported_version, term()}}
  def negotiate(version) when is_binary(version) do
    if version in @supported_versions,
      do: {:ok, version},
      else: {:error, {:unsupported_version, version}}
  end

  def negotiate(other), do: {:error, {:unsupported_version, other}}

  # -- Client-side builders ----------------------------------------------------

  @doc "Build a JSON-RPC request."
  @spec request(pos_integer(), String.t(), map()) :: request()
  def request(id, method, params \\ %{}) do
    %{jsonrpc: @jsonrpc_version, id: id, method: method, params: params}
  end

  @doc "Build a JSON-RPC notification (no id, no response expected)."
  @spec notification(String.t(), map()) :: notification()
  def notification(method, params \\ %{}) do
    %{jsonrpc: @jsonrpc_version, method: method, params: params}
  end

  # -- Server-side builders ----------------------------------------------------

  @doc "Build a JSON-RPC success response."
  @spec response(pos_integer(), term()) :: response()
  def response(id, result) do
    %{jsonrpc: @jsonrpc_version, id: id, result: result}
  end

  @doc "Build a JSON-RPC error response."
  @spec error_response(pos_integer() | nil, integer(), String.t(), term()) :: error_response()
  def error_response(id, code, message, data \\ nil) do
    error = %{code: code, message: message}
    error = if data, do: Map.put(error, :data, data), else: error
    %{jsonrpc: @jsonrpc_version, id: id, error: error}
  end

  # -- Encoding/Decoding -------------------------------------------------------

  @doc "Encode a message to a JSON string with newline delimiter."
  @spec encode(map()) :: {:ok, iodata()} | {:error, term()}
  def encode(message) do
    case Jason.encode(message) do
      {:ok, json} -> {:ok, [json, "\n"]}
      error -> error
    end
  end

  @doc """
  Encode a message, raising on failure.

  Returns iodata (JSON + newline).
  """
  @spec encode!(map()) :: iodata()
  def encode!(message) do
    [Jason.encode!(message), "\n"]
  end

  @doc "Decode a JSON string into a message map with atom keys for known fields."
  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  def decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, normalize(decoded)}
      error -> error
    end
  end

  # -- Predicates ---------------------------------------------------------------

  @doc "Check if a decoded message is a response (has id + result or error)."
  @spec response?(map()) :: boolean()
  def response?(%{id: _id, result: _}), do: true
  def response?(%{id: _id, error: _}), do: true
  def response?(_), do: false

  @doc "Check if a decoded message is an error response."
  @spec error?(map()) :: boolean()
  def error?(%{error: _}), do: true
  def error?(_), do: false

  @doc "Check if a decoded message is a notification (no id)."
  @spec notification?(map()) :: boolean()
  def notification?(%{method: _} = msg), do: not Map.has_key?(msg, :id)
  def notification?(_), do: false

  @doc "Check if a decoded message is a request (has id + method)."
  @spec request?(map()) :: boolean()
  def request?(%{id: _id, method: _}), do: true
  def request?(_), do: false

  # -- Private -----------------------------------------------------------------

  defp normalize(decoded) do
    decoded
    |> normalize_key("jsonrpc", :jsonrpc)
    |> normalize_key("id", :id)
    |> normalize_key("method", :method)
    |> normalize_key("params", :params)
    |> normalize_key("result", :result)
    |> normalize_key("error", :error)
  end

  defp normalize_key(map, string_key, atom_key) do
    case Map.pop(map, string_key) do
      {nil, map} -> map
      {value, map} -> Map.put(map, atom_key, value)
    end
  end
end
