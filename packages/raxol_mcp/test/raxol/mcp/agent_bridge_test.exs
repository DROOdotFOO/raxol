defmodule Raxol.MCP.AgentBridgeTest do
  @moduledoc """
  A bridged tool is gated like any other: an Action that declares itself
  sensitive, and `agent.send`, which types into any Headless session, are
  refused by a Server that has no authorizer.
  """
  use ExUnit.Case, async: true

  alias Raxol.MCP.{AgentBridge, Registry, Server, ToolDef}

  # The Action contract the bridge reads (`__action_meta__/0` and `call/2`, as
  # `use Raxol.Agent.Action` generates them); raxol_agent is not a dependency
  # of this package. `call/2` counts its runs in the context's counter.
  defmodule ResetAction do
    def __action_meta__ do
      %{
        name: "reset",
        description: "Reset the counter",
        input_schema: [],
        output_schema: [],
        sensitive: true
      }
    end

    def call(_params, %{ran: ran}) do
      :counters.add(ran, 1, 1)
      {:ok, %{set: 0}}
    end
  end

  defmodule ReadAction do
    def __action_meta__ do
      %{
        name: "read",
        description: "Read the counter",
        input_schema: [],
        output_schema: [],
        sensitive: false
      }
    end

    def call(_params, %{ran: ran}) do
      :counters.add(ran, 1, 1)
      {:ok, %{value: 1}}
    end
  end

  # No authorizer; the tools are registered after boot, as a session's are.
  defp unguarded_server(tools) do
    registry = :"reg_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry}, id: registry)
    {:ok, server} = Server.start_link(name: :"srv_#{registry}", registry: registry)
    :ok = Registry.register_tools(registry, tools)
    server
  end

  defp call_tool(server, name) do
    {:reply, response} =
      Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{"name" => name, "arguments" => %{}}
      })

    response
  end

  defp unguarded_refusal?(%{result: %{content: [%{text: text} | _], isError: true}}) do
    payload = Jason.decode!(text)

    payload["error"] == "authorization_required" and
      payload["detail"] =~ "sensitive_tool_unguarded"
  end

  defp unguarded_refusal?(_response), do: false

  test "a sensitive Action is refused without an authorizer and never runs" do
    ran = :counters.new(1, [])
    tools = AgentBridge.actions_to_mcp_tools([ResetAction, ReadAction], %{ran: ran})
    by_name = Map.new(tools, &{&1.name, &1})

    assert ToolDef.sensitive?(by_name["agent.reset"])
    refute ToolDef.sensitive?(by_name["agent.read"])

    server = unguarded_server(tools)

    assert unguarded_refusal?(call_tool(server, "agent.reset"))
    assert :counters.get(ran, 1) == 0, "the sensitive Action must never have run"

    refute unguarded_refusal?(call_tool(server, "agent.read"))
    assert :counters.get(ran, 1) == 1
  end

  test "agent.send is refused without an authorizer" do
    send_tool = Enum.find(AgentBridge.meta_tools(), &(&1.name == "agent.send"))
    server = unguarded_server([send_tool])

    assert unguarded_refusal?(call_tool(server, "agent.send"))
  end

  # The boot check leaves out derived widget tools by origin, not by the dot
  # in their names: `agent.send` is a static tool with a dotted name.
  test "a Server with no authorizer refuses to boot on the bridge's meta tools" do
    registry = :"reg_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry}, id: registry)
    :ok = Registry.register_tools(registry, AgentBridge.meta_tools())

    # The raise happens in init/1 of a LINKED process, so it comes back as a
    # start_link error rather than propagating into this process.
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stack}} =
             Server.start_link(name: :"srv_#{registry}", registry: registry)

    assert message =~ "refuses to boot"
    assert message =~ "agent.send"
  end
end
