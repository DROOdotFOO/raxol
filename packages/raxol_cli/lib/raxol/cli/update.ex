defmodule Raxol.CLI.Update do
  @moduledoc """
  `raxol update`: the command-line face of `Raxol.System.Updater`.

  This module owns the CLI experience (flags, messages, exit codes, the
  once-a-day interactive prompt). Finding the release, checking it against
  `SHA256SUMS`, and replacing the binary are `Raxol.System.Updater`'s, on its
  default channel: the `raxol-cli-v*` releases this binary is built from.
  """

  alias Raxol.System.Updater
  alias Raxol.System.Updater.Manifest

  @auto_check_interval_s 24 * 60 * 60

  # Options passed through to `Raxol.System.Updater` (tests point them at a
  # loopback release channel and scratch files).
  @updater_keys [:manifest, :platform, :current_executable, :backup_dir, :work_dir]

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(args, opts \\ []) do
    case parse_args(args) do
      {:ok, :help} ->
        print_help()
        0

      {:ok, parsed} ->
        execute(parsed, opts)

      {:error, reason} ->
        IO.puts(:stderr, "raxol update: #{reason}")
        64
    end
  end

  @doc false
  @spec auto_prompt(keyword()) :: :ok | :updated
  def auto_prompt(runtime \\ []) do
    with true <- Keyword.get_lazy(runtime, :prompt?, &interactive_prompt?/0),
         true <- auto_check_enabled?(runtime),
         true <- auto_check_due?(runtime),
         {:ok, _current_exe} <- Updater.current_executable(updater_opts(runtime)) do
      _ = write_auto_check(runtime)
      prompt_for_latest_update(runtime)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @doc false
  @spec latest_update(keyword()) ::
          {:update_available, String.t(), String.t()}
          | {:no_update, String.t()}
          | {:error, term()}
  def latest_update(runtime \\ []) do
    opts = updater_opts(runtime)

    with {:ok, _platform} <- platform(opts) do
      case Updater.check_for_updates([force: true] ++ opts) do
        {:update_available, target} -> {:update_available, target, opts[:current_version]}
        other -> other
      end
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [check: :boolean, version: :string, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      opts[:help] -> {:ok, :help}
      invalid != [] -> {:error, "unknown options: #{format_invalid(invalid)}"}
      positional != [] -> {:error, "unexpected arguments: #{Enum.join(positional, " ")}"}
      true -> {:ok, opts}
    end
  end

  defp format_invalid(invalid) do
    invalid
    |> Enum.map(fn
      {flag, nil} -> flag
      {flag, value} -> flag <> " " <> value
    end)
    |> Enum.join(", ")
  end

  defp execute(opts, runtime) do
    updater = updater_opts(runtime)
    current = updater[:current_version]

    case Updater.check_for_updates([force: true, version: opts[:version]] ++ updater) do
      {:no_update, _current} ->
        IO.puts("Current version: #{current}")
        IO.puts("Raxol is up to date")
        0

      {:update_available, target} ->
        IO.puts("Current version: #{current}")
        IO.puts("New version available: #{target}")
        if opts[:check], do: print_install_hint(), else: install(target, updater)

      {:error, reason} ->
        fail(reason)
    end
  end

  defp print_install_hint do
    IO.puts("Run `raxol update` to install the update")
    0
  end

  defp install(target, updater) do
    with {:ok, platform} <- platform(updater),
         {:ok, _current_exe} <- Updater.current_executable(updater) do
      IO.puts("Downloading raxol-#{platform}…")
      target |> Updater.self_update(updater) |> report_install(target)
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp report_install(:ok, target) do
    IO.puts("✔ Updated to #{target} (verified against SHA256SUMS)")
    IO.puts("Restart raxol to use the new version")
    0
  end

  defp report_install({:no_update, _current}, _target) do
    IO.puts("Raxol is up to date")
    0
  end

  defp report_install({:error, reason}, _target), do: fail(reason)

  defp fail(reason) do
    IO.puts(:stderr, "raxol update: #{format_reason(reason)}")
    1
  end

  defp prompt_for_latest_update(runtime) do
    case latest_update(runtime) do
      {:update_available, target_version, current_version} ->
        prompt_for_update(target_version, current_version, runtime)

      _ ->
        :ok
    end
  end

  defp prompt_for_update(target_version, current_version, runtime) do
    IO.puts("")
    IO.puts("Raxol #{target_version} is available (current #{current_version}).")

    answer =
      case IO.gets("Update now? [y/N] ") do
        :eof -> ""
        {:error, _reason} -> ""
        data -> data
      end
      |> String.trim()
      |> String.downcase()

    if answer in ["y", "yes"] do
      case run(["--version", target_version], runtime) do
        0 -> :updated
        _ -> :ok
      end
    else
      IO.puts("Skipping update. Run `raxol update` later.")
      :ok
    end
  end

  # The installed version is normalized here (build metadata dropped) so the
  # CLI prints the same version the updater compares.
  defp updater_opts(runtime) do
    current = Keyword.get_lazy(runtime, :current_version, &Raxol.CLI.version/0)

    runtime
    |> Keyword.take(@updater_keys)
    |> Keyword.put(:current_version, normalized_version(current))
    |> Keyword.put_new_lazy(:backup_dir, fn -> Path.expand("~/.raxol/backups") end)
  end

  defp normalized_version(version) do
    case Manifest.normalize_version(version) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> version
    end
  end

  defp platform(opts) do
    case Keyword.fetch(opts, :platform) do
      {:ok, platform} -> {:ok, platform}
      :error -> Manifest.host_platform()
    end
  end

  defp interactive_prompt? do
    case :io.getopts() do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) != false
      _ -> false
    end
  rescue
    _ -> false
  end

  defp auto_check_enabled?(runtime) do
    Keyword.get(runtime, :auto_check?, true) and
      System.get_env("RAXOL_NO_UPDATE_CHECK") not in ~w(1 true yes on)
  end

  defp auto_check_due?(runtime) do
    now = now_s(runtime)
    interval = Keyword.get(runtime, :auto_check_interval_s, @auto_check_interval_s)

    case read_last_auto_check(runtime) do
      {:ok, last_checked_at} -> now - last_checked_at >= interval
      :error -> true
    end
  end

  defp read_last_auto_check(runtime) do
    with {:ok, raw} <- File.read(auto_check_path(runtime)),
         {:ok, %{"last_checked_at" => last_checked_at}} when is_integer(last_checked_at) <-
           Jason.decode(raw) do
      {:ok, last_checked_at}
    else
      _ -> :error
    end
  end

  defp write_auto_check(runtime) do
    path = auto_check_path(runtime)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(%{"last_checked_at" => now_s(runtime)}))
  end

  defp auto_check_path(runtime) do
    Keyword.get_lazy(runtime, :auto_check_path, fn ->
      Path.expand("~/.raxol/cli-update-check.json")
    end)
  end

  defp now_s(runtime), do: Keyword.get_lazy(runtime, :now_s, fn -> :os.system_time(:second) end)

  defp format_reason(:not_running_as_binary),
    do:
      "not running as a Burrito binary; reinstall with `npm i -g @raxol/cli` or download the latest release"

  defp format_reason({:checksum_mismatch, name}), do: "checksum mismatch for #{name}"
  defp format_reason({:missing_checksum, name}), do: "SHA256SUMS is missing #{name}"
  defp format_reason({:unsupported_platform, platform}), do: "unsupported platform #{platform}"
  defp format_reason({:invalid_version, version}), do: "invalid version #{inspect(version)}"

  defp format_reason({:http_status, 404, _url}), do: "no such release"
  defp format_reason({:http_status, status, url}), do: "HTTP #{status} from #{url}"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp print_help do
    IO.puts("""
    Usage: raxol update [options]

    Options:
      --check            Check for an update without installing
      --version VERSION  Install a specific CLI release version
      -h, --help         Show this help

    Downloads the matching Burrito binary from the latest raxol-cli GitHub
    release, verifies it against SHA256SUMS, and replaces the running binary.
    The replaced binary is kept in ~/.raxol/backups/previous_version.
    """)
  end
end
