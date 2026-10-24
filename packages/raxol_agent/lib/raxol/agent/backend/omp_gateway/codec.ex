defmodule Raxol.Agent.Backend.OmpGateway.Codec do
  @moduledoc """
  Pure codec for the `omp auth-gateway stdio` JSON-lines protocol.

  The gateway prints `{"ready":true,"version":"X.Y.Z"}` first, then answers
  each request line `{id, method, path, body?}` with `{id, status, body,
  encoding?}` in completion order. HTTP headers never cross stdio, so the
  gateway's cost header is unreachable: a `/v1/messages` reply is priced here
  through `Raxol.Agent.LlmPrices` on the model that actually answered
  (ADR-0035, Narrowed by ADR-0042).

  `/v1/messages` goes through `Raxol.Agent.Backend.Anthropic.Wire`, the codec
  the direct Anthropic backend uses. The gateway re-encodes every reply, so
  the message id may be a synthetic `msg_...`; nothing here reads it.

  Errors carry the status and the body's error type, never the body: a
  gateway error message can quote the request back.
  """

  alias Raxol.Agent.Backend.Anthropic.Wire
  alias Raxol.Agent.LlmPrices
  alias Raxol.Agent.OMP.Version

  @backend :omp_gateway

  @typedoc "An HTTP method the gateway routes."
  @type method :: :get | :post

  @typedoc "One decoded response line."
  @type response :: %{id: term(), status: non_neg_integer(), body: term()}

  @typedoc "Why a non-2xx response failed: its status and `error.type`, if any."
  @type http_error :: {:http_error, non_neg_integer(), String.t() | nil}

  @doc "Encode one request line, newline-terminated. `body` nil sends none."
  @spec encode_request(pos_integer(), method(), String.t(), map() | nil) :: iodata()
  def encode_request(id, method, path, body) do
    request = %{"id" => id, "method" => method_name(method), "path" => path}
    request = if is_nil(body), do: request, else: Map.put(request, "body", body)

    [Jason.encode!(request), ?\n]
  end

  defp method_name(:get), do: "GET"
  defp method_name(:post), do: "POST"

  @doc """
  Decode the ready line and check its version against the tested pin
  (`Raxol.Agent.OMP.Version`): `{:ok, version, warnings}`, or
  `{:error, {:unsupported_major, found, tested}}`, or
  `{:error, :invalid_ready_line}` for anything that is not a ready line.
  """
  @spec decode_ready(binary()) ::
          {:ok, Elixir.Version.t(), [Version.warning()]} | {:error, term()}
  def decode_ready(line) do
    case Jason.decode(line) do
      {:ok, %{"ready" => true, "version" => version}} when is_binary(version) ->
        case Version.check(version) do
          {:ok, parsed, warnings} -> {:ok, parsed, warnings}
          {:error, :unparseable_version} -> {:error, :invalid_ready_line}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_ready_line}
    end
  end

  @doc """
  Decode one response line to `%{id, status, body}`. A base64 `encoding`
  is decoded to the raw binary body.
  """
  @spec decode_response(binary()) :: {:ok, response()} | {:error, :invalid_response}
  def decode_response(line) do
    with {:ok, %{"id" => id, "status" => status} = decoded} when is_integer(status) <-
           Jason.decode(line),
         {:ok, body} <- decode_body(Map.get(decoded, "body"), Map.get(decoded, "encoding")) do
      {:ok, %{id: id, status: status, body: body}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp decode_body(body, "base64") when is_binary(body) do
    case Base.decode64(body) do
      {:ok, raw} -> {:ok, raw}
      :error -> :error
    end
  end

  defp decode_body(body, nil), do: {:ok, body}
  defp decode_body(_body, _encoding), do: :error

  @doc """
  A response as a call result: the body of a 2xx, else
  `{:error, {:http_error, status, error_type}}`.
  """
  @spec result(response()) :: {:ok, term()} | {:error, http_error()}
  def result(%{status: status, body: body}) when status in 200..299, do: {:ok, body}
  def result(%{status: status, body: body}), do: {:error, {:http_error, status, error_type(body)}}

  # Both shapes the gateway emits: `{"error":{"type":...}}` from its own
  # routes and `{"type":"error","error":{"type":...}}` from the Anthropic
  # route. A string `error` (`No route: GET /nope`) carries no type.
  defp error_type(%{"error" => %{"type" => type}}) when is_binary(type), do: type
  defp error_type(_body), do: nil

  @doc """
  The `/v1/messages` request body: the `Wire` body with `stream: false`.
  `opts` must carry `:max_tokens` (the gateway refuses a request without it).
  """
  @spec messages_body([Wire.message()], keyword()) :: map()
  def messages_body(messages, opts) do
    {_url, _headers, body} = Wire.build_request(messages, opts)
    Map.put(body, :stream, false)
  end

  @doc """
  Parse a `/v1/messages` reply through `Wire` and price it on the reply's
  `model`. `metadata.cost_usd` is the `LlmPrices` figure and
  `metadata.cost_source` its source; a model `LlmPrices` cannot price keeps
  its token `usage` and is flagged `cost_usd: nil, cost_source: :unpriced`,
  never a silent zero.
  """
  @spec parse_messages(term()) :: {:ok, map()} | {:error, String.t()}
  def parse_messages(body) do
    with {:ok, response} <- Wire.parse_response(body, @backend) do
      {:ok, Map.update!(response, :metadata, &Map.merge(&1, cost(&1.model, response.usage)))}
    end
  end

  defp cost(model, usage) do
    case LlmPrices.turn_cost(@backend, model, usage) do
      {:ok, usd, source} -> %{cost_usd: usd, cost_source: source}
      :unknown -> %{cost_usd: nil, cost_source: :unpriced}
    end
  end

  @doc "Model ids from a `GET /v1/models` body."
  @spec model_ids(term()) :: [String.t()]
  def model_ids(%{"data" => data}) when is_list(data),
    do: for(%{"id" => id} <- data, is_binary(id), do: id)

  def model_ids(_body), do: []
end
