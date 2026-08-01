defmodule Raxol.Agent.Action.DynamicToolTest.EchoAction do
  @moduledoc false
  use Raxol.Agent.Action,
    name: "echo_action",
    description: "echoes its input",
    schema: [input: [x: [type: :string, required: false]]]

  @impl true
  def run(params, _context), do: {:ok, %{echoed: Map.get(params, :x)}}
end

defmodule Raxol.Agent.Action.DynamicToolTest.VetoHook do
  @moduledoc false
  @behaviour Raxol.Agent.ToolCall.Hook

  @impl true
  def before_call(_call, _context), do: {:halt, :nope}
end

defmodule Raxol.Agent.Action.DynamicToolTest.TransformHook do
  @moduledoc false
  @behaviour Raxol.Agent.ToolCall.Hook

  @impl true
  def before_call(call, _context), do: {:cont, %{call | params: %{msg: "TRANSFORMED"}}}
end

defmodule Raxol.Agent.Action.DynamicToolTest do
  @moduledoc """
  The MCP dynamic-dispatch seam: a runtime-discovered tool (`Dynamic`) is
  offered to and dispatched by the ReAct tool loop alongside Action modules,
  through the SAME authorizer + hook chain -- not a bypass.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Action.{Dynamic, ToolConverter}
  alias Raxol.Agent.Action.DynamicToolTest.{EchoAction, TransformHook, VetoHook}
  alias Raxol.Agent.{Stream, ToolPolicy}

  # A dynamic tool whose invoke reports to `pid` and echoes the message back.
  defp echo_tool(pid, opts \\ []) do
    %Dynamic{
      name: "mcp__echo__ping",
      description: "echo",
      input_schema: %{"type" => "object", "properties" => %{"msg" => %{"type" => "string"}}},
      sensitive: Keyword.get(opts, :sensitive, false),
      invoke: fn params, _ctx ->
        send(pid, {:invoked, params})
        {:ok, %{"echo" => Map.get(params, :msg) || Map.get(params, "msg")}}
      end
    }
  end

  defp call(args), do: %{"name" => "mcp__echo__ping", "arguments" => args, "id" => "c1"}

  describe "Dynamic.to_tool_definition/1" do
    test "matches the Action module tool-def outer shape" do
      schema = %{"type" => "object", "properties" => %{"msg" => %{"type" => "string"}}}

      tool = %Dynamic{
        name: "mcp__x__y",
        description: "d",
        input_schema: schema,
        invoke: fn _, _ -> {:ok, %{}} end
      }

      assert %{
               "type" => "function",
               "function" => %{
                 "name" => "mcp__x__y",
                 "description" => "d",
                 "parameters" => ^schema
               }
             } = Dynamic.to_tool_definition(tool)
    end

    test "defaults to an empty object schema when input_schema is empty" do
      tool = %Dynamic{name: "t", invoke: fn _, _ -> {:ok, %{}} end}

      assert %{"function" => %{"parameters" => %{"type" => "object", "properties" => %{}}}} =
               Dynamic.to_tool_definition(tool)
    end
  end

  describe "Dynamic.from_mcp/3" do
    test "namespaces the LLM name and keeps the raw name for invoke" do
      tools = [
        %{
          "name" => "status",
          "description" => "show status",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      assert [tool] = Dynamic.from_mcp(:fake_server, :git, tools)
      assert tool.name == Raxol.MCP.Client.tool_name(:git, "status")
      assert tool.description == "show status"
      assert tool.input_schema == %{"type" => "object"}
      # Discovered tools are sensitive by default (unknown capabilities), so the
      # default authorizer gates them until an operator opts in.
      assert tool.sensitive == true
      assert is_function(tool.invoke, 2)
    end

    test "sensitive: false marks the wrapped tools non-sensitive" do
      tools = [%{"name" => "now", "description" => "time", "inputSchema" => %{}}]

      assert [tool] = Dynamic.from_mcp(:fake_server, :time, tools, sensitive: false)
      assert tool.sensitive == false
    end
  end

  describe "ToolConverter with dynamic tools" do
    test "to_tool_definitions handles a mixed module + dynamic list" do
      defs = ToolConverter.to_tool_definitions([EchoAction, echo_tool(self())])
      names = Enum.map(defs, & &1["function"]["name"])

      assert "echo_action" in names
      assert "mcp__echo__ping" in names
      assert length(defs) == 2
    end

    test "dispatches to a dynamic tool through the default authorizer (non-sensitive allowed)" do
      tools = [EchoAction, echo_tool(self())]

      assert {:ok, %{"echo" => "hi"}} =
               ToolConverter.dispatch_tool_call(call(%{"msg" => "hi"}), tools, %{})

      assert_receive {:invoked, params}
      assert "hi" in Map.values(params)
    end

    test "default authorizer denies a sensitive dynamic tool; invoke never runs" do
      tools = [echo_tool(self(), sensitive: true)]

      assert {:error, {:tool_denied, "mcp__echo__ping", :sensitive_tool}} =
               ToolConverter.dispatch_tool_call(call(%{"msg" => "hi"}), tools, %{})

      refute_receive {:invoked, _}
    end

    test "allow_all lets a sensitive dynamic tool through" do
      tools = [echo_tool(self(), sensitive: true)]
      ctx = %{tool_authorizer: ToolPolicy.allow_all()}

      assert {:ok, %{"echo" => "hi"}} =
               ToolConverter.dispatch_tool_call(call(%{"msg" => "hi"}), tools, ctx)

      assert_receive {:invoked, _}
    end

    test "a hook can veto a dynamic tool call" do
      tools = [echo_tool(self())]
      ctx = %{tool_call_hooks: [VetoHook]}

      assert {:error, {:vetoed, :nope}} =
               ToolConverter.dispatch_tool_call(call(%{"msg" => "hi"}), tools, ctx)

      refute_receive {:invoked, _}
    end

    test "a hook can transform a dynamic tool's params (re-authorized, then invoked)" do
      tools = [echo_tool(self())]
      ctx = %{tool_call_hooks: [TransformHook]}

      assert {:ok, %{"echo" => "TRANSFORMED"}} =
               ToolConverter.dispatch_tool_call(call(%{"msg" => "hi"}), tools, ctx)

      assert_receive {:invoked, %{msg: "TRANSFORMED"}}
    end

    test "unknown tool name" do
      assert {:error, {:unknown_tool, "nope"}} =
               ToolConverter.dispatch_tool_call(
                 %{"name" => "nope", "arguments" => %{}},
                 [echo_tool(self())],
                 %{}
               )
    end
  end

  describe "end-to-end in the ReAct loop" do
    test "the loop offers a dynamic tool, the LLM calls it, invoke runs, result feeds back" do
      pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      # Round 1: emit a tool call for the dynamic tool. Round 2+: normal completion.
      tool_calls_fn = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0,
          do: [%{"name" => "mcp__echo__ping", "arguments" => %{"msg" => "hi"}, "id" => "c1"}],
          else: nil
      end

      result =
        "do the thing"
        |> Stream.react(
          backend: Raxol.Agent.Backend.Mock,
          backend_opts: [tool_calls_fn: tool_calls_fn, response: "all done"],
          actions: [echo_tool(pid)]
        )
        |> Stream.collect()

      assert {:ok, %{content: "all done"}} = result
      assert_receive {:invoked, params}
      assert "hi" in Map.values(params)
    end
  end
end
