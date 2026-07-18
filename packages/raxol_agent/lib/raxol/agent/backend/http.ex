defmodule Raxol.Agent.Backend.HTTP do
  @moduledoc """
  HTTP-based AI backend using Req.

  Supports Claude (Anthropic), GPT (OpenAI-compatible), Ollama, and Kimi APIs.
  The provider is auto-detected from the base URL or can be set explicitly.

  ## Configuration

      opts = [
        api_key: "sk-...",
        base_url: "https://api.anthropic.com",
        model: "claude-sonnet-4-20250514",
        provider: :anthropic,  # or :openai, :ollama, :kimi (auto-detected if omitted)
        timeout: 30_000
      ]

  ## Req Plugins

  Pass `:req_plugins` to attach Req response steps (e.g., auto-pay for HTTP 402):

      opts = [
        api_key: "sk-...",
        req_plugins: [
          fn req -> Raxol.Payments.Req.AutoPay.attach(req, wallet: MyWallet) end
        ]
      ]

  Each plugin is a function `(Req.Request.t() -> Req.Request.t())` applied
  before the request is sent. This keeps Backend.HTTP agnostic to payment
  details while letting callers wire in transparent 402 handling.
  """

  @behaviour Raxol.Agent.AIBackend

  @default_timeout Raxol.Core.Defaults.health_check_interval_ms()
  # A reasoning model (LongCat / DeepSeek-style) spends completion tokens on a
  # hidden reasoning channel BEFORE the answer. The old 1024 cap truncated such
  # turns mid-reasoning -- `finish_reason: length` with an EMPTY answer. 4096
  # leaves room for reasoning + answer; `AI_MAX_TOKENS` overrides at the
  # deployment boundary, an explicit `:max_tokens` opt overrides per call.
  @default_max_tokens 4_096
  @anthropic_api_version "2023-06-01"
  @default_ollama_port "11434"

  @impl true
  def complete(messages, opts \\ []) do
    provider = detect_provider(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    plugins = Keyword.get(opts, :req_plugins, [])

    {url, headers, body} = build_request(provider, messages, opts)

    # `parse_response/2` returns `{:ok, response} | {:error, reason}`: an
    # unparseable body or an empty length-truncated turn is an honest error,
    # NOT assistant prose (the "cannot lie at the wire boundary" rule). The
    # with-chain surfaces either the transport error or the parse error.
    with {:ok, response_body} <- do_request(url, headers, body, timeout, plugins),
         {:ok, parsed} <- parse_response(provider, response_body) do
      {:ok, parsed}
    end
  end

  # The per-call token budget. Precedence: explicit `:max_tokens` opt >
  # `AI_MAX_TOKENS` env > `@default_max_tokens`. Read at request-build time so a
  # deployment can raise the ceiling for reasoning models without code changes.
  defp default_max_tokens do
    case System.get_env("AI_MAX_TOKENS") do
      nil ->
        @default_max_tokens

      raw ->
        case Integer.parse(String.trim(raw)) do
          {n, _} when n > 0 -> n
          _ -> @default_max_tokens
        end
    end
  end

  @impl true
  def available? do
    Code.ensure_loaded?(Req)
  end

  @impl true
  def name, do: "HTTP Backend"

  @impl true
  def capabilities, do: [:completion, :streaming, :tool_use]

  @impl true
  def stream(messages, opts \\ []) do
    if available?() do
      provider = detect_provider(opts)
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      plugins = Keyword.get(opts, :req_plugins, [])
      {url, headers, body} = build_request(provider, messages, opts)
      body = Map.put(body, :stream, true)

      caller = self()
      ref = make_ref()

      task_pid =
        spawn_link(fn ->
          stream_request(url, headers, body, timeout, caller, ref, plugins)
        end)

      stream =
        Stream.resource(
          fn ->
            %{
              ref: ref,
              task_pid: task_pid,
              buffer: "",
              provider: provider,
              content: "",
              usage: %{},
              tool_calls: []
            }
          end,
          &stream_next/1,
          fn %{task_pid: pid} ->
            if Process.alive?(pid), do: Process.exit(pid, :normal)
          end
        )

      {:ok, stream}
    else
      {:error, :req_not_available}
    end
  end

  defp stream_request(url, headers, body, timeout, caller, ref, plugins) do
    try do
      req =
        Req.new(
          url: url,
          json: body,
          headers: headers,
          receive_timeout: timeout,
          into: fn {:data, data}, {req, resp} ->
            send(caller, {:sse_data, ref, data})
            {:cont, {req, resp}}
          end
        )
        |> apply_plugins(plugins)

      case Req.post(req) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          send(caller, {:sse_error, ref, "HTTP #{status}"})

        {:error, reason} ->
          send(caller, {:sse_error, ref, inspect(reason)})
      end
    rescue
      e -> send(caller, {:sse_error, ref, Exception.message(e)})
    end

    send(caller, {:sse_done, ref})
  end

  defp stream_next(%{buffer: :halt} = state), do: {:halt, state}

  defp stream_next(%{ref: ref, buffer: buffer, provider: provider} = state) do
    receive do
      {:sse_data, ^ref, data} ->
        {events, new_buffer} = parse_sse(buffer <> data, provider)

        # Preserve arrival order and interleaving: text deltas become
        # `{:chunk, _}` (the answer), reasoning deltas become
        # `{:reasoning, _}` (chain-of-thought), honest `:marker`s (unparseable
        # chunk / truncation) ride their own channel; only text feeds the
        # accumulated `content` — neither reasoning nor markers are the answer.
        out =
          Enum.flat_map(events, fn
            {:text_delta, text} -> [{:chunk, text}]
            {:reasoning_delta, text} -> [{:reasoning, text}]
            {:marker, text} -> [{:marker, text}]
            _ -> []
          end)

        new_content =
          state.content <>
            Enum.map_join(out, "", fn
              {:chunk, t} -> t
              _reasoning -> ""
            end)

        new_usage =
          case Enum.find(events, &match?({:usage, _}, &1)) do
            {:usage, u} -> u
            nil -> state.usage
          end

        new_tool_calls =
          case Enum.find(events, &match?({:tool_calls, _}, &1)) do
            {:tool_calls, tc} -> tc
            nil -> state.tool_calls
          end

        {out,
         %{
           state
           | buffer: new_buffer,
             content: new_content,
             usage: new_usage,
             tool_calls: new_tool_calls
         }}

      {:sse_error, ^ref, error} ->
        {[{:error, error}], %{state | buffer: :halt}}

      {:sse_done, ^ref} ->
        done =
          {:done,
           %{
             content: state.content,
             usage: state.usage,
             tool_calls: state.tool_calls,
             metadata: %{
               backend: :http,
               provider: state.provider,
               streamed: true
             }
           }}

        {[done], %{state | buffer: :halt}}
    after
      60_000 ->
        {:halt, state}
    end
  end

  # -- SSE parsing -------------------------------------------------------------

  @doc false
  # Exposed for unit tests: parse a raw SSE buffer for `provider` into
  # `{events, leftover_buffer}`. Events are `{:text_delta, t}`,
  # `{:reasoning_delta, t}`, `{:usage, u}`, or `{:marker, t}`.
  def parse_sse(raw, :ollama) do
    lines = String.split(raw, "\n")
    {complete, [buffer]} = Enum.split(lines, -1)

    events =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"done" => true}} -> [{:usage, %{}}]
          {:ok, %{"message" => %{"content" => text}}} -> [{:text_delta, text}]
          _ -> []
        end
      end)

    {events, buffer}
  end

  def parse_sse(raw, provider) when provider in [:anthropic, :openai, :kimi] do
    parts = String.split(raw, "\n\n")

    case parts do
      [single] ->
        {[], single}

      multiple ->
        {complete, [buffer]} = Enum.split(multiple, -1)

        events =
          complete
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(&parse_sse_event(&1, provider))

        {events, buffer}
    end
  end

  defp parse_sse_event(event_text, :anthropic) do
    data_line =
      event_text
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "data: "))

    with "data: " <> json <- data_line,
         {:ok, parsed} <- Jason.decode(json) do
      case parsed do
        # Extended-thinking blocks stream as `thinking_delta` (the thought)
        # then `signature_delta` (the crypto signature, not shown). Surface
        # the thought as reasoning; ignore the signature.
        %{"type" => "content_block_delta", "delta" => %{"thinking" => text}}
        when is_binary(text) ->
          [{:reasoning_delta, text}]

        %{"type" => "content_block_delta", "delta" => %{"text" => text}} ->
          [{:text_delta, text}]

        %{"type" => "message_delta", "usage" => usage} ->
          [{:usage, usage}]

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  defp parse_sse_event(event_text, :kimi),
    do: parse_sse_event(event_text, :openai)

  defp parse_sse_event(event_text, :openai) do
    data_line =
      event_text
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "data: "))

    case data_line do
      "data: [DONE]" ->
        [{:usage, %{}}]

      "data: " <> data ->
        case Jason.decode(data) do
          {:ok, decoded} -> openai_stream_events(decoded)
          # A `data:` line that IS present but is not valid JSON is a genuine
          # fidelity gap -- an honest marker, never a silently dropped chunk.
          {:error, _} -> [{:marker, "⚠ unparseable response chunk"}]
        end

      _ ->
        # No `data:` line (SSE comment / keep-alive / blank) -- correctly
        # skipped, not a parse failure.
        []
    end
  end

  # A streaming chunk -> ordered SSE events. Handles BOTH the streaming
  # (`delta`) and full-message (`message`, LongCat) shapes -- the delta-only
  # parser missed LongCat, which emits `delta: null` + a full `message`.
  # Reasoning rides its own channel (`reasoning`/`reasoning_content`), and a
  # `finish_reason: length` chunk (either key variant) emits an honest
  # truncation marker. A content-less chunk (role-only opener) yields nothing.
  defp openai_stream_events(%{"choices" => [choice | _]}) when is_map(choice) do
    msg = choice_message(choice)
    reasoning = choice_reasoning(msg)
    text = choice_text(msg)
    finish = finish_reason(choice)
    tool_calls = msg["tool_calls"]

    []
    |> maybe_append(reasoning && {:reasoning_delta, reasoning})
    |> maybe_append(text != "" && {:text_delta, text})
    |> maybe_append(
      # LongCat streams the FULL message per chunk (`delta: null`), so a
      # completed `tool_calls` array arrives whole -- no cross-chunk
      # accumulation needed for this provider. Surfaced as one terminal-ish
      # event the stream folds into `:done` (the OpenAI incremental
      # `delta.tool_calls[]` accumulation is a separate, later concern).
      is_list(tool_calls) and tool_calls != [] and
        {:tool_calls, parse_openai_tool_calls(tool_calls)}
    )
    |> maybe_append(finish == "length" && {:marker, truncation_marker(choice)})
  end

  # A trailing usage-only chunk (some providers emit `{"usage": {...}}` with an
  # empty `choices` at stream end) carries token accounting, nothing to render.
  defp openai_stream_events(%{"usage" => usage}) when is_map(usage),
    do: [{:usage, usage}]

  # A well-formed JSON object in an unrecognized shape is benign protocol, not
  # a fidelity gap -- skipped (never dumped). Only a JSON DECODE failure marks.
  defp openai_stream_events(_other), do: []

  defp maybe_append(events, falsy) when falsy in [nil, false], do: events
  defp maybe_append(events, event), do: events ++ [event]

  # -- Request building -------------------------------------------------------

  defp build_request(:anthropic, messages, opts) do
    base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com")
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")

    {system_msgs, chat_msgs} = split_system_messages(messages)
    system_text = Enum.map_join(system_msgs, "\n", & &1.content)

    url = "#{base_url}/v1/messages"

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_api_version},
      {"content-type", "application/json"}
    ]

    body = %{
      model: model,
      max_tokens: Keyword.get(opts, :max_tokens, default_max_tokens()),
      messages: Enum.map(chat_msgs, &format_message/1)
    }

    body =
      if system_text != "", do: Map.put(body, :system, system_text), else: body

    body = maybe_add_tools(:anthropic, body, opts)

    {url, headers, body}
  end

  defp build_request(:openai, messages, opts) do
    base_url = Keyword.get(opts, :base_url, "https://api.openai.com")
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, "gpt-4o")

    url = "#{base_url}/v1/chat/completions"

    headers =
      [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]
      |> append_extra_headers(opts)

    body = %{
      model: model,
      messages: Enum.map(messages, &format_message/1),
      max_tokens: Keyword.get(opts, :max_tokens, default_max_tokens())
    }

    body = maybe_add_tools(:openai, body, opts)

    {url, headers, body}
  end

  defp build_request(:kimi, messages, opts) do
    base_url = Keyword.get(opts, :base_url, "https://api.moonshot.ai")
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, "kimi-k2.5")

    url = "#{base_url}/v1/chat/completions"

    headers =
      [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]
      |> append_extra_headers(opts)

    body = %{
      model: model,
      messages: Enum.map(messages, &format_message/1),
      max_tokens: Keyword.get(opts, :max_tokens, default_max_tokens())
    }

    {url, headers, body}
  end

  defp build_request(:ollama, messages, opts) do
    base_url = Keyword.get(opts, :base_url, "http://localhost:11434")
    model = Keyword.get(opts, :model, "llama3")

    url = "#{base_url}/api/chat"
    headers = [{"content-type", "application/json"}]

    body = %{
      model: model,
      messages: Enum.map(messages, &format_message/1),
      stream: false
    }

    {url, headers, body}
  end

  # -- Tool support -----------------------------------------------------------

  defp maybe_add_tools(_provider, body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools when is_list(tools) -> Map.put(body, :tools, tools)
    end
  end

  # -- Response parsing -------------------------------------------------------
  #
  # Every clause returns `{:ok, response} | {:error, reason}`. There is NO
  # clause that dumps a raw map into `content` -- an unrecognized body is an
  # honest `{:error, marker}` (see the fall-through), never assistant prose.

  # Anthropic tool_use response: stop_reason "tool_use" with tool_use content blocks
  defp parse_response(
         :anthropic,
         %{"content" => content, "stop_reason" => "tool_use"} = body
       ) do
    tool_calls =
      content
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{
          "id" => block["id"],
          "name" => block["name"],
          "arguments" => block["input"] || %{}
        }
      end)

    text =
      content
      |> Enum.find_value("", fn
        %{"type" => "text", "text" => t} -> t
        _ -> nil
      end)

    {:ok,
     %{
       content: text,
       tool_calls: tool_calls,
       usage: Map.get(body, "usage", %{}),
       metadata: %{
         backend: :http,
         provider: :anthropic,
         model: Map.get(body, "model"),
         stop_reason: "tool_use"
       }
     }}
  end

  defp parse_response(
         :anthropic,
         %{"content" => [%{"text" => text} | _]} = body
       ) do
    {:ok,
     %{
       content: text,
       usage: Map.get(body, "usage", %{}),
       metadata: %{
         backend: :http,
         provider: :anthropic,
         model: Map.get(body, "model"),
         stop_reason: Map.get(body, "stop_reason")
       }
     }}
  end

  # OpenAI tool_calls response
  defp parse_response(
         :openai,
         %{"choices" => [%{"message" => %{"tool_calls" => tool_calls}} | _]} =
           body
       )
       when is_list(tool_calls) and tool_calls != [] do
    msg = choice_message(hd(body["choices"]))

    {:ok,
     %{
       content: choice_text(msg),
       tool_calls: parse_openai_tool_calls(tool_calls),
       usage: Map.get(body, "usage", %{}),
       metadata: %{backend: :http, provider: :openai, model: Map.get(body, "model")}
     }
     |> put_reasoning(choice_reasoning(msg))}
  end

  # OpenAI-compatible content response. One clause covers standard OpenAI
  # (`message.content`), LongCat's full-message shape, and the reasoning
  # channel (`reasoning`/`reasoning_content`). The `finish_reason` variant
  # (`finish_reason` OR the underscore-less `finishreason`) drives honest
  # truncation: a length-capped turn with an EMPTY answer is an error marker,
  # never a clean (blank) completion.
  defp parse_response(:openai, %{"choices" => [choice | _]} = body)
       when is_map(choice) do
    msg = choice_message(choice)
    content = choice_text(msg)
    reasoning = choice_reasoning(msg)
    finish = finish_reason(choice)

    cond do
      finish == "length" and blank?(content) ->
        {:error, truncation_marker(body)}

      true ->
        {:ok,
         %{
           content: content,
           usage: Map.get(body, "usage", %{}),
           metadata: openai_metadata(body, finish)
         }
         |> put_reasoning(reasoning)}
    end
  end

  defp parse_response(:kimi, body), do: parse_response(:openai, body)

  defp parse_response(:ollama, %{"message" => %{"content" => text}} = body) do
    {:ok,
     %{
       content: text,
       usage: %{},
       metadata: %{
         backend: :http,
         provider: :ollama,
         model: Map.get(body, "model"),
         eval_duration: Map.get(body, "eval_duration")
       }
     }}
  end

  # The honest fall-through: a body no clause could parse is an ERROR marker,
  # never `inspect(body)` painted as the assistant's answer. The shape hint
  # (top-level keys only, never values) rides under `RAXOL_DEBUG` so a raw
  # payload -- possibly carrying secrets -- is never leaked into a transcript.
  defp parse_response(provider, body) do
    {:error, unparseable_marker(provider, body)}
  end

  # Normalize an OpenAI-shape `tool_calls` list to the downstream contract
  # (STRING keys `"id"/"name"/"arguments"`, arguments JSON-decoded). Shared
  # by the blocking `parse_response/2` and the streaming path so both surface
  # the identical shape -- a tool call must round-trip the stream unchanged.
  defp parse_openai_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      args =
        case get_in(tc, ["function", "arguments"]) do
          s when is_binary(s) ->
            case Jason.decode(s) do
              {:ok, map} -> map
              _ -> %{}
            end

          map when is_map(map) ->
            map

          _ ->
            %{}
        end

      %{
        "id" => tc["id"],
        "name" => get_in(tc, ["function", "name"]),
        "arguments" => args
      }
    end)
  end

  # -- OpenAI-compatible field extraction (shared by complete + stream) --------

  # The content-bearing sub-object: a non-streaming/full-message chunk carries
  # `message`; a streaming chunk carries `delta`. LongCat emits `message` even
  # on the SSE path, which the delta-only parser missed.
  defp choice_message(%{"message" => msg}) when is_map(msg), do: msg
  defp choice_message(%{"delta" => delta}) when is_map(delta), do: delta
  defp choice_message(_choice), do: %{}

  defp choice_text(%{"content" => t}) when is_binary(t), do: t
  defp choice_text(_msg), do: ""

  # The separate reasoning channel: `reasoning` (OpenRouter) or
  # `reasoning_content` (DeepSeek / LongCat); nil when absent/blank.
  defp choice_reasoning(%{"reasoning_content" => t}) when is_binary(t) and t != "", do: t
  defp choice_reasoning(%{"reasoning" => t}) when is_binary(t) and t != "", do: t
  defp choice_reasoning(_msg), do: nil

  # Tolerate the wire-key variant: LongCat sends `finishreason` (no
  # underscore) where OpenAI sends `finish_reason`.
  defp finish_reason(choice) when is_map(choice),
    do: Map.get(choice, "finish_reason") || Map.get(choice, "finishreason")

  defp finish_reason(_choice), do: nil

  defp openai_metadata(body, finish) do
    meta = %{backend: :http, provider: :openai, model: Map.get(body, "model")}

    case finish do
      # A length-truncated round that still carried SOME answer text stays a
      # {:ok, _} (partial answer preserved) but rides the honest marker in
      # metadata — the non-streaming complete/2 loop has no other channel to
      # disclose the truncation ALONGSIDE the partial answer. (An EMPTY
      # length-truncated round is handled earlier as {:error, marker}.)
      "length" ->
        Map.merge(meta, %{
          finish_reason: :length,
          truncated: true,
          marker: truncation_marker(body)
        })

      nil ->
        meta

      other ->
        Map.put(meta, :finish_reason, other)
    end
  end

  defp put_reasoning(response, nil), do: response
  defp put_reasoning(response, reasoning), do: Map.put(response, :reasoning, reasoning)

  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # An honest, human-readable truncation marker; the token count is the honest
  # quantity when the response carried usage.
  defp truncation_marker(source) do
    tokens =
      get_in(source, ["usage", "completion_tokens"]) ||
        get_in(source, ["usage", "total_tokens"])

    suffix = if is_integer(tokens), do: " (#{tokens} tokens)", else: ""
    "⚠ response truncated — hit token limit#{suffix}; raise AI_MAX_TOKENS"
  end

  defp unparseable_marker(provider, body) do
    base = "⚠ unparseable response from #{provider}"
    if debug?(), do: base <> " — keys: #{shape_hint(body)}", else: base
  end

  # Keys only -- never values, never `inspect(body)` -- so the hint can never
  # reintroduce the `%{...}` dump the fall-through exists to prevent.
  defp shape_hint(body) when is_map(body),
    do: body |> Map.keys() |> Enum.map_join(", ", &to_string/1)

  defp shape_hint(body) when is_list(body), do: "list"
  defp shape_hint(_body), do: "scalar"

  defp debug?, do: System.get_env("RAXOL_DEBUG") in ["1", "true", "yes"]

  # -- Helpers ----------------------------------------------------------------

  defp do_request(url, headers, body, timeout, plugins) do
    if Code.ensure_loaded?(Req) do
      req =
        Req.new(
          url: url,
          json: body,
          headers: headers,
          receive_timeout: timeout
        )
        |> apply_plugins(plugins)

      case Req.post(req) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    else
      {:error, :req_not_available}
    end
  end

  # Caller- or harness-supplied headers (e.g. OpenRouter attribution:
  # HTTP-Referer, X-OpenRouter-Title) appended to the provider's base headers.
  defp append_extra_headers(headers, opts) do
    headers ++ Keyword.get(opts, :extra_headers, [])
  end

  defp apply_plugins(req, []), do: req

  defp apply_plugins(req, plugins) when is_list(plugins) do
    Enum.reduce(plugins, req, fn plugin, acc -> plugin.(acc) end)
  end

  defp detect_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        base_url = Keyword.get(opts, :base_url, "")

        cond do
          String.contains?(base_url, "anthropic") ->
            :anthropic

          String.contains?(base_url, "ollama") or
              String.contains?(base_url, @default_ollama_port) ->
            :ollama

          String.contains?(base_url, "moonshot") ->
            :kimi

          true ->
            :openai
        end

      provider ->
        provider
    end
  end

  defp split_system_messages(messages) do
    Enum.split_with(messages, fn msg -> msg.role == :system end)
  end

  defp format_message(%{role: role, content: content}) do
    %{role: to_string(role), content: content}
  end
end
