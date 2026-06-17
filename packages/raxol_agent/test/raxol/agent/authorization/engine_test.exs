defmodule Raxol.Agent.Authorization.EngineTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Authorization.{Engine, Policy, Verdict}

  defp pol(name, evaluate, attrs \\ []) do
    Policy.new(Keyword.merge([name: name, evaluate: evaluate], attrs))
  end

  defp allow(writes), do: fn _ -> Verdict.allow(writes) end
  defp ask(prompt, writes \\ %{}), do: fn _ -> Verdict.ask(prompt, writes) end
  defp deny(reason), do: fn _ -> Verdict.deny(reason) end

  describe "ALLOW" do
    test "all-allow yields :allow with merged labels" do
      policies = [pol(:a, allow(%{x: 1})), pol(:b, allow(%{y: 2}))]
      decision = Engine.evaluate(policies, :tool_call, %{}, Engine.new())

      assert decision.action == :allow
      assert decision.labels == %{x: 1, y: 2}
    end
  end

  describe "DENY" do
    test "short-circuits and keeps prior-ALLOW writes" do
      policies = [
        pol(:a, allow(%{x: 1})),
        pol(:b, deny(:forbidden)),
        pol(:c, allow(%{y: 2}))
      ]

      decision = Engine.evaluate(policies, :tool_call, %{}, Engine.new())

      assert decision.action == :deny
      assert decision.reason == :forbidden
      # `a`'s write survives; `c` never ran.
      assert decision.labels == %{x: 1}
    end
  end

  describe "ASK" do
    test "yields :ask, holding the ask's writes in escrow (not in labels yet)" do
      policies = [pol(:a, allow(%{x: 1})), pol(:b, ask("approve?", %{y: 2}))]
      decision = Engine.evaluate(policies, :tool_call, %{}, Engine.new())

      assert decision.action == :ask
      assert decision.labels == %{x: 1}
      assert decision.escrow == %{y: 2}
      assert [%{policy: :b, prompt: "approve?"}] = decision.asks
    end

    test "approve releases escrow into the labels" do
      policies = [pol(:b, ask("approve?", %{y: 2}))]
      state = Engine.new()
      decision = Engine.evaluate(policies, :tool_call, %{}, state)

      state = Engine.approve(decision, state)
      assert state.labels == %{y: 2}
    end
  end

  describe "monotonic merge across policies" do
    test "the most-restrictive write wins regardless of order" do
      monotonic = %{access: [:read, :write, :admin]}
      policies = [pol(:a, allow(%{access: :admin})), pol(:b, allow(%{access: :read}))]

      decision = Engine.evaluate(policies, :tool_call, %{}, Engine.new(monotonic: monotonic))
      assert decision.labels == %{access: :admin}
    end
  end

  describe "applicability" do
    test "phase gating excludes non-matching policies" do
      policies = [pol(:out, deny(:nope), phases: [:output])]
      decision = Engine.evaluate(policies, :tool_call, %{}, Engine.new())
      assert decision.action == :allow
    end

    test "condition gating reads the label snapshot" do
      policies = [pol(:prod_only, deny(:blocked), conditions: %{env: :prod})]

      assert Engine.evaluate(policies, :tool_call, %{}, Engine.new(labels: %{env: :dev})).action ==
               :allow

      assert Engine.evaluate(policies, :tool_call, %{}, Engine.new(labels: %{env: :prod})).action ==
               :deny
    end
  end

  describe "approval memory" do
    test ":session scope auto-approves subsequent evaluations" do
      policies = [pol(:b, ask("approve?", %{y: 2}), scope: :session)]
      state = Engine.new()

      d1 = Engine.evaluate(policies, :tool_call, %{}, state)
      assert d1.action == :ask
      state = Engine.approve(d1, state)

      d2 = Engine.evaluate(policies, :tool_call, %{}, state)
      assert d2.action == :allow
    end

    test ":root scope covers the same route but not a different one" do
      policies = [pol(:b, ask("approve?"), scope: :root)]
      state = Engine.new()

      d1 = Engine.evaluate(policies, :tool_call, %{}, state, route: "tree-1")
      state = Engine.approve(d1, state)

      assert Engine.evaluate(policies, :tool_call, %{}, state, route: "tree-1").action == :allow
      assert Engine.evaluate(policies, :tool_call, %{}, state, route: "tree-2").action == :ask
    end

    test ":once scope is never remembered" do
      policies = [pol(:b, ask("approve?"), scope: :once)]
      state = Engine.new()

      d1 = Engine.evaluate(policies, :tool_call, %{}, state)
      state = Engine.approve(d1, state)

      assert Engine.evaluate(policies, :tool_call, %{}, state).action == :ask
    end
  end
end
