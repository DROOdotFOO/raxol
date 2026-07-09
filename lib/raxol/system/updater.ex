defmodule Raxol.System.Updater do
  use Raxol.Core.Behaviours.BaseManager

  @moduledoc """
  Provides version management and self-update functionality for Raxol.

  This module handles:
  - Checking for updates from GitHub releases
  - Comparing versions to determine if updates are available
  - Self-updating the application when running as a compiled binary
  - Managing update settings and configurations
  """

  alias Raxol.System.Updater.{Core, Network, State, Validation}

  # --- Client API ---

  # start_link is provided by BaseManager

  def get_update_settings do
    State.get_update_settings()
  end

  def set_update_settings(settings) do
    State.set_update_settings(settings)
  end

  def default_update_settings do
    State.default_update_settings()
  end

  def download_update(version) do
    Core.download_update(version)
  end

  def install_update(context, version) do
    Core.install_update(context, version)
  end

  def handle_no_update(_context, {:no_update, _current_version}) do
    :ok
  end

  def rollback_update do
    Core.rollback_update()
  end

  def get_current_version do
    Core.get_current_version()
  end

  def get_available_versions do
    Core.get_available_versions()
  end

  def get_update_history do
    State.get_update_history()
  end

  def clear_update_history do
    State.clear_update_history()
  end

  def get_update_progress do
    State.get_update_progress()
  end

  def cancel_update do
    State.cancel_update()
  end

  def get_update_error do
    State.get_update_error()
  end

  def clear_update_error do
    State.clear_update_error()
  end

  def get_update_log do
    State.get_update_log()
  end

  def clear_update_log do
    State.clear_update_log()
  end

  def get_update_stats do
    State.get_update_stats()
  end

  def clear_update_stats do
    State.clear_update_stats()
  end

  def update(opts \\ []) do
    Core.update(opts)
  end

  # --- Server Callbacks ---

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    Core.init(opts)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:install_update, version}, from, state) do
    Core.handle_call({:install_update, version}, from, state)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_update_settings, from, state) do
    Core.handle_call(:get_update_settings, from, state)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_update_settings, settings}, from, state) do
    Core.handle_call({:set_update_settings, settings}, from, state)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:check_for_updates, from, state) do
    Core.handle_call(:check_for_updates, from, state)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_update_status, from, state) do
    Core.handle_call(:get_update_status, from, state)
  end

  # --- Public Helper Functions ---

  @doc """
  Checks if a newer version of Raxol is available.

  Returns a tuple with the check result and the latest version if available:
  - `{:no_update, current_version}` - No update available
  - `{:update_available, latest_version}` - Update available
  - `{:error, reason}` - Error occurred during check

  ## Parameters

  - `force`: When set to `true`, bypasses the update check interval. Defaults to `false`.

  ## Examples

      iex> Raxol.System.Updater.check_for_updates()
      {:no_update, "0.1.0"}

      iex> Raxol.System.Updater.check_for_updates(force: true)
      {:update_available, "0.2.0"}
  """
  def check_for_updates(opts \\ []) do
    force = Keyword.get(opts, :force, false)

    with {:ok, settings} <- get_update_settings(),
         true <- force || Validation.should_check_for_update?(settings),
         {:ok, latest_version} <- Network.fetch_latest_version() do
      _ = Validation.update_last_check(settings)
      {:ok, latest_version} |> Validation.compare_versions()
    else
      {:error, reason} -> {:error, reason}
      false -> {:no_update, Mix.Project.config()[:version]}
    end
  end

  @doc """
  Performs a self-update of the application if running as a compiled binary.

  Returns:
  - `:ok` - Update successfully completed
  - `{:error, reason}` - Error occurred during update
  - `{:no_update, current_version}` - No update needed

  ## Parameters

  - `version`: The version to update to. If not provided, updates to the latest version.
  - `opts`: Options for the update process:
    - `:use_delta`: Whether to try using delta updates (default: true)

  ## Examples

      iex> Raxol.System.Updater.self_update()
      :ok

      iex> Raxol.System.Updater.self_update("0.2.0")
      {:error, "Not running as a compiled binary"}
  """
  def self_update(version \\ nil, opts \\ []) do
    Core.self_update(version, opts)
  end

  @doc """
  Displays update information to the user, if an update is available.

  This function checks for updates (respecting the check interval) and
  outputs a message to the user if an update is available.

  ## Examples

      iex> Raxol.System.Updater.notify_if_update_available()
      :ok
  """
  def notify_if_update_available do
    Core.notify_if_update_available()
  end

  @doc """
  Enables or disables automatic update checks.

  ## Parameters

  - `enabled`: Whether to enable or disable automatic update checks

  ## Examples

      iex> Raxol.System.Updater.set_auto_check(true)
      :ok

      iex> Raxol.System.Updater.set_auto_check(false)
      :ok
  """
  def set_auto_check(enabled) when is_boolean(enabled) do
    State.set_auto_check(enabled)
  end
end
