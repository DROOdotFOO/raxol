defmodule Raxol.Gateway.Adapter.DiscordTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Adapter.Discord
  alias Raxol.Gateway.Route

  defp message_frame(overrides \\ %{}) do
    message =
      Map.merge(
        %{
          "content" => "hello",
          "channel_id" => "chan-1",
          "author" => %{"id" => "user-1"}
        },
        overrides
      )

    %{"t" => "MESSAGE_CREATE", "s" => 1, "op" => 0, "d" => message}
  end

  defp capture_conn(test_pid, responses \\ nil) do
    post_fn = fn url, req_opts ->
      send(test_pid, {:posted, url, req_opts})

      case responses do
        nil -> {:ok, %{status: 200, body: %{"id" => "msg"}}}
        fun -> fun.()
      end
    end

    {:ok, conn} = Discord.connect(bot_token: "tok", post_fn: post_fn)
    conn
  end

  describe "connect/1" do
    test "requires a bot token" do
      assert {:error, :no_bot_token} = Discord.connect([])
      assert {:error, :no_bot_token} = Discord.connect(bot_token: "")
      assert {:ok, _conn} = Discord.connect(bot_token: "tok")
      assert {:ok, _conn} = Discord.connect(%{bot_token: "tok"})
    end

    test "rejects non-config shapes" do
      assert {:error, :invalid_config} = Discord.connect("token")

      assert {:error, :invalid_config} =
               Discord.connect(%{"bot_token" => "tok"})
    end
  end

  test "platform/0 and disconnect/1" do
    assert Discord.platform() == :discord
    assert Discord.disconnect([]) == :ok
  end

  describe "normalize_event/1" do
    test "a guild message routes as :guild keyed by channel" do
      frame = message_frame(%{"guild_id" => "g-9"})

      assert {:ok, %Route{} = route, %{text: "hello"}} =
               Discord.normalize_event(frame)

      assert route.platform == :discord
      assert route.chat_type == :guild
      assert route.chat_id == "chan-1"
      assert route.user_id == "user-1"
    end

    test "a message without guild_id routes as :dm" do
      assert {:ok, route, _event} = Discord.normalize_event(message_frame())
      assert route.chat_type == :dm
    end

    test "bot-authored messages are ignored (no reply loops)" do
      frame = message_frame(%{"author" => %{"id" => "bot-1", "bot" => true}})
      assert Discord.normalize_event(frame) == :ignore
    end

    test "empty content, other dispatch types, and junk are ignored" do
      assert Discord.normalize_event(message_frame(%{"content" => ""})) ==
               :ignore

      assert Discord.normalize_event(%{"t" => "TYPING_START", "d" => %{}}) ==
               :ignore

      assert Discord.normalize_event(:not_a_frame) == :ignore
    end
  end

  describe "send_message/3" do
    test "posts to the channel with the bot auth header" do
      conn = capture_conn(self())
      route = %Route{platform: :discord, chat_type: :dm, chat_id: "chan-1"}

      assert :ok = Discord.send_message(conn, route, "hi there")

      assert_receive {:posted, url, req_opts}
      assert url == "https://discord.com/api/v10/channels/chan-1/messages"
      assert Keyword.fetch!(req_opts, :json) == %{content: "hi there"}
      assert {"authorization", "Bot tok"} in Keyword.fetch!(req_opts, :headers)
    end

    test "whitespace-only and empty replies are no-ops" do
      conn = capture_conn(self())
      route = %Route{platform: :discord, chat_type: :dm, chat_id: "c"}

      assert :ok = Discord.send_message(conn, route, "")
      assert :ok = Discord.send_message(conn, route, "  \n ")
      refute_receive {:posted, _url, _opts}, 50
    end

    test "invalid UTF-8 is rejected without a request" do
      conn = capture_conn(self())
      route = %Route{platform: :discord, chat_type: :dm, chat_id: "c"}

      assert {:error, :invalid_encoding} =
               Discord.send_message(conn, route, <<0xFF, 0xFE>>)

      refute_receive {:posted, _url, _opts}, 50
    end

    test "an API error halts remaining chunks and reports the status" do
      fail = fn ->
        {:ok, %{status: 403, body: %{"message" => "Missing Access"}}}
      end

      conn = capture_conn(self(), fail)
      route = %Route{platform: :discord, chat_type: :dm, chat_id: "c"}

      assert {:error, {:discord_api_error, 403, _body}} =
               Discord.send_message(conn, route, String.duplicate("a", 4100))

      assert_receive {:posted, _url, _opts}
      refute_receive {:posted, _url, _opts}, 50
    end
  end

  describe "chunking counts code points, not UTF-16 units or graphemes" do
    defp sent_contents(conn, route, text) do
      assert :ok = Discord.send_message(conn, route, text)
      collect_contents([])
    end

    defp collect_contents(acc) do
      receive do
        {:posted, _url, req_opts} ->
          collect_contents([Keyword.fetch!(req_opts, :json).content | acc])
      after
        50 -> Enum.reverse(acc)
      end
    end

    test "ASCII splits at exactly 2000" do
      conn = capture_conn(self())
      route = %Route{platform: :discord, chat_type: :dm, chat_id: "c"}

      chunks = sent_contents(conn, route, String.duplicate("a", 4500))
      assert Enum.map(chunks, &String.length/1) == [2000, 2000, 500]
    end

    test "2000 astral emoji fit in ONE message (UTF-16 counting would split)" do
      # U+1F600 is one code point but two UTF-16 units: a UTF-16 budget
      # (Telegram's rule) would split this into two messages.
      conn = capture_conn(self())
      route = %Route{platform: :discord, chat_type: :dm, chat_id: "c"}

      chunks = sent_contents(conn, route, String.duplicate("\u{1F600}", 2000))
      assert length(chunks) == 1
    end

    test "multi-codepoint graphemes are never split across a boundary" do
      # "e" + combining acute = one grapheme, two code points. 1001 of
      # them is 2002 code points: the boundary falls mid-grapheme and must
      # move the whole grapheme to the second chunk.
      conn = capture_conn(self())
      route = %Route{platform: :discord, chat_type: :dm, chat_id: "c"}

      grapheme = "é"
      chunks = sent_contents(conn, route, String.duplicate(grapheme, 1001))

      assert length(chunks) == 2

      for chunk <- chunks do
        assert rem(chunk |> String.codepoints() |> length(), 2) == 0
        assert String.starts_with?(chunk, "e")
      end
    end
  end
end
