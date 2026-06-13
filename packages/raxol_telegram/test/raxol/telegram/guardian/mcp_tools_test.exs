defmodule Raxol.Telegram.Guardian.MCPToolsTest do
  use ExUnit.Case, async: false

  alias Raxol.Telegram.Guardian.MCPTools

  setup do
    on_exit(fn ->
      Application.delete_env(:raxol_telegram, :guardian)
      Application.delete_env(:raxol_telegram, :guardian_predicate)
      Application.delete_env(:raxol_telegram, :bot_token)
    end)

    :ok
  end

  describe "tools/0" do
    test "returns four tools with the documented names" do
      names = MCPTools.tools() |> Enum.map(& &1.name)

      assert "telegram_guardian_approve" in names
      assert "telegram_guardian_decline" in names
      assert "telegram_guardian_screen" in names
      assert "telegram_guardian_list_pending" in names
    end

    test "all tools carry a description, inputSchema, and callable callback" do
      for tool <- MCPTools.tools() do
        assert is_binary(tool.description) and byte_size(tool.description) > 0
        assert is_map(tool.inputSchema)
        assert tool.inputSchema[:type] == "object"
        assert is_function(tool.callback, 1)
      end
    end

    test "approve and decline require chat_id + user_id" do
      for name <- ["telegram_guardian_approve", "telegram_guardian_decline"] do
        tool = Enum.find(MCPTools.tools(), &(&1.name == name))
        assert "chat_id" in tool.inputSchema.required
        assert "user_id" in tool.inputSchema.required
      end
    end
  end

  describe "register/1" do
    test "returns :raxol_mcp_not_available when registry not loaded" do
      # raxol_mcp is not a dep of raxol_telegram, so it's not loaded in this
      # test environment unless something else pulled it in.
      if Code.ensure_loaded?(Raxol.MCP.Registry) do
        # Skip when raxol_mcp is unexpectedly present
        :ok
      else
        assert {:error, :raxol_mcp_not_available} = MCPTools.register()
      end
    end
  end

  describe "tool callbacks" do
    test "telegram_guardian_screen returns the Guardian's decision as JSON" do
      Application.put_env(:raxol_telegram, :guardian_predicate, fn _ ->
        {:approve, "screen-test"}
      end)

      tool = find_tool("telegram_guardian_screen")

      assert {:ok, [%{type: "text", text: text}]} =
               tool.callback.(%{"chat_id" => 42, "user_id" => 99})

      decoded = Jason.decode!(text)
      assert decoded["decision"]["action"] == "approve"
      assert decoded["decision"]["reason"] == "screen-test"
    end

    test "telegram_guardian_screen reports ask_mini_app decisions" do
      Application.put_env(:raxol_telegram, :guardian_predicate, fn _ ->
        {:ask_mini_app, "https://verify.example.com", "Verify"}
      end)

      tool = find_tool("telegram_guardian_screen")

      assert {:ok, [%{type: "text", text: text}]} =
               tool.callback.(%{"chat_id" => 42, "user_id" => 99})

      decoded = Jason.decode!(text)
      assert decoded["decision"]["action"] == "ask_mini_app"
      assert decoded["decision"]["url"] == "https://verify.example.com"
      assert decoded["decision"]["button_text"] == "Verify"
    end

    test "telegram_guardian_approve applies the decision and reports ok" do
      stub = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => true}}}
      end

      tool = find_tool("telegram_guardian_approve", bot_token: "t", post_fn: stub)

      assert {:ok, [%{type: "text", text: "approve: ok"}]} =
               tool.callback.(%{
                 "chat_id" => 42,
                 "user_id" => 99,
                 "query_id" => "ABC",
                 "reason" => "vetted"
               })
    end

    test "telegram_guardian_approve reports error tag when the API fails" do
      stub = fn _url, _opts ->
        {:ok, %{status: 400, body: %{"description" => "bad request"}}}
      end

      tool = find_tool("telegram_guardian_approve", bot_token: "t", post_fn: stub)

      assert {:ok, [%{type: "text", text: text}]} =
               tool.callback.(%{"chat_id" => 42, "user_id" => 99})

      assert text =~ "approve: error"
      assert text =~ "bot_api_error"
    end

    test "telegram_guardian_decline applies the decision and reports ok" do
      stub = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => true}}}
      end

      tool = find_tool("telegram_guardian_decline", bot_token: "t", post_fn: stub)

      assert {:ok, [%{type: "text", text: "decline: ok"}]} =
               tool.callback.(%{"chat_id" => 42, "user_id" => 99, "reason" => "spam"})
    end

    test "telegram_guardian_list_pending returns an empty JSON array (v1 stub)" do
      tool = find_tool("telegram_guardian_list_pending")

      assert {:ok, [%{type: "text", text: text}]} = tool.callback.(%{})
      assert Jason.decode!(text) == []
    end
  end

  defp find_tool(name, apply_opts \\ []) do
    Enum.find(MCPTools.tools(apply_opts), &(&1.name == name)) ||
      raise "tool #{name} not found"
  end
end
