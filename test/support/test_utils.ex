defmodule Raxol.Test.TestUtils do
  # ExUnit.CaseTemplate macro generates pattern that dialyzer flags
  @dialyzer :no_match
  alias Raxol.Test.SharedUtilities

  @moduledoc """
  Consolidated test utilities providing comprehensive testing functionality.

  This module combines the functionality from:
  - Raxol.Test.Support.TestHelper (environment/config focus)
  - Raxol.Test.Helpers (process/assertions focus)
  - Raxol.Test.TestHelper (comprehensive utilities)

  Provides all test utilities in a single, organized module.
  """

  use ExUnit.CaseTemplate
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Raxol.Core.Events.Event

  # =============================================================================
  # ENVIRONMENT SETUP & CONFIGURATION
  # =============================================================================

  @doc """
  Sets up comprehensive test environment with services and configuration.
  Combines the best features from all three implementations.
  """
  def setup_test_env(opts \\ []) do
    # Start services if requested
    _ =
      if Keyword.get(opts, :start_services, false) do
        Application.ensure_all_started(:raxol)
      end

    SharedUtilities.setup_basic_test_env()

    # Create comprehensive test context with additional options
    context =
      SharedUtilities.create_test_context(
        test_data: %{
          test_id: :rand.uniform(1_000_000),
          services_started: Keyword.get(opts, :start_services, false),
          mock_modules: []
        }
      )

    {:ok, context}
  end

  @doc """
  Sets up terminal environment for testing.
  Supports both configuration mode and mock data mode.
  """
  def setup_test_terminal(mode \\ :config) do
    case mode do
      :config ->
        # Set up terminal-specific test configuration
        Application.put_env(:raxol, :terminal_test_mode, true)
        :ok

      :mock ->
        # Return mock terminal data
        %{
          width: 80,
          height: 24,
          output: [],
          cursor: {0, 0}
        }
    end
  end

  @doc """
  Sets up common mocks used across tests.
  """
  def setup_common_mocks do
    SharedUtilities.setup_common_mocks()
  end

  @doc """
  Cleans up test environment with support for multiple cleanup modes.
  """
  def cleanup_test_env(env_or_context \\ :default)

  def cleanup_test_env(env) when is_atom(env) do
    # Clean up any test-specific configuration
    Application.delete_env(:raxol, :test_mode)
    Application.delete_env(:raxol, :database_enabled)
    Application.delete_env(:raxol, :terminal_test_mode)

    # Clean up environment-specific configuration
    case env do
      :test -> Application.delete_env(:raxol, :test_mode)
      :development -> Application.delete_env(:raxol, :dev_mode)
      :production -> Application.delete_env(:raxol, :prod_mode)
      _ -> :ok
    end

    :ok
  end

  def cleanup_test_env(context) when is_map(context) do
    # Extract environment from context or use default
    env = Map.get(context, :env, :default)
    cleanup_test_env(env)
  end

  # =============================================================================
  # PROCESS MANAGEMENT & SUPERVISION
  # =============================================================================

  @doc """
  Starts a named process using the process naming utility.
  """
  def start_named_process(module, opts \\ []) do
    name = Raxol.Test.ProcessNaming.generate_name(module)
    start_supervised({module, Keyword.put(opts, :name, name)})
  end

  @doc """
  Asserts that a process has been started with the given name.
  """
  def assert_process_started(_module, name) do
    assert Process.whereis(name)
  end

  @doc """
  Cleans up a process and waits for it to be down.
  """
  def cleanup_process(pid, timeout \\ 5000) do
    case Process.alive?(pid) do
      true ->
        ref = Process.monitor(pid)
        Process.exit(pid, :normal)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          timeout -> :timeout
        end

      false ->
        :ok
    end
  end

  @doc """
  Cleans up an ETS table.
  """
  def cleanup_ets_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(table)
    end
  end

  @doc """
  Cleans up a registry.
  """
  def cleanup_registry(registry) do
    case Process.whereis(registry) do
      nil -> :ok
      _ -> Registry.unregister(registry, self())
    end
  end

  # =============================================================================
  # RENDERING & UI TESTING
  # =============================================================================

  @doc """
  Sets up a test environment with renderer and pipeline processes.
  """
  def setup_rendering_test do
    # Start the TimerServer first (required by Pipeline for animation)
    {:ok, timer_server_pid} =
      start_supervised(
        {Raxol.UI.Rendering.TimerServer, name: Raxol.UI.Rendering.TimerServer}
      )

    # Start the Renderer GenServer with module name registration
    {:ok, renderer_pid} =
      start_supervised(
        {Raxol.UI.Rendering.Renderer, name: Raxol.UI.Rendering.Renderer}
      )

    # Set test notification for renderer using the actual PID
    GenServer.cast(renderer_pid, {:set_test_pid, self()})

    %{
      renderer_pid: renderer_pid,
      timer_server_pid: timer_server_pid
    }
  end

  @doc """
  Asserts that a render event is received with the expected content.
  """
  def assert_render_event(expected_content, timeout \\ 100) do
    receive do
      {:renderer_rendered, ops} ->
        assert Enum.any?(ops, fn op ->
                 case op do
                   {:draw_text, _line, text} -> text == expected_content
                   _ -> false
                 end
               end),
               "Expected render event with content '#{expected_content}' but got #{inspect(ops)}"
    after
      timeout ->
        flunk(
          "Expected render event with content '#{expected_content}' not received within #{timeout}ms"
        )
    end
  end

  @doc """
  Asserts that a partial render event is received.
  """
  def assert_partial_render_event(
        expected_path,
        expected_subtree,
        expected_tree,
        timeout \\ 100
      ) do
    receive do
      {:renderer_partial_update, path, subtree, tree} ->
        assert path == expected_path,
               "Expected path #{inspect(expected_path)}, got #{inspect(path)}"

        assert subtree == expected_subtree,
               "Expected subtree #{inspect(expected_subtree)}, got #{inspect(subtree)}"

        assert tree == expected_tree,
               "Expected tree #{inspect(expected_tree)}, got #{inspect(tree)}"
    after
      timeout ->
        flunk("Expected partial render event not received within #{timeout}ms")
    end
  end

  @doc """
  Asserts that no render event is received within the timeout.
  """
  def refute_render_event(timeout \\ 50) do
    receive do
      {:renderer_rendered, ops} ->
        flunk("Unexpected render event received: #{inspect(ops)}")

      {:renderer_partial_update, path, subtree, tree} ->
        flunk(
          "Unexpected partial render event received: path=#{inspect(path)}, subtree=#{inspect(subtree)}, tree=#{inspect(tree)}"
        )
    after
      timeout -> :ok
    end
  end

  @doc """
  Captures all terminal output during a test.
  """
  def capture_terminal_output(fun) when is_function(fun, 0) do
    original_group_leader = Process.group_leader()
    {:ok, capture_pid} = StringIO.open("")
    Process.group_leader(self(), capture_pid)

    result =
      Raxol.Core.ErrorHandling.ensure_cleanup(
        fn ->
          fun.()
          {_input, output} = StringIO.contents(capture_pid)
          output
        end,
        fn ->
          Process.group_leader(self(), original_group_leader)
          StringIO.close(capture_pid)
        end
      )

    case result do
      {:ok, output} -> output
      {:error, _} -> ""
    end
  end

  # =============================================================================
  # WINDOW & TERMINAL ASSERTIONS
  # =============================================================================

  @doc """
  Asserts window size matches expected dimensions.
  """
  def assert_window_size(emulator, expected_width, expected_height) do
    assert emulator.window_state.size == {expected_width, expected_height}

    # Calculate expected pixel dimensions
    char_width_px =
      Raxol.Terminal.Commands.WindowHandler.default_char_width_px()

    char_height_px =
      Raxol.Terminal.Commands.WindowHandler.default_char_height_px()

    expected_pixel_width = expected_width * char_width_px
    expected_pixel_height = expected_height * char_height_px

    assert emulator.window_state.size_pixels ==
             {expected_pixel_width, expected_pixel_height}
  end

  # =============================================================================
  # TEST DATA GENERATION
  # =============================================================================

  @doc """
  Creates a test plugin for testing purposes.
  """
  def create_test_plugin(name, config \\ %{}) do
    %{
      name: name,
      module: String.to_atom("TestPlugin.#{name}"),
      config: config,
      enabled: true
    }
  end

  @doc """
  Creates a test plugin module for testing.
  """
  def create_test_plugin_module(name, callbacks \\ %{}) do
    SharedUtilities.create_test_plugin_module(name, callbacks)
  end

  @doc """
  Creates a test emulator instance for testing.
  """
  def create_test_emulator do
    Raxol.Terminal.Emulator.new(80, 24)
  end

  @doc """
  Creates a test emulator instance with custom settings.
  """
  def create_test_emulator(opts) when is_list(opts) do
    emulator = create_test_emulator()

    Enum.reduce(opts, emulator, fn {key, value}, acc ->
      case key do
        :settings -> set_settings(acc, value)
        :preferences -> set_preferences(acc, value)
        :environment -> set_environment(acc, value)
        _ -> acc
      end
    end)
  end

  @doc """
  Creates a test emulator instance with a struct cursor instead of a PID.
  """
  def create_test_emulator_with_struct_cursor do
    emulator = Raxol.Terminal.Emulator.new(80, 24)

    # Create a struct cursor instead of using the PID cursor
    struct_cursor = %Raxol.Terminal.Cursor.Manager{
      row: 0,
      col: 0,
      style: :blink_block,
      visible: true
    }

    %{emulator | cursor: struct_cursor}
  end

  @doc """
  Generates comprehensive test events for common scenarios.
  Returns both simple list format and categorized map format.
  """
  def test_events(format \\ :categorized) do
    case format do
      :simple ->
        [
          {:key, %{key: :enter}},
          {:mouse, %{x: 10, y: 5, button: :left}},
          {:resize, %{width: 100, height: 50}}
        ]

      :categorized ->
        %{
          keyboard: [
            Event.key(:enter),
            Event.key(:esc),
            Event.key({:char, ?a}),
            Event.key(:tab)
          ],
          mouse: [
            Event.mouse(:left, {0, 0}),
            Event.mouse(:right, {10, 5}),
            Event.mouse(:left, {20, 10}, drag: true)
          ],
          window: [
            Event.window(80, 24, :resize),
            Event.window(100, 30, :resize),
            Event.window(80, 24, :focus)
          ]
        }
    end
  end

  @doc """
  Creates a test component with comprehensive state normalization.
  """
  def create_test_component(module, opts \\ %{}) do
    # Handle both simple and complex component creation
    state =
      if function_exported?(module, :new, 1) do
        result = module.new(opts)

        case result do
          {:ok, actual_state} -> actual_state
          actual_state -> actual_state
        end
      else
        Map.merge(%{module: module}, opts)
      end

    # Normalize component state with comprehensive defaults
    normalized_state =
      state
      |> ensure_field(:style, %{})
      |> ensure_field(:disabled, false)
      |> ensure_field(:focused, false)
      |> normalize_component_attrs()

    # Return consistent component structure
    if Map.has_key?(state, :module) do
      # Advanced component structure
      %{
        module: module,
        state: normalized_state,
        subscriptions: [],
        rendered: nil
      }
    else
      # Simple component structure
      %{
        module: module,
        state: normalized_state,
        props: %{},
        children: []
      }
    end
  end

  @doc """
  Simulates a sequence of events on a component.
  """
  def simulate_event_sequence(component, events) when is_list(events) do
    Enum.reduce(events, {component, []}, fn event, {comp, all_commands} ->
      {updated_comp, commands} = Raxol.Test.Unit.simulate_event(comp, event)
      {updated_comp, all_commands ++ commands}
    end)
  end

  @doc """
  Generates test styles for component rendering.
  """
  def test_styles do
    %{
      default: %{
        color: :white,
        background: :black,
        bold: false,
        underline: false
      },
      highlighted: %{
        color: :yellow,
        background: :blue,
        bold: true,
        underline: false
      },
      error: %{
        color: :red,
        background: :black,
        bold: true,
        underline: true
      }
    }
  end

  @doc """
  Generates test layouts for component positioning.
  """
  def test_layouts do
    %{
      full_screen: %{
        x: 0,
        y: 0,
        width: 80,
        height: 24
      },
      centered: %{
        x: 20,
        y: 5,
        width: 40,
        height: 14
      },
      sidebar: %{
        x: 0,
        y: 0,
        width: 20,
        height: 24
      }
    }
  end

  @doc """
  Returns a complete theme struct for tests, merging any overrides provided.
  """
  def test_theme(overrides \\ %{}) do
    base = Raxol.UI.Theming.Theme.default_theme()

    # Merge overrides deeply for component_styles
    override_styles = Map.get(overrides, :component_styles, %{})

    merged_styles =
      Map.merge(base.component_styles, override_styles, fn _k, v1, v2 ->
        Map.merge(v1, v2)
      end)

    # Ensure all keys from base are present
    merged_styles = Map.merge(base.component_styles, merged_styles)

    base
    |> Map.merge(overrides)
    |> Map.put(:component_styles, merged_styles)
  end

  # =============================================================================
  # FILE & DIRECTORY UTILITIES
  # =============================================================================

  @doc """
  Creates a temporary directory for test files.
  """
  def create_temp_dir do
    dir = Path.join(System.tmp_dir!(), "raxol_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Cleans up a temporary directory.
  """
  def cleanup_temp_dir(dir) do
    File.rm_rf!(dir)
  end

  # =============================================================================
  # ADVANCED UTILITIES
  # =============================================================================

  @doc """
  Waits for a condition to be true, with a timeout.
  Uses event-based synchronization instead of Process.sleep.
  """
  def wait_for_state(condition_fun, timeout_ms \\ 100) do
    start = System.monotonic_time(:millisecond)
    do_wait_for_state(condition_fun, start, timeout_ms)
  end

  # =============================================================================
  # PRIVATE HELPER FUNCTIONS
  # =============================================================================

  # Terminal emulator configuration helpers
  defp set_settings(emulator, settings) do
    Enum.reduce(settings, emulator, fn {key, value}, acc ->
      Raxol.Terminal.Config.Manager.set_setting(acc, key, value)
    end)
  end

  defp set_preferences(emulator, preferences) do
    Enum.reduce(preferences, emulator, fn {key, value}, acc ->
      Raxol.Terminal.Config.Manager.set_preference(acc, key, value)
    end)
  end

  defp set_environment(emulator, env) do
    Raxol.Terminal.Config.Manager.set_environment_variables(emulator, env)
  end

  # Component state normalization helpers
  defp ensure_field(state, field, default) do
    case Map.has_key?(state, field) do
      true -> state
      false -> Map.put(state, field, default)
    end
  end

  defp normalize_component_attrs(state) do
    attrs = Map.get(state, :attrs, %{})
    normalized_attrs = normalize_attrs(attrs)
    Map.put(state, :attrs, normalized_attrs)
  end

  defp normalize_attrs(attrs) do
    cond do
      is_list(attrs) -> Map.new(attrs)
      is_map(attrs) -> attrs
      true -> %{}
    end
  end

  # Wait condition implementation
  defp do_wait_for_state(condition_fun, start, timeout_ms) do
    case condition_fun.() do
      true ->
        :ok

      false ->
        case System.monotonic_time(:millisecond) - start < timeout_ms do
          true ->
            timer_id = System.unique_integer([:positive])
            Process.send_after(self(), {:check_condition, timer_id}, 100)

            receive do
              {:check_condition, ^timer_id} ->
                do_wait_for_state(condition_fun, start, timeout_ms)
            after
              timeout_ms ->
                flunk("Condition not met within #{timeout_ms}ms")
            end

          false ->
            flunk("Condition not met within #{timeout_ms}ms")
        end
    end
  end
end
