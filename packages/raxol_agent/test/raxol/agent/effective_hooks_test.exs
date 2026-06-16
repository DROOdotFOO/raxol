defmodule Raxol.Agent.EffectiveHooksTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Sandbox.Shell
  alias Raxol.Agent.SandboxHook
  alias Raxol.Agent.ThreadLog

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

  defmodule AgentWithThreadLog do
    use Raxol.Agent

    def thread_log, do: {ThreadLog.Ets, %{table: :my_table}}
  end

  defmodule AgentWithBareModuleLog do
    use Raxol.Agent

    def thread_log, do: ThreadLog.Ets
  end

  describe "thread_log_adapter/1" do
    test "returns nil when thread_log/0 defaults to nil" do
      assert Raxol.Agent.thread_log_adapter(AgentNoHooks) == nil
    end

    test "returns the {module, config} tuple as-is" do
      assert {ThreadLog.Ets, %{table: :my_table}} =
               Raxol.Agent.thread_log_adapter(AgentWithThreadLog)
    end

    test "normalizes a bare module into {module, %{}}" do
      assert {ThreadLog.Ets, %{}} =
               Raxol.Agent.thread_log_adapter(AgentWithBareModuleLog)
    end

    test "returns nil for non-agent modules" do
      assert Raxol.Agent.thread_log_adapter(PlainModule) == nil
    end
  end
end
