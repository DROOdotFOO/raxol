# Plugin Templates

Templates for common plugin types, based on existing plugins in the Raxol ecosystem.

## Basic Plugin Template

The minimal structure for a Raxol plugin:

```elixir
defmodule Raxol.Plugins.MyBasicPlugin do
  @moduledoc """
  Basic template for Raxol plugins.
  """

  use Raxol.Plugin

  require Logger

  def manifest do
    %{
      id: "my-basic-plugin",
      name: "My Basic Plugin",
      version: "1.0.0",
      author: "Your Name",
      module: __MODULE__,
      description: "A basic plugin template",
      depends_on: [],
      provides: [:command_handler]
    }
  end

  defstruct [:config, :enabled, :data]

  @impl true
  def init(config) do
    state = %__MODULE__{config: config, enabled: true, data: %{}}
    Logger.info("[MyBasicPlugin] Initialized")
    {:ok, state}
  end

  @impl true
  def handle_command(:hello, _args, state) do
    {:ok, state, "Hello from #{__MODULE__}!"}
  end

  def handle_command(command, _args, state) do
    {:error, "Unknown command: #{command}", state}
  end

  @impl true
  def get_commands, do: [{:hello, :handle_command, 1}]
end
```

## UI in Plugins

There is no UI rendering callback on the `Raxol.Core.Runtime.Plugins.Plugin` behaviour. Plugins do not render to the screen directly. Two ways to get UI from a plugin:

1. **Emit commands or events** that a host app or widget consumes (`handle_command/3` returns the third element as the result).
2. **Run a companion `Raxol.UI.Components.Base.Component`** in the app and let the plugin update its model via the command/event channel.

If you need to embed visible widgets, build them as components -- see [Custom Components](../cookbook/CUSTOM_COMPONENTS.md).

## Background Task Plugin Template

For plugins that run periodic updates:

```elixir
defmodule Raxol.Plugins.MyBackgroundPlugin do
  @moduledoc """
  Template for plugins that run background tasks and periodic updates.
  """

  use GenServer
  use Raxol.Plugin

  require Logger

  def manifest do
    %{
      id: "my-background-plugin",
      name: "My Background Plugin",
      version: "1.0.0",
      author: "Your Name",
      module: __MODULE__,
      description: "Background task plugin template",
      provides: [:status_line, :command_handler]
    }
  end

  defstruct [
    :config,
    :enabled,
    :update_timer,
    :last_update,
    :cached_data,
    :status_info
  ]

  # GenServer API
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  # Plugin behaviour callbacks
  def init(config) do
    state = %__MODULE__{
      config: config,
      enabled: false,
      update_timer: nil,
      last_update: nil,
      cached_data: %{},
      status_info: ""
    }

    {:ok, state}
  end

  def terminate(_reason, state) do
    if state.update_timer do
      :timer.cancel(state.update_timer)
    end
    :ok
  end

  def enable(state) do
    {:ok, timer} = :timer.send_interval(
      state.config.update_interval_ms,
      :update_data
    )

    send(self(), :update_data)

    new_state = %{state |
      enabled: true,
      update_timer: timer
    }

    Logger.info("[MyBackgroundPlugin] Background tasks started")
    {:ok, new_state}
  end

  def disable(state) do
    if state.update_timer do
      :timer.cancel(state.update_timer)
    end

    new_state = %{state |
      enabled: false,
      update_timer: nil
    }

    Logger.info("[MyBackgroundPlugin] Background tasks stopped")
    {:ok, new_state}
  end

  def handle_command(:status, _args, state) do
    status = generate_status_report(state)
    {:ok, state, status}
  end

  def handle_command(:refresh, _args, state) do
    send(self(), :update_data)
    {:ok, state, :refresh_requested}
  end

  def handle_command(:get_data, _args, state) do
    {:ok, state, state.cached_data}
  end

  def get_commands do
    [
      {:status, :handle_command, 3},
      {:refresh, :handle_command, 3},
      {:get_data, :handle_command, 3}
    ]
  end

  # GenServer callbacks for background processing
  @impl GenServer
  def handle_info(:update_data, state) do
    if state.enabled do
      new_data = collect_data(state.config)
      status_info = format_status_info(new_data)

      new_state = %{state |
        cached_data: new_data,
        status_info: status_info,
        last_update: DateTime.utc_now()
      }

      Logger.debug("[MyBackgroundPlugin] Data updated: #{inspect(new_data)}")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.warning("[MyBackgroundPlugin] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:get_status_info, _from, state) do
    {:reply, state.status_info, state}
  end

  @impl GenServer
  def handle_cast({:update_config, new_config}, state) do
    new_state = %{state | config: Map.merge(state.config, new_config)}
    {:noreply, new_state}
  end

  # Status line integration
  def get_status_line_info do
    try do
      GenServer.call(__MODULE__, :get_status_info, 1000)
    catch
      :exit, {:timeout, _} -> ""
      :exit, {:noproc, _} -> ""
    end
  end

  # Private functions
  defp collect_data(config) do
    case File.stat(config.watch_path) do
      {:ok, stat} ->
        %{
          path: config.watch_path,
          size: stat.size,
          modified: stat.mtime,
          type: stat.type
        }

      {:error, reason} ->
        %{
          path: config.watch_path,
          error: reason
        }
    end
  end

  defp format_status_info(%{error: reason}) do
    "Error: #{reason}"
  end

  defp format_status_info(%{path: path, size: size}) do
    "#{Path.basename(path)}: #{format_size(size)}"
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)}KB"
  defp format_size(bytes), do: "#{div(bytes, 1024 * 1024)}MB"

  defp generate_status_report(state) do
    %{
      enabled: state.enabled,
      last_update: state.last_update,
      cached_data: state.cached_data,
      config: state.config
    }
  end
end
```

