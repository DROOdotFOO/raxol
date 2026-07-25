defmodule Raxol.Telegram.HTTPTest do
  # async: false - fetch_token falls back to the process-global app env token.
  use ExUnit.Case, async: false

  alias Raxol.Telegram.HTTP

  setup do
    original = Application.get_env(:raxol_telegram, :bot_token)
    Application.delete_env(:raxol_telegram, :bot_token)

    on_exit(fn ->
      if original,
        do: Application.put_env(:raxol_telegram, :bot_token, original),
        else: Application.delete_env(:raxol_telegram, :bot_token)
    end)

    :ok
  end

  defp download_opts(get_result, extra \\ []) do
    test_pid = self()

    post_fn = fn url, req_opts ->
      send(test_pid, {:get_file_posted, url, Keyword.fetch!(req_opts, :json)})
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"file_path" => "voice/f_1.oga"}}}}
    end

    get_fn = fn url, req_opts ->
      send(test_pid, {:downloaded, url, req_opts})
      get_result
    end

    Keyword.merge([bot_token: "test-token", post_fn: post_fn, get_fn: get_fn], extra)
  end

  describe "download_file/2" do
    test "resolves the path via getFile then GETs the token-scoped file URL" do
      opts = download_opts({:ok, %{status: 200, body: <<1, 2, 3>>}})

      assert {:ok, <<1, 2, 3>>} = HTTP.download_file("file-abc", opts)

      assert_received {:get_file_posted, post_url, %{file_id: "file-abc"}}
      assert String.ends_with?(post_url, "/bottest-token/getFile")

      assert_received {:downloaded, url, req_opts}
      assert url == "https://api.telegram.org/file/bottest-token/voice/f_1.oga"
      assert Keyword.fetch!(req_opts, :receive_timeout) == 10_000
    end

    test "a getFile Bot API error propagates and skips the GET" do
      post_fn = fn _url, _req_opts ->
        {:ok,
         %{status: 200, body: %{"ok" => false, "description" => "not found", "error_code" => 400}}}
      end

      assert {:error, {:bot_api_error, 400, "not found"}} =
               HTTP.download_file("nope",
                 bot_token: "t",
                 post_fn: post_fn,
                 get_fn: fn _, _ -> raise "no GET" end
               )
    end

    test "a getFile result without a file_path is an error" do
      post_fn = fn _url, _req_opts ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"file_id" => "x"}}}}
      end

      assert {:error, :no_file_path} =
               HTTP.download_file("x",
                 bot_token: "t",
                 post_fn: post_fn,
                 get_fn: fn _, _ -> raise "no GET" end
               )
    end

    test "a non-200 download is an error carrying only the status" do
      opts = download_opts({:ok, %{status: 404, body: "gone"}})

      assert {:error, {:download_status, 404}} = HTTP.download_file("f", opts)
    end

    test "a 200 with a non-binary body is an error" do
      opts = download_opts({:ok, %{status: 200, body: %{"weird" => true}}})

      assert {:error, :unexpected_download_body} = HTTP.download_file("f", opts)
    end

    test "a transport error is classified" do
      opts = download_opts({:error, :timeout})

      assert {:error, {:http_error, :timeout}} = HTTP.download_file("f", opts)
    end

    test "a URL-hostile file_path is percent-encoded before the GET" do
      test_pid = self()

      post_fn = fn _url, _req_opts ->
        {:ok,
         %{
           status: 200,
           body: %{"ok" => true, "result" => %{"file_path" => "voice/has space.oga"}}
         }}
      end

      get_fn = fn url, _req_opts ->
        send(test_pid, {:downloaded, url})
        {:ok, %{status: 200, body: "X"}}
      end

      assert {:ok, "X"} =
               HTTP.download_file("f", bot_token: "test-token", post_fn: post_fn, get_fn: get_fn)

      assert_received {:downloaded, url}
      assert url == "https://api.telegram.org/file/bottest-token/voice/has%20space.oga"
    end

    test "a transport error reason embedding the URL is redacted to a token-free term" do
      # Mint's invalid_request_target carries the full path -- token included.
      leaky = {:invalid_request_target, "/file/bottest-token/voice/x y.oga"}
      opts = download_opts({:error, leaky})

      result = HTTP.download_file("f", opts)

      assert result == {:error, {:http_error, :transport_error}}
      refute inspect(result) =~ "test-token"
    end

    test "a struct transport error is summarized without its fields" do
      opts = download_opts({:error, %URI{path: "/file/bottest-token/x"}})

      result = HTTP.download_file("f", opts)

      assert result == {:error, {:http_error, URI}}
      refute inspect(result) =~ "test-token"
    end

    test "a struct error with an atom reason keeps that reason" do
      opts = download_opts({:error, %{__struct__: SomeTransportError, reason: :econnrefused}})

      assert {:error, {:http_error, :econnrefused}} = HTTP.download_file("f", opts)
    end

    test "fails fast without a token, before any request" do
      assert {:error, :no_bot_token} =
               HTTP.download_file("f",
                 post_fn: fn _, _ -> raise "no POST" end,
                 get_fn: fn _, _ -> raise "no GET" end
               )
    end
  end
end
