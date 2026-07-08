defmodule Raxol.System.Updater.State.UpdaterServer do
  @moduledoc """
  GenServer implementation for the System Updater state management.

  This server manages update settings, progress tracking, statistics,
  and logging while eliminating Process dictionary usage.

  ## Features
  - Update settings management
  - Progress tracking for active updates
  - Update history and statistics
  - Error tracking and logging
  - Supervised state management
  """

  use Raxol.Core.Behaviours.BaseManager

  @update_settings_file "~/.raxol/update_settings.json"

  # Client API

  # start_link is provided by BaseManager

  #  def start_link(opts \\ []) do
  #    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  #  end

  @doc """
  Returns a child specification for this server.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # Public API

  def get_update_settings do
    GenServer.call(__MODULE__, :get_update_settings)
  end

  def set_update_settings(settings) do
    GenServer.call(__MODULE__, {:set_update_settings, settings})
  end

  def get_update_history do
    GenServer.call(__MODULE__, :get_update_history)
  end

  def clear_update_history do
    GenServer.call(__MODULE__, :clear_update_history)
  end

  def get_update_progress do
    GenServer.call(__MODULE__, :get_update_progress)
  end

  def set_update_progress(progress) do
    GenServer.call(__MODULE__, {:set_update_progress, progress})
  end

  def cancel_update do
    GenServer.call(__MODULE__, :cancel_update)
  end

  def set_update_pid(pid) do
    GenServer.call(__MODULE__, {:set_update_pid, pid})
  end

  def get_update_error do
    GenServer.call(__MODULE__, :get_update_error)
  end

  def set_update_error(error) do
    GenServer.call(__MODULE__, {:set_update_error, error})
  end

  def clear_update_error do
    GenServer.call(__MODULE__, :clear_update_error)
  end

  def get_update_log do
    GenServer.call(__MODULE__, :get_update_log)
  end

  def clear_update_log do
    GenServer.call(__MODULE__, :clear_update_log)
  end

  def log_update(message) do
    GenServer.cast(__MODULE__, {:log_update, message})
  end

  def get_update_stats do
    GenServer.call(__MODULE__, :get_update_stats)
  end

  def clear_update_stats do
    GenServer.call(__MODULE__, :clear_update_stats)
  end

  def update_stats(stats) do
    GenServer.call(__MODULE__, {:update_stats, stats})
  end

  def set_auto_check(enabled) do
    GenServer.call(__MODULE__, {:set_auto_check, enabled})
  end

  # Server Callbacks

  @impl true
  def init_manager(_opts) do
    # Load settings from file or use defaults
    settings = load_or_default_settings()

    state = %{
      settings: settings,
      update_progress: 0,
      update_pid: nil,
      update_error: nil,
      history: [],
      stats: default_stats()
    }

    # Load history and stats from disk
    state = load_persisted_state(state)

    {:ok, state}
  end

  # Handle settings retrieval
  @impl true
  def handle_manager_call(:get_update_settings, _from, state) do
    {:reply, state.settings, state}
  end

  @impl true
  def handle_manager_call({:set_update_settings, settings}, _from, state) do
    # Save to disk
    case save_update_settings(settings) do
      :ok ->
        {:reply, :ok, %{state | settings: settings}}

      error ->
        {:reply, error, state}
    end
  end

  # Handle history management
  @impl true
  def handle_manager_call(:get_update_history, _from, state) do
    history = load_history(state.settings)
    {:reply, {:ok, history}, %{state | history: history}}
  end

  @impl true
  def handle_manager_call(:clear_update_history, _from, state) do
    history_file =
      Path.join(state.settings.download_path, "update_history.json")

    case File.write(history_file, Jason.encode!([])) do
      :ok ->
        {:reply, :ok, %{state | history: []}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Handle progress tracking
  @impl true
  def handle_manager_call(:get_update_progress, _from, state) do
    {:reply, state.update_progress, state}
  end

  @impl true
  def handle_manager_call({:set_update_progress, progress}, _from, state) do
    {:reply, :ok, %{state | update_progress: progress}}
  end

  @impl true
  def handle_manager_call({:set_update_pid, pid}, _from, state) do
    {:reply, :ok, %{state | update_pid: pid}}
  end

  @impl true
  def handle_manager_call(:cancel_update, _from, state) do
    case state.update_pid do
      nil ->
        {:reply, {:error, :no_update_in_progress}, state}

      pid ->
        Process.exit(pid, :normal)
        {:reply, :ok, %{state | update_pid: nil, update_progress: 0}}
    end
  end

  # Handle error tracking
  @impl true
  def handle_manager_call(:get_update_error, _from, state) do
    {:reply, state.update_error, state}
  end

  @impl true
  def handle_manager_call({:set_update_error, error}, _from, state) do
    {:reply, :ok, %{state | update_error: error}}
  end

  @impl true
  def handle_manager_call(:clear_update_error, _from, state) do
    {:reply, :ok, %{state | update_error: nil}}
  end

  # Handle logging
  @impl true
  def handle_manager_call(:get_update_log, _from, state) do
    log_file = Path.join(state.settings.download_path, "update.log")

    result =
      case File.read(log_file) do
        {:ok, content} -> {:ok, String.split(content, "\n", trim: true)}
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_manager_call(:clear_update_log, _from, state) do
    log_file = Path.join(state.settings.download_path, "update.log")

    result =
      case File.write(log_file, "") do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  # Handle statistics
  @impl true
  def handle_manager_call(:get_update_stats, _from, state) do
    stats = load_stats(state.settings)
    {:reply, {:ok, stats}, %{state | stats: stats}}
  end

  @impl true
  def handle_manager_call(:clear_update_stats, _from, state) do
    stats_file = Path.join(state.settings.download_path, "update_stats.json")
    new_stats = default_stats()

    case File.write(stats_file, Jason.encode!(new_stats)) do
      :ok ->
        {:reply, :ok, %{state | stats: new_stats}}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_manager_call({:update_stats, stats}, _from, state) do
    stats_file = Path.join(state.settings.download_path, "update_stats.json")

    case File.write(stats_file, Jason.encode!(stats)) do
      :ok ->
        {:reply, :ok, %{state | stats: stats}}

      error ->
        {:reply, error, state}
    end
  end

  # Handle auto-check setting
  @impl true
  def handle_manager_call({:set_auto_check, enabled}, _from, state)
      when is_boolean(enabled) do
    updated_settings = Map.put(state.settings, :auto_check, enabled)

    case save_update_settings(updated_settings) do
      :ok ->
        {:reply, :ok, %{state | settings: updated_settings}}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_manager_cast({:log_update, message}, state) do
    log_file = Path.join(state.settings.download_path, "update.log")
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    log_entry = "[#{timestamp}] #{message}\n"

    _ = File.write(log_file, log_entry, [:append])

    {:noreply, state}
  end

  # Private helper functions

  defp load_or_default_settings do
    file_path = Path.expand(@update_settings_file)

    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, settings} -> settings
          _ -> default_update_settings()
        end

      _ ->
        default_update_settings()
    end
  end

  defp default_update_settings do
    %{
      auto_update: true,
      # 24 hours in seconds
      check_interval: 24 * 60 * 60,
      update_channel: :stable,
      notify_on_update: true,
      download_path: System.get_env("HOME") <> "/.raxol/downloads",
      backup_path: System.get_env("HOME") <> "/.raxol/backups",
      max_backups: 5,
      retry_count: 3,
      # seconds
      retry_delay: 5,
      # seconds
      timeout: 300,
      verify_checksums: true,
      require_confirmation: true
    }
  end

  defp save_update_settings(settings) do
    file_path = Path.expand(@update_settings_file)

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(file_path))

    case Jason.encode(settings) do
      {:ok, json} ->
        File.write(file_path, json)

      error ->
        error
    end
  end

  defp load_persisted_state(state) do
    history = load_history(state.settings)
    stats = load_stats(state.settings)

    %{state | history: history, stats: stats}
  end

  defp load_history(settings) do
    history_file = Path.join(settings.download_path, "update_history.json")

    case File.read(history_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, history} -> history
          _ -> []
        end

      _ ->
        []
    end
  end

  defp load_stats(settings) do
    stats_file = Path.join(settings.download_path, "update_stats.json")

    case File.read(stats_file) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, stats} -> stats
          _ -> default_stats()
        end

      _ ->
        default_stats()
    end
  end

  defp default_stats do
    %{
      total_updates: 0,
      successful_updates: 0,
      failed_updates: 0,
      last_update: nil,
      average_update_time: 0
    }
  end
end
