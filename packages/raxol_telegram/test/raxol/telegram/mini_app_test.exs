defmodule Raxol.Telegram.MiniAppTest do
  use ExUnit.Case, async: true

  alias Raxol.Telegram.MiniApp

  describe "button/2" do
    test "builds the web_app button shape Telegram expects" do
      assert MiniApp.button("Verify", "https://verify.example.com") == %{
               text: "Verify",
               web_app: %{url: "https://verify.example.com"}
             }
    end
  end

  describe "inline_keyboard/2" do
    test "wraps a single button in a single-row inline_keyboard" do
      assert MiniApp.inline_keyboard("Verify", "https://verify.example.com") == %{
               inline_keyboard: [
                 [%{text: "Verify", web_app: %{url: "https://verify.example.com"}}]
               ]
             }
    end
  end

  describe "build_url/2" do
    test "appends chat_id, user_id, query_id from atom-keyed applicant" do
      applicant = %{user_id: 99, chat_id: 42, query_id: "ABC"}

      assert MiniApp.build_url("https://verify.example.com", applicant) ==
               "https://verify.example.com?chat_id=42&query_id=ABC&user_id=99"
    end

    test "appends from string-keyed applicant too" do
      applicant = %{"user_id" => 99, "chat_id" => 42, "query_id" => "ABC"}

      assert MiniApp.build_url("https://verify.example.com", applicant) ==
               "https://verify.example.com?chat_id=42&query_id=ABC&user_id=99"
    end

    test "preserves existing query params on the base URL" do
      applicant = %{user_id: 99, chat_id: 42}

      assert MiniApp.build_url("https://verify.example.com?theme=dark", applicant) ==
               "https://verify.example.com?theme=dark&chat_id=42&user_id=99"
    end

    test "omits query_id when nil or absent" do
      applicant = %{user_id: 99, chat_id: 42}

      assert MiniApp.build_url("https://verify.example.com", applicant) ==
               "https://verify.example.com?chat_id=42&user_id=99"
    end

    test "omits empty-string fields" do
      applicant = %{user_id: 99, chat_id: 42, query_id: ""}

      refute MiniApp.build_url("https://verify.example.com", applicant) =~ "query_id"
    end

    test "returns base url unchanged when applicant has no usable fields" do
      assert MiniApp.build_url("https://verify.example.com", %{}) ==
               "https://verify.example.com"
    end

    test "URL-encodes parameter values" do
      applicant = %{user_id: 99, chat_id: 42, query_id: "abc def"}

      assert MiniApp.build_url("https://verify.example.com", applicant) ==
               "https://verify.example.com?chat_id=42&query_id=abc+def&user_id=99"
    end
  end
end
