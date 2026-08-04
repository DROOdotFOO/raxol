defmodule Raxol.Agent.Authorization.McpAuthorizerTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Authorization.{McpAuthorizer, Policy, Verdict}

  # A policy that gates by tool name, exercising all three Engine actions.
  defp gate do
    Policy.new(
      name: :gate,
      phases: [:tool_call],
      evaluate: fn ctx ->
        case ctx.tool do
          "danger" -> Verdict.deny(:mutating_financial)
          "review" -> Verdict.ask("Approve #{ctx.tool}?")
          _ -> Verdict.allow()
        end
      end
    )
  end

  test "maps Engine allow/deny/ask to the MCP decision vocabulary" do
    auth = McpAuthorizer.build([gate()])

    assert :allow = auth.("safe_read", %{}, %{})
    assert {:deny, :mutating_financial} = auth.("danger", %{}, %{})
    assert {:ask, "Approve review?"} = auth.("review", %{}, %{})
  end

  test "no policies allow (the engine's default), matching a nil MCP authorizer" do
    auth = McpAuthorizer.build([])
    assert :allow = auth.("anything", %{"x" => 1}, %{})
  end

  test "threads tool, arguments, static context, and per-call context into the policy" do
    test = self()

    spy =
      Policy.new(
        name: :spy,
        phases: [:tool_call],
        evaluate: fn ctx ->
          send(test, {:ctx, ctx})
          Verdict.allow()
        end
      )

    auth = McpAuthorizer.build([spy], context: %{env: :test})
    auth.("greet", %{"name" => "ada"}, %{transport: :sse})

    assert_received {:ctx, ctx}
    assert ctx.tool == "greet"
    assert ctx.arguments == %{"name" => "ada"}
    assert ctx.env == :test
    assert ctx.transport == :sse
  end

  test "per-call context does not override the authoritative tool/arguments" do
    test = self()

    spy =
      Policy.new(
        name: :spy,
        phases: [:tool_call],
        evaluate: fn ctx ->
          send(test, {:ctx, ctx})
          Verdict.allow()
        end
      )

    # A client that tries to spoof `tool` in the extra context must not win.
    McpAuthorizer.build([spy]).("real", %{"a" => 1}, %{tool: "spoofed"})
    assert_received {:ctx, ctx}
    assert ctx.tool == "real"
  end

  test "produces a 3-arity closure (the shape Raxol.MCP.Server expects)" do
    assert is_function(McpAuthorizer.build([]), 3)
  end
end
