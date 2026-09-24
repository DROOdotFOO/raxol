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
        help: :boolean
      ],
      aliases: [
        c: :check,
        f: :force,
        a: :auto,
        v: :version,
        h: :help
      ]
    )
  end

  # Absent flags are nil, not false, in OptionParser's result.
  defp handle_command(opts) do
    cond do
      opts[:help] -> print_help()
      opts[:auto] != nil -> handle_auto_check(opts[:auto])
      opts[:check] -> check_for_updates(force: opts[:force] == true)
      true -> perform_update(opts[:version], force: opts[:force] == true)
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
    case get_check_result(version, opts) do
      {:update_available, update_version} ->
        do_update(update_version)

      {:no_update, version} ->
        Log.info("Raxol is already up to date (v#{version})")

      {:error, reason} ->
        Log.error("Error checking for updates: #{format_reason(reason)}")
    end
  end

  defp do_update(version) do
    Log.info("Updating to version v#{version}...")

    case Updater.self_update(version) do
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

  defp get_check_result(version, _opts) when version != nil,
    do: {:update_available, version}

  defp get_check_result(nil, opts) do
    Log.info("Checking for updates...")
    Updater.check_for_updates(opts)
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
      -h, --help               Show this help message

    Examples:
      raxol update                     # Check and install updates
      raxol update --check             # Only check for updates
      raxol update --version 0.2.0     # Update to version 0.2.0
      raxol update --auto off          # Disable automatic update checks
    """

    Log.info(help_text)
  end
end