## File System Plugin Template

For plugins that monitor file changes:

```elixir
defmodule Raxol.Plugins.MyFileSystemPlugin do
  @moduledoc """
  Template for plugins that interact with the file system and monitor changes.
  """

  use GenServer
  use Raxol.Plugin

  require Logger

  def manifest do
    %{
      id: "my-filesystem-plugin",
      name: "My FileSystem Plugin",
      version: "1.0.0",
      author: "Your Name",
      module: __MODULE__,
      description: "File system monitoring plugin template",
      provides: [:file_watcher, :command_handler]
    }
  end

  defstruct [
    :config,
    :watchers,
    :file_index,
    :recent_changes
  ]

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def init(config) do
    state = %__MODULE__{
      config: config,
      watchers: %{},
      file_index: %{},
      recent_changes: []
    }

    {:ok, state}
  end

  def terminate(_reason, state) do
    Enum.each(state.watchers, fn {_path, watcher} ->
      stop_file_watcher(watcher)
    end)
    :ok
  end

  def enable(state) do
    watchers =
      state.config.watch_directories
      |> Enum.reduce(%{}, fn dir, acc ->
        case start_file_watcher(dir, state.config) do
          {:ok, watcher} ->
            Map.put(acc, dir, watcher)
          {:error, reason} ->
            Logger.warning("Failed to watch #{dir}: #{reason}")
            acc
        end
      end)

    file_index = build_file_index(state.config)

    new_state = %{state |
      watchers: watchers,
      file_index: file_index
    }

    Logger.info("[MyFileSystemPlugin] Started watching #{map_size(watchers)} directories")
    {:ok, new_state}
  end

  def disable(state) do
    Enum.each(state.watchers, fn {_path, watcher} ->
      stop_file_watcher(watcher)
    end)

    new_state = %{state |
      watchers: %{},
      file_index: %{}
    }

    {:ok, new_state}
  end

  def handle_command(:list_files, [pattern], state) do
    files = find_files_by_pattern(state.file_index, pattern)
    {:ok, state, files}
  end

  def handle_command(:recent_changes, _args, state) do
    changes = Enum.take(state.recent_changes, 10)
    {:ok, state, changes}
  end

  def handle_command(:file_info, [path], state) do
    info = get_file_info(path, state.file_index)
    {:ok, state, info}
  end

  def get_commands do
    [
      {:list_files, :handle_command, 3},
      {:recent_changes, :handle_command, 3},
      {:file_info, :handle_command, 3}
    ]
  end

  @impl GenServer
  def handle_info({:file_event, path, events}, state) do
    new_state = process_file_events(path, events, state)
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.debug("[MyFileSystemPlugin] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp start_file_watcher(path, config) do
    watcher = spawn_link(fn ->
      file_watcher_loop(path, config, self())
    end)

    {:ok, watcher}
  end

  defp stop_file_watcher(watcher) when is_pid(watcher) do
    Process.exit(watcher, :normal)
  end

  defp file_watcher_loop(path, config, parent) do
    receive do
      :stop -> :ok
    after
      5000 ->
        case scan_directory(path, config) do
          {:changes, changes} ->
            Enum.each(changes, fn change ->
              send(parent, {:file_event, change.path, [:modified]})
            end)
          :no_changes ->
            :ok
        end
        file_watcher_loop(path, config, parent)
    end
  end

  defp build_file_index(config) do
    config.watch_directories
    |> Enum.reduce(%{}, fn dir, acc ->
      case scan_directory(dir, config) do
        {:files, files} ->
          Enum.reduce(files, acc, fn file, file_acc ->
            Map.put(file_acc, file.path, file)
          end)
        {:error, _reason} ->
          acc
      end
    end)
  end

  defp scan_directory(path, config) do
    try do
      files =
        Path.wildcard(Path.join(path, "**/*"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.filter(&matches_patterns?(&1, config.watch_patterns))
        |> Enum.reject(&matches_patterns?(&1, config.ignore_patterns))
        |> Enum.map(&create_file_entry/1)
        |> Enum.filter(fn file ->
          file.size_mb <= config.max_file_size_mb
        end)

      {:files, files}
    rescue
      error ->
        {:error, error}
    end
  end

  defp matches_patterns?(path, patterns) do
    Enum.any?(patterns, fn pattern ->
      String.contains?(path, String.replace(pattern, "*", ""))
    end)
  end

  defp create_file_entry(path) do
    stat = File.stat!(path)

    %{
      path: path,
      name: Path.basename(path),
      directory: Path.dirname(path),
      size: stat.size,
      size_mb: stat.size / (1024 * 1024),
      modified: stat.mtime,
      type: get_file_type(path)
    }
  end

  defp get_file_type(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir_script
      ".md" -> :markdown
      ".json" -> :json
      ".toml" -> :toml
      _ -> :other
    end
  end

  defp process_file_events(path, events, state) do
    change_entry = %{
      path: path,
      events: events,
      timestamp: DateTime.utc_now()
    }

    new_file_index = case :modified in events do
      true ->
        updated_entry = create_file_entry(path)
        Map.put(state.file_index, path, updated_entry)
      false ->
        state.file_index
    end

    new_recent_changes =
      [change_entry | state.recent_changes]
      |> Enum.take(50)

    %{state |
      file_index: new_file_index,
      recent_changes: new_recent_changes
    }
  end

  defp find_files_by_pattern(file_index, pattern) do
    file_index
    |> Enum.filter(fn {path, _info} ->
      String.contains?(String.downcase(path), String.downcase(pattern))
    end)
    |> Enum.map(fn {_path, info} -> info end)
    |> Enum.sort_by(& &1.modified, {:desc, DateTime})
  end

  defp get_file_info(path, file_index) do
    case Map.get(file_index, path) do
      nil -> {:error, :not_found}
      info -> {:ok, info}
    end
  end
end
```

