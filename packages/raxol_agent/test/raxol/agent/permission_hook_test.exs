defmodule Raxol.Agent.PermissionHookTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.PermissionHook
  alias Raxol.Core.Runtime.Command

  @context %{agent_id: :test, agent_module: nil}

  describe "policy/2" do
    test "creates a policy with the given mode" do
      policy = PermissionHook.policy(:read_only)
      assert policy.mode == :read_only
      assert policy.prompter == nil
    end

    test "accepts a prompter function" do
      prompter = fn _cmd, _ctx -> true end
      policy = PermissionHook.policy(:read_only, prompter: prompter)
      assert policy.prompter == prompter
    end

    test "read_only denies shell, system, send_agent, async, task" do
      policy = PermissionHook.policy(:read_only)

      for type <- [
            :shell,
            :system,
            :send_agent,
            :async,
            :task,
            :clipboard_write,
            :notify
          ] do
        assert MapSet.member?(policy.denied_types, type),
               "expected :#{type} to be denied in :read_only mode"
      end
    end

    test "read_only allows none, delay, quit, broadcast, clipboard_read" do
      policy = PermissionHook.policy(:read_only)

      for type <- [:none, :delay, :quit, :broadcast, :clipboard_read] do
        refute MapSet.member?(policy.denied_types, type),
               "expected :#{type} to be allowed in :read_only mode"
      end
    end

    test "send_only allows send_agent, task, async but denies shell, system" do
      policy = PermissionHook.policy(:send_only)

      for type <- [:send_agent, :task, :async] do
        refute MapSet.member?(policy.denied_types, type),
               "expected :#{type} to be allowed in :send_only mode"
      end

      for type <- [:shell, :system] do
        assert MapSet.member?(policy.denied_types, type),
               "expected :#{type} to be denied in :send_only mode"
      end
    end

    test "workspace_write allows clipboard_write, notify but denies shell, system" do
      policy = PermissionHook.policy(:workspace_write)

      for type <- [:clipboard_write, :notify, :send_agent, :task, :async] do
        refute MapSet.member?(policy.denied_types, type),
               "expected :#{type} to be allowed in :workspace_write mode"
      end

      for type <- [:shell, :system] do
        assert MapSet.member?(policy.denied_types, type),
               "expected :#{type} to be denied in :workspace_write mode"
      end
    end

    test "full_access allows everything" do
      policy = PermissionHook.policy(:full_access)
      assert MapSet.size(policy.denied_types) == 0
    end

    test "allow allows everything" do
      policy = PermissionHook.policy(:allow)
      assert MapSet.size(policy.denied_types) == 0
    end
  end

  describe "authorize/3" do
    test "allows permitted command types" do
      policy = PermissionHook.policy(:full_access)

      assert :allow ==
               PermissionHook.authorize(Command.shell("ls"), policy, @context)
    end

    test "denies restricted command types" do
      policy = PermissionHook.policy(:read_only)

      assert {:deny, reason} =
               PermissionHook.authorize(Command.shell("ls"), policy, @context)

      assert is_binary(reason)
      assert String.contains?(reason, ":shell")
    end

    test "always allows :none regardless of mode" do
      policy = PermissionHook.policy(:read_only)

      assert :allow ==
               PermissionHook.authorize(Command.none(), policy, @context)
    end

    test "prompter can escalate a denied command" do
      policy =
        PermissionHook.policy(:read_only, prompter: fn _cmd, _ctx -> true end)

      assert :allow ==
               PermissionHook.authorize(Command.shell("ls"), policy, @context)
    end

    test "prompter can reject escalation" do
      policy =
        PermissionHook.policy(:read_only, prompter: fn _cmd, _ctx -> false end)

      assert {:deny, reason} =
               PermissionHook.authorize(Command.shell("ls"), policy, @context)

      assert String.contains?(reason, "prompter")
    end
  end

  describe "required_mode/1" do
    test "shell requires full_access" do
      assert :full_access == PermissionHook.required_mode(:shell)
    end

    test "system requires full_access" do
      assert :full_access == PermissionHook.required_mode(:system)
    end

    test "send_agent requires send_only" do
      assert :send_only == PermissionHook.required_mode(:send_agent)
    end

    test "none requires read_only" do
      assert :read_only == PermissionHook.required_mode(:none)
    end

    test "unknown types default to full_access" do
      assert :full_access == PermissionHook.required_mode(:unknown_thing)
    end
  end

  describe "mode_permits?/2" do
    test "allow permits everything" do
      for mode <- [
            :read_only,
            :send_only,
            :workspace_write,
            :full_access,
            :allow
          ] do
        assert PermissionHook.mode_permits?(:allow, mode)
      end
    end

    test "read_only only permits read_only" do
      assert PermissionHook.mode_permits?(:read_only, :read_only)
      refute PermissionHook.mode_permits?(:read_only, :send_only)
      refute PermissionHook.mode_permits?(:read_only, :full_access)
    end

    test "full_access permits everything except allow" do
      assert PermissionHook.mode_permits?(:full_access, :read_only)
      assert PermissionHook.mode_permits?(:full_access, :send_only)
      assert PermissionHook.mode_permits?(:full_access, :workspace_write)
      assert PermissionHook.mode_permits?(:full_access, :full_access)
      refute PermissionHook.mode_permits?(:full_access, :allow)
    end
  end

  describe "pre_execute/2 (CommandHook integration)" do
    test "allows commands when policy permits" do
      PermissionHook.new(:full_access)
      command = Command.shell("ls")
      assert {:ok, ^command} = PermissionHook.pre_execute(command, @context)
    end

    test "denies commands when policy restricts" do
      PermissionHook.new(:read_only)
      command = Command.shell("rm -rf /")
      assert {:deny, reason} = PermissionHook.pre_execute(command, @context)
      assert is_binary(reason)
    end
  end

  describe "integration with CommandHook.wrap_commands/3" do
    test "denied commands produce denial notifications" do
      PermissionHook.new(:read_only)

      commands = [Command.shell("ls"), Command.none()]

      wrapped =
        Raxol.Agent.CommandHook.wrap_commands(
          commands,
          [PermissionHook],
          @context
        )

      # shell should be wrapped as denial, none should pass through
      [denied_cmd, pass_cmd] = wrapped

      assert denied_cmd.type == :async
      assert pass_cmd.type == :none

      # Execute the denial wrapper
      sender = fn msg -> send(self(), {:sent, msg}) end
      denied_cmd.data.(sender)

      assert_received {:sent, {:command_denied, :shell, reason}}
      assert is_binary(reason)
    end
  end

  alias Raxol.Agent.Directive

  describe "authorize/3 with directives" do
    test "allows permitted directive types" do
      policy = PermissionHook.policy(:full_access)

      assert :allow ==
               PermissionHook.authorize(Directive.shell("ls"), policy, @context)
    end

    test "denies restricted directive types" do
      policy = PermissionHook.policy(:read_only)

      assert {:deny, reason} =
               PermissionHook.authorize(Directive.shell("ls"), policy, @context)

      assert String.contains?(reason, ":shell")
    end

    test "Directive.send_agent allowed in :send_only mode" do
      policy = PermissionHook.policy(:send_only)

      assert :allow ==
               PermissionHook.authorize(
                 Directive.send_agent(:t, :hello),
                 policy,
                 @context
               )
    end

    test "Directive.async allowed in :send_only mode" do
      policy = PermissionHook.policy(:send_only)

      assert :allow ==
               PermissionHook.authorize(
                 Directive.async(fn _s -> :ok end),
                 policy,
                 @context
               )
    end

    test "Directive.schedule (mapped to :delay) allowed in :read_only mode" do
      policy = PermissionHook.policy(:read_only)

      assert :allow ==
               PermissionHook.authorize(
                 Directive.schedule(50, :tick),
                 policy,
                 @context
               )
    end

    test "Directive.stop (mapped to :quit) allowed in :read_only mode" do
      policy = PermissionHook.policy(:read_only)

      assert :allow ==
               PermissionHook.authorize(Directive.stop(), policy, @context)
    end
  end
end
