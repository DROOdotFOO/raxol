defmodule Raxol.AgentClientProtocol.Rpc do
  @moduledoc """
  JSON-RPC 2.0 primitives for the Agent Client Protocol.

  This is the envelope layer: `Request`, `Response`, `Notification` structs,
  the `RequestId` correlation type, and `Message` (the `"jsonrpc": "2.0"`
  wire wrapper). All `from_json/1` decoders in this namespace are TOTAL —
  malformed input never raises, it returns `{:error, reason}`.

  The request id is `null | integer | string`. Its concrete wire type MUST be
  preserved byte-for-byte on echo-back: a request sent with a string id must
  be answered with that same string, not a coerced integer, or the sender's
  pending-request table silently misses the reply. A `null` id is a real,
  meaningful value (used for server-initiated errors that could not be
  correlated to a request, e.g. a parse error before any id was readable) —
  it is never treated as "absent".

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """
end

defmodule Raxol.AgentClientProtocol.Rpc.RequestId do
  @moduledoc """
  JSON-RPC request id: `null | integer | string`. Wire type is preserved
  exactly (no coercion between string and integer ids).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t :: nil | integer() | String.t()

  @doc "True when `term` is a wire-valid request id (`null | integer | string`)."
  @spec valid?(term()) :: boolean()
  def valid?(nil), do: true
  def valid?(id) when is_integer(id), do: true
  def valid?(id) when is_binary(id), do: true
  def valid?(_other), do: false

  @doc "Encode a valid id to its wire representation. Callers must check `valid?/1` first."
  @spec to_json(t()) :: nil | integer() | String.t()
  def to_json(nil), do: nil
  def to_json(id) when is_integer(id), do: id
  def to_json(id) when is_binary(id), do: id

  @doc "Decode a valid wire id. Callers must check `valid?/1` first."
  @spec from_json(term()) :: t()
  def from_json(nil), do: nil
  def from_json(id) when is_integer(id), do: id
  def from_json(id) when is_binary(id), do: id

  @spec display(t()) :: String.t()
  def display(nil), do: "null"
  def display(id) when is_integer(id), do: Integer.to_string(id)
  def display(id) when is_binary(id), do: id
end

defmodule Raxol.AgentClientProtocol.Rpc.Request do
  @moduledoc """
  JSON-RPC 2.0 Request object (`id` + `method` + optional `params`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Rpc.RequestId

  @enforce_keys [:id, :method]
  defstruct [:id, :method, :params, _meta: %{}]

  @type t :: %__MODULE__{
          id: RequestId.t(),
          method: String.t(),
          params: any() | nil,
          _meta: map()
        }

  @known_fields ~w(id method params)

  @spec new(RequestId.t(), String.t(), any() | nil) :: t()
  def new(id, method, params \\ nil) when is_binary(method) do
    %__MODULE__{id: id, method: method, params: params}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = req) do
    base = %{"id" => RequestId.to_json(req.id), "method" => req.method}
    base = if req.params != nil, do: Map.put(base, "params", req.params), else: base
    Map.merge(req._meta || %{}, base)
  end

  @doc """
  Decode a Request object. Total: a missing/wrong-typed `id` or `method`
  returns `{:error, :invalid_request}` rather than raising.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_request}
  def from_json(%{"id" => id, "method" => method} = map) when is_binary(method) do
    if RequestId.valid?(id) do
      meta = Map.drop(map, @known_fields)

      {:ok,
       %__MODULE__{
         id: RequestId.from_json(id),
         method: method,
         params: Map.get(map, "params"),
         _meta: meta
       }}
    else
      {:error, :invalid_request}
    end
  end

  def from_json(_invalid), do: {:error, :invalid_request}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Rpc.Request do
  def encode(val, opts) do
    val |> Raxol.AgentClientProtocol.Rpc.Request.to_json() |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Rpc.Response do
  @moduledoc """
  JSON-RPC 2.0 Response object: either a result or an error, represented as
  a tagged tuple `{:result, id, result}` | `{:error, id, error}` rather than
  a struct (a Response is a discriminated union at the wire level, and the
  two shapes are mutually exclusive per spec).

  `id` may legitimately be `nil` — a server-side parse error or
  invalid-request error detected before any request id could be read is
  answered with a `null`-id error response; this is not an absent id, it is
  the spec-mandated value for an uncorrelatable error.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Rpc.RequestId

  @type t ::
          {:result, RequestId.t(), any()}
          | {:error, RequestId.t(), Error.t()}

  @spec new(RequestId.t(), {:ok, any()} | {:error, Error.t()}) :: t()
  def new(id, {:ok, result}), do: {:result, id, result}
  def new(id, {:error, error}), do: {:error, id, error}

  @spec result(RequestId.t(), any()) :: t()
  def result(id, result), do: {:result, id, result}

  @spec error(RequestId.t(), Error.t()) :: t()
  def error(id, error), do: {:error, id, error}

  @spec to_json(t()) :: map()
  def to_json({:result, id, result}) do
    %{"id" => RequestId.to_json(id), "result" => result}
  end

  def to_json({:error, id, error}) do
    %{"id" => RequestId.to_json(id), "error" => Error.to_json(error)}
  end

  @doc """
  Decode a Response object. Total: a missing/wrong-typed `id`, or an
  unparseable `error` payload, returns `{:error, :invalid_request}` rather
  than raising or crashing on a hard match.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_request}
  def from_json(%{"id" => id, "result" => result}) do
    if RequestId.valid?(id) do
      {:ok, {:result, RequestId.from_json(id), result}}
    else
      {:error, :invalid_request}
    end
  end

  def from_json(%{"id" => id, "error" => error}) do
    with true <- RequestId.valid?(id),
         {:ok, decoded_error} <- Error.from_json(error) do
      {:ok, {:error, RequestId.from_json(id), decoded_error}}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  def from_json(_invalid), do: {:error, :invalid_request}
end

defmodule Raxol.AgentClientProtocol.Rpc.Notification do
  @moduledoc """
  JSON-RPC 2.0 Notification object: `method` + optional `params`, no `id`,
  no response expected.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @enforce_keys [:method]
  defstruct [:method, :params, _meta: %{}]

  @type t :: %__MODULE__{
          method: String.t(),
          params: any() | nil,
          _meta: map()
        }

  @known_fields ~w(method params)

  @spec new(String.t(), any() | nil) :: t()
  def new(method, params \\ nil) when is_binary(method) do
    %__MODULE__{method: method, params: params}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = notif) do
    base = %{"method" => notif.method}
    base = if notif.params != nil, do: Map.put(base, "params", notif.params), else: base
    Map.merge(notif._meta || %{}, base)
  end

  @doc """
  Decode a Notification object. Total: a missing/wrong-typed `method`
  returns `{:error, :invalid_request}` rather than raising.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_request}
  def from_json(%{"method" => method} = map) when is_binary(method) do
    meta = Map.drop(map, @known_fields)
    {:ok, %__MODULE__{method: method, params: Map.get(map, "params"), _meta: meta}}
  end

  def from_json(_invalid), do: {:error, :invalid_request}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Rpc.Notification do
  def encode(val, opts) do
    val |> Raxol.AgentClientProtocol.Rpc.Notification.to_json() |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Rpc.Message do
  @moduledoc """
  Wraps a Request, Notification, or Response with the required
  `"jsonrpc": "2.0"` field, and decodes a raw wire frame into whichever of
  the three it turns out to be.

  `decode/1` is TOTAL:

    * malformed JSON (the bytes don't parse at all) -> `{:error, :parse_error}`
    * well-formed JSON that isn't a valid JSON-RPC 2.0 frame (wrong
      `jsonrpc` version, not an object, or missing the fields needed to
      classify it as a Request/Response/Notification) -> `{:error, :invalid_request}`
      (or the more specific `{:error, :invalid_jsonrpc_version}` when the
      `jsonrpc` field is present but not `"2.0"`)

  It never raises.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Rpc.{Notification, Request, Response}

  @enforce_keys [:message]
  defstruct [:message]

  @type inner :: Request.t() | Notification.t() | Response.t() | map()
  @type t :: %__MODULE__{message: inner()}

  @spec wrap(inner()) :: t()
  def wrap(message), do: %__MODULE__{message: message}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{message: %Request{} = req}) do
    req |> Request.to_json() |> Map.put("jsonrpc", "2.0")
  end

  def to_json(%__MODULE__{message: %Notification{} = notif}) do
    notif |> Notification.to_json() |> Map.put("jsonrpc", "2.0")
  end

  def to_json(%__MODULE__{message: {:result, _id, _result} = resp}) do
    resp |> Response.to_json() |> Map.put("jsonrpc", "2.0")
  end

  def to_json(%__MODULE__{message: {:error, _id, _error} = resp}) do
    resp |> Response.to_json() |> Map.put("jsonrpc", "2.0")
  end

  def to_json(%__MODULE__{message: message}) when is_map(message) do
    Map.put(message, "jsonrpc", "2.0")
  end

  @doc "Encode to a JSON string (newline-delimited framing is the transport's concern)."
  @spec encode!(t()) :: String.t()
  def encode!(%__MODULE__{} = msg) do
    Jason.encode!(to_json(msg))
  end

  @doc "Decode a JSON string into the inner Request, Notification, or Response. See moduledoc."
  @spec decode(term()) ::
          {:ok, Request.t() | Notification.t() | Response.t()}
          | {:error, :parse_error | :invalid_request | :invalid_jsonrpc_version}
  def decode(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"jsonrpc" => "2.0"} = map} -> classify(map)
      {:ok, map} when is_map(map) -> {:error, :invalid_jsonrpc_version}
      {:ok, _not_a_map} -> {:error, :invalid_request}
      {:error, _reason} -> {:error, :parse_error}
    end
  end

  def decode(_not_a_string), do: {:error, :parse_error}

  # Precedence mirrors the mutual exclusivity of the three shapes: a
  # Request always has both "id" and "method"; a Response has "id" and
  # ("result" or "error") but never "method"; a Notification has "method"
  # but never "id".
  defp classify(%{"id" => _id, "method" => _method} = map) do
    Request.from_json(map)
  end

  defp classify(map) when is_map_key(map, "id") and is_map_key(map, "result") do
    Response.from_json(map)
  end

  defp classify(map) when is_map_key(map, "id") and is_map_key(map, "error") do
    Response.from_json(map)
  end

  defp classify(map) when is_map_key(map, "method") and not is_map_key(map, "id") do
    Notification.from_json(map)
  end

  defp classify(_map), do: {:error, :invalid_request}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Rpc.Message do
  def encode(val, opts) do
    val |> Raxol.AgentClientProtocol.Rpc.Message.to_json() |> Jason.Encoder.encode(opts)
  end
end