## Testing Template

```elixir
defmodule MyPluginTest do
  use ExUnit.Case, async: true

  alias Raxol.Plugins.MyPlugin

  describe "plugin manifest" do
    test "returns valid manifest structure" do
      manifest = MyPlugin.manifest()

      assert is_binary(manifest.id)
      assert is_binary(manifest.name)
      assert is_binary(manifest.version)
      assert is_binary(manifest.author)
      assert is_atom(manifest.module)
      assert is_list(manifest.provides)
      assert is_list(manifest.depends_on)
    end
  end

  describe "plugin lifecycle" do
    test "initializes with valid config" do
      config = %{enabled: true, debug: false}

      assert {:ok, state} = MyPlugin.init(config)
      assert state.config == config
      assert is_boolean(state.enabled)
    end

    test "handles enable/disable cycle" do
      config = %{enabled: true}
      {:ok, initial_state} = MyPlugin.init(config)

      assert {:ok, enabled_state} = MyPlugin.enable(initial_state)
      assert enabled_state.enabled == true

      assert {:ok, disabled_state} = MyPlugin.disable(enabled_state)
      assert disabled_state.enabled == false
    end

    test "terminates cleanly" do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)

      assert :ok = MyPlugin.terminate(:normal, state)
    end
  end

  describe "command handling" do
    setup do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)
      {:ok, enabled_state} = MyPlugin.enable(state)

      {:ok, state: enabled_state}
    end

    test "handles hello command", %{state: state} do
      assert {:ok, new_state, result} = MyPlugin.handle_command(:hello, [], state)
      assert is_binary(result)
      assert String.contains?(result, "Hello")
      assert new_state.enabled == true
    end

    test "returns error for unknown command", %{state: state} do
      assert {:error, reason, _state} = MyPlugin.handle_command(:unknown, [], state)
      assert String.contains?(reason, "Unknown command")
    end

    test "declares available commands" do
      commands = MyPlugin.get_commands()
      assert is_list(commands)
      assert {:hello, :handle_command, 3} in commands
    end
  end

  describe "event filtering" do
    setup do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)
      {:ok, state: state}
    end

    test "passes through events by default", %{state: state} do
      event = {:key_press, "a"}
      assert {:ok, ^event} = MyPlugin.filter_event(event, state)
    end

    test "can modify events", %{state: state} do
      event = {:test_event, "data"}
      assert {:ok, filtered_event} = MyPlugin.filter_event(event, state)
      # Add assertions based on your plugin's behavior
    end
  end
end

# Integration test template
defmodule MyPluginIntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  setup do
    config = %{enabled: true, debug: true}
    {:ok, config: config}
  end

  test "plugin integrates with plugin system", %{config: config} do
    assert {:ok, _state} = MyPlugin.init(config)
  end

  test "plugin commands are accessible" do
    commands = MyPlugin.get_commands()

    Enum.each(commands, fn {name, function, arity} ->
      assert is_atom(name)
      assert is_atom(function)
      assert is_integer(arity)
      assert arity >= 0
    end)
  end
end
```

## How to Use These Templates

Pick the template that fits your needs:

- **Basic Plugin** -- Simple functionality, no UI
- **UI Plugin** -- Interactive overlays and panels
- **Background Plugin** -- Periodic tasks and monitoring
- **File System Plugin** -- File watching and directory operations

Then customize it: replace placeholder names, implement your logic, list your `provides:` capabilities, and declare any plugin `depends_on:` IDs.

Test everything. Use the test template as a starting point, cover all lifecycle states, verify command handling, and test event filtering if you implemented it.

A few things to keep in mind: clean up resources in `terminate/2`, handle errors without crashing, use appropriate log levels, and document what your plugin does.
