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
    {:ok, timer} =
      :timer.send_interval(
        state.config.update_interval_ms,
        :update_data
      )

    send(self(), :update_data)

    new_state = %{state | enabled: true, update_timer: timer}

    Logger.info("[MyBackgroundPlugin] Background tasks started")
    {:ok, new_state}
  end

  def disable(state) do
    if state.update_timer do
      :timer.cancel(state.update_timer)
    end

    new_state = %{state | enabled: false, update_timer: nil}

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

      new_state = %{
        state
        | cached_data: new_data,
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
