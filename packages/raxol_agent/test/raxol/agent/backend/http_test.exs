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
end
