defmodule Raxol.Agent.CommandHookWiringTest do
  @moduledoc """
  C2 regression: the permission/sandbox/audit hook chain must run at dispatch
  time.

  Pre-fix, `CommandHook.wrap_commands` had no call site, so `PermissionHook`,
  `SandboxHook`, and any declared `command_hooks/0` never ran and every agent
  directive (Shell/Async/SendAgent) executed unguarded. This proves an agent's
  declared hooks are invoked, with the agent identity, before a directive runs,
  and that a `{:deny, _}` actually blocks execution.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.Session

  @moduletag :capture_log

  defmodule ObservingDenyHook do
    @moduledoc false
    @behaviour Raxol.Agent.CommandHook

    @impl true
    def pre_execute(command, context) do
      if pid = Process.whereis(:command_hook_wiring_observer) do
        send(pid, {:hook_fired, command, context})
      end

      {:deny, :blocked_by_test}
    end
  end

  defmodule HookedAgent do
    @moduledoc false
    use Raxol.Agent

    def command_hooks, do: [ObservingDenyHook]

    def init(_context), do: %{events: []}

    def update({:agent_message, _from, :work}, model) do
      {model, [Directive.async(fn sender -> sender.(:executed) end)]}
    end

    def update({:command_result, :executed}, model) do
      {%{model | events: [:executed | model.events]}, []}
    end

    def update({:command_result, {:command_denied, type, reason}}, model) do
      {%{model | events: [{:denied, type, reason} | model.events]}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    Process.register(self(), :command_hook_wiring_observer)
    :ok
  end

  test "declared command_hooks run before a directive executes, and a deny blocks it" do
    {:ok, _pid} = Session.start_link(app_module: HookedAgent, id: :hook_wiring)

    Session.send_message(:hook_wiring, :work)

    # The hook fired at dispatch, with the agent's identity -- the C2 wiring.
    assert_receive {:hook_fired, %Raxol.Agent.Directive.Async{},
                    %{agent_module: HookedAgent, agent_id: :hook_wiring}},
                   2_000

    # The directive was denied, not executed: the agent records the denial and
    # never sees the original :executed result.
    Process.sleep(200)
    {:ok, model} = Session.get_model(:hook_wiring)
    assert {:denied, :async, :blocked_by_test} in model.events
    refute :executed in model.events
  end
end
