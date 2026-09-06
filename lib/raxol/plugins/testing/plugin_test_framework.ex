# Two mock terminals exist in this file, deliberately, and they are NOT
# interchangeable:
#
#   * `Raxol.Plugins.Testing.StubTerminal` (below) is map-based. `new/3`
#     returns a plain map and every accessor is a map lookup.
#   * `Raxol.Plugins.Testing.MockTerminal` (further down) is a BaseManager
#     GenServer. `new/3` returns a pid and every accessor is a `GenServer.call`.
#
# `PluginTestFramework`'s own function bodies drive the StubTerminal, while the
# `__using__` macro aliases the GenServer MockTerminal into the consuming test
# module. Do not "consolidate" them without deciding which contract callers
# get -- a pid and a map do not substitute for each other.
#
# Both were previously `defmodule StubRunner`/`defmodule MockTerminal` at the
# top level, i.e. unnamespaced, which injected two generic names into the
# global module namespace of every application depending on raxol.
defmodule Raxol.Plugins.Testing.StubRunner do
  @moduledoc """
  Map-based stub plugin runner. See the note above about the two runners.
  """

  def load_plugin(terminal, _plugin_module, _config) do
    {:ok, terminal}
  end
end

defmodule Raxol.Plugins.Testing.StubTerminal do
  @moduledoc """
  Map-based stub terminal. See the note above about the two terminals.
  """

  def new(width, height, _opts) do
    %{
      width: width,
      height: height,
      buffer: %{},
      loaded_plugins: [],
      visible_panels: [],
      status_line: "",
      state: %{}
    }
  end

  def get_buffer(terminal) do
    terminal.buffer
  end

  def get_loaded_plugins(terminal) do
    terminal.loaded_plugins
  end

  def get_panel_content(_terminal, _plugin_name) do
    ""
  end

  def get_state(terminal) do
    terminal.state
  end

  def get_status_line(terminal) do
    terminal.status_line
  end

  def get_visible_panels(terminal) do
    terminal.visible_panels
  end

  def send_keypress(terminal, _key) do
    # Mock implementation
    {:ok, terminal}
  end
end

