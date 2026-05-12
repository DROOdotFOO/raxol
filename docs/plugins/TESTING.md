# Plugin Testing

Guide to testing Raxol plugins -- unit, integration, and property-based approaches.

## Setup

### Dependencies

```elixir
# In your plugin's mix.exs
defp deps do
  [
    {:raxol, "~> 2.4", only: [:dev, :test]},
    {:mox, "~> 1.0", only: :test}  # For mocking
  ]
end
```

### Test Configuration

```elixir
# config/test.exs
import Config

config :logger, level: :warning

config :raxol, :test_mode, true

config :my_plugin,
  test_data_path: "test/fixtures",
  mock_external_services: true
```

## Unit Tests

### Manifest and Structure

```elixir
defmodule MyPluginTest do
  use ExUnit.Case, async: true

  alias MyPlugin

  describe "plugin manifest" do
    test "returns valid manifest structure" do
      manifest = MyPlugin.manifest()

      assert is_binary(manifest.id)
      assert is_binary(manifest.name)
      assert is_binary(manifest.version)
      assert is_binary(manifest.author)
      assert is_atom(manifest.module)
      assert is_list(manifest.depends_on)
      assert is_list(manifest.provides)
      assert Enum.all?(manifest.provides, &is_atom/1)
    end

    test "version follows semantic versioning" do
      manifest = MyPlugin.manifest()
      assert Regex.match?(~r/^\d+\.\d+\.\d+(-[\w\d\.-]+)?$/, manifest.version)
    end
  end

  describe "plugin lifecycle" do
    test "initializes with valid config" do
      config = %{
        enabled: true,
        debug: false,
        custom_setting: "value"
      }

      assert {:ok, state} = MyPlugin.init(config)

      assert state.config == config
      assert is_boolean(state.enabled)
    end

    test "handles enable/disable transitions" do
      config = %{enabled: true}
      {:ok, initial_state} = MyPlugin.init(config)

      assert {:ok, enabled_state} = MyPlugin.enable(initial_state)
      assert enabled_state.enabled == true

      assert enabled_state.timers != []
      assert enabled_state.subscriptions != []

      assert {:ok, disabled_state} = MyPlugin.disable(enabled_state)
      assert disabled_state.enabled == false

      assert disabled_state.timers == []
      assert disabled_state.subscriptions == []
    end

    test "terminates cleanly" do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)
      {:ok, enabled_state} = MyPlugin.enable(state)

      assert :ok = MyPlugin.terminate(:normal, enabled_state)
    end

    test "handles error conditions during lifecycle" do
      invalid_config = %{required_field: nil}

      case MyPlugin.init(invalid_config) do
        {:ok, _state} ->
          :ok
        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end
    end
  end
end
```

### Command Handling

```elixir
defmodule MyPluginCommandTest do
  use ExUnit.Case, async: true

  alias MyPlugin

  setup do
    config = %{enabled: true, debug: false}
    {:ok, initial_state} = MyPlugin.init(config)
    {:ok, state} = MyPlugin.enable(initial_state)

    on_exit(fn ->
      MyPlugin.terminate(:normal, state)
    end)

    {:ok, state: state}
  end

  describe "command declarations" do
    test "declares available commands" do
      commands = MyPlugin.get_commands()

      assert is_list(commands)

      Enum.each(commands, fn {name, function, arity} ->
        assert is_atom(name)
        assert is_atom(function)
        assert is_integer(arity) and arity >= 0

        assert function_exported?(MyPlugin, function, arity)
      end)
    end

    test "command names are unique" do
      commands = MyPlugin.get_commands()
      command_names = Enum.map(commands, fn {name, _, _} -> name end)

      assert length(command_names) == length(Enum.uniq(command_names)),
        "Duplicate command names found"
    end
  end

  describe "command execution" do
    test "handles valid commands", %{state: state} do
      commands = MyPlugin.get_commands()

      Enum.each(commands, fn {name, _, _} ->
        case MyPlugin.handle_command(name, [], state) do
          {:ok, new_state, result} ->
            assert is_map(new_state)
            assert result != nil

          {:error, reason, error_state} ->
            assert is_binary(reason) or is_atom(reason)
            assert is_map(error_state)
        end
      end)
    end

    test "handles invalid commands", %{state: state} do
      invalid_commands = [:nonexistent, :invalid_cmd, :unknown]

      Enum.each(invalid_commands, fn cmd ->
        result = MyPlugin.handle_command(cmd, [], state)
        assert match?({:error, _, _}, result)
      end)
    end

    test "handles command with arguments", %{state: state} do
      test_cases = [
        {:search, ["query", "term"]},
        {:set_config, [%{setting: "value"}]},
        {:execute, ["action", %{param: 1}]}
      ]

      Enum.each(test_cases, fn {command, args} ->
        case MyPlugin.handle_command(command, args, state) do
          {:ok, _new_state, _result} -> :ok
          {:error, _reason, _state} -> :ok
        end
      end)
    end
  end

  describe "command state management" do
    test "commands preserve state integrity", %{state: initial_state} do
      commands_sequence = [
        {:init_data, []},
        {:add_item, ["test_item"]},
        {:get_status, []},
        {:clear_data, []}
      ]

      final_state =
        Enum.reduce(commands_sequence, initial_state, fn {cmd, args}, state ->
          case MyPlugin.handle_command(cmd, args, state) do
            {:ok, new_state, _result} -> new_state
            {:error, _reason, error_state} -> error_state
          end
        end)

      assert is_map(final_state)
      assert Map.has_key?(final_state, :config)
    end

    test "commands handle concurrent access", %{state: state} do
      tasks =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            MyPlugin.handle_command(:get_status, [i], state)
          end)
        end)

      results = Task.await_many(tasks, 5000)

      Enum.each(results, fn result ->
        assert match?({:ok, _state, _result}, result) or
               match?({:error, _reason, _state}, result)
      end)
    end
  end
end
```

