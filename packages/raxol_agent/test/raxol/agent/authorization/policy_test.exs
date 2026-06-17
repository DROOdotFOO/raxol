defmodule Raxol.Agent.Authorization.PolicyTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Authorization.{Policy, Verdict}

  defp pol(attrs),
    do: Policy.new(Keyword.merge([name: :p, evaluate: fn _ -> Verdict.allow() end], attrs))

  describe "applies?/3" do
    test "phase :all applies to any phase" do
      assert Policy.applies?(pol(phases: :all), :tool_call, %{})
    end

    test "a phase list gates by phase" do
      p = pol(phases: [:tool_call])
      assert Policy.applies?(p, :tool_call, %{})
      refute Policy.applies?(p, :output, %{})
    end

    test "conditions AND across keys" do
      p = pol(conditions: %{env: :prod, tier: :paid})
      assert Policy.applies?(p, :tool_call, %{env: :prod, tier: :paid})
      refute Policy.applies?(p, :tool_call, %{env: :prod, tier: :free})
    end

    test "conditions OR within a key's list" do
      p = pol(conditions: %{env: [:prod, :staging]})
      assert Policy.applies?(p, :tool_call, %{env: :staging})
      refute Policy.applies?(p, :tool_call, %{env: :dev})
    end
  end

  describe "run/2" do
    test "filters writes to the writable_labels whitelist" do
      p = pol(writable_labels: [:a], evaluate: fn _ -> Verdict.allow(%{a: 1, b: 2}) end)
      assert Policy.run(p, %{}).writes == %{a: 1}
    end

    test ":all permits any write" do
      p = pol(writable_labels: :all, evaluate: fn _ -> Verdict.allow(%{a: 1, b: 2}) end)
      assert Policy.run(p, %{}).writes == %{a: 1, b: 2}
    end
  end
end
