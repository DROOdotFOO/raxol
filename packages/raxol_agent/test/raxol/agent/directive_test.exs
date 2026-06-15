defmodule Raxol.Agent.DirectiveTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Directive
  alias Raxol.Agent.Directive.{Async, SendAgent, Shell}
  alias Raxol.Core.Runtime.Directive.{Schedule, Spawn, Stop}
  alias Raxol.Core.Runtime.Directive.Executor

  describe "constructors" do
    test "async/1 builds an Async struct" do
      fun = fn _sender -> :ok end
      assert %Async{fun: ^fun} = Directive.async(fun)
    end

    test "shell/2 builds a Shell struct with default opts" do
      assert %Shell{command: "echo hi", opts: []} = Directive.shell("echo hi")
    end

    test "shell/2 carries opts" do
      assert %Shell{command: "ls", opts: [timeout: 5_000, cd: "/tmp"]} =
               Directive.shell("ls", timeout: 5_000, cd: "/tmp")
    end

    test "send_agent/2 builds a SendAgent struct" do
      assert %SendAgent{target_id: "worker", message: {:task, 1}} =
               Directive.send_agent("worker", {:task, 1})
    end

    test "schedule/2 builds a Schedule struct" do
      assert %Schedule{interval_ms: 1_000, payload: :tick} =
               Directive.schedule(1_000, :tick)
    end

    test "schedule/2 accepts zero interval" do
      assert %Schedule{interval_ms: 0, payload: :now} =
               Directive.schedule(0, :now)
    end

    test "spawn/1 builds a Spawn struct" do
      fun = fn -> :result end
      assert %Spawn{fun: ^fun} = Directive.spawn(fun)
    end

    test "stop/0 defaults reason to :normal" do
      assert %Stop{reason: :normal} = Directive.stop()
    end

    test "stop/1 carries a custom reason" do
      assert %Stop{reason: :shutdown} = Directive.stop(:shutdown)
    end
  end

  describe "Executor for Async" do
    test "sender callback delivers messages to context.pid" do
      directive =
        Directive.async(fn sender ->
          sender.(:first)
          sender.(:second)
          sender.({:progress, 50})
        end)

      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, :first}, 1_000
      assert_receive {:command_result, :second}, 1_000
      assert_receive {:command_result, {:progress, 50}}, 1_000
    end

    test "raised exceptions are reported as :async_error" do
      directive =
        Directive.async(fn _sender ->
          raise "boom"
        end)

      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:async_error, "boom"}}, 1_000
    end
  end

  describe "Executor for Shell" do
    test "captures stdout and exit_status 0" do
      directive = Directive.shell("echo hello-from-shell")
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:shell_result, %{exit_status: 0, output: output}}},
                     5_000

      assert String.contains?(output, "hello-from-shell")
    end

    test "non-zero exit_status is returned" do
      directive = Directive.shell("exit 7")
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:shell_result, %{exit_status: 7}}},
                     5_000
    end

    test "timeout closes the port and reports :timeout" do
      directive = Directive.shell("sleep 5", timeout: 100)
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:shell_result, %{exit_status: :timeout}}},
                     2_000
    end
  end

  describe "Executor for SendAgent" do
    test "registry-missing path reports :send_agent_error" do
      directive = Directive.send_agent("nobody", :payload)
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:send_agent_error, :not_found, "nobody"}},
                     1_000
    end

    test "registered agent receives the cast" do
      {:ok, _} =
        start_supervised({Registry, keys: :unique, name: Raxol.Agent.Registry})

      {:ok, _} =
        Registry.register(Raxol.Agent.Registry, "self-as-agent", :metadata)

      directive = Directive.send_agent("self-as-agent", {:work, 42})
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:"$gen_cast", {:send_message, {:work, 42}, %{}}}, 1_000
    end

    test "cast carries causation_id when sender has an active span" do
      {:ok, _} =
        start_supervised({Registry, keys: :unique, name: Raxol.Agent.Registry})

      {:ok, _} = Registry.register(Raxol.Agent.Registry, "causation-target", nil)

      _ = Raxol.Core.Telemetry.TraceContext.start_trace()
      %{span_id: span_id} = Raxol.Core.Telemetry.TraceContext.current()

      directive = Directive.send_agent("causation-target", :payload)
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:"$gen_cast", {:send_message, :payload, %{causation_id: ^span_id}}},
                     1_000
    after
      Raxol.Core.Telemetry.TraceContext.clear()
    end
  end

  describe "Executor for Schedule" do
    test "delivers payload after interval_ms" do
      directive = Directive.schedule(50, {:tick, 1})
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      refute_receive {:command_result, _}, 10
      assert_receive {:command_result, {:tick, 1}}, 500
    end
  end

  describe "Executor for Spawn" do
    test "single return value is delivered as command_result" do
      directive = Directive.spawn(fn -> {:done, :answer} end)
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:done, :answer}}, 1_000
    end
  end

  describe "Executor for Stop" do
    test "sends :quit_runtime to context.runtime_pid" do
      directive = Directive.stop()
      Executor.execute(directive, %{pid: self(), runtime_pid: self()})

      assert_receive :quit_runtime, 1_000
    end
  end
end