### Event Filtering

```elixir
defmodule MyPluginEventTest do
  use ExUnit.Case, async: true

  alias MyPlugin

  setup do
    config = %{enabled: true}
    {:ok, state} = MyPlugin.init(config)
    {:ok, state: state}
  end

  describe "event filtering" do
    test "passes through unhandled events", %{state: state} do
      unhandled_events = [
        {:key_press, "a"},
        {:mouse_click, {10, 20}},
        {:terminal_resize, {80, 24}},
        {:custom_event, "data"}
      ]

      Enum.each(unhandled_events, fn event ->
        result = MyPlugin.filter_event(event, state)
        assert {:ok, ^event} = result
      end)
    end

    test "handles plugin-specific events", %{state: state} do
      plugin_events = [
        {:key_press, "ctrl+p"},
        {:key_press, "escape"},
        {:file_change, "/path/to/file"}
      ]

      Enum.each(plugin_events, fn event ->
        result = MyPlugin.filter_event(event, state)

        case result do
          {:ok, modified_event} ->
            assert modified_event != event
          :halt ->
            :ok
          {:error, reason} ->
            assert is_binary(reason)
        end
      end)
    end

    test "can halt event propagation", %{state: state} do
      halt_events = [
        {:key_press, "F12"},
        {:plugin_internal_event, "data"}
      ]

      Enum.each(halt_events, fn event ->
        case MyPlugin.filter_event(event, state) do
          :halt -> :ok
          {:ok, _modified_event} -> :ok
          other -> flunk("Unexpected result for halt event: #{inspect(other)}")
        end
      end)
    end

    test "maintains state consistency during event filtering", %{state: state} do
      events = [
        {:key_press, "j"},
        {:key_press, "k"},
        {:key_press, "enter"},
        {:key_press, "escape"}
      ]

      final_state =
        Enum.reduce(events, state, fn event, current_state ->
          case MyPlugin.filter_event(event, current_state) do
            {:ok, _event} -> current_state
            :halt -> current_state
            {:error, _reason} -> current_state
          end
        end)

      assert final_state == state
    end
  end

  describe "event performance" do
    test "event filtering is performant", %{state: state} do
      event = {:key_press, "a"}

      {time_microseconds, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            MyPlugin.filter_event(event, state)
          end)
        end)

      # 1000 events should complete in under 10ms
      assert time_microseconds < 10_000,
        "Event filtering too slow: #{time_microseconds} microseconds"
    end

    test "handles high-frequency events", %{state: state} do
      high_freq_events = [
        {:mouse_move, {1, 1}},
        {:mouse_move, {2, 2}},
        {:mouse_move, {3, 3}},
        {:scroll, :up},
        {:scroll, :down}
      ]

      Enum.each(high_freq_events, fn event ->
        assert {:ok, _} = MyPlugin.filter_event(event, state)
      end)
    end
  end
end
```

## Integration Tests

### Plugin System Integration

