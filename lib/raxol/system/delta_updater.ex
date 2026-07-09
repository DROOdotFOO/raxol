defmodule Raxol.System.DeltaUpdater do
  @moduledoc """
  Handles delta updates for the Raxol terminal emulator.
  """

  # Called via adapter now
  alias Raxol.System.DeltaUpdaterSystemAdapterImpl

  defp system_adapter do
    Application.get_env(:raxol, :system_adapter, DeltaUpdaterSystemAdapterImpl)
  end

  def check_delta_availability(target_version) do
    with {:ok, releases} <- get_releases(),
         {:ok, assets} <- extract_assets(releases, target_version),
         {:ok, full_asset} <- find_full_asset(assets, target_version),
         {:ok, delta_asset} <- find_delta_asset(assets, target_version) do
      compare_asset_sizes(full_asset, delta_asset)
    else
      error -> error
    end
  end

  defp compare_asset_sizes(full_asset, delta_asset) do
    full_size = full_asset["size"]
    delta_size = delta_asset["size"]

    evaluate_delta_size(
      delta_size < full_size * 0.5,
      delta_size,
      full_size,
      delta_asset,
      full_asset
    )
  end

  def apply_delta_update(delta_url, target_version) do
    random_suffix = :rand.uniform(1_000_000)

    with {:ok, base_tmp_dir} <- system_adapter().system_tmp_dir(),
         tmp_dir_path =
           Path.join(base_tmp_dir, "raxol_update_#{random_suffix}"),
         :ok <- system_adapter().file_mkdir_p(tmp_dir_path) do
      Raxol.Core.ErrorHandling.ensure_cleanup(
        fn -> perform_update(tmp_dir_path, delta_url, target_version) end,
        fn -> system_adapter().file_rm_rf(tmp_dir_path) end
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_update(tmp_dir_path, delta_url, target_version) do
    with {:ok, current_exe} <- get_current_executable(),
         delta_file = Path.join(tmp_dir_path, "update.delta"),
         :ok <- download_delta(delta_url, delta_file),
         new_exe = Path.join(tmp_dir_path, "raxol.new"),
         :ok <- apply_binary_delta(current_exe, delta_file, new_exe),
         :ok <- verify_patched_executable(new_exe, target_version),
         :ok <- replace_executable(current_exe, new_exe) do
      {:ok, :update_applied}
    end
  end

  # Private functions

  defp extract_assets(releases, target_version) when is_list(releases) do
    # Find the release with the target version
    case Enum.find(releases, &(&1["tag_name"] == "v#{target_version}")) do
      nil -> {:error, :release_not_found}
      release -> extract_assets(release, target_version)
    end
  end

  defp extract_assets(%{"assets" => assets}, _target_version)
       when is_list(assets),
       do: {:ok, assets}

  defp extract_assets(_, _), do: {:error, "No assets found in release data"}

  defp find_delta_asset(assets, target_version) do
    # Match assets like raxol-delta-*-<from>-<to>-*.bin
    regex = ~r/raxol-delta-[^-]+-#{Regex.escape(target_version)}-[^.]+\.bin/

    case Enum.find(assets, &(&1["name"] =~ regex)) do
      nil -> {:error, :delta_not_found}
      asset -> {:ok, asset}
    end
  end

  defp find_full_asset(assets, target_version) do
    case Enum.find(assets, &(&1["name"] =~ ~r/raxol-#{target_version}/)) do
      nil -> {:error, :full_package_not_found}
      asset -> {:ok, asset}
    end
  end

  defp download_delta(url, destination) do
    case system_adapter().httpc_request(
           :get,
           {String.to_charlist(url), []},
           [],
           [{:stream, String.to_charlist(destination)}]
         ) do
      {:ok, :saved_to_file} ->
        :ok

      {:error, reason} ->
        # Return error tuple instead of throwing
        {:error, {:download_failed, reason}}
    end
  end

  defp get_current_executable do
    # Use adapter for system calls
    exe_path_env = system_adapter().system_get_env("BURRITO_EXECUTABLE_PATH")
    argv = system_adapter().system_argv()

    exe = exe_path_env || List.first(argv)

    handle_executable_path(is_nil(exe), exe)
  end

  defp apply_binary_delta(original_file, delta_file, output_file) do
    # We use bsdiff/bspatch for binary deltas
    # This assumes bspatch is available on the system
    case system_adapter().system_cmd(
           "bspatch",
           [original_file, output_file, delta_file],
           []
         ) do
      {_output, 0} ->
        :ok

      {error_output, _exit_status} ->
        # Return error tuple
        {:error, {:apply_delta_failed, error_output}}
    end
  end

  defp verify_patched_executable(exe_path, expected_version) do
    case system_adapter().file_chmod(exe_path, 0o755) do
      :ok -> check_version(exe_path, expected_version)
      {:error, reason} -> {:error, {:chmod_failed, reason}}
      error -> error
    end
  end

  defp check_version(exe_path, expected_version) do
    case system_adapter().system_cmd(exe_path, ["--version"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        validate_version_output(String.contains?(output, expected_version))

      {error_output, _exit_status} ->
        {:error, {:verify_failed_to_run, error_output}}
    end
  end

  defp replace_executable(current_exe, new_exe) do
    # Determine platform using adapter
    platform =
      case system_adapter().os_type() do
        {:win32, _} -> "windows"
        # Default to unix for other :os.type() results
        _ -> "unix"
      end

    # Call the shared helper function via adapter
    system_adapter().updater_do_replace_executable(
      current_exe,
      new_exe,
      platform
    )
  end

  defp get_releases do
    url = "https://api.github.com/repos/raxol/raxol/releases"

    case system_adapter().http_get(url) do
      {:ok, body} ->
        decode_releases_json(body)

      {:error, {:http_error, status_code, _body}} ->
        {:error, {:fetch_releases_failed_status, status_code}}

      {:error, reason} ->
        {:error, {:fetch_releases_failed, reason}}
    end
  end

  defp decode_releases_json(body) do
    case Raxol.Core.ErrorHandling.safe_call(fn -> Jason.decode!(body) end) do
      {:ok, releases} -> {:ok, releases}
      {:error, _} -> {:error, :json_decode_error}
    end
  end

  # Helper functions to eliminate if statements

  defp evaluate_delta_size(
         false,
         _delta_size,
         _full_size,
         _delta_asset,
         _full_asset
       ) do
    {:error, :delta_too_large}
  end

  defp evaluate_delta_size(true, delta_size, full_size, delta_asset, full_asset) do
    savings_percent = round((1 - delta_size / full_size) * 100)

    {:ok,
     %{
       delta_size: delta_size,
       full_size: full_size,
       savings_percent: savings_percent,
       delta_url: delta_asset["browser_download_url"],
       full_url: full_asset["browser_download_url"]
     }}
  end

  defp handle_executable_path(true, _exe) do
    {:error, :cannot_determine_executable_path}
  end

  defp handle_executable_path(false, exe) do
    {:ok, exe}
  end

  defp validate_version_output(true), do: :ok

  defp validate_version_output(false),
    do: {:error, :version_verification_failed}
end
