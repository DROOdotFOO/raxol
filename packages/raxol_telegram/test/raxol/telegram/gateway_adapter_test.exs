defmodule Raxol.Telegram.GatewayAdapterTest do
  # async: false - connect/1 falls back to the process-global app env token.
  use ExUnit.Case, async: false

  alias Raxol.Telegram.GatewayAdapter

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

  defp capture_conn(extra \\ []) do
    test_pid = self()

    post_fn = fn url, req_opts ->
      send(test_pid, {:posted, url, Keyword.fetch!(req_opts, :json)})
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{}}}}
    end

    Keyword.merge([bot_token: "test-token", post_fn: post_fn], extra)
  end

  describe "platform/0 and connect/1" do
    test "platform is :telegram" do
      assert GatewayAdapter.platform() == :telegram
    end

    test "connect succeeds with a token and returns the opts as conn" do
      assert {:ok, conn} = GatewayAdapter.connect(bot_token: "t")
      assert conn[:bot_token] == "t"
      assert GatewayAdapter.disconnect(conn) == :ok
    end

    test "connect fails fast without a token" do
      assert {:error, :no_bot_token} = GatewayAdapter.connect([])
    end
  end

  describe "normalize_event/1" do
    test "private text message with atom keys" do
      raw = %{
        message: %{
          text: "hello",
          chat: %{id: 42, type: "private"},
          from: %{id: 7}
        }
      }

      assert {:ok, route, %{text: "hello"}} = GatewayAdapter.normalize_event(raw)
      assert route.platform == :telegram
      assert route.chat_type == :private
      assert route.chat_id == 42
      assert route.user_id == 7
    end

    test "supergroup maps to :supergroup" do
      raw = %{message: %{text: "x", chat: %{id: 1, type: "supergroup"}}}

      assert {:ok, route, _event} = GatewayAdapter.normalize_event(raw)
      assert route.chat_type == :supergroup
      assert route.user_id == nil
    end

    test "string-keyed webhook payload" do
      raw = %{
        "message" => %{
          "text" => "from webhook",
          "chat" => %{"id" => 99, "type" => "group"},
          "from" => %{"id" => 3}
        }
      }

      assert {:ok, route, %{text: "from webhook"}} = GatewayAdapter.normalize_event(raw)
      assert route.chat_type == :group
      assert route.chat_id == 99
      assert route.user_id == 3
    end

    test "non-text and unsupported updates are ignored" do
      ignored = [
        %{message: %{text: "", chat: %{id: 1, type: "private"}}},
        %{message: %{photo: [], chat: %{id: 1, type: "private"}}},
        %{callback_query: %{data: "key:enter"}},
        %{chat_join_request: %{chat: %{id: 1}}},
        # unknown chat type stays out of the atom space
        %{message: %{text: "x", chat: %{id: 1, type: "weird"}}},
        %{},
        :not_a_map
      ]

      for raw <- ignored do
        assert GatewayAdapter.normalize_event(raw) == :ignore
      end
    end
  end

  describe "send_message/3" do
    test "posts sendMessage with chat_id and plain text" do
      conn = capture_conn()
      route = %{chat_id: 42}

      assert :ok = GatewayAdapter.send_message(conn, route, "hello there")

      assert_receive {:posted, url, body}
      assert String.ends_with?(url, "/sendMessage")
      assert body == %{chat_id: 42, text: "hello there"}
    end

    test "empty and whitespace-only replies are a no-op" do
      conn = capture_conn()

      assert :ok = GatewayAdapter.send_message(conn, %{chat_id: 1}, "")
      assert :ok = GatewayAdapter.send_message(conn, %{chat_id: 1}, "   \n ")

      refute_receive {:posted, _, _}, 50
    end

    test "long replies chunk in order at the UTF-16 limit" do
      conn = capture_conn()
      text = String.duplicate("a", 5000)

      assert :ok = GatewayAdapter.send_message(conn, %{chat_id: 1}, text)

      assert_receive {:posted, _, %{text: first}}
      assert_receive {:posted, _, %{text: second}}
      assert String.length(first) == 4096
      assert String.length(second) == 904
      assert first <> second == text
    end

    test "chunks count UTF-16 code units, not graphemes" do
      conn = capture_conn()
      # A surrogate-pair emoji is 2 UTF-16 units: 2500 of them fit in one
      # 4096-grapheme chunk but must split at 2048 per message.
      text = String.duplicate("\u{1F600}", 2500)

      assert :ok = GatewayAdapter.send_message(conn, %{chat_id: 1}, text)

      assert_receive {:posted, _, %{text: first}}
      assert_receive {:posted, _, %{text: second}}
      assert String.length(first) == 2048
      assert String.length(second) == 452
    end

    test "halts on the first Bot API error" do
      test_pid = self()

      post_fn = fn _url, req_opts ->
        send(test_pid, {:posted, Keyword.fetch!(req_opts, :json)})

        {:ok,
         %{
           status: 200,
           body: %{"ok" => false, "description" => "Bad Request", "error_code" => 400}
         }}
      end

      conn = [bot_token: "t", post_fn: post_fn]
      text = String.duplicate("a", 5000)

      assert {:error, {:bot_api_error, 400, "Bad Request"}} =
               GatewayAdapter.send_message(conn, %{chat_id: 1}, text)

      assert_receive {:posted, _}
      refute_receive {:posted, _}, 50
    end

    test "non-binary rendered is rejected" do
      assert {:error, :unsupported_rendered} =
               GatewayAdapter.send_message(capture_conn(), %{chat_id: 1}, {:tuple, "x"})
    end
  end
end
