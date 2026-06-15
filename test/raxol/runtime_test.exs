# --- Mock Application ---
defmodule MockApp do
  @behaviour Raxol.Core.Runtime.Application
  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Directive

  @impl Raxol.Core.Runtime.Application
  def init(_context), do: %{count: 0, last_clipboard: nil}

  @impl Raxol.Core.Runtime.Application
  def update({:event, %Event{type: :key, data: %{char: "="}}}, model) do
    {%{model | count: model.count + 1}, []}
  end

  @impl Raxol.Core.Runtime.Application
  def update({:event, %Event{type: :key, data: %{char: <<17>>}}}, model) do
    {model, [Directive.stop()]}
  end

  @impl Raxol.Core.Runtime.Application
  def update(_event_tuple, model), do: {model, []}

  @impl Raxol.Core.Runtime.Application
  def handle_event(_), do: :ok

  @impl Raxol.Core.Runtime.Application
  def handle_message(_, _), do: :ok

  @impl Raxol.Core.Runtime.Application
  def handle_tick(_), do: {nil, []}

  @impl Raxol.Core.Runtime.Application
  def terminate(_, _), do: :ok

  @impl Raxol.Core.Runtime.Application
  def view(model) do
    [:text, "Count: #{model.count}, Clipboard: #{inspect(model.last_clipboard)}"]
  end

  @impl Raxol.Core.Runtime.Application
  def subscriptions(_model), do: []
end

defmodule Raxol.RuntimeTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Supervisor, as: RuntimeSupervisor

  # Lightweight mock GenServers to replace real runtime children
  defmodule MockDispatcher do
    use GenServer

    def start_link(_sup_pid, _init_arg),
      do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    def init(_), do: {:ok, %{model: %{count: 0, last_clipboard: nil}}}

    def handle_call(:get_model, _from, state),
      do: {:reply, {:ok, state.model}, state}
  end

  defmodule MockEngine do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
    def init(_), do: {:ok, nil}
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end

  defmodule MockPluginManager do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
    def init(_), do: {:ok, nil}
  end

  setup do
    # Clean up any leftover processes from previous tests
    for name <- [MockDispatcher, MockEngine, MockPluginManager, RuntimeSupervisor] do
      case Process.whereis(name) do
        nil -> :ok
        pid ->
          Process.unlink(pid)
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)
          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
          after
            500 -> :ok
          end
      end
    end

    :ok
  end

  defp start_supervisor do
    init_arg = %{
      app_module: MockApp,
      width: 80,
      height: 24,
      dispatcher_module: MockDispatcher,
      rendering_engine_module: MockEngine,
      plugin_manager_module: MockPluginManager
    }

    RuntimeSupervisor.start_link(init_arg)
  end

  test "successfully starts the supervisor and core processes" do
    {:ok, sup_pid} = start_supervisor()
    assert Process.alive?(sup_pid)

    # Verify children are running
    children = Supervisor.which_children(sup_pid)
    child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

    assert MockDispatcher in child_ids
    assert MockEngine in child_ids
    assert MockPluginManager in child_ids

    Supervisor.stop(sup_pid)
  end

  test "supervisor uses one_for_all strategy" do
    result =
      RuntimeSupervisor.init(%{
        app_module: MockApp,
        width: 80,
        height: 24
      })

    assert {:ok, {sup_flags, _children}} = result
    assert sup_flags.strategy == :one_for_all
  end

  test "core processes are alive and responsive" do
    {:ok, sup_pid} = start_supervisor()

    # Verify mock dispatcher responds
    dispatcher_pid = Process.whereis(MockDispatcher)
    assert Process.alive?(dispatcher_pid)

    {:ok, model} = GenServer.call(dispatcher_pid, :get_model, 500)
    assert model == %{count: 0, last_clipboard: nil}

    Supervisor.stop(sup_pid)
  end

  test "supervisor restarts child processes after crash" do
    {:ok, sup_pid} = start_supervisor()

    # Get initial dispatcher PID
    dispatcher_info =
      Supervisor.which_children(sup_pid)
      |> Enum.find(fn {id, _, _, _} -> id == MockDispatcher end)

    assert {MockDispatcher, old_pid, :worker, _} = dispatcher_info
    assert Process.alive?(old_pid)

    # Kill the dispatcher
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 5000

    # Wait for supervisor restart (one_for_all restarts all)
    Process.sleep(500)

    # Verify new processes were started
    new_dispatcher_info =
      Supervisor.which_children(sup_pid)
      |> Enum.find(fn {id, _, _, _} -> id == MockDispatcher end)

    assert {MockDispatcher, new_pid, :worker, _} = new_dispatcher_info
    refute new_pid == old_pid
    assert Process.alive?(new_pid)

    Supervisor.stop(sup_pid)
  end

  test "supervisor stops cleanly" do
    {:ok, sup_pid} = start_supervisor()
    Process.unlink(sup_pid)

    Supervisor.stop(sup_pid, :shutdown, :infinity)

    refute Process.alive?(sup_pid)
    assert Process.whereis(MockDispatcher) == nil
    assert Process.whereis(MockEngine) == nil
    assert Process.whereis(MockPluginManager) == nil
  end

  test "supervisor has correct number of children" do
    {:ok, sup_pid} = start_supervisor()

    children = Supervisor.which_children(sup_pid)
    # Task.Supervisor + dispatcher + engine + plugin_manager = 4
    assert length(children) == 4

    Supervisor.stop(sup_pid)
  end
end
