defmodule Raxol.Agent.Backend.Anthropic.Wire do
  @moduledoc """
  Pure codec for the Anthropic Messages API (`POST /v1/messages`).

  `build_request/2` turns Raxol messages plus opts into `{url, headers, body}`;
  `parse_response/2` turns a decoded response body into the backend response
  contract (`{:ok, response} | {:error, marker}`). No I/O: the caller owns the
  transport (`Raxol.Agent.Backend.HTTP` over Req).

  `:max_tokens` is taken from opts as given; the caller resolves its default
  (the `AI_MAX_TOKENS` precedence lives in the backend, not the codec).
  """

  @api_version "2023-06-01"
  @default_base_url "https://api.anthropic.com"
  @default_model "claude-sonnet-4-20250514"

  @typedoc "A Raxol chat message: `role` is `:system`, `:user` or `:assistant`."
  @type message :: %{required(:role) => atom(), required(:content) => term()}

  @doc "The `anthropic-version` header value this codec speaks."
  @spec api_version() :: String.t()
  def api_version, do: @api_version

  @doc """
  Build the Messages request.

  Opts: `:base_url` (default `#{@default_base_url}`), `:model` (default
  `#{@default_model}`), `:api_key` (absent or empty omits `x-api-key`),
  `:max_tokens`, `:tools` (a non-empty list rides as `tools`). System messages
  are joined with a newline into the top-level `system` field.
  """
  @spec build_request([message()], keyword()) ::
          {String.t(), [{String.t(), String.t()}], map()}
  def build_request(messages, opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    {"#{base_url}/v1/messages", headers(opts), build_body(messages, opts)}
  end

  defp headers(opts) do
    api_key_header(opts) ++
      [
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ]
  end

  # An absent key omits the header and lets the endpoint answer (a legible
  # 401), rather than raising before any request is built.
  defp api_key_header(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> [{"x-api-key", key}]
      _absent -> []
    end
  end

  defp build_body(messages, opts) do
    {system_msgs, chat_msgs} = Enum.split_with(messages, &(&1.role == :system))
    system_text = Enum.map_join(system_msgs, "\n", & &1.content)

    %{
      model: Keyword.get(opts, :model, @default_model),
      max_tokens: Keyword.get(opts, :max_tokens),
      messages: Enum.map(chat_msgs, &format_message/1)
    }
    |> put_system(system_text)
    |> put_tools(Keyword.get(opts, :tools))
  end

  defp format_message(%{role: role, content: content}) do
    %{role: to_string(role), content: content}
  end

  defp put_system(body, ""), do: body
  defp put_system(body, system_text), do: Map.put(body, :system, system_text)

  defp put_tools(body, nil), do: body
  defp put_tools(body, []), do: body
  defp put_tools(body, tools) when is_list(tools), do: Map.put(body, :tools, tools)

  @doc """
  Parse a decoded Messages response body.

  A `tool_use` stop yields `tool_calls` (string keys `"id"/"name"/"arguments"`)
  plus the first text block (or `""`); a text reply yields its first block. Any
  other body is `{:error, marker}`, never the raw map. `backend` tags
  `metadata.backend`.
  """
  @spec parse_response(term(), atom()) :: {:ok, map()} | {:error, String.t()}
  def parse_response(%{"content" => content, "stop_reason" => "tool_use"} = body, backend) do
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
       metadata: metadata(body, backend, "tool_use")
     }}
  end

  def parse_response(%{"content" => [%{"text" => text} | _]} = body, backend) do
    {:ok,
     %{
       content: text,
       usage: Map.get(body, "usage", %{}),
       metadata: metadata(body, backend, Map.get(body, "stop_reason"))
     }}
  end

  def parse_response(body, _backend), do: {:error, unparseable_marker(:anthropic, body)}

  defp metadata(body, backend, stop_reason) do
    %{
      backend: backend,
      provider: :anthropic,
      model: Map.get(body, "model"),
      stop_reason: stop_reason
    }
  end

  @doc """
  The honest marker for a body no parser recognised: never `inspect(body)`
  painted as the assistant's answer. The shape hint (top-level keys only,
  never values) rides under `RAXOL_DEBUG`, so a raw payload (possibly carrying
  secrets) never reaches a transcript.
  """
  @spec unparseable_marker(atom(), term()) :: String.t()
  def unparseable_marker(provider, body) do
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
end
