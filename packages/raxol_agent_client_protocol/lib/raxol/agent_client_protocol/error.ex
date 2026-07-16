defmodule Raxol.AgentClientProtocol.Error do
  @moduledoc """
  JSON-RPC 2.0 error object, plus the ACP-specific vendor error codes.

  Standard JSON-RPC 2.0 codes:

    * `-32700` — parse error (malformed JSON)
    * `-32600` — invalid request (well-formed JSON, not a valid Request object)
    * `-32601` — method not found
    * `-32602` — invalid params
    * `-32603` — internal error

  ACP-specific codes:

    * `-32000` — authentication required
    * `-32002` — resource not found

  Decoding is total: `from_json/1` never raises. Unknown fields on the wire
  object are preserved in `_meta` and re-emitted on encode (forward-compat
  pass-through), never rejected as an error.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :data, _meta: %{}]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: any() | nil,
          _meta: map()
        }

  @known_fields ~w(code message data)

  # -- Error code constants --------------------------------------------------

  @spec parse_error_code() :: integer()
  def parse_error_code, do: -32700

  @spec invalid_request_code() :: integer()
  def invalid_request_code, do: -32600

  @spec method_not_found_code() :: integer()
  def method_not_found_code, do: -32601

  @spec invalid_params_code() :: integer()
  def invalid_params_code, do: -32602

  @spec internal_error_code() :: integer()
  def internal_error_code, do: -32603

  @spec auth_required_code() :: integer()
  def auth_required_code, do: -32000

  @spec resource_not_found_code() :: integer()
  def resource_not_found_code, do: -32002

  # -- Convenience constructors ----------------------------------------------

  @spec parse_error() :: t()
  def parse_error, do: %__MODULE__{code: -32700, message: "Parse error"}

  @spec invalid_request() :: t()
  def invalid_request, do: %__MODULE__{code: -32600, message: "Invalid request"}

  @spec method_not_found() :: t()
  def method_not_found, do: %__MODULE__{code: -32601, message: "Method not found"}

  @spec invalid_params() :: t()
  def invalid_params, do: %__MODULE__{code: -32602, message: "Invalid params"}

  @spec internal_error() :: t()
  def internal_error, do: %__MODULE__{code: -32603, message: "Internal error"}

  @spec auth_required() :: t()
  def auth_required, do: %__MODULE__{code: -32000, message: "Authentication required"}

  @spec resource_not_found(String.t() | nil) :: t()
  def resource_not_found(uri \\ nil)

  def resource_not_found(nil), do: %__MODULE__{code: -32002, message: "Resource not found"}

  def resource_not_found(uri) when is_binary(uri) do
    %__MODULE__{code: -32002, message: "Resource not found", data: %{"uri" => uri}}
  end

  @spec new(integer(), String.t()) :: t()
  def new(code, message) when is_integer(code) and is_binary(message) do
    %__MODULE__{code: code, message: message}
  end

  @spec with_data(t(), any()) :: t()
  def with_data(%__MODULE__{} = err, data), do: %{err | data: data}

  @doc "Convert an ErrorCode integer to its name atom, or `{:other, code}` when unrecognized."
  @spec code_name(integer()) :: atom() | {:other, integer()}
  def code_name(-32700), do: :parse_error
  def code_name(-32600), do: :invalid_request
  def code_name(-32601), do: :method_not_found
  def code_name(-32602), do: :invalid_params
  def code_name(-32603), do: :internal_error
  def code_name(-32000), do: :auth_required
  def code_name(-32002), do: :resource_not_found
  def code_name(code) when is_integer(code), do: {:other, code}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = err) do
    base = %{"code" => err.code, "message" => err.message}
    base = if err.data != nil, do: Map.put(base, "data", err.data), else: base
    Map.merge(err._meta || %{}, base)
  end

  @doc """
  Decode a JSON-RPC error object. Total: malformed or wrong-shaped input
  returns `{:error, :invalid_error}` rather than raising.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_error}
  def from_json(%{"code" => code, "message" => message} = map)
      when is_integer(code) and is_binary(message) do
    meta = Map.drop(map, @known_fields)

    {:ok,
     %__MODULE__{
       code: code,
       message: message,
       data: Map.get(map, "data"),
       _meta: meta
     }}
  end

  def from_json(_invalid), do: {:error, :invalid_error}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Error do
  def encode(err, opts) do
    err |> Raxol.AgentClientProtocol.Error.to_json() |> Jason.Encoder.encode(opts)
  end
end
