defmodule Raxol.Telegram.GuardianTest do
  use ExUnit.Case, async: false

  alias Raxol.Telegram.Guardian

  defmodule ApproveAll do
    @behaviour Raxol.Telegram.Guardian
    @impl true
    def screen(_applicant), do: {:approve, "always ok"}
  end

  defmodule DeclineAll do
    @behaviour Raxol.Telegram.Guardian
    @impl true
    def screen(_applicant), do: {:decline, "always no"}
  end

  defmodule AskAll do
    @behaviour Raxol.Telegram.Guardian
    @impl true
    def screen(_applicant), do: {:ask_mini_app, "https://verify.example.com", "Verify"}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:raxol_telegram, :guardian)
      Application.delete_env(:raxol_telegram, :guardian_predicate)
      Application.delete_env(:raxol_telegram, :bot_token)
    end)

    :ok
  end

  describe "decide/2" do
    test "uses the passed module" do
      assert {:approve, "always ok"} = Guardian.decide(applicant(), ApproveAll)
      assert {:decline, "always no"} = Guardian.decide(applicant(), DeclineAll)
    end

    test "reads from app env when no module passed" do
      Application.put_env(:raxol_telegram, :guardian, DeclineAll)
      assert {:decline, "always no"} = Guardian.decide(applicant())
    end

    test "defaults to Static when nothing configured" do
      assert {:approve, nil} = Guardian.decide(applicant())
    end
  end

  describe "apply_decision/3 -- approve (modern, with query_id)" do
    test "calls answerChatJoinRequestQuery when query_id present" do
      capture = capturing_post()
      app = applicant(query_id: "ABC")

      assert {:ok, _} =
               Guardian.apply_decision(app, {:approve, "ok"},
                 bot_token: "t",
                 post_fn: capture.post_fn
               )

      assert capture.received_url.() =~ "answerChatJoinRequestQuery"
      assert capture.received_body.()[:json] == %{query_id: "ABC", action: "approve"}
    end

    test "calls approveChatJoinRequest when query_id absent" do
      capture = capturing_post()
      app = applicant()

      assert {:ok, _} =
               Guardian.apply_decision(app, {:approve, nil},
                 bot_token: "t",
                 post_fn: capture.post_fn
               )

      assert capture.received_url.() =~ "approveChatJoinRequest"
      assert capture.received_body.()[:json] == %{chat_id: 42, user_id: 99}
    end

    test "falls back to approveChatJoinRequest when answerChatJoinRequestQuery returns bot_api_error" do
      call_count = :counters.new(1, [])

      post_fn = fn url, opts ->
        :counters.add(call_count, 1, 1)

        cond do
          String.contains?(url, "answerChatJoinRequestQuery") ->
            {:ok, %{status: 200, body: %{"ok" => false, "description" => "method not found"}}}

          String.contains?(url, "approveChatJoinRequest") ->
            assert opts[:json] == %{chat_id: 42, user_id: 99}
            {:ok, %{status: 200, body: %{"ok" => true, "result" => true}}}
        end
      end

      app = applicant(query_id: "ABC")

      assert {:ok, true} =
               Guardian.apply_decision(app, {:approve, nil}, bot_token: "t", post_fn: post_fn)

      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "apply_decision/3 -- decline" do
    test "uses answerChatJoinRequestQuery with action decline when query_id present" do
      capture = capturing_post()

      assert {:ok, _} =
               Guardian.apply_decision(applicant(query_id: "XYZ"), {:decline, "spam"},
                 bot_token: "t",
                 post_fn: capture.post_fn
               )

      assert capture.received_url.() =~ "answerChatJoinRequestQuery"
      assert capture.received_body.()[:json][:action] == "decline"
    end

    test "falls back to declineChatJoinRequest without query_id" do
      capture = capturing_post()

      assert {:ok, _} =
               Guardian.apply_decision(applicant(), {:decline, nil},
                 bot_token: "t",
                 post_fn: capture.post_fn
               )

      assert capture.received_url.() =~ "declineChatJoinRequest"
    end
  end

  describe "apply_decision/3 -- ask_mini_app" do
    test "sends sendMessage to the applicant with a web_app inline keyboard" do
      capture = capturing_post()

      Guardian.apply_decision(
        applicant(query_id: "ABC"),
        {:ask_mini_app, "https://verify.example.com", "Verify"},
        bot_token: "t",
        post_fn: capture.post_fn
      )

      url = capture.received_url.()
      body = capture.received_body.()[:json]

      assert url =~ "sendMessage"
      # The "chat" for the applicant DM is the applicant's user_id
      assert body[:chat_id] == 99
      assert body[:text] == "Verify"

      assert %{
               inline_keyboard: [
                 [%{text: "Verify", web_app: %{url: appended_url}}]
               ]
             } = body[:reply_markup]

      # MiniApp.build_url appends applicant context to the base URL
      assert appended_url =~ "https://verify.example.com"
      assert appended_url =~ "user_id=99"
      assert appended_url =~ "chat_id=42"
      assert appended_url =~ "query_id=ABC"
    end

    test "honors a custom :mini_app_url_builder" do
      capture = capturing_post()

      Guardian.apply_decision(
        applicant(),
        {:ask_mini_app, "https://verify.example.com", "Verify"},
        bot_token: "t",
        post_fn: capture.post_fn,
        mini_app_url_builder: fn url, _applicant -> url <> "?custom=1" end
      )

      body = capture.received_body.()[:json]

      assert %{inline_keyboard: [[%{web_app: %{url: "https://verify.example.com?custom=1"}}]]} =
               body[:reply_markup]
    end
  end

  describe "telemetry" do
    setup do
      ref = make_ref()

      :telemetry.attach_many(
        {ref, :guardian_test},
        [
          [:raxol_telegram, :guardian, :approved],
          [:raxol_telegram, :guardian, :declined],
          [:raxol_telegram, :guardian, :asked],
          [:raxol_telegram, :guardian, :error]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach({ref, :guardian_test}) end)
      :ok
    end

    test "emits :approved on success with chat_id, user_id, reason, source" do
      Guardian.apply_decision(applicant(), {:approve, "ok"},
        bot_token: "t",
        post_fn: stub_post_ok()
      )

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :approved], _, metadata}
      assert metadata.chat_id == 42
      assert metadata.user_id == 99
      assert metadata.reason == "ok"
      assert metadata.source == :bot
    end

    test "emits :declined with source: :mcp when passed" do
      Guardian.apply_decision(applicant(), {:decline, "no"},
        bot_token: "t",
        post_fn: stub_post_ok(),
        source: :mcp
      )

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :declined], _, %{source: :mcp}}
    end

    test "emits :asked with url metadata" do
      Guardian.apply_decision(
        applicant(),
        {:ask_mini_app, "https://verify.example.com", "Verify"},
        bot_token: "t",
        post_fn: stub_post_ok()
      )

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :asked], _, metadata}
      assert metadata.url =~ "https://verify.example.com"
    end

    test "emits :error with error_reason when the API call fails" do
      Guardian.apply_decision(applicant(), {:approve, nil},
        bot_token: "t",
        post_fn: stub_post_error()
      )

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :error], _, metadata}
      assert {:bot_api_error, _, _} = metadata.error_reason
    end
  end

  # --- Helpers ---

  defp applicant(overrides \\ []) do
    Map.merge(
      %{user_id: 99, chat_id: 42, query_id: nil},
      Map.new(overrides)
    )
  end

  defp stub_post_ok do
    fn _url, _opts ->
      {:ok, %{status: 200, body: %{"ok" => true, "result" => true}}}
    end
  end

  defp stub_post_error do
    fn _url, _opts ->
      {:ok, %{status: 400, body: %{"description" => "bad request"}}}
    end
  end

  defp capturing_post do
    {:ok, url_agent} = Agent.start_link(fn -> nil end)
    {:ok, body_agent} = Agent.start_link(fn -> nil end)

    post_fn = fn url, opts ->
      Agent.update(url_agent, fn _ -> url end)
      Agent.update(body_agent, fn _ -> opts end)
      {:ok, %{status: 200, body: %{"ok" => true, "result" => true}}}
    end

    %{
      post_fn: post_fn,
      received_url: fn -> Agent.get(url_agent, & &1) end,
      received_body: fn -> Agent.get(body_agent, & &1) end
    }
  end
end
