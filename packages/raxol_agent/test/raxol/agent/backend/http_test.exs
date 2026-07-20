defmodule Raxol.Agent.Backend.HTTPTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Backend.HTTP

  describe "complete/2" do
    test "accepts req_plugins option" do
      # Plugin that records it was called
      test_pid = self()

      plugin = fn req ->
        send(test_pid, {:plugin_called, req})
        req
      end

      # Will fail to connect but the plugin should still be called
      result =
        HTTP.complete(
          [%{role: :user, content: "hello"}],
          api_key: "test",
          base_url: "http://127.0.0.1:19876",
          req_plugins: [plugin],
          timeout: 100
        )

      assert {:error, _} = result
      assert_received {:plugin_called, %Req.Request{}}
    end

    test "works without req_plugins" do
      result =
        HTTP.complete(
          [%{role: :user, content: "hello"}],
          api_key: "test",
          base_url: "http://127.0.0.1:19876",
          timeout: 100
        )

      assert {:error, _} = result
    end

    test "applies multiple plugins in order" do
      test_pid = self()

      plugin_a = fn req ->
        send(test_pid, {:plugin, :a})
        req
      end

      plugin_b = fn req ->
        send(test_pid, {:plugin, :b})
        req
      end

      HTTP.complete(
        [%{role: :user, content: "hello"}],
        api_key: "test",
        base_url: "http://127.0.0.1:19876",
        req_plugins: [plugin_a, plugin_b],
        timeout: 100
      )

      assert_received {:plugin, :a}
      assert_received {:plugin, :b}
    end
  end

  describe "stream/2" do
    test "accepts req_plugins option" do
      test_pid = self()

      plugin = fn req ->
        send(test_pid, {:stream_plugin_called, req})
        req
      end

      # Stream returns {:ok, stream} or {:error, _}
      # The plugin runs inside the spawned process, so we need to wait
      case HTTP.stream(
             [%{role: :user, content: "hello"}],
             api_key: "test",
             base_url: "http://127.0.0.1:19876",
             req_plugins: [plugin],
             timeout: 100
           ) do
        {:ok, stream} ->
          # Consume one element to trigger the request
          stream |> Enum.take(1)
          # Plugin runs in spawned process, give it time
          assert_receive {:stream_plugin_called, %Req.Request{}}, 1000

        {:error, _} ->
          # If Req isn't loaded, that's fine
          :ok
      end
    end
  end

  describe "plugin can modify request" do
    test "plugin adds custom header" do
      test_pid = self()

      plugin = fn req ->
        req = Req.Request.put_header(req, "x-custom", "test-value")
        send(test_pid, {:headers, req.headers})
        req
      end

      HTTP.complete(
        [%{role: :user, content: "hello"}],
        api_key: "test",
        base_url: "http://127.0.0.1:19876",
        req_plugins: [plugin],
        timeout: 100
      )

      assert_received {:headers, headers}
      # Headers is a map in Req
      assert headers["x-custom"] == ["test-value"]
    end
  end

  describe "extra_headers option" do
    test "attaches caller-supplied attribution headers to the request" do
      test_pid = self()

      plugin = fn req ->
        send(test_pid, {:headers, req.headers})
        req
      end

      HTTP.complete(
        [%{role: :user, content: "hello"}],
        provider: :openai,
        api_key: "test",
        base_url: "http://127.0.0.1:19876",
        extra_headers: [{"HTTP-Referer", "https://raxol.io"}],
        req_plugins: [plugin],
        timeout: 100
      )

      assert_received {:headers, headers}
      # Req lowercases header field names on the wire (HTTP-compliant).
      assert headers["http-referer"] == ["https://raxol.io"]
    end

    test "appends exactly one /v1/chat/completions to a base URL ending in /api" do
      # Guards the OpenRouter base_url gotcha: build_request must not double the
      # /v1 when the base already ends in /api (openrouter.ai/api -> .../api/v1/...).
      test_pid = self()

      plugin = fn req ->
        send(test_pid, {:url, URI.to_string(req.url)})
        req
      end

      HTTP.complete(
        [%{role: :user, content: "hello"}],
        provider: :openai,
        api_key: "test",
        base_url: "http://127.0.0.1:19876/api",
        req_plugins: [plugin],
        timeout: 100
      )

      assert_received {:url, url}
      assert url == "http://127.0.0.1:19876/api/v1/chat/completions"
    end
  end

  # Request-assembly pins: a system message must land in each provider's
  # correct slot -- Anthropic's top-level :system field, an OpenAI-compatible
  # messages[0] role=system, Ollama's system message in /api/chat messages.
  # A system prompt silently dropped in transit is a trust bug; these pins
  # make that failure loud. Captured via the req_plugins seam (the request is
  # fully built before the plugin runs; the send then fails on a dead port).
  @system_text "You are terse."
  @sys_and_user [
    %{role: :system, content: "You are terse."},
    %{role: :user, content: "hello"}
  ]

  defp captured_body(messages, provider_opts) do
    test_pid = self()

    plugin = fn req ->
      send(test_pid, {:req_json, req.options[:json]})
      req
    end

    HTTP.complete(
      messages,
      provider_opts ++
        [
          base_url: "http://127.0.0.1:19876",
          req_plugins: [plugin],
          timeout: 100
        ]
    )

    assert_received {:req_json, body}
    body
  end

  describe "system prompt request assembly" do
    test "anthropic: system message becomes the top-level :system field" do
      body = captured_body(@sys_and_user, provider: :anthropic, api_key: "test")

      assert body.system == @system_text
      assert [%{role: "user", content: "hello"}] = body.messages
    end

    test "anthropic: multiple system messages join into one :system field" do
      messages = [
        %{role: :system, content: "Line one."},
        %{role: :system, content: "Line two."},
        %{role: :user, content: "hello"}
      ]

      body = captured_body(messages, provider: :anthropic, api_key: "test")

      assert body.system == "Line one.\nLine two."
      assert [%{role: "user", content: "hello"}] = body.messages
    end

    test "anthropic: no system message means no :system key at all" do
      body =
        captured_body(
          [%{role: :user, content: "hello"}],
          provider: :anthropic,
          api_key: "test"
        )

      refute Map.has_key?(body, :system)
    end

    test "openai: system message stays as messages[0] role=system" do
      body = captured_body(@sys_and_user, provider: :openai, api_key: "test")

      assert [
               %{role: "system", content: @system_text},
               %{role: "user", content: "hello"}
             ] = body.messages

      refute Map.has_key?(body, :system)
    end

    test "kimi: system message stays as messages[0] role=system" do
      body = captured_body(@sys_and_user, provider: :kimi, api_key: "test")

      assert [
               %{role: "system", content: @system_text},
               %{role: "user", content: "hello"}
             ] = body.messages

      refute Map.has_key?(body, :system)
    end

    test "ollama: system message rides in the /api/chat messages array" do
      body = captured_body(@sys_and_user, provider: :ollama)

      assert [
               %{role: "system", content: @system_text},
               %{role: "user", content: "hello"}
             ] = body.messages

      refute Map.has_key?(body, :system)
    end
  end

  describe "streamed tool-call accumulation" do
    test "incremental deltas merge: name from the first fragment, args across chunks" do
      # OpenAI-compatible providers (incl. LongCat) stream tool_calls
      # incrementally: id + function.name on the first fragment for an index,
      # function.arguments as string fragments after. Reading each chunk whole
      # with last-wins loses the name (the final fragment is args-only) --
      # the :missing_tool_name bug. Accumulation by index fixes it.
      batches = [
        [%{"index" => 0, "id" => "c1", "function" => %{"name" => "edit_file", "arguments" => ""}}],
        [%{"index" => 0, "function" => %{"arguments" => "{\"path\":\"mix.exs\","}}],
        [%{"index" => 0, "function" => %{"arguments" => "\"old\":\"a\",\"new\":\"b\"}"}}]
      ]

      assert [
               %{
                 "id" => "c1",
                 "name" => "edit_file",
                 "arguments" => %{"path" => "mix.exs", "old" => "a", "new" => "b"}
               }
             ] = HTTP.accumulate_tool_calls(batches)
    end

    test "a single full-message tool_call (name + whole args string in one chunk) also works" do
      batches = [
        [
          %{
            "index" => 0,
            "id" => "c9",
            "function" => %{"name" => "read_file", "arguments" => "{\"path\":\"a.txt\"}"}
          }
        ]
      ]

      assert [%{"id" => "c9", "name" => "read_file", "arguments" => %{"path" => "a.txt"}}] =
               HTTP.accumulate_tool_calls(batches)
    end

    test "no tool-call fragments -> empty list" do
      assert [] = HTTP.accumulate_tool_calls([])
    end

    test "two indexless complete single-call batches in separate chunks are NOT cross-merged" do
      # No "index" key at all (a no-index provider) -- each batch is a
      # complete, standalone call (id + name + full arguments in one
      # shot). Before the fix, the position-within-batch fallback (`pos`)
      # restarts at 0 for every single-fragment batch, so the second
      # call's fragment silently overwrote the first's slot and only one
      # call survived.
      batches = [
        [
          %{
            "id" => "c1",
            "function" => %{"name" => "read_file", "arguments" => "{\"path\":\"a.txt\"}"}
          }
        ],
        [
          %{
            "id" => "c2",
            "function" => %{"name" => "list_dir", "arguments" => "{\"path\":\".\"}"}
          }
        ]
      ]

      result = HTTP.accumulate_tool_calls(batches)

      assert length(result) == 2
      assert %{"id" => "c1", "name" => "read_file", "arguments" => %{"path" => "a.txt"}} in result
      assert %{"id" => "c2", "name" => "list_dir", "arguments" => %{"path" => "."}} in result
    end

    test "an indexless continuation fragment that repeats the id still merges into the same call" do
      batches = [
        [%{"id" => "c1", "function" => %{"name" => "edit_file", "arguments" => "{\"a\":"}}],
        [%{"id" => "c1", "function" => %{"arguments" => "1}"}}]
      ]

      assert [%{"id" => "c1", "name" => "edit_file", "arguments" => %{"a" => 1}}] =
               HTTP.accumulate_tool_calls(batches)
    end

    test "undecodable accumulated arguments surface an honest marker, never a silently laundered %{}" do
      batches = [
        [
          %{
            "index" => 0,
            "id" => "c1",
            "function" => %{"name" => "edit_file", "arguments" => "{not valid json"}
          }
        ]
      ]

      assert [%{"id" => "c1", "name" => "edit_file", "arguments" => %{}} = call] =
               HTTP.accumulate_tool_calls(batches)

      assert is_binary(call["arguments_error"])
      assert call["arguments_error"] =~ "undecodable"

      refute call["arguments_error"] =~ "not valid json",
             "the marker must not leak the raw provider text"
    end
  end
end
