defmodule Raxol.Web3.MCPCall do
  @moduledoc """
  One stateless MCP `tools/call`, out through `Raxol.Web3.HTTP`.

  A streamable-HTTP MCP server that is stateless needs no session at all: no
  `initialize`, no `notifications/initialized`, no `mcp-session-id` header, one
  POST per call. That is the whole module, and it is why issue #1028 records the
  Solana primary as unblocked while the Tron one waits on a session client.
  Measured 2026-09-14 against `portal.sqd.dev/mcp`: a bare `tools/list` POST
  with no prior handshake answers 200, and so does a `tools/call` POST, so the
  handshake this module omits is one the upstream does not require.

  This module knows nothing about any chain. It takes an endpoint, a tool name,
  an argument map and `Raxol.Web3.HTTP` options. Three upstreams in this package
  are stateless and each wanted the same twenty lines, so it is one module
  rather than three private functions.

  ## Three return shapes, and why an announced refusal is not an error term

  A `tools/call` result arrives as `result.content[0].text` holding a JSON
  **string**, so there are two decodes: the JSON-RPC envelope, then the text
  inside it. What comes back is the second one:

    * `{:ok, payload}` - the tool answered.
    * `{:tool_error, payload}` - the tool announced a failure through the
      protocol's `isError` flag, and this is its structured body.
    * `{:error, reason}` - a transport, status, framing or envelope failure,
      from `Raxol.Web3.Backend`'s closed taxonomy.

  The middle one exists because collapsing it would throw away the only
  machine-readable reason. Measured 2026-09-14 on SQD, an unknown network
  answers HTTP 200 with `isError: true` and `error.code == "unknown_network"`,
  and an account-scoped query with no time window answers 200 with
  `isError: true` and `error.code == "invalid_request"`. The first means "this
  source does not serve that chain" and the second means "your arguments were
  wrong": two different operator problems, and only the caller knows which of
  its own error terms each maps onto. This is the posture `Raxol.Web3.HTTP`
  takes with an HTTP status, one layer up: return it, decide nothing.

  A caller's obligation, therefore, and it is the whole reason the tag is
  distinct: **a `{:tool_error, payload}` is mapped onto a closed error term and
  the payload is dropped.** Nothing from it may travel inside an error tuple,
  because ADR-0038 decision 6 keeps upstream text out of one. An announced
  failure whose body is not a JSON object at all is `{:upstream_refused,
  :unknown}` here rather than a decode failure, since the protocol already told
  us what happened and only the prose is unusable.

  ## What this module will not interpret

  The payload carries model-facing prose beside its structured fields. Measured
  2026-09-14, `portal_get_head` returns `answer: "Current value: 446,949,476."`
  next to the structured `number`, and `portal_get_network_info` returns a
  `_tool_contract.untrusted_fields` list that names `display_name` among the
  fields a client must not trust. None of that is this module's business: the
  payload is returned whole and the caller takes the fields it named. ADR-0033
  §7's rule is that we serve a normalized contract and never a pass-through, and
  the place that rule is enforced is the backend that maps the payload.

  `result.structuredContent` is ignored even though SQD sends it, measured the
  same day. Two carriers for one value means two shapes to pin and a silent
  divergence when they disagree, and `content[0].text` is the one every server
  in this package's survey emits.

  ## Two content types, one framing module

  A streamable-HTTP server may answer a POST as `application/json` or as
  `text/event-stream` carrying one `event: message` frame. SQD answers
  `text/event-stream`, measured 2026-09-14, so a JSON decode of the body fails
  and the frames have to be split first; ccscan answers `application/json` with
  no framing at all. Both work here because the body is tried as JSON first and
  unframed only if that fails, rather than branching on a `content-type` the
  spec does not oblige a server to set precisely.

  The framing itself is `Raxol.MCP.Client.SSE.payloads/1`, not a second grammar
  here. This module briefly carried its own copy, because that one was being
  written in parallel and a compile dependency on an uncommitted module would
  have broken this package's build; it landed, so the copy is gone. One SSE
  grammar, in the package that owns the protocol.
  """

  alias Raxol.MCP.Client.SSE
  alias Raxol.Web3.Backend
  alias Raxol.Web3.HTTP

  # Defaults, merged per name rather than assigned over the caller's list. An
  # account-gated server needs an `authorization` header, and a module that
  # replaced the list would make a credential structurally impossible to send.
  # `accept` carries both types because the spec lets a streamable-HTTP server
  # answer a POST either way and a client that accepts only one is at the
  # server's mercy; put_new semantics mean a caller cannot drop it by supplying
  # unrelated headers, only by setting it deliberately.
  @default_headers [
    {"content-type", "application/json"},
    {"accept", "application/json, text/event-stream"}
  ]

  @type result :: {:ok, map()} | {:tool_error, map()} | {:error, Backend.error()}

  @doc """
  Call one tool and return its decoded payload.

  `opts` is forwarded to `Raxol.Web3.HTTP` unchanged except for `:headers`, so
  the caller owns the cache class, the rate-limit seed and the breaker
  settings: this module has no opinion about any of them, because it does not
  know whose budget it is spending. `:headers` is merged with the two defaults
  above, so a caller's `authorization` survives and the defaults appear only
  where the caller did not set them. `user-agent` is not policed here;
  `Raxol.Web3.HTTP` drops a supplied one and sets its own.
  """
  @spec call(String.t(), String.t(), map(), keyword()) :: result()
  def call(endpoint, tool, arguments, opts \\ [])
      when is_binary(endpoint) and is_binary(tool) and is_map(arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => arguments}
      })

    endpoint
    |> HTTP.post(body, opts |> Keyword.put(:headers, headers(opts)) |> classified())
    |> decode()
  end

  # An MCP tool server announces a refusal inside a 200 in two different
  # shapes -- a JSON-RPC `error` on the envelope and `isError: true` on the
  # result -- so the cache stage cannot tell an answer from a refusal by
  # status and has to be told. The measured cost of not telling it: SQD's
  # `portal_list_networks` is cached under `:catalog` for an hour, so one
  # transient tool error resolved every read on that source to a refusal for
  # the rest of the hour while the source was already answering again.
  defp classified(opts) do
    case Keyword.get(opts, :cache) do
      nil -> opts
      spec -> Keyword.put(opts, :cache, Keyword.put(spec, :cacheable, &answered?/1))
    end
  end

  # `decode/1` itself, rather than a second reading of the same body: the two
  # would have to agree about both refusal shapes forever, and the only way to
  # guarantee that is to have one of them.
  defp answered?(response), do: match?({:ok, _payload}, decode({:ok, response}))

  defp headers(opts) do
    Enum.reduce(@default_headers, Keyword.get(opts, :headers, []), fn {name, value}, headers ->
      put_new_header(headers, name, value)
    end)
  end

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {supplied, _value} -> String.downcase(supplied) == name end),
      do: headers,
      else: [{name, value} | headers]
  end

  # -- decoding ----------------------------------------------------------------

  defp decode({:ok, %{status: status, body: body}}) when status in 200..299 do
    with {:ok, envelope} <- envelope(body),
         {:ok, result} <- result(envelope) do
      content(result)
    end
  end

  defp decode({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp decode({:error, _reason} = error), do: error

  defp envelope(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      _not_json ->
        case SSE.payloads(body) do
          {[payload | _rest], _tail} -> json_object(payload, :sse)
          {[], _tail} -> {:error, {:decode_failed, :sse}}
        end
    end
  end

  defp result(%{"result" => result}) when is_map(result), do: {:ok, result}
  defp result(%{"error" => error}), do: {:error, {:upstream_refused, class(error)}}
  defp result(_other), do: {:error, {:decode_failed, :jsonrpc}}

  defp content(%{"content" => [%{"text" => text} | _rest]} = result) when is_binary(text) do
    case json_object(text, :mcp_content) do
      {:ok, payload} -> tag(result, payload)
      {:error, _reason} = error -> announced(result, error)
    end
  end

  defp content(result), do: announced(result, {:error, {:decode_failed, :mcp_content}})

  defp tag(%{"isError" => true}, payload), do: {:tool_error, payload}
  defp tag(_result, payload), do: {:ok, payload}

  defp announced(%{"isError" => true}, _error), do: {:error, {:upstream_refused, :unknown}}
  defp announced(_result, error), do: error

  defp json_object(text, tag) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, tag}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  # The code is a number we can reason about; the message is upstream prose and
  # stays where it is. The same split as `Raxol.Web3.RPC` makes, over the same
  # codes, because MCP rides on JSON-RPC.
  defp class(%{"code" => code}) when code in [-32_601, -32_602], do: :not_found
  defp class(%{"code" => code}) when code in [401, -32_001], do: :auth
  defp class(%{"code" => code}) when code in [429, -32_005], do: :rate_limit
  defp class(_error), do: :unknown
end
