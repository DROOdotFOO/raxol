defmodule Raxol.Agent.CommandHookTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.CommandHook
  alias Raxol.Agent.Directive
  alias Raxol.Agent.Directive.{Async, SendAgent, Shell}

  defmodule AllowHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(effect, _context), do: {:ok, effect}

    @impl true
    def post_execute(_effect, result, _context), do: {:ok, result}
  end

  defmodule DenyShellHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(%Shell{}, _context), do: {:deny, :shell_not_allowed}
    def pre_execute(effect, _context), do: {:ok, effect}
  end

  defmodule AuditHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(effect, context) do
      send(context.test_pid, {:pre, struct_tag(effect)})
      {:ok, effect}
    end

    @impl true
    def post_execute(effect, result, context) do
      send(context.test_pid, {:post, struct_tag(effect), result})
      {:ok, result}
    end

    defp struct_tag(%Async{}), do: :async
    defp struct_tag(%Shell{}), do: :shell
    defp struct_tag(%SendAgent{}), do: :send_agent
  end

  defmodule ModifyHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(%Shell{command: cmd} = effect, _context) do
      {:ok, %{effect | command: "echo modified: " <> cmd}}
    end

    def pre_execute(effect, _context), do: {:ok, effect}
  end

  defmodule PreOnlyHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(effect, _context), do: {:ok, effect}
  end

  @context %{agent_id: :test, agent_module: nil}

  describe "run_pre_hooks/3" do
    test "empty hooks list allows directive" do
      effect = Directive.shell("ls")
      assert {:ok, ^effect} = CommandHook.run_pre_hooks([], effect, @context)
    end

    test "allow hook passes directive through" do
      effect = Directive.shell("ls")
      assert {:ok, ^effect} = CommandHook.run_pre_hooks([AllowHook], effect, @context)
    end

    test "deny hook blocks directive" do
      effect = Directive.shell("rm -rf /")

      assert {:deny, :shell_not_allowed} =
               CommandHook.run_pre_hooks([DenyShellHook], effect, @context)
    end

    test "deny short-circuits the chain" do
      effect = Directive.shell("ls")
      context = Map.put(@context, :test_pid, self())

      assert {:deny, :shell_not_allowed} =
               CommandHook.run_pre_hooks([DenyShellHook, AuditHook], effect, context)

      refute_received {:pre, :shell}
    end

    test "hooks can modify directives" do
      effect = Directive.shell("ls")

      assert {:ok, %Shell{command: "echo modified: ls"}} =
               CommandHook.run_pre_hooks([ModifyHook], effect, @context)
    end

    test "hooks execute in order" do
      effect = Directive.async(fn _sender -> :ok end)
      context = Map.put(@context, :test_pid, self())

      {:ok, _} = CommandHook.run_pre_hooks([AuditHook, AllowHook], effect, context)

      assert_received {:pre, :async}
    end
  end

  describe "run_post_hooks/4" do
    test "empty hooks list passes result through" do
      effect = Directive.shell("ls")
      assert {:ok, :some_result} = CommandHook.run_post_hooks([], effect, :some_result, @context)
    end

    test "hook receives and passes result" do
      effect = Directive.shell("ls")
      context = Map.put(@context, :test_pid, self())

      assert {:ok, :result} =
               CommandHook.run_post_hooks([AuditHook], effect, :result, context)

      assert_received {:post, :shell, :result}
    end

    test "skips hooks without post_execute/3" do
      effect = Directive.shell("ls")

      assert {:ok, :result} =
               CommandHook.run_post_hooks([PreOnlyHook], effect, :result, @context)
    end
  end

  describe "wrap_commands/3" do
    test "returns directives unchanged with no hooks" do
      effects = [Directive.shell("ls"), Directive.stop()]
      assert effects == CommandHook.wrap_commands(effects, [], @context)
    end

    test "non-hookable directives (Schedule, Spawn, Stop) pass through" do
      effects = [Directive.schedule(50, :tick), Directive.spawn(fn -> :ok end), Directive.stop()]
      assert effects == CommandHook.wrap_commands(effects, [DenyShellHook], @context)
    end

    test "denied shell directive becomes async denial" do
      effects = [Directive.shell("rm -rf /")]
      [wrapped] = CommandHook.wrap_commands(effects, [DenyShellHook], @context)

      assert %Async{} = wrapped

      sender = fn msg -> send(self(), {:sent, msg}) end
      wrapped.fun.(sender)

      assert_received {:sent, {:command_denied, :shell, :shell_not_allowed}}
    end

    test "allowed async directive executes with post-hooks" do
      original = Directive.async(fn sender -> sender.(:original_result) end)
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands([original], [AuditHook], context)

      assert %Async{} = wrapped

      sender = fn msg -> send(self(), {:sent, msg}) end
      wrapped.fun.(sender)

      assert_received {:pre, :async}
      assert_received {:post, :async, :original_result}
      assert_received {:sent, :original_result}
    end

    test "shell directive passes through pre-hooks" do
      effects = [Directive.shell("ls")]
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands(effects, [AuditHook], context)

      assert %Shell{command: "ls"} = wrapped
      assert_received {:pre, :shell}
    end

    test "send_agent directive passes through pre-hooks" do
      effects = [Directive.send_agent(:target, :hello)]
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands(effects, [AuditHook], context)

      assert %SendAgent{target_id: :target, message: :hello} = wrapped
      assert_received {:pre, :send_agent}
    end

    test "multiple hooks chain correctly" do
      effects = [Directive.shell("ls")]

      [wrapped] =
        CommandHook.wrap_commands(effects, [ModifyHook, AllowHook], @context)

      assert %Shell{command: "echo modified: ls"} = wrapped
    end
  end
end
