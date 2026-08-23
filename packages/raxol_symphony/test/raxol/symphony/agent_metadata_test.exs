defmodule Raxol.Symphony.AgentMetadataTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.AgentMetadata
  alias Raxol.Symphony.TestSupport.{AgentWithMetadata, AgentWithoutMetadata, DenyTurnSandbox}

  describe "read/1 -- nil module" do
    test "returns empty defaults" do
      assert %{
               module: nil,
               hooks: [],
               sandboxes: [],
               thread_log: nil
             } = AgentMetadata.read(nil)
    end
  end

  describe "read/1 -- agent with metadata" do
    test "extracts sandboxes from sandbox/0" do
      meta = AgentMetadata.read(AgentWithMetadata)
      assert [%DenyTurnSandbox{reason: :module_deny}] = meta.sandboxes
    end

    test "extracts thread_log from thread_log/0 via normalize" do
      meta = AgentMetadata.read(AgentWithMetadata)

      assert {Raxol.Agent.ThreadLog.Ets, %{table: :symphony_test_module_thread_log}} =
               meta.thread_log
    end

    test "extracts hooks via effective_hooks/1 (prepends SandboxHook)" do
      meta = AgentMetadata.read(AgentWithMetadata)

      # effective_hooks/1 prepends SandboxHook when sandbox/0 is
      # non-empty AND keeps command_hooks/0 behind it.
      assert Raxol.Agent.SandboxHook in meta.hooks
      assert Raxol.Symphony.TestSupport.NoopHook in meta.hooks
    end

    test "preserves the module field" do
      meta = AgentMetadata.read(AgentWithMetadata)
      assert meta.module == AgentWithMetadata
    end
  end

  describe "read/1 -- agent without metadata callbacks" do
    test "returns empty sandboxes / thread_log / hooks" do
      meta = AgentMetadata.read(AgentWithoutMetadata)
      assert meta.sandboxes == []
      assert meta.thread_log == nil
      # effective_hooks returns [] when neither command_hooks nor
      # sandbox is exported.
      assert meta.hooks == []
    end
  end
end
