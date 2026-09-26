defmodule Raxol.System.Updater.State do
  @moduledoc """
  Refactored System Updater State module with GenServer-based state management.

  This module provides backward compatibility while eliminating Process dictionary usage.
  All state is now managed through the Updater.State.Server GenServer.

  ## Migration Notes

  This module replaces direct Process dictionary usage with supervised GenServer state.
  The API remains the same, but the implementation is now OTP-compliant and more robust.

  ## Features Maintained

  * Update settings management
  * Progress tracking for active updates
  * Update history and statistics
  * Error tracking and logging
  * Auto-update configuration
  """

  alias Raxol.System.Updater.State.UpdaterServer, as: Server

  # @update_settings_file "~/.raxol/update_settings.json"

  defp ensure_server_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      Server,
      fn -> GenServer.start(Server, [], name: Server) end
    )
  end

  @doc """
  Get the current update settings.
  """
  def get_update_settings do
    ensure_server_started()
    Server.get_update_settings()
  end

  @doc """
  Set the update settings.
  """
  def set_update_settings(settings) do
    ensure_server_started()
    Server.set_update_settings(settings)
  end

  @doc """
  Get the update history.
  """
  def get_update_history do
    ensure_server_started()
    Server.get_update_history()
  end

  @doc """
  Clear the update history.
  """
  def clear_update_history do
    ensure_server_started()
    Server.clear_update_history()
  end

  @doc """
  Get the current update progress (0-100).
  """
  def get_update_progress do
    ensure_server_started()
    Server.get_update_progress()
  end

  @doc """
  Set the update progress.
  """
  def set_update_progress(progress) do
    ensure_server_started()
    Server.set_update_progress(progress)
  end

  @doc """
  Cancel the current update operation.
  """
  def cancel_update do
    ensure_server_started()
    Server.cancel_update()
  end

  @doc """
  Get any error from the last update attempt.
  """
  def get_update_error do
    ensure_server_started()
    Server.get_update_error()
  end

  @doc """
  Set an update error.
  """
  def set_update_error(error) do
    ensure_server_started()
    Server.set_update_error(error)
  end

  @doc """
  Clear any update error.
  """
  def clear_update_error do
    ensure_server_started()
    Server.clear_update_error()
  end

  @doc """
  Get the update log.
  """
  def get_update_log do
    ensure_server_started()
    Server.get_update_log()
  end

  @doc """
  Clear the update log.
  """
  def clear_update_log do
    ensure_server_started()
    Server.clear_update_log()
  end

  @doc """
  Log an update message.
  """
  def log_update(message) do
    ensure_server_started()
    Server.log_update(message)
  end

  @doc """
  Get update statistics.
  """
  def get_update_stats do
    ensure_server_started()
    Server.get_update_stats()
  end

  @doc """
  Clear update statistics.
  """
  def clear_update_stats do
    ensure_server_started()
    Server.clear_update_stats()
  end

  @doc """
  Update the statistics.
  """
  def update_stats(stats) do
    ensure_server_started()
    Server.update_stats(stats)
  end

  @doc """
  Enable or disable automatic update checking.
  """
  def set_auto_check(enabled) when is_boolean(enabled) do
    ensure_server_started()
    Server.set_auto_check(enabled)
  end

  @doc """
  Returns the default update settings.
  This is provided for backward compatibility.
  """
  @spec default_update_settings() :: %{
          :auto_update => boolean(),
          :check_interval => pos_integer(),
          :update_channel => atom(),
          :notify_on_update => boolean(),
          :download_path => String.t(),
          :backup_path => String.t(),
          :max_backups => pos_integer(),
          :retry_count => non_neg_integer(),
          :retry_delay => pos_integer(),
          :timeout => pos_integer(),
          :require_confirmation => boolean()
        }
  def default_update_settings do
    %{
      auto_update: true,
      # 24 hours in seconds
      check_interval: 24 * 60 * 60,
      update_channel: :stable,
      notify_on_update: true,
      download_path: Path.expand("~/.raxol/downloads"),
      backup_path: Path.expand("~/.raxol/backups"),
      max_backups: 5,
      retry_count: 3,
      # seconds
      retry_delay: 5,
      # seconds
      timeout: 300,
      require_confirmation: true
    }
  end
end
