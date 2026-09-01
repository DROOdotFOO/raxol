defmodule Raxol.System.Updater.Core do
  @moduledoc """
  Core update logic and GenServer callbacks for the Raxol System Updater.
  """
  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Runtime.Log
  alias Raxol.System.Updater.{Network, State, Validation}

  @github_repo "username/raxol"
  @version Mix.Project.config()[:version]

  # --- Client API ---

  def check_for_updates do
    settings = State.get_update_settings()
    handle_update_check(settings.auto_update, settings)
  end

  defp handle_update_check(false, _settings),
    do: {:error, :auto_update_disabled}

  defp handle_update_check(true, _settings) do
    with {:ok, %{version: latest_version}} <- Network.fetch_latest_version(),
         current_version = get_current_version(),
         true <- latest_version != current_version do
      {:ok, latest_version}
    else
      {:error, reason} -> {:error, reason}
      false -> {:no_update, get_current_version()}
    end
  end

  def download_update(version) do
    settings = State.get_update_settings()
    platform = Validation.get_platform()

    ext =
      case platform == "windows" do
        true -> "zip"
        false -> "tar.gz"
      end

    url =
      "https://github.com/#{@github_repo}/releases/download/v#{version}/raxol-#{version}-#{platform}.#{ext}"

    :ok =
      Network.download_file(
        url,
        Path.join(settings.download_path, "update.#{ext}")
      )

    {:ok, version}
  end

  def install_update(context, version) do
    settings = State.get_update_settings()
    platform = Validation.get_platform()

    ext =
      case platform == "windows" do
        true -> "zip"
        false -> "tar.gz"
      end

    update_path = Path.join(settings.download_path, "update.#{ext}")

    with :ok <-
           Network.extract_archive(update_path, settings.download_path, ext),
         {:ok, new_exe} <-
           Network.find_executable(settings.download_path, platform),
         :ok <- apply_update(context.current_exe, new_exe, platform) do
      {:ok, version}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def rollback_update do
    settings = State.get_update_settings()
    backup_path = Path.join(settings.backup_path, "previous_version")
    handle_rollback(File.exists?(backup_path), backup_path)
  end

  defp handle_rollback(false, _backup_path), do: {:error, :no_backup_found}

  defp handle_rollback(true, backup_path) do
    _platform = Validation.get_platform()

    current_exe =
      System.get_env("BURRITO_EXECUTABLE_PATH") ||
        System.argv() |> List.first()

    case File.cp(backup_path, current_exe) do
      :ok -> {:ok, get_current_version()}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_current_version do
    Application.spec(:raxol)[:vsn]
  end

  def get_available_versions do
    case Network.fetch_github_releases() do
      {:ok, releases} -> {:ok, releases}
      {:error, reason} -> {:error, reason}
    end
  end

  def update(opts \\ []) do
    opts =
      case is_map(opts) do
        true -> Enum.into(opts, [])
        false -> opts
      end

    force = Keyword.get(opts, :force, false)
    use_delta = Keyword.get(opts, :use_delta, true)
    version = Keyword.get(opts, :version)

    Raxol.Core.ErrorHandling.safe_call(fn ->
      with {:ok, target_version} <- get_target_version(version, force) do
        apply_target_update(target_version, use_delta)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, {:throw, {:no_update, v}}} -> {:no_update, v}
      {:error, {:throw, {:error, reason}}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def self_update(version \\ nil, opts \\ []) do
    use_delta = Keyword.get(opts, :use_delta, true)

    Raxol.Core.ErrorHandling.safe_call(fn ->
      handle_self_update(is_binary(version), version, use_delta)
    end)
    |> case do
      {:ok, result} -> result
      {:error, {:throw, {:error, reason}}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def notify_if_update_available do
    case check_for_updates() do
      {:ok, _version} ->
        # Use bright green on black for the update notification
        fg = {0, 255, 0}
        bg = {0, 0, 0}

        fg_hex =
          Raxol.Style.Colors.Color.from_rgb(
            elem(fg, 0),
            elem(fg, 1),
            elem(fg, 2)
          )
          |> Raxol.Style.Colors.Color.to_hex()

        bg_hex =
          Raxol.Style.Colors.Color.from_rgb(
            elem(bg, 0),
            elem(bg, 1),
            elem(bg, 2)
          )
          |> Raxol.Style.Colors.Color.to_hex()

        Raxol.UI.Terminal.println("Update Available!",
          color: fg_hex,
          background: bg_hex
        )

        :ok

      {:no_update, _} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init_manager(_opts) do
    state = %{
      settings: State.default_update_settings(),
      status: :idle,
      current_version: current_version(),
      available_updates: [],
      last_check: nil,
      error: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:install_update, version}, _from, state) do
    case perform_install_update(version, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:get_update_settings, _from, state) do
    {:reply, state.settings, state}
  end

  @impl true
  def handle_manager_call({:set_update_settings, settings}, _from, state) do
    state = %{state | settings: settings}
    {:reply, :ok, state}
  end

  @impl true
  def handle_manager_call(:check_for_updates, _from, state) do
    case check_updates(state) do
      {:ok, updates} ->
        state = %{
          state
          | status: :updates_available,
            available_updates: updates,
            last_check: DateTime.utc_now(),
            error: nil
        }

        {:reply, {:ok, updates}, state}

      {:error, reason} ->
        state = %{state | status: :error, error: reason}
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:get_update_status, _from, state) do
    status = %{
      current_version: state.current_version,
      available_updates: state.available_updates,
      last_check: state.last_check,
      error: state.error
    }

    {:reply, status, state}
  end

  # --- Private Functions ---

  defp current_version do
    Application.spec(:raxol)[:vsn]
  end

  defp check_updates(state) do
    case Network.fetch_latest_version() do
      {:ok, %{version: latest_version}} ->
        versions_different = latest_version != state.current_version
        build_update_response(versions_different, latest_version)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_update_response(false, _latest_version), do: {:ok, []}

  defp build_update_response(true, latest_version) do
    {:ok,
     [
       %{
         version: latest_version,
         url:
           "https://github.com/#{@github_repo}/releases/tag/v#{latest_version}"
       }
     ]}
  end

  defp perform_install_update(version, state) do
    case self_update(version, use_delta: true) do
      :ok ->
        new_state = %{
          state
          | status: :installed,
            current_version: version,
            error: nil
        }

        {:ok, new_state}

      {:error, reason} ->
        _new_state = %{state | status: :error, error: reason}
        {:error, reason}

      {:no_update, _current_version} ->
        {:ok, state}
    end
  end

  defp do_version_update(version, use_delta) do
    select_update_method(use_delta, version)
  end

  defp select_update_method(true, version), do: try_delta_update(version)
  defp select_update_method(false, version), do: do_self_update(version)

  defp get_update_version(version) do
    handle_version_fetch(is_nil(version), version)
  end

  defp handle_version_fetch(false, version), do: {:ok, version}

  defp handle_version_fetch(true, _version) do
    case Network.fetch_latest_version() do
      {:ok, latest} -> {:ok, latest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_self_update(false, _version, _use_delta) do
    {:error, "Not running as a compiled binary"}
  end

  defp handle_self_update(true, version, use_delta) do
    with {:ok, target_version} <- get_update_version(version) do
      case @version == target_version do
        false -> do_version_update(target_version, use_delta)
        true -> {:no_update, @version}
      end
    end
  end

  defp do_self_update(version) do
    platform = Validation.get_platform()
    ext = platform_extension(platform)
    url = release_url(version, platform, ext)

    tmp_dir = System.tmp_dir!() |> Path.join("raxol_update_#{version}")
    _ = File.rm_rf(tmp_dir)
    :ok = File.mkdir_p(tmp_dir)

    Raxol.Core.ErrorHandling.ensure_cleanup(
      fn -> perform_self_update(tmp_dir, url, ext, platform) end,
      fn -> File.rm_rf(tmp_dir) end
    )
    |> unwrap_cleanup_result()
  end

  defp platform_extension("windows"), do: "zip"
  defp platform_extension(_), do: "tar.gz"

  defp release_url(version, platform, ext) do
    "https://github.com/#{@github_repo}/releases/download/v#{version}/raxol-#{version}-#{platform}.#{ext}"
  end

  defp perform_self_update(tmp_dir, url, ext, platform) do
    archive_path = Path.join(tmp_dir, "update.#{ext}")
    :ok = Network.download_file(url, archive_path)
    :ok = Network.extract_archive(archive_path, tmp_dir, ext)

    current_exe =
      System.get_env("BURRITO_EXECUTABLE_PATH") ||
        System.argv() |> List.first()

    new_exe = Network.find_executable(tmp_dir, platform)
    apply_update(current_exe, new_exe, platform)
    :ok
  end

  defp unwrap_cleanup_result({:ok, result}), do: result

  defp unwrap_cleanup_result({:error, {:throw, {:error, reason}}}),
    do: {:error, reason}

  defp unwrap_cleanup_result({:error, reason}), do: {:error, reason}

  defp apply_update(current_exe, new_exe, platform) do
    Network.do_replace_executable(current_exe, new_exe, platform)
    # Consider if any further action is needed here after calling the helper,
    # especially for the non-Windows case where we didn't System.stop() inside.
    # If the application should exit after update on Unix, add System.stop(0) here.
    # For now, returning :ok based on the helper's success.
    :ok
  end

  defp do_delta_update(version, delta_info) do
    Log.info(
      "Delta update available (#{delta_info.savings_percent}% smaller download)"
    )

    case Raxol.System.DeltaUpdater.apply_delta_update(
           version,
           delta_info.delta_url
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Log.error("Delta update failed: #{inspect(reason)}")
        Log.warning("Falling back to full update...")
        do_self_update(version)
    end
  end

  defp try_delta_update(version) do
    case Raxol.System.DeltaUpdater.check_delta_availability(version) do
      {:ok, delta_info} -> do_delta_update(version, delta_info)
      {:error, _reason} -> do_self_update(version)
    end
  end

  defp get_target_version(version, force) do
    case version do
      nil ->
        case check_for_updates_with_force(force) do
          {:update_available, v} -> {:ok, v}
          {:no_update, v} -> {:no_update, v}
          {:error, reason} -> {:error, reason}
        end

      v ->
        {:ok, v}
    end
  end

  defp check_for_updates_with_force(force) do
    with {:ok, settings} <- State.get_update_settings(),
         true <- force || Validation.should_check_for_update?(settings),
         {:ok, latest_version} <- Network.fetch_latest_version() do
      _ = Validation.update_last_check(settings)
      {:ok, latest_version} |> Validation.compare_versions()
    else
      {:error, reason} -> {:error, reason}
      false -> {:no_update, Mix.Project.config()[:version]}
    end
  end

  defp apply_target_update(version, use_delta) do
    case self_update(version, use_delta: use_delta) do
      :ok -> :ok
      {:no_update, v} -> {:no_update, v}
      {:error, reason} -> {:error, reason}
    end
  end
end
