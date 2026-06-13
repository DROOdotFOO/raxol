defmodule Raxol.Telegram.RichMessage.SenderTest do
  use ExUnit.Case, async: false

  import Raxol.Telegram.RichMessage

  alias Raxol.Telegram.RichMessage.Sender

  setup do
    # Clear any test pollution of app env between tests.
    on_exit(fn ->
      Application.delete_env(:raxol_telegram, :bot_token)
      Application.delete_env(:raxol_telegram, :api_base)
    end)

    :ok
  end

  describe "send/3 token resolution" do
    test "returns :no_bot_token when neither opts nor app env has one" do
      assert {:error, :no_bot_token} =
               Sender.send(42, rich_message([paragraph("hi")]), post_fn: stub_post(:ok))
    end

    test "uses bot_token from opts" do
      assert {:ok, %{"message_id" => 1}} =
               Sender.send(42, rich_message([paragraph("hi")]),
                 bot_token: "test-token",
                 post_fn: stub_post(:ok)
               )
    end

    test "falls back to app env bot_token" do
      Application.put_env(:raxol_telegram, :bot_token, "env-token")

      assert {:ok, _} =
               Sender.send(42, rich_message([paragraph("hi")]), post_fn: stub_post(:ok))
    end

    test "treats empty string token as missing" do
      assert {:error, :no_bot_token} =
               Sender.send(42, rich_message([paragraph("hi")]),
                 bot_token: "",
                 post_fn: stub_post(:ok)
               )
    end
  end

  describe "send/3 URL construction" do
    test "uses default api_base when none configured" do
      url_capture = stub_post_capturing_url()

      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        post_fn: url_capture.post_fn
      )

      assert "https://api.telegram.org/bott/sendRichMessage" == url_capture.received_url.()
    end

    test "honors :api_base opt for self-hosted Bot API server" do
      url_capture = stub_post_capturing_url()

      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        api_base: "https://bot.local",
        post_fn: url_capture.post_fn
      )

      assert "https://bot.local/bott/sendRichMessage" == url_capture.received_url.()
    end

    test "honors :api_base from app env" do
      Application.put_env(:raxol_telegram, :api_base, "https://bot.env")
      url_capture = stub_post_capturing_url()

      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        post_fn: url_capture.post_fn
      )

      assert "https://bot.env/bott/sendRichMessage" == url_capture.received_url.()
    end
  end

  describe "send/3 payload assembly" do
    test "builds chat_id and rich_message in body" do
      capture = stub_post_capturing_body()

      msg = rich_message([paragraph("hi")])
      Sender.send(42, msg, bot_token: "t", post_fn: capture.post_fn)

      body = capture.received_body.()
      assert body[:json][:chat_id] == 42
      assert body[:json][:rich_message] == msg
    end

    test "forwards reply_markup, disable_notification, reply_to_message_id" do
      capture = stub_post_capturing_body()
      markup = %{inline_keyboard: [[%{text: "Ok"}]]}

      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        reply_markup: markup,
        disable_notification: true,
        reply_to_message_id: 99,
        post_fn: capture.post_fn
      )

      body = capture.received_body.()
      assert body[:json][:reply_markup] == markup
      assert body[:json][:disable_notification] == true
      assert body[:json][:reply_to_message_id] == 99
    end

    test "uses configured :timeout as :receive_timeout" do
      capture = stub_post_capturing_body()

      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        timeout: 5_000,
        post_fn: capture.post_fn
      )

      assert capture.received_body.()[:receive_timeout] == 5_000
    end
  end

  describe "send/3 chunking" do
    test "applies chunking by default for long messages" do
      capture = stub_post_capturing_body()
      big = String.duplicate("x", 5_000)
      msg = rich_message([paragraph(big), paragraph(big)])

      Sender.send(42, msg, bot_token: "t", post_fn: capture.post_fn)

      [_first, second] = capture.received_body.()[:json][:rich_message].blocks
      assert second.type == "details"
    end

    test "passes :chunk_opts through to RichMessage.chunk/2" do
      capture = stub_post_capturing_body()
      big = String.duplicate("x", 5_000)
      msg = rich_message([paragraph(big), paragraph(big)])

      Sender.send(42, msg,
        bot_token: "t",
        chunk_opts: [summary: "Expand"],
        post_fn: capture.post_fn
      )

      [_, details_block] = capture.received_body.()[:json][:rich_message].blocks
      assert details_block.summary == [%{type: "text", text: "Expand"}]
    end

    test "skips chunking when chunk: false" do
      capture = stub_post_capturing_body()
      big = String.duplicate("x", 5_000)
      msg = rich_message([paragraph(big), paragraph(big)])

      Sender.send(42, msg, bot_token: "t", chunk: false, post_fn: capture.post_fn)

      assert capture.received_body.()[:json][:rich_message] == msg
    end

    test "returns {:error, :too_long} when content exceeds max_chars" do
      huge = String.duplicate("x", 40_000)
      msg = rich_message([paragraph(huge)])

      assert {:error, :too_long} =
               Sender.send(42, msg, bot_token: "t", post_fn: stub_post(:ok))
    end
  end

  describe "send/3 response handling" do
    test "returns {:ok, result} on Bot API success" do
      result = %{"message_id" => 123, "chat" => %{"id" => 42}}

      assert {:ok, ^result} =
               Sender.send(42, rich_message([paragraph("hi")]),
                 bot_token: "t",
                 post_fn:
                   stub_post({:ok, %{status: 200, body: %{"ok" => true, "result" => result}}})
               )
    end

    test "returns Bot API error when status 200 but ok: false" do
      response = %{
        status: 200,
        body: %{"ok" => false, "description" => "Bad Request", "error_code" => 400}
      }

      assert {:error, {:bot_api_error, 400, "Bad Request"}} =
               Sender.send(42, rich_message([paragraph("hi")]),
                 bot_token: "t",
                 post_fn: stub_post({:ok, response})
               )
    end

    test "returns wrapped error for non-200 status" do
      response = %{status: 429, body: %{"description" => "Too Many Requests"}}

      assert {:error, {:bot_api_error, 429, %{"description" => "Too Many Requests"}}} =
               Sender.send(42, rich_message([paragraph("hi")]),
                 bot_token: "t",
                 post_fn: stub_post({:ok, response})
               )
    end

    test "wraps transport errors" do
      assert {:error, {:http_error, :timeout}} =
               Sender.send(42, rich_message([paragraph("hi")]),
                 bot_token: "t",
                 post_fn: stub_post({:error, :timeout})
               )
    end

    test "propagates :req_not_available" do
      not_available_post = fn _url, _opts -> {:error, :req_not_available} end

      assert {:error, :req_not_available} =
               Sender.send(42, rich_message([paragraph("hi")]),
                 bot_token: "t",
                 post_fn: not_available_post
               )
    end
  end

  describe "telemetry" do
    setup do
      ref = make_ref()
      events = [[:raxol_telegram, :rich_message, :sent], [:raxol_telegram, :rich_message, :error]]

      :telemetry.attach_many(
        {ref, :sender_test},
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach({ref, :sender_test}) end)

      {:ok, %{}}
    end

    test "emits :sent on success with byte_size and chunked? metadata" do
      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        post_fn: stub_post(:ok)
      )

      assert_receive {:telemetry, [:raxol_telegram, :rich_message, :sent], measurements, metadata}
      assert is_integer(measurements.byte_size) and measurements.byte_size > 0
      assert metadata.chat_id == 42
      assert metadata.chunked? == false
    end

    test "marks chunked? = true when chunking occurred" do
      big = String.duplicate("x", 5_000)
      msg = rich_message([paragraph(big), paragraph(big)])

      Sender.send(42, msg, bot_token: "t", post_fn: stub_post(:ok))

      assert_receive {:telemetry, [:raxol_telegram, :rich_message, :sent], _, %{chunked?: true}}
    end

    test "emits :error on Bot API failure with reason metadata" do
      response = %{status: 429, body: %{"description" => "Too Many Requests"}}

      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        post_fn: stub_post({:ok, response})
      )

      assert_receive {:telemetry, [:raxol_telegram, :rich_message, :error], _, %{reason: reason}}
      assert {:bot_api_error, 429, _} = reason
    end

    test "emits :error on transport failure" do
      Sender.send(42, rich_message([paragraph("hi")]),
        bot_token: "t",
        post_fn: stub_post({:error, :timeout})
      )

      assert_receive {:telemetry, [:raxol_telegram, :rich_message, :error], _, %{reason: reason}}
      assert {:http_error, :timeout} = reason
    end
  end

  # --- Helpers ---

  defp stub_post(:ok) do
    fn _url, _opts ->
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => 1}}}}
    end
  end

  defp stub_post(response) do
    fn _url, _opts -> response end
  end

  defp stub_post_capturing_url do
    {:ok, pid} = Agent.start_link(fn -> nil end)

    post_fn = fn url, _opts ->
      Agent.update(pid, fn _ -> url end)
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => 1}}}}
    end

    %{post_fn: post_fn, received_url: fn -> Agent.get(pid, & &1) end}
  end

  defp stub_post_capturing_body do
    {:ok, pid} = Agent.start_link(fn -> nil end)

    post_fn = fn _url, opts ->
      Agent.update(pid, fn _ -> opts end)
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => 1}}}}
    end

    %{post_fn: post_fn, received_body: fn -> Agent.get(pid, & &1) end}
  end
end