```elixir
defmodule MyPluginIntegrationTest do
  use ExUnit.Case

  alias Raxol.Core.Runtime.Plugins.PluginManager

  @moduletag :integration

  setup do
    {:ok, _pid} = PluginManager.start_link(test_mode: true)

    on_exit(fn ->
      try do
        PluginManager.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "plugin loading" do
    test "plugin can be loaded into system" do
      plugin_manifest = MyPlugin.manifest()

      result = PluginManager.load_plugin("my-plugin", %{
        manifest: plugin_manifest,
        module: MyPlugin
      })

      assert :ok = result

      {:ok, status} = PluginManager.get_plugin_status("my-plugin")
      assert status.status in [:loaded, :running]
    end

    test "plugin dependencies are resolved" do
      manifest = MyPlugin.manifest()

      case PluginManager.resolve_dependencies(manifest) do
        {:ok, resolved} ->
          assert "raxol-core" in Map.keys(resolved)

        {:error, conflicts} ->
          assert is_list(conflicts)
          Enum.each(conflicts, fn conflict ->
            assert is_map(conflict)
            assert Map.has_key?(conflict, :plugin)
            assert Map.has_key?(conflict, :requirement)
          end)
      end
    end

    test "plugin hot reload works" do
      assert :ok = PluginManager.load_plugin("my-plugin")

      {:ok, initial_status} = PluginManager.get_plugin_status("my-plugin")

      assert :ok = PluginManager.hot_reload_plugin("my-plugin")

      {:ok, reloaded_status} = PluginManager.get_plugin_status("my-plugin")
      assert reloaded_status.status == :running
      assert reloaded_status.last_reload != initial_status.last_reload
    end
  end

  describe "command integration" do
    setup do
      PluginManager.load_plugin("my-plugin")
      :ok
    end

    test "plugin commands are registered" do
      commands = MyPlugin.get_commands()

      Enum.each(commands, fn {name, _, _} ->
        command_name = "my-plugin:#{name}"

        case Raxol.Commands.execute(command_name) do
          {:ok, _result} -> :ok
          {:error, :not_found} -> flunk("Command not registered: #{command_name}")
          {:error, _other} -> :ok
        end
      end)
    end
  end

  describe "performance monitoring" do
    setup do
      PluginManager.load_plugin("my-plugin")
      :ok
    end

    test "plugin performance is monitored" do
      {:ok, status} = PluginManager.get_plugin_status("my-plugin")

      assert is_map(status.performance_metrics)

      expected_metrics = [
        :memory_usage_mb,
        :cpu_usage_percent,
        :event_processing_time_ms,
        :command_execution_count
      ]

      Enum.each(expected_metrics, fn metric ->
        assert Map.has_key?(status.performance_metrics, metric),
          "Missing performance metric: #{metric}"
      end)
    end

    test "plugin stays within its resource budget" do
      manifest = MyPlugin.manifest()
      budget = Map.get(manifest, :resource_budget, %{})

      {:ok, status} = PluginManager.get_plugin_status("my-plugin")

      if max_mb = budget[:max_memory_mb] do
        assert status.performance_metrics.memory_usage_mb < max_mb
      end
    end
  end
end
```

### Terminal Integration

```elixir
defmodule MyPluginTerminalTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @moduletag :terminal_integration

  describe "terminal interaction" do
    test "plugin responds to terminal events" do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)

      terminal_events = [
        {:terminal_resize, {80, 24}},
        {:terminal_focus, true},
        {:terminal_focus, false}
      ]

      Enum.each(terminal_events, fn event ->
        case MyPlugin.filter_event(event, state) do
          {:ok, _modified_event} -> :ok
          :halt -> :ok
          {:error, reason} ->
            flunk("Plugin failed to handle terminal event #{inspect(event)}: #{reason}")
        end
      end)
    end

  end
end
```

## Test Helpers

### Plugin Test Helper Module

```elixir
defmodule Raxol.PluginTestHelpers do
  @moduledoc """
  Helper functions for testing Raxol plugins.
  """

  def load_test_plugin(plugin_module, config \\ %{}) do
    {:ok, state} = plugin_module.init(config)
    {:ok, enabled_state} = plugin_module.enable(state)
    enabled_state
  end

  def unload_test_plugin(plugin_module, state) do
    {:ok, disabled_state} = plugin_module.disable(state)
    :ok = plugin_module.terminate(:normal, disabled_state)
  end

  def simulate_event(event, state, plugin_module) do
    case plugin_module.filter_event(event, state) do
      {:ok, _modified_event} -> state
      :halt -> state
      {:error, _reason} -> state
    end
  end

  def execute_command(command, args, state, plugin_module) do
    plugin_module.handle_command(command, args, state)
  end

  def assert_plugin_state(state, expected_status) do
    case expected_status do
      :running ->
        assert state.enabled == true
      :stopped ->
        assert state.enabled == false
      :initialized ->
        assert is_map(state)
        assert Map.has_key?(state, :config)
    end
  end

  def capture_plugin_output(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end

  def with_test_plugin(plugin_module, config \\ %{}, test_fun) do
    state = load_test_plugin(plugin_module, config)

    try do
      test_fun.(state)
    after
      unload_test_plugin(plugin_module, state)
    end
  end

  def assert_valid_manifest(manifest) do
    string_fields = [:id, :name, :version, :author]

    Enum.each(string_fields, fn field ->
      assert Map.has_key?(manifest, field), "Missing required field: #{field}"
      assert is_binary(Map.get(manifest, field)), "Field #{field} should be a string"
    end)

    assert is_atom(manifest.module), "module should be the plugin module atom"

    provides = Map.get(manifest, :provides, [])
    assert is_list(provides) and Enum.all?(provides, &is_atom/1)

    depends_on = Map.get(manifest, :depends_on, [])
    assert is_list(depends_on)
  end
end
```

