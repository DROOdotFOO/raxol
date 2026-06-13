defmodule Raxol.Telegram.PollTest do
  use ExUnit.Case, async: false

  alias Raxol.Telegram.Poll

  setup do
    on_exit(fn ->
      Application.delete_env(:raxol_telegram, :bot_token)
      Application.delete_env(:raxol_telegram, :api_base)
    end)

    :ok
  end

  describe "link_entity/3" do
    test "produces a text_link MessageEntity with the right keys" do
      assert Poll.link_entity(0, 5, "https://example.com") == %{
               type: "text_link",
               offset: 0,
               length: 5,
               url: "https://example.com"
             }
    end

    test "guards against zero or negative length" do
      assert_raise FunctionClauseError, fn -> Poll.link_entity(0, 0, "https://x") end
      assert_raise FunctionClauseError, fn -> Poll.link_entity(0, -1, "https://x") end
    end

    test "guards against negative offset" do
      assert_raise FunctionClauseError, fn -> Poll.link_entity(-1, 5, "https://x") end
    end
  end

  describe "link_option/2" do
    test "returns the tagged tuple" do
      assert Poll.link_option("Read", "https://x") == {:link, "Read", "https://x"}
    end
  end

  describe "to_input_poll_option/1" do
    test "plain string becomes %{text: string}" do
      assert Poll.to_input_poll_option("Yes") == %{text: "Yes"}
    end

    test "link tuple becomes text + single text_link entity covering the whole label" do
      assert Poll.to_input_poll_option({:link, "Read ADR", "https://x"}) == %{
               text: "Read ADR",
               text_entities: [
                 %{type: "text_link", offset: 0, length: 8, url: "https://x"}
               ]
             }
    end

    test "map with text only does not add empty text_entities" do
      assert Poll.to_input_poll_option(%{text: "hello"}) == %{text: "hello"}
    end

    test "map with empty entities list omits text_entities" do
      assert Poll.to_input_poll_option(%{text: "hello", entities: []}) == %{text: "hello"}
    end

    test "map with entities passes them through under text_entities" do
      entity = Poll.link_entity(0, 5, "https://x")

      assert Poll.to_input_poll_option(%{text: "hello", entities: [entity]}) == %{
               text: "hello",
               text_entities: [entity]
             }
    end

    test "uses String.length (display width) for full-label hyperlink offsets" do
      assert %{text_entities: [%{length: 3}]} =
               Poll.to_input_poll_option({:link, "日本語", "https://x"})
    end
  end

  describe "send_poll/4: validation" do
    test "rejects fewer than 2 options without calling the API" do
      capture = capturing_post()

      assert {:error, {:poll_validation, :too_few_options, 1}} =
               Poll.send_poll(42, "Q", ["only one"], bot_token: "t", post_fn: capture.post_fn)

      assert capture.received_url.() == nil
    end

    test "rejects more than 10 options without calling the API" do
      capture = capturing_post()
      eleven = for i <- 1..11, do: "opt#{i}"

      assert {:error, {:poll_validation, :too_many_options, 11}} =
               Poll.send_poll(42, "Q", eleven, bot_token: "t", post_fn: capture.post_fn)

      assert capture.received_url.() == nil
    end

    test "accepts exactly 2 options" do
      capture = capturing_post()
      assert {:ok, _} = Poll.send_poll(42, "Q", ["a", "b"], bot_token: "t", post_fn: capture.post_fn)
      assert capture.received_url.() =~ "sendPoll"
    end

    test "accepts exactly 10 options" do
      capture = capturing_post()
      ten = for i <- 1..10, do: "opt#{i}"
      assert {:ok, _} = Poll.send_poll(42, "Q", ten, bot_token: "t", post_fn: capture.post_fn)
      assert capture.received_url.() =~ "sendPoll"
    end
  end

  describe "send_poll/4: body shape" do
    test "builds chat_id, question, options array" do
      capture = capturing_post()

      Poll.send_poll(42, "Pick one",
        ["Yes", Poll.link_option("Read more", "https://x")],
        bot_token: "t",
        post_fn: capture.post_fn
      )

      body = capture.received_body.()[:json]
      assert body[:chat_id] == 42
      assert body[:question] == "Pick one"

      assert body[:options] == [
               %{text: "Yes"},
               %{
                 text: "Read more",
                 text_entities: [
                   %{type: "text_link", offset: 0, length: 9, url: "https://x"}
                 ]
               }
             ]
    end

    test "forwards recognized Telegram poll options" do
      capture = capturing_post()

      Poll.send_poll(42, "Q", ["a", "b"],
        is_anonymous: false,
        allows_multiple_answers: true,
        type: "regular",
        bot_token: "t",
        post_fn: capture.post_fn
      )

      body = capture.received_body.()[:json]
      assert body[:is_anonymous] == false
      assert body[:allows_multiple_answers] == true
      assert body[:type] == "regular"
    end

    test "forwards quiz-style options" do
      capture = capturing_post()

      Poll.send_poll(42, "Q", ["a", "b"],
        type: "quiz",
        correct_option_id: 1,
        explanation: "B wins",
        bot_token: "t",
        post_fn: capture.post_fn
      )

      body = capture.received_body.()[:json]
      assert body[:type] == "quiz"
      assert body[:correct_option_id] == 1
      assert body[:explanation] == "B wins"
    end

    test "drops unrecognized options without erroring" do
      capture = capturing_post()

      Poll.send_poll(42, "Q", ["a", "b"],
        not_a_real_option: "x",
        bot_token: "t",
        post_fn: capture.post_fn
      )

      body = capture.received_body.()[:json]
      refute Map.has_key?(body, :not_a_real_option)
    end

    test "URL targets sendPoll" do
      capture = capturing_post()
      Poll.send_poll(42, "Q", ["a", "b"], bot_token: "t", post_fn: capture.post_fn)
      assert capture.received_url.() =~ "/sendPoll"
    end

    test "honors :api_base for self-hosted Bot API server" do
      capture = capturing_post()

      Poll.send_poll(42, "Q", ["a", "b"],
        bot_token: "t",
        api_base: "https://bot.local",
        post_fn: capture.post_fn
      )

      assert capture.received_url.() =~ "https://bot.local"
    end
  end

  describe "send_poll/4: response handling" do
    test "returns {:ok, result} on Bot API success" do
      message = %{"message_id" => 123, "poll" => %{"id" => "p1"}}

      stub = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => message}}}
      end

      assert {:ok, ^message} =
               Poll.send_poll(42, "Q", ["a", "b"], bot_token: "t", post_fn: stub)
    end

    test "returns wrapped error on Bot API failure" do
      stub = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"ok" => false, "description" => "POLL_OPTION_INVALID"}}}
      end

      assert {:error, {:bot_api_error, _, "POLL_OPTION_INVALID"}} =
               Poll.send_poll(42, "Q", ["a", "b"], bot_token: "t", post_fn: stub)
    end

    test "returns :no_bot_token when none configured" do
      assert {:error, :no_bot_token} = Poll.send_poll(42, "Q", ["a", "b"], post_fn: stub_ok())
    end
  end

  describe "option_count_range/0" do
    test "returns the documented {2, 10} pair" do
      assert Poll.option_count_range() == {2, 10}
    end
  end

  describe "Jason encoding round-trip" do
    test "the full body serializes to valid JSON without losing structure" do
      capture = capturing_post()

      Poll.send_poll(42, "Q?",
        ["plain", Poll.link_option("link", "https://x")],
        type: "quiz",
        correct_option_id: 0,
        bot_token: "t",
        post_fn: capture.post_fn
      )

      body = capture.received_body.()[:json]
      assert {:ok, json} = Jason.encode(body)
      assert {:ok, decoded} = Jason.decode(json)

      assert decoded["chat_id"] == 42
      assert decoded["question"] == "Q?"
      assert length(decoded["options"]) == 2
      assert decoded["type"] == "quiz"

      [%{"text" => "plain"}, %{"text" => "link", "text_entities" => [link_entity]}] =
        decoded["options"]

      assert link_entity == %{
               "type" => "text_link",
               "offset" => 0,
               "length" => 4,
               "url" => "https://x"
             }
    end
  end

  # --- Helpers ---

  defp stub_ok do
    fn _url, _opts ->
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => 1}}}}
    end
  end

  defp capturing_post do
    {:ok, url_agent} = Agent.start_link(fn -> nil end)
    {:ok, body_agent} = Agent.start_link(fn -> nil end)

    post_fn = fn url, opts ->
      Agent.update(url_agent, fn _ -> url end)
      Agent.update(body_agent, fn _ -> opts end)
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => 1}}}}
    end

    %{
      post_fn: post_fn,
      received_url: fn -> Agent.get(url_agent, & &1) end,
      received_body: fn -> Agent.get(body_agent, & &1) end
    }
  end
end
