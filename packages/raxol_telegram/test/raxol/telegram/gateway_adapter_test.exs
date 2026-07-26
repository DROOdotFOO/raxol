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

    test "connect rejects non-keyword and string-keyed configs" do
      assert {:error, :invalid_config} = GatewayAdapter.connect(%{"bot_token" => "t"})
      assert {:error, :invalid_config} = GatewayAdapter.connect([1, 2])
      assert {:error, :invalid_config} = GatewayAdapter.connect("token")
    end

    test "connect accepts an atom-keyed map" do
      assert {:ok, conn} = GatewayAdapter.connect(%{bot_token: "t"})
      assert conn[:bot_token] == "t"
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

    test "voice note with atom keys normalizes to a media event" do
      raw = %{
        message: %{
          voice: %{file_id: "vf-1", duration: 3, mime_type: "audio/ogg", file_size: 512},
          chat: %{id: 42, type: "private"},
          from: %{id: 7}
        }
      }

      assert {:ok, route, %{media: media}} = GatewayAdapter.normalize_event(raw)
      assert route.platform == :telegram
      assert route.chat_id == 42
      assert route.user_id == 7

      assert media == %{
               kind: :voice,
               ref: "vf-1",
               mime: "audio/ogg",
               duration_s: 3,
               size_bytes: 512
             }
    end

    test "string-keyed voice note carries nil for absent metadata" do
      raw = %{
        "message" => %{
          "voice" => %{"file_id" => "vf-2", "duration" => 1},
          "chat" => %{"id" => 9, "type" => "group"},
          "from" => %{"id" => 3}
        }
      }

      assert {:ok, route, %{media: media}} = GatewayAdapter.normalize_event(raw)
      assert route.chat_type == :group
      assert route.user_id == 3
      assert media == %{kind: :voice, ref: "vf-2", mime: nil, duration_s: 1, size_bytes: nil}
    end

    test "voice notes without a usable file_id or chat type are ignored" do
      ignored = [
        %{message: %{voice: %{duration: 2}, chat: %{id: 1, type: "private"}}},
        %{message: %{voice: %{file_id: ""}, chat: %{id: 1, type: "private"}}},
        %{
          "message" => %{
            "voice" => %{"file_id" => "v"},
            "chat" => %{"id" => 1, "type" => "weird"}
          }
        }
      ]

      for raw <- ignored do
        assert GatewayAdapter.normalize_event(raw) == :ignore
      end
    end
  end

  describe "fetch_media/2" do
    test "downloads the bytes behind the media ref" do
      test_pid = self()

      post_fn = fn _url, _req_opts ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"file_path" => "voice/v.oga"}}}}
      end

      get_fn = fn url, _req_opts ->
        send(test_pid, {:got, url})
        {:ok, %{status: 200, body: "OGGBYTES"}}
      end

      conn = [bot_token: "tok", post_fn: post_fn, get_fn: get_fn]

      assert {:ok, "OGGBYTES"} = GatewayAdapter.fetch_media(conn, %{kind: :voice, ref: "vf-1"})
      assert_received {:got, "https://api.telegram.org/file/bottok/voice/v.oga"}
    end

    test "a media map without a binary ref is rejected" do
      assert {:error, :unsupported_media} =
               GatewayAdapter.fetch_media([], %{kind: :voice, ref: nil})

      assert {:error, :unsupported_media} = GatewayAdapter.fetch_media([], %{})
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

    test "invalid UTF-8 is rejected with an error tuple, not a raise" do
      conn = capture_conn()

      assert {:error, :invalid_encoding} =
               GatewayAdapter.send_message(conn, %{chat_id: 1}, <<0xFF, 0xFE, "x">>)

      refute_receive {:posted, _, _}, 50
    end

    test "a whitespace-only chunk is skipped, later chunks still send" do
      conn = capture_conn()
      # 4090 'a's, then >4096 spaces (forcing an all-whitespace middle
      # chunk), then a trailing word that must still be delivered.
      text = String.duplicate("a", 4090) <> String.duplicate(" ", 4200) <> "tail"

      assert :ok = GatewayAdapter.send_message(conn, %{chat_id: 1}, text)

      posted =
        for _ <- 1..2 do
          assert_receive {:posted, _, %{text: chunk}}
          chunk
        end

      refute_receive {:posted, _, _}, 50
      assert Enum.all?(posted, &(String.trim(&1) != ""))
      assert List.last(posted) =~ "tail"
    end

    test "a single oversized grapheme cluster is split rather than sent over-limit" do
      conn = capture_conn()
      # 3000 combining acute accents on one base char: one grapheme cluster
      # of ~3001 UTF-16 units with a 2048-unit budget in a small helper run.
      zalgo = "a" <> String.duplicate("́", 5000)

      assert :ok = GatewayAdapter.send_message(conn, %{chat_id: 1}, zalgo)

      chunks = collect_chunks()
      assert length(chunks) > 1

      for chunk <- chunks do
        units =
          chunk
          |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
          |> byte_size()
          |> div(2)

        assert units <= 4096
      end
    end
  end

  defp collect_chunks(acc \\ []) do
    receive do
      {:posted, _, %{text: chunk}} -> collect_chunks([chunk | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