defmodule Raxol.Plugins.Testing.PluginTestFramework do
  @moduledoc """
  Plugin Testing Framework for Raxol

  Provides comprehensive testing utilities for plugin development including:
  - Plugin manifest validation
  - Mock terminal environments
  - UI rendering tests
  - Keyboard event simulation
  - Integration testing helpers
  - Performance benchmarking
  """

  # This module's own bodies drive the map-based stubs. The `__using__` macro
  # below aliases the GenServer `MockTerminal`/`PluginRunner` into the
  # CONSUMING test module instead; see the note at the top of this file.
  alias Raxol.Plugins.Testing.StubRunner
  alias Raxol.Plugins.Testing.StubTerminal

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, unquote(opts)
      import Raxol.Plugins.Testing.PluginTestFramework
      import Raxol.Plugins.Testing.Assertions
      import Raxol.Plugins.Testing.Helpers
      import Raxol.Plugins.Testing.FrameworkHelpers

      alias Raxol.Plugins.Testing.MockTerminal
      alias Raxol.Plugins.Testing.PluginRunner
    end
  end

  @doc """
  Validates a plugin manifest against the required schema
  """
  def validate_manifest(plugin_module) do
    manifest = plugin_module.manifest()

    with :ok <- validate_required_fields(manifest),
         :ok <- validate_field_types(manifest),
         :ok <- validate_capabilities(manifest),
         :ok <- validate_config_schema(manifest) do
      {:ok, manifest}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a mock terminal environment for testing
  """
  def create_mock_terminal(opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    StubTerminal.new(width, height, opts)
  end

  @doc """
  Loads a plugin in the test environment
  """
  def load_plugin(terminal, plugin_module, config \\ %{}) do
    case validate_manifest(plugin_module) do
      {:ok, _manifest} ->
        StubRunner.load_plugin(terminal, plugin_module, config)

      {:error, reason} ->
        {:error, {:invalid_manifest, reason}}
    end
  end

  @doc """
  Simulates a keypress event
  """
  def send_keypress(terminal, key) do
    StubTerminal.send_keypress(terminal, key)
  end

  @doc """
  Simulates multiple keypress events
  """
  def send_keypresses(terminal, keys) when is_list(keys) do
    Enum.each(keys, fn key ->
      _ = send_keypress(terminal, key)
      # Small delay to simulate realistic typing
      Process.sleep(10)
    end)
  end

  @doc """
  Gets the current terminal buffer content
  """
  def get_terminal_buffer(terminal) do
    StubTerminal.get_buffer(terminal)
  end

  @doc """
  Waits for a plugin to reach a specific state
  """
  def wait_for_state(plugin_pid, expected_state, timeout \\ 5000) do
    start_time = System.monotonic_time(:millisecond)

    wait_for_state_loop(plugin_pid, expected_state, start_time, timeout)
  end

  defp wait_for_state_loop(plugin_pid, expected_state, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time > timeout do
      {:error, :timeout}
    else
      current_state = GenServer.call(plugin_pid, :get_state)

      if states_match?(current_state, expected_state) do
        {:ok, current_state}
      else
        Process.sleep(50)
        wait_for_state_loop(plugin_pid, expected_state, start_time, timeout)
      end
    end
  end

  defp states_match?(current, expected) when is_map(expected) do
    Enum.all?(expected, fn {key, value} ->
      Map.get(current, key) == value
    end)
  end

  defp states_match?(current, expected), do: current == expected

  # Private validation functions

  defp validate_required_fields(manifest) do
    required = [:name, :version, :description, :author]

    missing =
      Enum.filter(required, fn field ->
        not Map.has_key?(manifest, field) or is_nil(Map.get(manifest, field))
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_fields, missing}}
    end
  end

  defp validate_field_types(manifest) do
    validations = [
      {:name, :string},
      {:version, :string},
      {:description, :string},
      {:author, :string},
      {:capabilities, :list},
      {:dependencies, :map},
      {:config_schema, :map}
    ]

    errors =
      Enum.flat_map(validations, fn {field, expected_type} ->
        value = Map.get(manifest, field)

        if value != nil and not type?(value, expected_type) do
          [{field, expected_type, typeof(value)}]
        else
          []
        end
      end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, {:type_errors, errors}}
    end
  end

  defp validate_capabilities(manifest) do
    valid_capabilities = [
      :ui_panel,
      :keyboard_input,
      :shell_command,
      :file_system,
      :file_watcher,
      :status_line,
      :theme_provider,
      :clipboard,
      :network
    ]

    capabilities = Map.get(manifest, :capabilities, [])

    invalid =
      Enum.filter(capabilities, fn cap ->
        cap not in valid_capabilities
      end)

    if Enum.empty?(invalid) do
      :ok
    else
      {:error, {:invalid_capabilities, invalid}}
    end
  end

  defp validate_config_schema(manifest) do
    case Map.get(manifest, :config_schema) do
      nil ->
        :ok

      schema when is_map(schema) ->
        validate_config_fields(schema)

      _ ->
        {:error, :invalid_config_schema}
    end
  end

  defp validate_config_fields(schema) do
    errors =
      Enum.flat_map(schema, fn {field_name, field_config} ->
        validate_config_field(field_name, field_config)
      end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, {:config_schema_errors, errors}}
    end
  end

  defp validate_config_field(field_name, field_config) do
    errors = []

    # Check required keys
    errors =
      case Map.has_key?(field_config, :type) do
        true -> errors
        false -> [{field_name, :missing_type} | errors]
      end

    # Check type validity
    errors =
      case Map.get(field_config, :type) do
        type when type in [:string, :integer, :boolean, :list, :map] -> errors
        type -> [{field_name, {:invalid_type, type}} | errors]
      end

    errors
  end

  defp type?(value, :string), do: is_binary(value)
  defp type?(value, :integer), do: is_integer(value)
  defp type?(value, :boolean), do: is_boolean(value)
  defp type?(value, :list), do: is_list(value)
  defp type?(value, :map), do: is_map(value)

  defp typeof(value) when is_binary(value), do: :string
  defp typeof(value) when is_integer(value), do: :integer
  defp typeof(value) when is_boolean(value), do: :boolean
  defp typeof(value) when is_list(value), do: :list
  defp typeof(value) when is_map(value), do: :map
  defp typeof(_), do: :unknown
end

defmodule Raxol.Plugins.Testing.FrameworkAssertions do
  @moduledoc """
  Custom assertions for plugin testing
  """

  import ExUnit.Assertions

  # Map-based stub, not the GenServer MockTerminal; see the note at the top.
  alias Raxol.Plugins.Testing.StubTerminal

  def assert_plugin_loaded(terminal, plugin_name) do
    loaded_plugins = StubTerminal.get_loaded_plugins(terminal)

    assert plugin_name in loaded_plugins,
           "Expected plugin '#{plugin_name}' to be loaded, but got: #{inspect(loaded_plugins)}"
  end

  def assert_panel_visible(terminal, plugin_name) do
    visible_panels = StubTerminal.get_visible_panels(terminal)

    assert plugin_name in visible_panels,
           "Expected panel for '#{plugin_name}' to be visible, but got: #{inspect(visible_panels)}"
  end

  def assert_panel_content(terminal, plugin_name, expected_content) do
    actual_content = StubTerminal.get_panel_content(terminal, plugin_name)

    case expected_content do
      content when is_binary(content) ->
        assert String.contains?(actual_content, content),
               "Expected panel content to contain '#{content}', but got: #{actual_content}"

      %Regex{} = regex ->
        assert Regex.match?(regex, actual_content),
               "Expected panel content to match #{inspect(regex)}, but got: #{actual_content}"

      content when is_list(content) ->
        Enum.each(content, fn line ->
          assert String.contains?(actual_content, line),
                 "Expected panel content to contain '#{line}', but got: #{actual_content}"
        end)
    end
  end

  def assert_status_line_contains(terminal, expected_text) do
    status_line = StubTerminal.get_status_line(terminal)

    assert String.contains?(status_line, expected_text),
           "Expected status line to contain '#{expected_text}', but got: '#{status_line}'"
  end

  def assert_keypress_handled(terminal, key) do
    # Send keypress and check if it was handled
    old_state = StubTerminal.get_state(terminal)
    _ = StubTerminal.send_keypress(terminal, key)
    new_state = StubTerminal.get_state(terminal)

    refute old_state == new_state,
           "Expected keypress '#{key}' to change terminal state, but it was ignored"
  end

  def assert_plugin_state(plugin_pid, expected_state) do
    actual_state = GenServer.call(plugin_pid, :get_state)

    case expected_state do
      state when is_map(state) ->
        Enum.each(state, fn {key, expected_value} ->
          actual_value = Map.get(actual_state, key)

          assert actual_value == expected_value,
                 "Expected plugin state.#{key} to be #{inspect(expected_value)}, but got #{inspect(actual_value)}"
        end)

      state ->
        assert actual_state == state,
               "Expected plugin state to be #{inspect(state)}, but got #{inspect(actual_state)}"
    end
  end

  def assert_plugin_output(plugin_pid, expected_output) do
    output = GenServer.call(plugin_pid, :get_output)

    assert output == expected_output,
           "Expected plugin output to be #{inspect(expected_output)}, but got #{inspect(output)}"
  end
end

defmodule Raxol.Plugins.Testing.FrameworkHelpers do
  @moduledoc """
  Test helper functions for common plugin testing scenarios.
  Note: This module provides additional helpers specific to the PluginTestFramework.
  For basic test helpers, see Raxol.Plugins.Testing.Helpers.
  """

  @doc """
  Creates a test config for git plugin testing with git-specific defaults.
  Returns as keyword list for compatibility with BaseManager.
  """
  def create_git_test_config(overrides \\ %{}) do
    default_config = %{
      enabled: true,
      hotkey: "ctrl+t",
      panel_width: 30,
      refresh_interval: 1000,
      auto_refresh: false,
      show_untracked: true,
      show_ignored: false,
      position: "right",
      graph_depth: 20,
      diff_context: 3
    }

    # Return as keyword list for compatibility with BaseManager
    default_config
    |> Map.merge(overrides)
    |> Map.to_list()
  end

  def simulate_file_change(plugin_pid, path, events \\ [:modified]) do
    GenServer.cast(plugin_pid, {:file_event, path, events})
  end

  def simulate_timer_tick(plugin_pid) do
    send(plugin_pid, :refresh)
  end

  def capture_plugin_logs(fun) do
    ExUnit.CaptureLog.capture_log(fun)
  end

  def with_temp_directory(fun) do
    # Force use of /tmp directly to avoid macOS symlink issues with /private/tmp
    temp_dir = Path.join("/tmp", "plugin_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(temp_dir)

    # Always use the real path to ensure git commands work properly
    real_temp_dir = Path.expand(temp_dir)

    try do
      fun.(real_temp_dir)
    after
      File.rm_rf!(temp_dir)
    end
  end

  def create_temp_directory do
    # Create temp directory but don't clean it up automatically
    temp_dir = Path.join("/tmp", "plugin_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)
    Path.expand(temp_dir)
  end

  def cleanup_temp_directory(temp_dir) do
    File.rm_rf!(temp_dir)
  end

  def create_test_files(base_path, file_specs) do
    Enum.each(file_specs, fn
      {path, :directory} ->
        File.mkdir_p!(Path.join(base_path, path))

      {path, content} when is_binary(content) ->
        full_path = Path.join(base_path, path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, content)
    end)
  end
end

defmodule Raxol.Plugins.Testing.MockTerminal do
  @moduledoc """
  Mock terminal implementation for plugin testing
  """

  use Raxol.Core.Behaviours.BaseManager

  defstruct [
    :width,
    :height,
    :buffer,
    :loaded_plugins,
    :visible_panels,
    :panel_contents,
    :status_line,
    :cursor_position,
    :state
  ]

  def new(width, height, opts \\ []) do
    {:ok, pid} = start_link({width, height, opts})
    pid
  end

  def send_keypress(terminal, key) do
    GenServer.cast(terminal, {:keypress, key})
  end

  def get_buffer(terminal) do
    GenServer.call(terminal, :get_buffer)
  end

  def get_loaded_plugins(terminal) do
    GenServer.call(terminal, :get_loaded_plugins)
  end

  def get_visible_panels(terminal) do
    GenServer.call(terminal, :get_visible_panels)
  end

  def get_panel_content(terminal, plugin_name) do
    GenServer.call(terminal, {:get_panel_content, plugin_name})
  end

  def get_status_line(terminal) do
    GenServer.call(terminal, :get_status_line)
  end

  def get_state(terminal) do
    GenServer.call(terminal, :get_state)
  end

  # BaseManager callbacks

  @impl true
  def init_manager({width, height, _opts}) do
    state = %__MODULE__{
      width: width,
      height: height,
      buffer: create_empty_buffer(width, height),
      loaded_plugins: [],
      visible_panels: [],
      panel_contents: %{},
      status_line: "",
      cursor_position: {0, 0},
      state: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call(:get_buffer, _from, state) do
    {:reply, state.buffer, state}
  end

  def handle_manager_call(:get_loaded_plugins, _from, state) do
    {:reply, state.loaded_plugins, state}
  end

  def handle_manager_call(:get_visible_panels, _from, state) do
    {:reply, state.visible_panels, state}
  end

  def handle_manager_call({:get_panel_content, plugin_name}, _from, state) do
    content = Map.get(state.panel_contents, plugin_name, "")
    {:reply, content, state}
  end

  def handle_manager_call(:get_status_line, _from, state) do
    {:reply, state.status_line, state}
  end

  def handle_manager_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_manager_cast({:keypress, key}, state) do
    # Simulate keypress handling
    new_state = handle_keypress_simulation(key, state)
    {:noreply, new_state}
  end

  def handle_manager_cast({:register_plugin, plugin_name, _pid}, state) do
    # Add plugin to loaded plugins list
    new_state = %{state | loaded_plugins: [plugin_name | state.loaded_plugins]}
    {:noreply, new_state}
  end

  defp create_empty_buffer(width, height) do
    for _y <- 0..(height - 1) do
      for _x <- 0..(width - 1) do
        %{char: " ", style: %{}}
      end
    end
  end

  defp handle_keypress_simulation(key, state) do
    # Update state to indicate keypress was handled
    new_internal_state = Map.put(state.state, :last_keypress, key)
    %{state | state: new_internal_state}
  end
end

defmodule Raxol.Plugins.Testing.PluginRunner do
  @moduledoc """
  Plugin runner for test environments
  """

  def load_plugin(terminal, plugin_module, config) do
    case plugin_module.start_link(config) do
      {:ok, pid} ->
        # Register plugin with mock terminal
        GenServer.cast(
          terminal,
          {:register_plugin, plugin_module.manifest().name, pid}
        )

        {:ok, pid}

      error ->
        error
    end
  end
end

defmodule Raxol.Plugins.Testing.BenchmarkHelper do
  @moduledoc """
  Benchmarking utilities for plugin performance testing
  """

  def benchmark_plugin_render(plugin_pid, iterations \\ 1000) do
    {time, _result} =
      :timer.tc(fn ->
        Enum.each(1..iterations, fn _ ->
          GenServer.call(plugin_pid, {:render_panel, 80, 24})
        end)
      end)

    time_per_iteration = time / iterations

    %{
      total_time: time,
      iterations: iterations,
      time_per_iteration: time_per_iteration,
      fps: 1_000_000 / time_per_iteration
    }
  end

  def benchmark_keypress_handling(plugin_pid, keys, iterations \\ 100) do
    {time, _result} =
      :timer.tc(fn ->
        Enum.each(1..iterations, fn _ ->
          send_all_keys(plugin_pid, keys)
        end)
      end)

    total_keypresses = length(keys) * iterations
    time_per_keypress = time / total_keypresses

    %{
      total_time: time,
      total_keypresses: total_keypresses,
      time_per_keypress: time_per_keypress
    }
  end

  defp send_all_keys(plugin_pid, keys) do
    Enum.each(keys, fn key ->
      GenServer.call(plugin_pid, {:handle_keypress, key})
    end)
  end
end
