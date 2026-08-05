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

    new_state = %{state | watchers: watchers, file_index: file_index}

    Logger.info(
      "[MyFileSystemPlugin] Started watching #{map_size(watchers)} directories"
    )

    {:ok, new_state}
  end

  def disable(state) do
    Enum.each(state.watchers, fn {_path, watcher} ->
      stop_file_watcher(watcher)
    end)

    new_state = %{state | watchers: %{}, file_index: %{}}

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
    watcher =
      spawn_link(fn ->
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

    new_file_index =
      case :modified in events do
        true ->
          updated_entry = create_file_entry(path)
          Map.put(state.file_index, path, updated_entry)

        false ->
          state.file_index
      end

    new_recent_changes =
      [change_entry | state.recent_changes]
      |> Enum.take(50)

    %{state | file_index: new_file_index, recent_changes: new_recent_changes}
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