### Mock and Fixture Support

```elixir
defmodule Raxol.PluginTestMocks do
  @moduledoc """
  Mock implementations for testing plugins.
  """

  use Mox

  defmock(MockHTTPoison, for: HTTPoisonBehaviour)
  defmock(MockFileSystem, for: FileSystemBehaviour)

  def mock_file_system do
    MockFileSystem
    |> expect(:ls, fn _path ->
      {:ok, ["file1.ex", "file2.ex", "dir1"]}
    end)
    |> expect(:stat, fn path ->
      {:ok, %{
        size: 1024,
        type: :regular,
        access: :read_write,
        atime: ~N[2025-09-26 12:00:00],
        mtime: ~N[2025-09-26 12:00:00],
        ctime: ~N[2025-09-26 12:00:00]
      }}
    end)
  end

  def mock_http_client do
    MockHTTPoison
    |> expect(:get, fn url ->
      case url do
        "http://api.example.com/data" ->
          {:ok, %{status_code: 200, body: "{\"data\": \"test\"}"}}
        _ ->
          {:ok, %{status_code: 404, body: "Not found"}}
      end
    end)
  end
end
```

## Property-Based Testing

```elixir
defmodule MyPluginPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias MyPlugin

  describe "property-based tests" do
    property "plugin handles arbitrary configuration" do
      check all config <- config_generator() do
        case MyPlugin.init(config) do
          {:ok, state} ->
            assert is_map(state)
            assert Map.has_key?(state, :config)

          {:error, reason} ->
            assert is_binary(reason) or is_atom(reason)
        end
      end
    end

    property "event filtering preserves event structure" do
      check all event <- event_generator() do
        config = %{enabled: true}
        {:ok, state} = MyPlugin.init(config)

        case MyPlugin.filter_event(event, state) do
          {:ok, filtered_event} ->
            assert is_tuple(filtered_event)
          :halt ->
            :ok
          {:error, _reason} ->
            :ok
        end
      end
    end

    property "commands with random args don't crash plugin" do
      check all {command, args} <- command_generator() do
        config = %{enabled: true}
        {:ok, state} = MyPlugin.init(config)

        case MyPlugin.handle_command(command, args, state) do
          {:ok, new_state, _result} ->
            assert is_map(new_state)
          {:error, _reason, error_state} ->
            assert is_map(error_state)
        end
      end
    end
  end

  # Generators
  defp config_generator do
    gen all enabled <- boolean(),
            debug <- boolean(),
            timeout <- integer(1..10000),
            name <- string(:ascii, min_length: 1, max_length: 50) do
      %{
        enabled: enabled,
        debug: debug,
        timeout: timeout,
        name: name
      }
    end
  end

  defp event_generator do
    one_of([
      {:key_press, string(:ascii, length: 1)},
      {:mouse_click, {integer(0..100), integer(0..50)}},
      {:terminal_resize, {integer(20..200), integer(10..100)}},
      {:file_change, string(:ascii, min_length: 1, max_length: 100)}
    ])
  end

  defp command_generator do
    gen all command <- atom(:alphanumeric),
            args <- list_of(term(), max_length: 5) do
      {command, args}
    end
  end
end
```

## Test File Organization

```
test/
├── my_plugin_test.exs                 # Unit tests
├── my_plugin_command_test.exs         # Command handling
├── my_plugin_event_test.exs           # Event filtering
├── my_plugin_integration_test.exs     # Integration tests
├── my_plugin_property_test.exs        # Property-based tests
├── support/
│   ├── plugin_test_helpers.exs
│   ├── mocks.exs
│   └── fixtures/
│       ├── sample_config.json
│       ├── test_data.txt
│       └── mock_responses/
└── performance/
    └── my_plugin_performance_test.exs
```

## CI Integration

```yaml
# .github/workflows/plugin_tests.yml
name: Plugin Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.15"
          otp-version: "26"

      - name: Install dependencies
        run: mix deps.get

      - name: Run plugin tests
        run: |
          TMPDIR=/tmp SKIP_TERMBOX2_TESTS=true mix test test/plugins/

      - name: Run integration tests
        run: |
          TMPDIR=/tmp SKIP_TERMBOX2_TESTS=true mix test --only integration

      - name: Check test coverage
        run: mix test --cover
```
