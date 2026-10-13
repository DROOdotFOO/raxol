defmodule Raxol.Core.Runtime.SupervisorTest do
  @moduledoc """
  Tests for the runtime supervisor, including child process management,
  supervisor configuration, and error handling.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Raxol.Test.TestUtils

  # Mock modules for testing
  defmodule Mock.EventLoop do
    use GenServer

    # RuntimeSupervisor calls dispatcher with start_link(supervisor_pid, init_arg)
    def start_link(_sup_pid, _init_arg),
      do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    def init(_), do: {:ok, nil}
  end

  defmodule Mock.RenderLoop do
    use GenServer

    def start_link(_),
      do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    def init(_), do: {:ok, nil}
  end

  defmodule Mock.Plugins.Manager do
    use GenServer

    def start_link(_),
      do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    def init(_), do: {:ok, nil}
  end

  # Define mocks for dependencies
  # Dispatcher mock removed - no behavior exists for Events Dispatcher
  # Mox.defmock(Raxol.Core.Runtime.Events.DispatcherMock,
  #   for: Raxol.Core.Runtime.Events.Dispatcher.Behaviour
  # )

  # Rendering Engine mock removed - no behavior exists for Rendering Engine
  # Mox.defmock(Raxol.Core.Runtime.Rendering.EngineMock,
  #   for: Raxol.Core.Runtime.Rendering.Engine.Behaviour
  # )

  # PluginManager.Behaviour mock removed - behavior doesn't exist
  # Mox.defmock(Raxol.Core.Runtime.Plugins.PluginManagerMock,
  #   for: Raxol.Core.Runtime.Plugins.PluginManager.Behaviour
  # )

  # DriverMock already defined in test/support/terminal_driver_mock.ex

  setup do
    # Set Mox to global mode so expectations are visible to spawned processes
    Mox.set_mox_global(true)
    # Set up test environment and mocks
    {:ok, context} = setup_test_env()
    setup_common_mocks()

    # Verify on exit
    :verify_on_exit!

    {:ok, context}
  end

  describe "supervisor structure" do
    test ~c"starts all runtime child processes with mocks" do
      # Use the inline Mock modules defined in this test module
      init_arg = %{
        dispatcher_module: Mock.EventLoop,
        rendering_engine_module: Mock.RenderLoop,
        plugin_manager_module: Mock.Plugins.Manager,
        app_module: TestApp,
        width: 80,
        height: 24
      }

      {:ok, sup_pid} = Raxol.Core.Runtime.Supervisor.start_link(init_arg)

      # Verify supervisor started and has children
      children = Supervisor.which_children(sup_pid)
      assert length(children) >= 3

      # Verify mock modules are running as children
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert Mock.EventLoop in child_ids
      assert Mock.RenderLoop in child_ids
      assert Mock.Plugins.Manager in child_ids

      # Clean up
      Supervisor.stop(sup_pid)
    end

    test ~c"uses one_for_all strategy" do
      init_arg = %{
        app_module: TestApp,
        width: 80,
        height: 24
      }

      result = Raxol.Core.Runtime.Supervisor.init(init_arg)
      assert {:ok, {sup_flags, children}} = result
      assert sup_flags.strategy == :one_for_all
      assert is_list(children)
    end
  end
end
