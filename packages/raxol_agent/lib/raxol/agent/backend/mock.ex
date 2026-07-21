defmodule Raxol.Agent.Backend.Mock do
  @moduledoc """
  Deterministic AI backend for testing.

  Responds with configurable canned responses. Supports a response queue
  (FIFO) or a static default response.

  ## Usage

      # Static response
      opts = [response: "Hello from mock"]
      {:ok, resp} = Mock.complete([%{role: :user, content: "hi"}], opts)

      # Response queue (pops from front)
      opts = [responses: ["first", "second", "third"]]
      {:ok, resp1} = Mock.complete(messages, opts)  # "first"
      {:ok, resp2} = Mock.complete(messages, opts)  # "second"
  """

  @behaviour Raxol.Agent.AIBackend

  @bytes_per_token_estimate 4

  @impl true
  def complete(messages, opts \\ []) do
    latency = Keyword.get(opts, :latency_ms, 0)
    if latency > 0, do: Process.sleep(latency)

    case Keyword.get(opts, :error) do
      nil ->
        case resolve_tool_calls(opts) do
          nil ->
            content = resolve_response(messages, opts)

            {:ok,
             %{
               content: content,
               usage: %{
                 input_tokens: count_tokens(messages),
                 output_tokens: count_tokens(content)
               },
               metadata: %{backend: :mock, model: "mock-1"}
             }}

          tool_calls when is_list(tool_calls) ->
            {:ok,
             %{
               content: "",
               tool_calls: tool_calls,
               usage: %{
                 input_tokens: count_tokens(messages),
                 output_tokens: 0
               },
               metadata: %{backend: :mock, model: "mock-1"}
             }}
        end

      error ->
        {:error, error}
    end
  end

  @impl true
  def stream(messages, opts \\ []) do
    case complete(messages, opts) do
      {:ok, response} ->
        events = [
          {:chunk, response.content},
          {:done, response}
        ]

        {:ok, events}

      error ->
        error
    end
  end

  @impl true
  def available?, do: true

  @impl true
  def name, do: "Mock Backend"

  @impl true
  def capabilities, do: [:completion, :streaming, :tool_use]

  defp resolve_response(_messages, opts) do
    case {Keyword.get(opts, :response_fn), Keyword.get(opts, :response)} do
      {fun, _} when is_function(fun, 0) -> fun.()
      {_, response} when not is_nil(response) -> response
      _ -> "Mock response"
    end
  end

  # `tool_calls:` is static (every round replays it); `tool_calls_fn:` is
  # the dynamic variant -- a 0-arity fun consulted per round, so a test or
  # demo can script a ONE-SHOT tool call (return the list once, nil after)
  # without the caller looping through the same call forever.
  defp resolve_tool_calls(opts) do
    case {Keyword.get(opts, :tool_calls_fn), Keyword.get(opts, :tool_calls)} do
      {fun, _} when is_function(fun, 0) -> fun.()
      {_, tool_calls} -> tool_calls
    end
  end

  defp count_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(fn %{content: c} -> byte_size(c) end)
    |> Enum.sum()
    |> div(@bytes_per_token_estimate)
  end

  defp count_tokens(text) when is_binary(text),
    do: div(byte_size(text), @bytes_per_token_estimate)

  defp count_tokens(_), do: 0
end
