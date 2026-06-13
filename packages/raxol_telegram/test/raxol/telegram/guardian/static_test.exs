defmodule Raxol.Telegram.Guardian.StaticTest do
  use ExUnit.Case, async: false

  alias Raxol.Telegram.Guardian.Static

  setup do
    on_exit(fn -> Application.delete_env(:raxol_telegram, :guardian_predicate) end)
    :ok
  end

  describe "screen/1 (unconfigured)" do
    test "approves everyone by default" do
      assert {:approve, nil} = Static.screen(%{user_id: 1, chat_id: 1})
    end
  end

  describe "screen/1 with a predicate" do
    test "delegates to the configured fun" do
      Application.put_env(:raxol_telegram, :guardian_predicate, fn applicant ->
        if applicant.user_id == 666 do
          {:decline, "blocked"}
        else
          {:approve, "ok"}
        end
      end)

      assert {:approve, "ok"} = Static.screen(%{user_id: 1, chat_id: 1})
      assert {:decline, "blocked"} = Static.screen(%{user_id: 666, chat_id: 1})
    end

    test "supports :ask_mini_app return shape" do
      Application.put_env(:raxol_telegram, :guardian_predicate, fn _applicant ->
        {:ask_mini_app, "https://verify.example.com", "Verify"}
      end)

      assert {:ask_mini_app, "https://verify.example.com", "Verify"} =
               Static.screen(%{user_id: 1, chat_id: 1})
    end

    test "falls back to approve when configured value is not a function" do
      Application.put_env(:raxol_telegram, :guardian_predicate, "not a function")

      assert {:approve, nil} = Static.screen(%{user_id: 1, chat_id: 1})
    end
  end
end
