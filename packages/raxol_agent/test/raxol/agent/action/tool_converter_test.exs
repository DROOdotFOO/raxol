defmodule Raxol.Agent.Action.ToolConverterTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.ToolPolicy

  defmodule ReadFile do
    use Raxol.Agent.Action,
      name: "read_file",
      description: "Read a file from disk",
      schema: [
        input: [
          path: [type: :string, required: true, description: "File path"]
        ]
      ]

    @impl true
    def run(%{path: path}, _ctx) do
      {:ok, %{content: "contents of #{path}", path: path}}
    end
  end

  defmodule CountLines do
    use Raxol.Agent.Action,
      name: "count_lines",
      description: "Count lines in text",
      schema: [
        input: [
          text: [type: :string, required: true, description: "Text to count"]
        ]
      ]

    @impl true
    def run(%{text: text}, _ctx) do
      {:ok, %{line_count: length(String.split(text, "\n"))}}
    end
  end

  defmodule MoveFunds do
    use Raxol.Agent.Action,
      name: "move_funds",
      sensitive: true,
      description: "Send money (sensitive)",
      schema: [
        input: [
          to: [type: :string, required: true, description: "Recipient"]
        ]
      ]

    @impl true
    def run(%{to: to}, _ctx) do
      {:ok, %{sent_to: to}}
    end
  end

  @actions [ReadFile, CountLines, MoveFunds]

  describe "tool authorization (H1)" do
    test "a tool_authorizer deny blocks the action before it runs" do
      tool_call = %{"name" => "count_lines", "arguments" => %{"text" => "a\nb"}}
      context = %{tool_authorizer: ToolPolicy.deny_all(:blocked)}

      assert {:error, {:tool_denied, "count_lines", :blocked}} =
               ToolConverter.dispatch_tool_call(tool_call, @actions, context)
    end

    test "allowlist permits named tools and denies the rest" do
      context = %{tool_authorizer: ToolPolicy.allowlist(["count_lines"])}

      assert {:ok, _} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "count_lines", "arguments" => %{"text" => "x"}},
                 @actions,
                 context
               )

      assert {:error, {:tool_denied, "read_file", :not_in_allowlist}} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "read_file", "arguments" => %{"path" => "/tmp/x"}},
                 @actions,
                 context
               )
    end

    test "denylist denies named tools and permits the rest" do
      context = %{tool_authorizer: ToolPolicy.denylist(["read_file"])}

      assert {:error, {:tool_denied, "read_file", :denied}} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "read_file", "arguments" => %{"path" => "/tmp/x"}},
                 @actions,
                 context
               )

      assert {:ok, _} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "count_lines", "arguments" => %{"text" => "x"}},
                 @actions,
                 context
               )
    end

    test "no authorizer allows a non-sensitive call" do
      assert {:ok, _} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "count_lines", "arguments" => %{"text" => "x"}},
                 @actions,
                 %{}
               )
    end

    test "no authorizer denies a sensitive call by default" do
      assert {:error, {:tool_denied, "move_funds", :sensitive_tool}} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "move_funds", "arguments" => %{"to" => "0xabc"}},
                 @actions,
                 %{}
               )
    end

    test "an explicit allow_all overrides the default sensitive denial" do
      context = %{tool_authorizer: ToolPolicy.allow_all()}

      assert {:ok, _} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "move_funds", "arguments" => %{"to" => "0xabc"}},
                 @actions,
                 context
               )
    end

    test "deny_sensitive permits read-only tools and denies sensitive ones" do
      context = %{tool_authorizer: ToolPolicy.deny_sensitive()}

      assert {:ok, _} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "read_file", "arguments" => %{"path" => "/tmp/x"}},
                 @actions,
                 context
               )

      assert {:error, {:tool_denied, "move_funds", :sensitive_tool}} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "move_funds", "arguments" => %{"to" => "0xabc"}},
                 @actions,
                 context
               )
    end
  end

  describe "to_tool_definitions/1" do
    test "converts action modules to tool definitions" do
      defs = ToolConverter.to_tool_definitions(@actions)
      assert length(defs) == 3

      [read_def, count_def, move_def] = defs
      assert read_def["function"]["name"] == "read_file"
      assert count_def["function"]["name"] == "count_lines"
      assert move_def["function"]["name"] == "move_funds"
      assert read_def["type"] == "function"
    end

    test "includes parameter schemas" do
      [read_def | _] = ToolConverter.to_tool_definitions(@actions)
      props = read_def["function"]["parameters"]["properties"]
      assert props["path"]["type"] == "string"
      assert "path" in read_def["function"]["parameters"]["required"]
    end
  end

  describe "dispatch_tool_call/3" do
    test "dispatches to matching action with atom-keyed args" do
      tool_call = %{"name" => "read_file", "arguments" => %{path: "/tmp/test.txt"}}
      assert {:ok, result} = ToolConverter.dispatch_tool_call(tool_call, @actions)
      assert result.content == "contents of /tmp/test.txt"
    end

    test "dispatches with string-keyed args" do
      tool_call = %{"name" => "read_file", "arguments" => %{"path" => "/tmp/test.txt"}}
      assert {:ok, result} = ToolConverter.dispatch_tool_call(tool_call, @actions)
      assert result.content == "contents of /tmp/test.txt"
    end

    test "dispatches with JSON string args" do
      tool_call = %{
        "name" => "count_lines",
        "arguments" => ~s({"text": "line1\\nline2\\nline3"})
      }

      assert {:ok, result} = ToolConverter.dispatch_tool_call(tool_call, @actions)
      assert result.line_count == 3
    end

    test "returns error for unknown tool" do
      tool_call = %{"name" => "nonexistent", "arguments" => %{}}

      assert {:error, {:unknown_tool, "nonexistent"}} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)
    end

    test "passes context through" do
      defmodule CtxAction do
        use Raxol.Agent.Action,
          name: "ctx_action",
          description: "Reads context",
          schema: [input: []]

        @impl true
        def run(_params, ctx), do: {:ok, %{user: Map.get(ctx, :user)}}
      end

      tool_call = %{"name" => "ctx_action", "arguments" => %{}}

      assert {:ok, result} =
               ToolConverter.dispatch_tool_call(tool_call, [CtxAction], %{user: "alice"})

      assert result.user == "alice"
    end

    test "returns validation error for bad input" do
      tool_call = %{"name" => "read_file", "arguments" => %{}}

      assert {:error, errors} = ToolConverter.dispatch_tool_call(tool_call, @actions)
      assert is_list(errors)
    end
  end

  describe "format_tool_result/2" do
    test "formats result as tool role message" do
      result = ToolConverter.format_tool_result("call_123", %{content: "hello"})
      assert result.role == "tool"
      assert result.tool_call_id == "call_123"
      assert result.content == ~s({"content":"hello"})
    end
  end
end
