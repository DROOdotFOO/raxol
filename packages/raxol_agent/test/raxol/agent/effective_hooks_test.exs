defmodule Raxol.Agent.EffectiveHooksTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Sandbox.Shell
  alias Raxol.Agent.SandboxHook

  defmodule AgentWithSandbox do
    use Raxol.Agent

    def sandbox, do: [Shell.deny_all()]
    def command_hooks, do: [SomeAuditHook]
  end

  defmodule AgentNoSandbox do
    use Raxol.Agent

    def command_hooks, do: [SomeAuditHook]
  end

  defmodule AgentNoHooks do
    use Raxol.Agent
  end

  defmodule PlainModule do
    # Not built with `use Raxol.Agent`.
  end

  describe "effective_hooks/1" do
    test "prepends SandboxHook when sandbox/0 is non-empty" do
      assert [SandboxHook, SomeAuditHook] =
               Raxol.Agent.effective_hooks(AgentWithSandbox)
    end

    test "returns command_hooks/0 alone when sandbox/0 is empty" do
      assert [SomeAuditHook] = Raxol.Agent.effective_hooks(AgentNoSandbox)
    end

    test "returns [] when both callbacks default" do
      assert [] = Raxol.Agent.effective_hooks(AgentNoHooks)
    end

    test "falls back to [] for non-agent modules" do
      assert [] = Raxol.Agent.effective_hooks(PlainModule)
    end
  end
end
