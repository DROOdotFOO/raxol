defmodule Raxol.System.Updater do
  use Raxol.Core.Behaviours.BaseManager

  @moduledoc """
  Version checks and verified self-update for a Burrito-packaged binary.

  Where updates come from is a `Raxol.System.Updater.Manifest`: by default the
  `raxol` CLI release channel (`raxol-cli-v*` releases on `DROOdotFOO/raxol`),
  or whatever an application sets in `config :raxol, :updater_manifest`.
  Every download is checked against the release's `SHA256SUMS` and, unless
  the manifest sets `provenance: :off`, against the release's Sigstore
  attestation (`Raxol.System.Updater.Provenance`: signed by the manifest's
  workflow for that tag) before it is extracted or installed. The replaced
  executable is kept so `rollback_update/1` can restore it.

  ## Options

  Every function takes a keyword list; each option defaults to the running
  installation:

    * `:manifest` - a `Manifest` struct or overrides of the configured one
    * `:force` - check even when the automatic-check interval has not passed
    * `:version` - for `check_for_updates/1`, check that release instead of the newest
    * `:current_version` - the installed version (default: the manifest's `:app`)
    * `:current_executable` - the binary to replace (default: the Burrito binary)
    * `:platform` - the manifest platform key (default: the host's)
    * `:backup_dir`, `:download_dir` - default to the update settings' paths
    * `:work_dir` - scratch directory (default: a fresh temp dir, removed after)
  """

  alias Raxol.System.Updater.{Core, State}

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

  @doc "Downloads and verifies a release asset; see `install_update/3`."
  def download_update(version, opts \\ []) do
    Core.download_update(version, opts)
  end

  @doc "Re-verifies and installs an asset fetched by `download_update/2`."
  def install_update(context, version, opts \\ []) do
    Core.install_update(context, version, opts)
  end

  def handle_no_update(_context, {:no_update, _current_version}) do
    :ok
  end

  @doc "Restores the executable the last install replaced."
  def rollback_update(opts \\ []) do
    Core.rollback_update(opts)
  end

  def get_current_version(opts \\ []) do
    Core.get_current_version(opts)
  end

  @doc """
  The executable an update would replace: `:current_executable`, else the
  Burrito binary this node runs from; `{:error, :not_running_as_binary}` on a
  plain `mix`/`iex` node.
  """
  def current_executable(opts \\ []) do
    Core.current_executable(opts)
  end

  def get_available_versions(opts \\ []) do
    Core.get_available_versions(opts)
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
  Checks whether a newer release than the installed version is published.

  Without `force: true` this only goes to the network when automatic checks
  are enabled and the check interval has passed, and records the check time.

  Returns `{:update_available, version}`, `{:no_update, current_version}`,
  or `{:error, reason}`.
  """
  def check_for_updates(opts \\ []) do
    Core.check(opts)
  end

  @doc """
  Updates the running binary to `version` (default: the newest release),
  when that release is newer than the installed one.

  Returns `:ok`, `{:no_update, current_version}`, or `{:error, reason}`.
  Nothing is installed unless its checksum matches the release's
  `SHA256SUMS` and, with provenance required, the release's attestation
  covers it; a provenance failure is `{:error, {:provenance_failed, reason}}`.
  """
  def self_update(version \\ nil, opts \\ []) do
    Core.self_update(version, opts)
  end

  @doc "Prints a notice when `check_for_updates/1` finds a newer release."
  def notify_if_update_available(opts \\ []) do
    Core.notify_if_update_available(opts)
  end

  @doc "Enables or disables automatic update checks."
  def set_auto_check(enabled) when is_boolean(enabled) do
    State.set_auto_check(enabled)
  end
end
