defmodule Raxol.CLI.Commands.UpdateCmd do
  @moduledoc """
  CLI command for managing Raxol updates.

  This module handles:
  - Checking for updates
  - Performing self-updates
  - Managing update settings
  """

  alias Raxol.Core.Runtime.Log
  alias Raxol.System.Updater

  @doc """
  Executes the update command with the provided options and arguments.

  ## Options

  - `--check` or `-c`: Check for updates without installing
  - `--force` or `-f`: Force update check, bypassing the check interval
  - `--auto` or `-a`: Enable or disable automatic update checks (value: on/off)
  - `--version` or `-v`: Update to a specific version
  - `--no-delta` or `-n`: Disable delta updates and use full updates only
  - `--delta-info` or `-d`: Show information about delta update availability

  ## Examples

  Check for updates:
  ```
  raxol update --check
  ```

  Perform an update:
  ```
  raxol update
  ```

  Update to a specific version:
  ```
  raxol update --version 0.2.0
  ```

  Update without using delta updates:
  ```
  raxol update --no-delta
  ```

  Disable automatic update checks:
  ```
  raxol update --auto off
  ```
  """
  def execute(args) do
    {opts, _, _} = parse_options(args)
    handle_command(opts)
  end

  defp parse_options(args) do
    OptionParser.parse(args,
      strict: [
        check: :boolean,
        force: :boolean,
        auto: :string,
        version: :string,
        help: :boolean,
        no_delta: :boolean,
        delta_info: :boolean
      ],
      aliases: [
        c: :check,
        f: :force,
        a: :auto,
        v: :version,
        h: :help,
        n: :no_delta,
        d: :delta_info
      ]
    )
  end

  # Helper functions for pattern matching refactoring

  defp handle_command(opts) do
    case {opts[:help], opts[:auto], opts[:check], opts[:delta_info]} do
      {true, _, _, _} ->
        print_help()

      {false, auto, _, _} when auto != nil ->
        handle_auto_check(auto)

      {false, nil, true, _} ->
        check_for_updates(force: opts[:force])

      {false, nil, false, true} ->
        show_delta_info(opts[:version], force: opts[:force])

      {false, nil, false, false} ->
        perform_update(opts[:version],
          force: opts[:force],
          use_delta: !opts[:no_delta]
        )
    end
  end

  defp handle_auto_check(value) do
    case String.downcase(value) do
      "on" ->
        _ = Updater.set_auto_check(true)
        Log.info("Automatic update checks are now enabled")

      "off" ->
        _ = Updater.set_auto_check(false)
        Log.info("Automatic update checks are now disabled")

      _ ->
        Log.error("Invalid value for --auto. Use 'on' or 'off'")
    end
  end

  defp check_for_updates(opts) do
    Log.info("Checking for updates...")

    case Updater.check_for_updates(opts) do
      {:update_available, version} ->
        Log.info("Update available: v#{version}")
        Log.info("Current version: v#{Updater.get_current_version()}")
        Log.info("\nRun 'raxol update' to install the update")

      {:no_update, version} ->
        Log.info("Raxol is up to date (v#{version})")

      {:error, reason} ->
        Log.error("Error checking for updates: #{format_reason(reason)}")
    end
  end

  defp perform_update(version, opts) do
    _force = Keyword.get(opts, :force, false)
    use_delta = Keyword.get(opts, :use_delta, true)

    check_result = get_check_result(version, opts)

    case check_result do
      {:update_available, update_version} ->
        do_update(update_version, use_delta)

      {:no_update, version} ->
        Log.info("Raxol is already up to date (v#{version})")

      {:error, reason} ->
        Log.error("Error checking for updates: #{format_reason(reason)}")
    end
  end

  defp do_update(version, use_delta) do
    Log.info("Updating to version v#{version} #{get_update_message(use_delta)}")

    case Updater.self_update(version, use_delta: use_delta) do
      :ok ->
        Log.info("Update successful!")
        Log.info("Raxol has been updated to v#{version}")
        Log.info("Please restart Raxol to use the new version")

      {:no_update, current_version} ->
        Log.info("Already running version v#{current_version}")

      {:error, reason} ->
        Log.error("Update failed: #{format_reason(reason)}")
        Log.info("\nYou can try downloading the latest version manually from:")
        Log.info(releases_page())
    end
  end

  defp show_delta_info(version, opts) do
    # Check delta info based on whether version is provided
    handle_delta_info_check(version, opts)
  end

  defp check_delta_for_version(version) do
    Log.info("Checking delta update availability for version v#{version}...")

    alias Raxol.System.DeltaUpdater

    case DeltaUpdater.check_delta_availability(version) do
      {:ok, delta_info} ->
        Log.info("Delta update available!")
        Log.info("Full package size: #{format_bytes(delta_info.full_size)}")
        Log.info("Delta size: #{format_bytes(delta_info.delta_size)}")
        Log.info("Space savings: #{delta_info.savings_percent}%")
        Log.info("\nTo update using delta updates, run: raxol update")

      {:error, reason} ->
        Log.error("Delta update not available: #{format_reason(reason)}")
        Log.info("Full update will be used when updating to this version.")
    end
  end

  defp format_bytes(bytes), do: Raxol.Utils.Format.format_bytes_iec(bytes)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp releases_page do
    case Raxol.System.Updater.Manifest.load() do
      {:ok, manifest} ->
        Raxol.System.Updater.Manifest.releases_page_url(manifest)

      {:error, reason} ->
        "(no update channel configured: #{inspect(reason)})"
    end
  end

  defp success_msg(text) do
    "\e[32m#{text}\e[0m"
  end

  defp get_check_result(version, _opts) when version != nil,
    do: {:update_available, version}

  defp get_check_result(nil, opts) do
    Log.info("Checking for updates...")
    Updater.check_for_updates(opts)
  end

  defp get_update_message(true), do: "(with delta updates if available)..."
  defp get_update_message(false), do: "(using full update)..."

  defp handle_delta_info_check(nil, opts) do
    Log.info("Checking for updates...")

    case Updater.check_for_updates(opts) do
      {:update_available, latest_version} ->
        check_delta_for_version(latest_version)

      {:no_update, current_version} ->
        Log.info(
          success_msg("Raxol is already up to date (v#{current_version})")
        )

        Log.info("No delta update information available.")

      {:error, reason} ->
        Log.error("Error checking for updates: #{format_reason(reason)}")
    end
  end

  defp handle_delta_info_check(version, _opts) do
    # Check delta info for the specified version
    check_delta_for_version(version)
  end

  defp print_help do
    help_text = """
    Raxol Update Command

    Usage: raxol update [options]

    Options:
      -c, --check              Check for updates without installing
      -f, --force              Force update check, bypassing the check interval
      -a, --auto on|off        Enable or disable automatic update checks
      -v, --version VERSION    Update to a specific version
      -n, --no-delta           Disable delta updates, use full updates only
      -d, --delta-info         Show information about delta update availability
      -h, --help               Show this help message

    Examples:
      raxol update                     # Check and install updates (with delta if available)
      raxol update --check             # Only check for updates
      raxol update --delta-info        # Check delta update availability
      raxol update --no-delta          # Update using full update only
      raxol update --version 0.2.0     # Update to version 0.2.0
      raxol update --auto off          # Disable automatic update checks
    """

    Log.info(help_text)
  end
end
