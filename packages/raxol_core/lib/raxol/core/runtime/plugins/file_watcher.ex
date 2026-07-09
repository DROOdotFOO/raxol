defmodule Raxol.Core.Runtime.Plugins.FileWatcher do
  @moduledoc """
  Handles file watching and plugin reloading functionality.
  """


  @doc """
  Sets up file watching for plugin hot-reloading.
  """
  def setup_file_watching(config \\ %{}) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Setting up file watching for plugin hot-reloading",
      %{config: config}
    )

    # Merge the watch settings into the incoming config so callers keep their
    # own fields (e.g. plugin_dirs/plugins_dir) rather than having them dropped.
    watch_config =
      Map.merge(config, %{
        watch_directories: Map.get(config, :watch_directories, ["plugins/"]),
        debounce_ms: Map.get(config, :debounce_ms, 1000),
        file_patterns: Map.get(config, :file_patterns, ["*.ex"])
      })

    {:ok, watch_config}
  end

  @doc """
  Handles a file event.
  """
  def handle_file_event(path, state) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Handling file event for path: #{path}",
      %{path: path}
    )

    case extract_plugin_id_from_path(path) do
      {:ok, plugin_id} ->
        schedule_reload(plugin_id, path, state)

      {:error, reason} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[#{__MODULE__}] Could not extract plugin ID from path: #{path}",
          %{path: path, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Handles debounced file events.
  """
  def handle_debounced_events(plugin_id, plugin_path, state) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Handling debounced events for plugin: #{plugin_id}",
      %{plugin_id: plugin_id, plugin_path: plugin_path}
    )

    case Raxol.Core.Runtime.Plugins.PluginReloader.reload_plugin(
           plugin_id,
           state
         ) do
      {:ok, updated_state} ->
        {:ok, updated_state}

      {:error, reason, current_state} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to reload plugin: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, plugin_path: plugin_path}
        )

        {:error, reason, current_state}
    end
  end

  @doc """
  Schedules a plugin reload.
  """
  def schedule_reload(plugin_id, path, state) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Scheduling reload for plugin: #{plugin_id}",
      %{plugin_id: plugin_id, path: path}
    )

    # Cancel existing timer if any
    new_state =
      Raxol.Core.Runtime.Plugins.TimerManager.cancel_existing_timer(state)

    # Schedule new reload
    timer_ref =
      Process.send_after(
        self(),
        {:reload_plugin_file_debounced, plugin_id, path},
        # 1 second debounce
        1000
      )

    updated_state = %{new_state | file_event_timer: timer_ref}
    {:ok, updated_state}
  end

  # Helper function to extract plugin ID from file path
  @spec extract_plugin_id_from_path(String.t()) :: any()
  defp extract_plugin_id_from_path(path) do
    case Path.basename(path, ".ex") do
      filename when is_binary(filename) and byte_size(filename) > 0 ->
        {:ok, filename}

      _ ->
        {:error, :invalid_path}
    end
  end

  @doc """
  Starts the file watcher process.
  """
  def start_link(config \\ %{}) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Starting file watcher",
      %{config: config}
    )

    # For now, just return a mock PID
    # In a real implementation, this would start a GenServer or use a file system watcher
    {:ok, spawn(fn -> :ok end)}
  end

  @doc """
  Stops the file watcher process.
  """
  def stop(pid) when is_pid(pid) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Stopping file watcher",
      %{pid: pid}
    )

    # For now, just return :ok
    # In a real implementation, this would stop the watcher process
    :ok
  end

  @doc """
  Subscribes to file watcher events.
  """
  def subscribe(pid) when is_pid(pid) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Subscribing to file watcher events",
      %{pid: pid}
    )

    # For now, just return :ok
    # In a real implementation, this would subscribe the calling process to events
    :ok
  end
end
