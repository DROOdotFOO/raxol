defmodule Raxol.Core.Runtime.LifecycleTest do
  @moduledoc """
  Tests for the application lifecycle system, including application registration,
  environment handling, error handling, and cleanup.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import ExUnit.CaptureLog

  alias Raxol.Core.Runtime.Application
  alias Raxol.Core.Runtime.Lifecycle

  defmodule TestApp do
    @moduledoc false
    @behaviour Application

    @impl Application
    def init(_), do: %{initialized: true}

    @impl Application
    def update(_msg, model), do: {model, []}

    @impl Application
    def view(_model), do: %{type: :text, content: "Test App View"}

    @impl Application
    def subscriptions(_model), do: []

    @impl Application
    def handle_event(_), do: :ok

    @impl Application
    def handle_message(_, _), do: :ok

    @impl Application
    def handle_tick(_), do: :ok

    @impl Application
    def terminate(_, _), do: :ok

    def app_name, do: :test_app
  end

  defmodule MockTerminalUtils do
    @moduledoc false
    def set_terminal_title(_title), do: :ok
    def initialize_terminal(_width, _height), do: :ok
    def restore_terminal, do: :ok
  end

  setup_all do
    case start_supervised(Raxol.DynamicSupervisor) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {{:already_started, _pid}, _}} -> :ok
    end

    # Handle case where registry is already running from global test setup or supervisor
    case start_supervised(Raxol.Terminal.Registry) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, {{:already_started, _pid}, _}} ->
        :ok

      {:error, reason} ->
        raise "Failed to start Raxol.Terminal.Registry: #{inspect(reason)}"
    end

    # Ensure event subscriptions registry exists for Dispatcher
    if Process.whereis(:raxol_event_subscriptions) == nil do
      {:ok, _} =
        Registry.start_link(keys: :duplicate, name: :raxol_event_subscriptions)
    end

    # Start UserPreferences which is required by the application lifecycle
    # Must pass name option so it registers with the expected module name
    case start_supervised({Raxol.Core.UserPreferences, [name: Raxol.Core.UserPreferences]}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "Failed to start Raxol.Core.UserPreferences: #{inspect(reason)}"
    end

    :ok
  end

  setup do
    stop_registered_process(:test_app)
    :ok
  end

  defp stop_registered_process(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              1_000 -> :ok
            end
        end

        # Ensure the name is fully unregistered
        wait_for_unregister(name, 10)
    end
  end

  defp wait_for_unregister(_name, 0), do: :ok

  defp wait_for_unregister(name, retries) do
    case Process.whereis(name) do
      nil -> :ok
      _ -> Process.sleep(50) && wait_for_unregister(name, retries - 1)
    end
  end

  describe "application lifecycle" do
    # test 'register_application registers an app with the registry' do
    #   :ok = Lifecycle.register_application(:test_app, self())
    #   assert {:error, :not_found} == Lifecycle.lookup_app(:test_app)
    # end

    test "lookup_app returns error for non-existent app" do
      assert {:error, :not_found} == Lifecycle.lookup_app(:nonexistent_app)
    end

    test "start_application uses app_name from module if available" do
      {:ok, pid} = Lifecycle.start_application(TestApp, [])
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "get_app_name returns module's app_name if available" do
      app_module = TestApp
      result = Lifecycle.get_app_name(app_module)
      assert result == :test_app
    end

    test "get_app_name returns :default if app_name/0 not available" do
      defmodule ModuleWithoutAppName do
        @behaviour Application
        @impl Application
        def init(_), do: %{}
        @impl Application
        def update(_msg, model), do: {model, []}
        @impl Application
        def view(_), do: %{type: :text, content: "View"}
        @impl Application
        def subscriptions(_), do: []
      end

      result = Lifecycle.get_app_name(ModuleWithoutAppName)
      assert result == :default
    end
  end

  describe "error handling" do
    test "handle_error logs termbox errors and attempts retry" do
      state = %{
        app_module: TestApp,
        model: %{},
        app_name: :test_app,
        environment: :terminal
      }

      error = {:termbox_error, :some_reason}

      log =
        capture_log(fn ->
          result = Lifecycle.handle_error(error, state)
          assert result == {:stop, :normal, %{}}
        end)

      assert log =~ "[Lifecycle] Termbox error: :some_reason"
      assert log =~ "[Lifecycle] Attempting to restore terminal"
    end

    test "handle_error logs application errors and stops" do
      state = %{
        app_module: TestApp,
        model: %{},
        app_name: :test_app,
        environment: :terminal
      }

      error = {:application_error, :crash}

      log =
        capture_log(fn ->
          result = Lifecycle.handle_error(error, state)
          assert result == {:stop, :normal, %{}}
        end)

      assert log =~ "[Lifecycle] Application error: :crash"
      assert log =~ "[Lifecycle] Stopping application"
    end

    test "handle_error logs unknown errors and continues" do
      state = %{
        app_module: TestApp,
        model: %{},
        app_name: :test_app,
        environment: :terminal
      }

      error = {:unknown_error, :reason}

      log =
        capture_log(fn ->
          result = Lifecycle.handle_error(error, state)
          assert result == {:stop, :normal, %{}}
        end)

      assert log =~ "[Lifecycle] Unknown error: {:unknown_error, :reason}"
      assert log =~ "[Lifecycle] Continuing execution"
    end
  end

  describe "environment handling" do
    test "initialize_environment with :terminal option" do
      options = [
        environment: :terminal,
        width: 100,
        height: 50,
        title: "Test Title"
      ]

      log =
        capture_log(fn ->
          result = Lifecycle.initialize_environment(options)
          assert result == options
        end)

      assert log =~ "[Lifecycle] Initializing terminal environment"
    end

    test "initialize_environment handles terminal initialization failure" do
      options = [environment: :web]

      log =
        capture_log(fn ->
          result = Lifecycle.initialize_environment(options)
          assert result == options
        end)

      assert log =~ "[Lifecycle] Terminal initialization failed"
    end

    test "initialize_environment with unknown environment type" do
      options = [environment: :unknown]

      log =
        capture_log(fn ->
          result = Lifecycle.initialize_environment(options)
          assert result == options
        end)

      assert log =~ "[Lifecycle] Unknown environment type: :unknown"
    end
  end

  describe "cleanup handling" do
    test "handle_cleanup performs proper cleanup" do
      state = %{app_name: :test_app}

      log =
        capture_log(fn ->
          result = Lifecycle.handle_cleanup(state)
          assert result == :ok
        end)

      assert log =~ "[Lifecycle] Cleaning up for app: test_app"
      assert log =~ "[Lifecycle] Cleanup completed"
    end
  end
end
