defmodule Raxol.Agent.Authorization.HookTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Authorization.{Hook, Policy, Verdict}
  alias Raxol.Agent.Directive.{Async, Shell}

  setup do
    on_exit(&Hook.clear/0)
    :ok
  end

  defp shell(cmd \\ "ls"), do: %Shell{command: cmd, opts: []}
  defp async, do: %Async{fun: fn _sender -> :ok end}
  defp ctx, do: %{agent_id: :a, agent_module: __MODULE__}

  defp deny_shell do
    Policy.new(
      name: :deny_shell,
      phases: [:tool_call],
      evaluate: fn %{type: type} ->
        if type == :shell, do: Verdict.deny(:no_shell), else: Verdict.allow()
      end
    )
  end

  defp ask_policy(scope \\ :session, writes \\ %{}) do
    Policy.new(
      name: :ask_net,
      phases: [:tool_call],
      scope: scope,
      evaluate: fn _ -> Verdict.ask("allow shell?", writes) end
    )
  end

  test "is a neutral no-op when not configured" do
    assert {:ok, _} = Hook.pre_execute(shell(), ctx())
  end

  test "allows a directive no policy denies" do
    Hook.configure(policies: [deny_shell()])
    assert {:ok, %Async{}} = Hook.pre_execute(async(), ctx())
  end

  test "denies a shell directive" do
    Hook.configure(policies: [deny_shell()])
    assert {:deny, :no_shell} = Hook.pre_execute(shell("rm -rf /"), ctx())
  end

  test "an ASK approved by the prompter allows and releases escrow" do
    Hook.configure(
      policies: [ask_policy(:session, %{net: :granted})],
      prompter: fn _d, _c -> :approve end
    )

    assert {:ok, %Shell{}} = Hook.pre_execute(shell(), ctx())
    assert Hook.labels() == %{net: :granted}
  end

  test "an ASK denied by the prompter denies with the prompts" do
    Hook.configure(policies: [ask_policy()], prompter: fn _d, _c -> :deny end)
    assert {:deny, {:ask_denied, ["allow shell?"]}} = Hook.pre_execute(shell(), ctx())
  end

  test "an ASK with no prompter requires approval" do
    Hook.configure(policies: [ask_policy()])
    assert {:deny, {:requires_approval, ["allow shell?"]}} = Hook.pre_execute(shell(), ctx())
  end

  test "composes in the CommandHook chain" do
    Hook.configure(policies: [deny_shell()])
    assert {:deny, :no_shell} = Raxol.Agent.CommandHook.run_pre_hooks([Hook], shell(), ctx())
  end
end
