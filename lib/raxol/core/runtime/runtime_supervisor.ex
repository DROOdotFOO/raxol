defmodule Raxol.Core.Runtime.Supervisor do
  @moduledoc """
  Supervises the core runtime processes of a Raxol application.

  This supervisor manages:
  * Application runtime
  * Event handlers
  * Render processes
  * State management
  * Plugin system
  """

  use Supervisor

  def start_link(init_arg) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] start_link called with args: #{inspect(init_arg)}"
    )

    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(init_arg) do
    Raxol.Core.Runtime.Log.debug(
      "[#{__MODULE__}] init called with args: #{inspect(init_arg)}"
    )

    # Allow overriding child modules via init_arg for testing
    dispatcher_mod =
      init_arg[:dispatcher_module] || Raxol.Core.Runtime.Events.Dispatcher

    rendering_engine_mod =
      init_arg[:rendering_engine_module] || Raxol.Core.Runtime.Rendering.Engine

    plugin_manager_mod =
      init_arg[:plugin_manager_module] ||
        Raxol.Core.Runtime.Plugins.PluginManager

    # Assuming Task.Supervisor doesn't need mocking/overriding

    # Define the child spec for Dispatcher explicitly
    # Pass the supervisor's pid (self()) and the full init_arg map
    dispatcher_spec = %{
      # Use potentially overridden module
      id: dispatcher_mod,
      start: {dispatcher_mod, :start_link, [self(), init_arg]},
      type: :worker,
      restart: :permanent,
      shutdown: Raxol.Core.Defaults.shutdown_timeout_ms()
    }

    # Define Rendering Engine spec, extracting needed args from init_arg
    rendering_engine_args = %{
      app_module: init_arg[:app_module],
      # Use the potentially overridden module name for the dispatcher PID lookup if needed,
      # or pass the actual registered name if that's stable. Using the mod name here.
      dispatcher_pid: dispatcher_mod,
      width: init_arg[:width],
      height: init_arg[:height],
      # Default if not provided
      environment: init_arg[:environment] || :terminal
    }

    rendering_engine_spec = %{
      # Use potentially overridden module
      id: rendering_engine_mod,
      start: {rendering_engine_mod, :start_link, [rendering_engine_args]},
      type: :worker,
      restart: :permanent,
      shutdown: Raxol.Core.Defaults.shutdown_timeout_ms()
    }

    # Define Plugin Manager spec (assuming simple start_link/1)
    plugin_manager_spec = %{
      # Use potentially overridden module
      id: plugin_manager_mod,
      # Pass supervisor's PID as :runtime_pid
      start: {plugin_manager_mod, :start_link, [[runtime_pid: self()]]},
      type: :worker,
      restart: :permanent,
      shutdown: Raxol.Core.Defaults.shutdown_timeout_ms()
    }

    # Note: Terminal.Driver is started elsewhere by runtime components

    children = [
      # Task supervisor for isolated task execution
      {Task.Supervisor, name: Raxol.Core.Runtime.TaskSupervisor},
      # Core runtime services using potentially overridden modules
      dispatcher_spec,
      rendering_engine_spec,
      plugin_manager_spec
    ]

    # Add name here for init/1
    opts = [strategy: :one_for_all, name: __MODULE__]

    Raxol.Core.Runtime.Log.debug(
      "[#{__MODULE__}] Initializing supervisor with children: #{inspect(children)} and opts: #{inspect(opts)}"
    )

    # Original call format
    Supervisor.init(children, strategy: :one_for_all)
  end
end
