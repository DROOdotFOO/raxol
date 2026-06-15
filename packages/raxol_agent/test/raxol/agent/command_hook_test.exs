defmodule Raxol.Agent.CommandHookTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.CommandHook
  alias Raxol.Core.Runtime.Command

  defmodule AllowHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(command, _context), do: {:ok, command}

    @impl true
    def post_execute(_command, result, _context), do: {:ok, result}
  end

  defmodule DenyShellHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(%Command{type: :shell}, _context) do
      {:deny, :shell_not_allowed}
    end

    def pre_execute(command, _context), do: {:ok, command}
  end

  defmodule AuditHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(command, context) do
      send(context.test_pid, {:pre, command.type})
      {:ok, command}
    end

    @impl true
    def post_execute(command, result, context) do
      send(context.test_pid, {:post, command.type, result})
      {:ok, result}
    end
  end

  defmodule ModifyHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(%Command{type: :shell, data: {cmd, opts}} = command, _context) do
      {:ok, %{command | data: {"echo modified: " <> cmd, opts}}}
    end

    def pre_execute(command, _context), do: {:ok, command}
  end

  defmodule PreOnlyHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(command, _context), do: {:ok, command}
  end

  @context %{agent_id: :test, agent_module: nil}

  describe "run_pre_hooks/3" do
    test "empty hooks list allows command" do
      command = Command.shell("ls")
      assert {:ok, ^command} = CommandHook.run_pre_hooks([], command, @context)
    end

    test "allow hook passes command through" do
      command = Command.shell("ls")
      assert {:ok, ^command} = CommandHook.run_pre_hooks([AllowHook], command, @context)
    end

    test "deny hook blocks command" do
      command = Command.shell("rm -rf /")

      assert {:deny, :shell_not_allowed} =
               CommandHook.run_pre_hooks([DenyShellHook], command, @context)
    end

    test "deny short-circuits the chain" do
      command = Command.shell("ls")
      context = Map.put(@context, :test_pid, self())

      assert {:deny, :shell_not_allowed} =
               CommandHook.run_pre_hooks([DenyShellHook, AuditHook], command, context)

      refute_received {:pre, :shell}
    end

    test "hooks can modify commands" do
      command = Command.shell("ls")

      assert {:ok, modified} =
               CommandHook.run_pre_hooks([ModifyHook], command, @context)

      assert {"echo modified: ls", _opts} = modified.data
    end

    test "hooks execute in order" do
      command = Command.async(fn _sender -> :ok end)
      context = Map.put(@context, :test_pid, self())

      {:ok, _} = CommandHook.run_pre_hooks([AuditHook, AllowHook], command, context)

      assert_received {:pre, :async}
    end
  end

  describe "run_post_hooks/4" do
    test "empty hooks list passes result through" do
      command = Command.shell("ls")
      assert {:ok, :some_result} = CommandHook.run_post_hooks([], command, :some_result, @context)
    end

    test "hook receives and passes result" do
      command = Command.shell("ls")
      context = Map.put(@context, :test_pid, self())

      assert {:ok, :result} =
               CommandHook.run_post_hooks([AuditHook], command, :result, context)

      assert_received {:post, :shell, :result}
    end

    test "skips hooks without post_execute/3" do
      command = Command.shell("ls")

      assert {:ok, :result} =
               CommandHook.run_post_hooks([PreOnlyHook], command, :result, @context)
    end
  end

  describe "wrap_commands/3" do
    test "returns commands unchanged with no hooks" do
      commands = [Command.shell("ls"), Command.none()]
      assert commands == CommandHook.wrap_commands(commands, [], @context)
    end

    test "non-hookable commands pass through" do
      commands = [Command.none(), Command.quit(), Command.delay(:tick, 1000)]
      result = CommandHook.wrap_commands(commands, [DenyShellHook], @context)
      assert result == commands
    end

    test "denied command becomes async denial notification" do
      commands = [Command.shell("rm -rf /")]
      [wrapped] = CommandHook.wrap_commands(commands, [DenyShellHook], @context)

      assert wrapped.type == :async

      # Execute the wrapper to verify it sends the denial
      sender = fn msg -> send(self(), {:sent, msg}) end
      wrapped.data.(sender)

      assert_received {:sent, {:command_denied, :shell, :shell_not_allowed}}
    end

    test "allowed async command executes with post-hooks" do
      original = Command.async(fn sender -> sender.(:original_result) end)
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands([original], [AuditHook], context)

      assert wrapped.type == :async

      sender = fn msg -> send(self(), {:sent, msg}) end
      wrapped.data.(sender)

      assert_received {:pre, :async}
      assert_received {:post, :async, :original_result}
      assert_received {:sent, :original_result}
    end

    test "allowed task command executes with post-hooks" do
      original = Command.task(fn -> :task_result end)
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands([original], [AuditHook], context)

      assert wrapped.type == :task
      assert wrapped.data.() == :task_result
      assert_received {:post, :task, :task_result}
    end

    test "multiple hooks chain correctly" do
      commands = [Command.shell("ls")]

      [wrapped] =
        CommandHook.wrap_commands(commands, [ModifyHook, AllowHook], @context)

      assert {"echo modified: ls", _opts} = wrapped.data
    end
  end

  alias Raxol.Agent.Directive
  alias Raxol.Agent.Directive.{Async, SendAgent, Shell}

  defmodule DenyDirectiveShellHook do
    @behaviour CommandHook

    @impl true
    def pre_execute(%Shell{}, _context), do: {:deny, :shell_not_allowed}
    def pre_execute(effect, _context), do: {:ok, effect}
  end

  defmodule DirectiveAuditHook do
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

  describe "wrap_commands/3 with directives" do
    test "non-hookable directives (Schedule, Spawn) pass through" do
      effects = [Directive.schedule(50, :tick), Directive.spawn(fn -> :ok end)]
      assert effects == CommandHook.wrap_commands(effects, [DenyDirectiveShellHook], @context)
    end

    test "denied shell directive becomes async denial" do
      effects = [Directive.shell("rm -rf /")]
      [wrapped] = CommandHook.wrap_commands(effects, [DenyDirectiveShellHook], @context)

      assert %Async{} = wrapped

      sender = fn msg -> send(self(), {:sent, msg}) end
      wrapped.fun.(sender)

      assert_received {:sent, {:command_denied, :shell, :shell_not_allowed}}
    end

    test "allowed async directive executes with post-hooks" do
      original = Directive.async(fn sender -> sender.(:original_result) end)
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands([original], [DirectiveAuditHook], context)

      assert %Async{} = wrapped

      sender = fn msg -> send(self(), {:sent, msg}) end
      wrapped.fun.(sender)

      assert_received {:pre, :async}
      assert_received {:post, :async, :original_result}
      assert_received {:sent, :original_result}
    end

    test "shell directive passes through pre-hooks but no post-hook wrap" do
      effects = [Directive.shell("ls")]
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands(effects, [DirectiveAuditHook], context)

      assert %Shell{command: "ls"} = wrapped
      assert_received {:pre, :shell}
    end

    test "send_agent directive passes through pre-hooks" do
      effects = [Directive.send_agent(:target, :hello)]
      context = Map.put(@context, :test_pid, self())

      [wrapped] = CommandHook.wrap_commands(effects, [DirectiveAuditHook], context)

      assert %SendAgent{target_id: :target, message: :hello} = wrapped
      assert_received {:pre, :send_agent}
    end
  end
end
