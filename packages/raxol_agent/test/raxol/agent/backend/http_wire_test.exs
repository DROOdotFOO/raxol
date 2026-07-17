defmodule Raxol.Agent.Backend.HTTPWireTest do
  # Not async: several tests mutate process-global env (AI_MAX_TOKENS,
  # RAXOL_DEBUG). Serializing this module keeps those reads deterministic.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.HTTP

  # This file pins the LongCat / reasoning-model wire defects: a raw response
  # map rendered as assistant prose (honesty violation), the non-standard
  # LongCat shape (message-object chunk, `finishreason`, `reasoning_content`),
  # the separate reasoning channel, and length-truncation honesty + the
  # raised/configurable max_tokens ceiling.

  # -- helpers ----------------------------------------------------------------

  # Stub the transport so `complete/2` runs the real request/parse pipeline
  # against a canned response body -- exercising `parse_response/2` end to end.
  defp complete_stub(response_body, provider_opts) do
    adapter = fn req -> {req, Req.Response.new(status: 200, body: response_body)} end
    plugin = fn req -> %{req | adapter: adapter} end

    HTTP.complete(
      [%{role: :user, content: "hello"}],
      provider_opts ++
        [base_url: "http://127.0.0.1:19876", req_plugins: [plugin], timeout: 100]
    )
  end

  # Capture the assembled request body (the plugin captures :json before the
  # send fails on a dead port).
  defp captured_body(provider_opts) do
    test_pid = self()

    plugin = fn req ->
      send(test_pid, {:req_json, req.options[:json]})
      req
    end

    HTTP.complete(
      [%{role: :user, content: "hi"}],
      provider_opts ++
        [base_url: "http://127.0.0.1:19876", req_plugins: [plugin], timeout: 100]
    )

    assert_received {:req_json, body}
    body
  end

  # The exact frame from the live LongCat transcript: a full-message chunk
  # (`message`, not `delta`), the underscore-less `finishreason`, and the
  # separate `reasoning_content` channel.
  defp longcat_body(overrides \\ %{}) do
    message =
      Map.merge(
        %{
          "role" => "assistant",
          "content" => "the sky is blue",
          "reasoning_content" => "let me think about the sky..."
        },
        Map.get(overrides, "message", %{})
      )

    choice =
      Map.merge(
        %{"delta" => nil, "finishreason" => "stop", "message" => message},
        Map.drop(overrides, ["message", "usage"])
      )

    %{
      "object" => "chat.completion",
      "model" => "LongCat-2.0",
      "choices" => [choice],
      "usage" => Map.get(overrides, "usage", %{"completion_tokens" => 42})
    }
  end

  defp no_raw_map!(text) do
    refute text =~ "%{", "content must not contain a raw Elixir map: #{inspect(text)}"
    refute text =~ "=>", "content must not contain map arrows: #{inspect(text)}"
    text
  end

  # -- non-streaming (complete/2) shape ---------------------------------------

  describe "LongCat non-streaming (complete/2) shape" do
    test "extracts message.content as text, reasoning_content as :reasoning, no raw map" do
      assert {:ok, response} = complete_stub(longcat_body(), provider: :openai, api_key: "k")

      assert response.content == "the sky is blue"
      no_raw_map!(response.content)
      assert response.reasoning == "let me think about the sky..."
    end

    test "tolerates the standard finish_reason key too" do
      body = longcat_body(%{"finishreason" => nil, "finish_reason" => "stop"})
      assert {:ok, response} = complete_stub(body, provider: :openai, api_key: "k")
      assert response.content == "the sky is blue"
    end

    test "standard OpenAI (no reasoning channel) carries no :reasoning key" do
      body = longcat_body(%{"message" => %{"reasoning_content" => nil}})
      assert {:ok, response} = complete_stub(body, provider: :openai, api_key: "k")
      refute Map.has_key?(response, :reasoning)
    end
  end

  describe "honesty: unparseable response is an error marker, never prose" do
    test "a body no clause can parse yields {:error, marker}, not inspect(body)" do
      # The old fall-through did `content: inspect(body)` -- this is the bug.
      weird = %{"unexpected" => %{"nested" => "shape"}, "id" => "x"}
      assert {:error, marker} = complete_stub(weird, provider: :openai, api_key: "k")

      assert is_binary(marker)
      assert marker =~ "unparseable"
      no_raw_map!(marker)
    end

    test "the marker never leaks payload values (keys-only shape hint under debug)" do
      System.put_env("RAXOL_DEBUG", "1")
      on_exit(fn -> System.delete_env("RAXOL_DEBUG") end)

      secret = %{"api_secret" => "sk-do-not-leak", "weird" => "shape"}
      assert {:error, marker} = complete_stub(secret, provider: :openai, api_key: "k")

      refute marker =~ "sk-do-not-leak"
      assert marker =~ "api_secret"
      no_raw_map!(marker)
    end
  end

  describe "honesty: length-truncation" do
    test "finishreason:length with EMPTY content is a truncation marker, not a clean answer" do
      body =
        longcat_body(%{
          "finishreason" => "length",
          "message" => %{"content" => "", "reasoning_content" => "ran out mid-thought"},
          "usage" => %{"completion_tokens" => 1024}
        })

      assert {:error, marker} = complete_stub(body, provider: :openai, api_key: "k")
      assert marker =~ "truncated"
      assert marker =~ "1024 tokens"
      assert marker =~ "AI_MAX_TOKENS"
      no_raw_map!(marker)
    end

    test "length with NON-empty content keeps the partial answer but discloses truncation" do
      body = longcat_body(%{"finishreason" => "length"})
      assert {:ok, response} = complete_stub(body, provider: :openai, api_key: "k")
      assert response.content == "the sky is blue"
      assert response.metadata.finish_reason == :length
      assert response.metadata.truncated == true
    end
  end

  describe "max_tokens default + AI_MAX_TOKENS override" do
    test "default is raised well above the old 1024 cap" do
      System.delete_env("AI_MAX_TOKENS")
      body = captured_body(provider: :openai, api_key: "k")
      assert body.max_tokens >= 4096
    end

    test "AI_MAX_TOKENS env overrides the default" do
      System.put_env("AI_MAX_TOKENS", "8000")
      on_exit(fn -> System.delete_env("AI_MAX_TOKENS") end)

      body = captured_body(provider: :openai, api_key: "k")
      assert body.max_tokens == 8000
    end

    test "an explicit :max_tokens opt still wins over the env" do
      System.put_env("AI_MAX_TOKENS", "8000")
      on_exit(fn -> System.delete_env("AI_MAX_TOKENS") end)

      body = captured_body(provider: :openai, api_key: "k", max_tokens: 256)
      assert body.max_tokens == 256
    end
  end

  # -- streaming (:openai SSE) shape ------------------------------------------

  # parse_sse emits {:reasoning_delta, _} for the reasoning channel; stream_next
  # maps it to the backend-stream {:reasoning, _} event (verified separately).
  describe "parse_sse/2 :openai reasoning + message-object chunks" do
    test "a full-message chunk (message, not delta) streams content + reasoning" do
      raw =
        ~s(data: {"choices":[{"delta":null,"message":{"content":"hi there","reasoning_content":"pondering"}}]}\n\n)

      {events, buffer} = HTTP.parse_sse(raw, :openai)

      assert {:reasoning_delta, "pondering"} in events
      assert {:text_delta, "hi there"} in events
      assert buffer == ""
    end

    test "standard OpenAI delta.content still parses (no regression)" do
      raw = ~s(data: {"choices":[{"delta":{"content":"tok"}}]}\n\n)
      {events, _} = HTTP.parse_sse(raw, :openai)
      assert events == [{:text_delta, "tok"}]
    end

    test "delta.reasoning_content streams on the reasoning channel" do
      raw = ~s(data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}\n\n)
      {events, _} = HTTP.parse_sse(raw, :openai)
      assert events == [{:reasoning_delta, "hmm"}]
    end

    test "delta.reasoning (OpenRouter variant) also streams on the reasoning channel" do
      raw = ~s(data: {"choices":[{"delta":{"reasoning":"or"}}]}\n\n)
      {events, _} = HTTP.parse_sse(raw, :openai)
      assert events == [{:reasoning_delta, "or"}]
    end

    test "finishreason:length emits a truncation marker" do
      raw =
        ~s(data: {"choices":[{"delta":{"content":""},"finishreason":"length"}]}\n\n)

      {events, _} = HTTP.parse_sse(raw, :openai)
      assert {:marker, marker} = Enum.find(events, &match?({:marker, _}, &1))
      assert marker =~ "truncated"
      no_raw_map!(marker)
    end

    test "[DONE] is a usage sentinel; role-only openers are skipped" do
      assert {[{:usage, %{}}], ""} = HTTP.parse_sse("data: [DONE]\n\n", :openai)

      assert {[], ""} =
               HTTP.parse_sse(~s(data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n), :openai)
    end

    test "an unparseable data line is an honest marker, not a silent drop or a dump" do
      {events, _} = HTTP.parse_sse("data: {not valid json\n\n", :openai)
      assert [{:marker, marker}] = events
      assert marker =~ "unparseable"
      no_raw_map!(marker)
    end

    test "SSE comments / keep-alives are skipped (no marker)" do
      assert {[], _} = HTTP.parse_sse(": keep-alive\n\n", :openai)
    end
  end

  describe "parse_sse/2 no-regression for other providers" do
    test "anthropic content_block_delta still yields text" do
      raw = ~s(data: {"type":"content_block_delta","delta":{"text":"a"}}\n\n)
      assert {[{:text_delta, "a"}], _} = HTTP.parse_sse(raw, :anthropic)
    end

    test "ollama NDJSON message.content still yields text" do
      raw = ~s({"message":{"content":"o"}}\n)
      {events, _} = HTTP.parse_sse(raw, :ollama)
      assert events == [{:text_delta, "o"}]
    end
  end
end
