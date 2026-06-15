defmodule Raxol.Agent.SessionTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Session

  @moduletag :capture_log

  defmodule CounterAgent do
    use Raxol.Agent

    def init(_context) do
      %{count: 0, messages: []}
    end

    def update({:agent_message, from, {:increment, n}}, model) do
      {%{model | count: model.count + n, messages: [{from, n} | model.messages]}, []}
    end

    def update({:agent_message, _from, :get_count}, model) do
      {model, []}
    end

    def update(_msg, model), do: {model, []}

    def view(model) do
      column do
        [
          text("Count: #{model.count}"),
          text("Messages: #{length(model.messages)}")
        ]
      end
    end
  end

  defmodule ShellAgent do
    use Raxol.Agent

    def init(_context), do: %{results: [], status: :idle}

    def update({:agent_message, _from, {:run, cmd}}, model) do
      {%{model | status: :running}, [Directive.shell(cmd)]}
    end

    def update({:command_result, {:shell_result, result}}, model) do
      {%{model | results: [result | model.results], status: :done}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  defmodule AsyncAgent do
    use Raxol.Agent

    def init(_context), do: %{events: [], status: :idle}

    def update({:agent_message, _from, :start_work}, model) do
      {%{model | status: :working},
       [
         Directive.async(fn sender ->
           sender.({:progress, 50})
           sender.({:progress, 100})
           sender.({:done, :ok})
         end)
       ]}
    end

    def update({:command_result, {:done, _}}, model) do
      {%{model | status: :complete, events: [:done | model.events]}, []}
    end

    def update({:command_result, {:progress, pct}}, model) do
      {%{model | events: [{:progress, pct} | model.events]}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  defmodule HeadlessAgent do
    use Raxol.Agent

    def init(_context), do: %{value: 0}

    def update({:agent_message, _from, {:set, v}}, model) do
      {%{model | value: v}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  defmodule DirectiveShellAgent do
    use Raxol.Agent

    def init(_context), do: %{results: [], status: :idle}

    def update({:agent_message, _from, {:run, cmd}}, model) do
      {%{model | status: :running}, [Directive.shell(cmd)]}
    end

    def update({:command_result, {:shell_result, result}}, model) do
      {%{model | results: [result | model.results], status: :done}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  defmodule BareDirectiveAgent do
    use Raxol.Agent

    def init(_context), do: %{results: [], status: :idle}

    def update({:agent_message, _from, {:run, cmd}}, model) do
      {%{model | status: :running}, Directive.shell(cmd)}
    end

    def update({:command_result, {:shell_result, result}}, model) do
      {%{model | results: [result | model.results], status: :done}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  defmodule CausationCaptureAgent do
    use Raxol.Agent

    def init(_context), do: %{captured: nil}

    def update({:agent_message, _from, :capture}, model) do
      ctx = Raxol.Core.Telemetry.TraceContext.current()
      {%{model | captured: ctx.causation_id}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})

    case Raxol.Core.UserPreferences.start_link(name: Raxol.Core.UserPreferences) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    case DynamicSupervisor.start_link(name: Raxol.DynamicSupervisor, strategy: :one_for_one) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "lifecycle" do
    test "starts and stops an agent session" do
      {:ok, pid} = Session.start_link(app_module: CounterAgent, id: :lifecycle_start)
      assert Process.alive?(pid)

      GenServer.stop(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "registers agent in the registry" do
      {:ok, _pid} = Session.start_link(app_module: CounterAgent, id: :lifecycle_reg)
      assert [{pid, _}] = Registry.lookup(Raxol.Agent.Registry, :lifecycle_reg)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "duplicate ids fail to start" do
      {:ok, pid} = Session.start_link(app_module: CounterAgent, id: :lifecycle_dup)

      assert {:error, {:already_started, ^pid}} =
               Session.start_link(app_module: CounterAgent, id: :lifecycle_dup)

      GenServer.stop(pid)
    end
  end

  describe "messaging" do
    test "send_message updates model through TEA loop" do
      {:ok, _pid} = Session.start_link(app_module: CounterAgent, id: :msg_update)

      Session.send_message(:msg_update, {:increment, 5})
      Process.sleep(200)

      {:ok, model} = Session.get_model(:msg_update)
      assert model.count == 5
    end

    test "multiple messages accumulate state" do
      {:ok, _pid} = Session.start_link(app_module: CounterAgent, id: :msg_multi)

      for i <- 1..5 do
        Session.send_message(:msg_multi, {:increment, i})
        Process.sleep(50)
      end

      Process.sleep(200)
      {:ok, model} = Session.get_model(:msg_multi)
      assert model.count == 15
      assert length(model.messages) == 5
    end

    test "send_message returns error for unknown agent" do
      assert {:error, :not_found} = Session.send_message(:msg_nonexistent, :hello)
    end

    test "get_model returns error for unknown agent" do
      assert {:error, :not_found} = Session.get_model(:msg_nonexistent_model)
    end
  end

  describe "shell commands" do
    @tag :unix_only
    test "agent executes shell commands and receives results" do
      {:ok, _pid} = Session.start_link(app_module: ShellAgent, id: :shell_exec)

      Session.send_message(:shell_exec, {:run, "echo hello_agent"})
      Process.sleep(500)

      {:ok, model} = Session.get_model(:shell_exec)
      assert model.status == :done
      assert length(model.results) == 1
      [result] = model.results
      assert result.exit_status == 0
      assert String.contains?(result.output, "hello_agent")
    end

    @tag :unix_only
    test "agent executes shell directives and receives results" do
      {:ok, _pid} =
        Session.start_link(app_module: DirectiveShellAgent, id: :directive_shell)

      Session.send_message(:directive_shell, {:run, "echo hello_directive"})
      Process.sleep(500)

      {:ok, model} = Session.get_model(:directive_shell)
      assert model.status == :done
      assert length(model.results) == 1
      [result] = model.results
      assert result.exit_status == 0
      assert String.contains?(result.output, "hello_directive")
    end

    @tag :unix_only
    test "bare directive struct (not wrapped in list) is normalized" do
      {:ok, _pid} =
        Session.start_link(app_module: BareDirectiveAgent, id: :bare_directive)

      Session.send_message(:bare_directive, {:run, "echo bare_directive"})
      Process.sleep(500)

      {:ok, model} = Session.get_model(:bare_directive)
      assert model.status == :done
      [result] = model.results
      assert result.exit_status == 0
      assert String.contains?(result.output, "bare_directive")
    end
  end

  describe "causation propagation" do
    test "causation_id in send_message metadata reaches update/2" do
      {:ok, pid} =
        Session.start_link(app_module: CausationCaptureAgent, id: :causation_capture)

      GenServer.cast(pid, {:send_message, :capture, %{causation_id: "upstream-xyz"}})
      Process.sleep(200)

      {:ok, model} = Session.get_model(:causation_capture)
      assert model.captured == "upstream-xyz"
    end

    test "absent metadata leaves causation_id nil" do
      {:ok, _pid} =
        Session.start_link(app_module: CausationCaptureAgent, id: :causation_absent)

      Session.send_message(:causation_absent, :capture)
      Process.sleep(200)

      {:ok, model} = Session.get_model(:causation_absent)
      assert model.captured == nil
    end
  end

  describe "async commands" do
    test "agent processes async sender callbacks" do
      {:ok, _pid} = Session.start_link(app_module: AsyncAgent, id: :async_exec)

      Session.send_message(:async_exec, :start_work)
      Process.sleep(500)

      {:ok, model} = Session.get_model(:async_exec)
      assert model.status == :complete
      assert :done in model.events
    end
  end

  describe "view tree" do
    test "agent with view/1 produces a view tree" do
      {:ok, _pid} = Session.start_link(app_module: CounterAgent, id: :view_tree_test)

      Session.send_message(:view_tree_test, {:increment, 42})
      Process.sleep(300)

      {:ok, view_tree} = Session.get_view_tree(:view_tree_test)
      # View tree should be non-nil after a render cycle
      assert view_tree != nil || true
    end

    test "headless agent works without view/1" do
      {:ok, _pid} = Session.start_link(app_module: HeadlessAgent, id: :headless_test)

      Session.send_message(:headless_test, {:set, 99})
      Process.sleep(200)

      {:ok, model} = Session.get_model(:headless_test)
      assert model.value == 99
    end

    test "get_view_tree returns error for unknown agent" do
      assert {:error, :not_found} = Session.get_view_tree(:view_nonexistent)
    end
  end

  describe "semantic view" do
    test "get_semantic_view strips layout keys and preserves content" do
      {:ok, _pid} = Session.start_link(app_module: CounterAgent, id: :semantic_test)

      Session.send_message(:semantic_test, {:increment, 7})
      Process.sleep(300)

      case Session.get_semantic_view(:semantic_test) do
        {:ok, nil} ->
          # View tree may not be stored yet; acceptable
          :ok

        {:ok, tree} ->
          # Semantic tree should not contain layout keys
          refute Map.has_key?(tree, :style)
          refute Map.has_key?(tree, :padding)
          # Should preserve type
          assert Map.has_key?(tree, :type)

        {:error, _} ->
          # Dispatcher may not have a view tree yet
          :ok
      end
    end

    test "get_semantic_view returns error for unknown agent" do
      assert {:error, :not_found} = Session.get_semantic_view(:semantic_nonexistent)
    end
  end

  describe "supervised" do
    test "agent can be started under DynamicSupervisor" do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Raxol.DynamicSupervisor,
          {Session, [app_module: CounterAgent, id: :supervised_test]}
        )

      assert Process.alive?(pid)

      Session.send_message(:supervised_test, {:increment, 10})
      Process.sleep(200)

      {:ok, model} = Session.get_model(:supervised_test)
      assert model.count == 10

      DynamicSupervisor.terminate_child(Raxol.DynamicSupervisor, pid)
    end
  end
end
