defmodule Raxol.Agent.Authorization.ServerTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Authorization.{Policy, Server, Verdict}

  defp pol(name, evaluate, attrs \\ []),
    do: Policy.new(Keyword.merge([name: name, evaluate: evaluate], attrs))

  defp start(policies, opts \\ []) do
    start_supervised!({Server, [policies: policies] ++ opts})
  end

  test "an allow decision commits its labels" do
    server = start([pol(:a, fn _ -> Verdict.allow(%{x: 1}) end)])
    assert %{action: :allow} = Server.evaluate(server, :tool_call, %{})
    assert Server.labels(server) == %{x: 1}
  end

  test "a deny decision commits prior-allow labels" do
    server =
      start([
        pol(:a, fn _ -> Verdict.allow(%{x: 1}) end),
        pol(:b, fn _ -> Verdict.deny(:no) end)
      ])

    assert %{action: :deny, reason: :no} = Server.evaluate(server, :tool_call, %{})
    assert Server.labels(server) == %{x: 1}
  end

  describe "ask lifecycle" do
    test "ask parks pending; approve releases escrow" do
      server = start([pol(:b, fn _ -> Verdict.ask("ok?", %{y: 2}) end)])

      assert %{action: :ask} = Server.evaluate(server, :tool_call, %{}, route: "r1")
      # escrow not yet applied
      assert Server.labels(server) == %{}

      assert :ok = Server.approve(server, "r1")
      assert Server.labels(server) == %{y: 2}
    end

    test "reject drops the pending ask without applying escrow" do
      server = start([pol(:b, fn _ -> Verdict.ask("ok?", %{y: 2}) end)])
      assert %{action: :ask} = Server.evaluate(server, :tool_call, %{}, route: "r1")

      assert :ok = Server.reject(server, "r1")
      assert Server.labels(server) == %{}
      assert {:error, :no_pending} = Server.approve(server, "r1")
    end

    test "approving an unknown route errors" do
      server = start([pol(:a, fn _ -> Verdict.allow() end)])
      assert {:error, :no_pending} = Server.approve(server, "nope")
    end

    test "a :session-scoped approval auto-allows the next evaluation" do
      server = start([pol(:b, fn _ -> Verdict.ask("ok?") end, scope: :session)])

      assert %{action: :ask} = Server.evaluate(server, :tool_call, %{}, route: "r1")
      :ok = Server.approve(server, "r1")
      assert %{action: :allow} = Server.evaluate(server, :tool_call, %{})
    end
  end
end
