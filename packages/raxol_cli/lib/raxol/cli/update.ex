defmodule Raxol.CLI.Update do
  @moduledoc """
  Self-update command for Burrito-built `raxol` binaries.
  """

  @repo "DROOdotFOO/raxol"
  @tag_prefix "raxol-cli-v"
  @timeout 30_000
  @auto_check_interval_s 24 * 60 * 60

  @type release :: map()
  @type target :: %{asset: String.t(), label: String.t(), windows?: boolean()}

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
         {:ok, _current_exe} <- current_executable(runtime) do
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
    current_version = runtime |> current_version() |> base_version()

    with {:ok, _target} <- target(runtime),
         {:ok, release} <- resolve_release(nil, runtime),
         {:ok, target_version} <- release_version(release) do
      if update_needed?(current_version, target_version) do
        {:update_available, target_version, current_version}
      else
        {:no_update, current_version}
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
    current_version = runtime |> current_version() |> base_version()

    with {:ok, target} <- target(runtime),
         {:ok, release} <- resolve_release(opts[:version], runtime),
         {:ok, target_version} <- release_version(release) do
      cond do
        !update_needed?(current_version, target_version) ->
          IO.puts("Current version: #{current_version}")
          IO.puts("Raxol is up to date")
          0

        opts[:check] ->
          IO.puts("Current version: #{current_version}")
          IO.puts("New version available: #{target_version}")
          IO.puts("Run `raxol update` to install the update")
          0

        true ->
          install_update(current_version, target_version, target, release, runtime)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, "raxol update: #{format_reason(reason)}")
        1
    end
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

  defp current_version(runtime) do
    Keyword.get_lazy(runtime, :current_version, &Raxol.CLI.version/0)
  end

  defp update_needed?(current, target) do
    case {Version.parse(target), Version.parse(current)} do
      {{:ok, target_v}, {:ok, current_v}} -> Version.compare(target_v, current_v) == :gt
      _ -> target != current
    end
  end

  defp install_update(current_version, target_version, target, release, runtime) do
    with {:ok, binary} <- asset(release, target.asset),
         {:ok, sums} <- checksum_asset(release, runtime),
         {:ok, expected_sha} <- checksum_for(sums, target.asset),
         {:ok, current_exe} <- current_executable(runtime) do
      IO.puts("Current version: #{current_version}")
      IO.puts("New version available: #{target_version}")
      IO.puts("Downloading #{target.label}…")

      case download_verify_install(binary, current_exe, expected_sha, target, runtime) do
        :ok ->
          IO.puts("✔ Updated to #{target_version}")
          IO.puts("Restart raxol to use the new version")
          0

        {:error, reason} ->
          IO.puts(:stderr, "raxol update: #{format_reason(reason)}")
          1
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, "raxol update: #{format_reason(reason)}")
        1
    end
  end

  defp download_verify_install(binary, current_exe, expected_sha, target, runtime) do
    tmp_path = update_path(current_exe)

    result =
      with :ok <- download(Map.fetch!(binary, "browser_download_url"), tmp_path, runtime),
           :ok <- verify_checksum(tmp_path, expected_sha) do
        IO.puts("Verified sha256:#{expected_sha}")
        IO.puts("Installing update...")
        replace_executable(tmp_path, current_exe, target)
      end

    if result != :ok or !target.windows? do
      if File.exists?(tmp_path), do: File.rm(tmp_path)
    end

    result
  end

  defp update_path(current_exe) do
    dir = Path.dirname(current_exe)
    base = Path.basename(current_exe)
    suffix = System.unique_integer([:positive])
    Path.join(dir, ".#{base}.#{suffix}.update")
  end

  defp replace_executable(tmp_path, current_exe, %{windows?: true}) do
    with :ok <- File.chmod(tmp_path, 0o755),
         :ok <- write_windows_replacer(tmp_path, current_exe) do
      :ok
    else
      {:error, reason} ->
        {:error, "failed to schedule executable replacement: #{inspect(reason)}"}
    end
  end

  defp replace_executable(tmp_path, current_exe, %{windows?: false}) do
    with :ok <- File.chmod(tmp_path, 0o755),
         :ok <- File.rename(tmp_path, current_exe) do
      :ok
    else
      {:error, reason} -> {:error, "failed to replace executable: #{inspect(reason)}"}
    end
  end

  defp write_windows_replacer(tmp_path, current_exe) do
    bat = Path.join(System.tmp_dir!(), "raxol-updater-#{System.unique_integer([:positive])}.bat")

    body = """
    @echo off
    timeout /t 2 /nobreak > nul
    move /y "#{Path.expand(tmp_path)}" "#{Path.expand(current_exe)}" > nul
    del "%~f0"
    """

    with :ok <- File.write(bat, body),
         {_, 0} <- System.cmd("cmd", ["/c", "start", "/b", bat]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, {:cmd_failed, status, output}}
    end
  end

  defp verify_checksum(path, expected_sha) do
    actual_sha =
      path
      |> File.stream!(65_536, [:raw, :binary])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual_sha == String.downcase(expected_sha) do
      :ok
    else
      {:error, "checksum mismatch for downloaded binary"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp resolve_release(nil, runtime) do
    releases_url = "https://api.github.com/repos/#{@repo}/releases?per_page=20"

    with {:ok, releases} when is_list(releases) <- get_json(releases_url, runtime),
         %{} = release <- Enum.find(releases, &cli_release?/1) do
      {:ok, release}
    else
      nil -> {:error, "no #{@tag_prefix} release found"}
      {:ok, _} -> {:error, "GitHub releases response was not a list"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_release(version, runtime) do
    tag = @tag_prefix <> base_version(version)
    url = "https://api.github.com/repos/#{@repo}/releases/tags/#{tag}"
    get_json(url, runtime)
  end

  defp cli_release?(%{"tag_name" => @tag_prefix <> _, "draft" => draft, "prerelease" => pre}) do
    draft != true and pre != true
  end

  defp cli_release?(_), do: false

  defp release_version(%{"tag_name" => @tag_prefix <> version}), do: {:ok, version}
  defp release_version(_), do: {:error, "release tag is not a #{@tag_prefix} tag"}

  defp asset(%{"assets" => assets}, name) when is_list(assets) do
    case Enum.find(assets, &(Map.get(&1, "name") == name)) do
      %{} = asset -> {:ok, asset}
      nil -> {:error, "release is missing #{name}"}
    end
  end

  defp asset(_release, name), do: {:error, "release is missing #{name}"}

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

  defp checksum_asset(release, runtime) do
    with {:ok, asset} <- asset(release, "SHA256SUMS") do
      get_text(Map.fetch!(asset, "browser_download_url"), runtime)
    end
  end

  defp checksum_for(sums, filename) do
    sums
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line) do
        [sha, ^filename | _] -> sha
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, "SHA256SUMS is missing #{filename}"}
      sha -> validate_sha(sha)
    end
  end

  defp validate_sha(sha) do
    if String.match?(sha, ~r/\A[0-9a-fA-F]{64}\z/) do
      {:ok, String.downcase(sha)}
    else
      {:error, "invalid sha256 in SHA256SUMS"}
    end
  end

  defp current_executable(runtime) do
    runtime
    |> Keyword.get(:current_executable)
    |> case do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> burrito_executable_path()
    end
  end

  defp burrito_executable_path do
    with true <- Code.ensure_loaded?(Burrito.Util.Args),
         true <- function_exported?(Burrito.Util.Args, :get_bin_path, 0),
         path when is_binary(path) <- Burrito.Util.Args.get_bin_path() do
      {:ok, path}
    else
      _ ->
        {:error,
         "not running as a Burrito binary; reinstall with `npm i -g raxol` or download the latest release"}
    end
  end

  defp target(runtime) do
    case Keyword.get(runtime, :target) || host_target() do
      nil ->
        {:error,
         "unsupported platform #{inspect(:os.type())} #{:erlang.system_info(:system_architecture)}"}

      target ->
        {:ok, target}
    end
  end

  defp host_target do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()
    os = :os.type()

    cond do
      os == {:unix, :darwin} and arch_matches?(arch, ["aarch64", "arm64"]) ->
        %{asset: "raxol_cli_macos", label: "raxol-darwin-arm64", windows?: false}

      match?({:unix, _}, os) and arch_matches?(arch, ["x86_64", "amd64"]) ->
        %{asset: "raxol_cli_linux", label: "raxol-linux-x64", windows?: false}

      match?({:unix, _}, os) and arch_matches?(arch, ["aarch64", "arm64"]) ->
        %{asset: "raxol_cli_linux_arm", label: "raxol-linux-arm64", windows?: false}

      match?({:win32, _}, os) ->
        %{asset: "raxol_cli_windows.exe", label: "raxol-win32-x64", windows?: true}

      true ->
        nil
    end
  end

  defp arch_matches?(arch, needles), do: Enum.any?(needles, &String.contains?(arch, &1))

  defp get_json(url, runtime) do
    case Keyword.get(runtime, :http_get_json) do
      fun when is_function(fun, 1) -> fun.(url)
      _ -> default_get_json(url)
    end
  end

  defp get_text(url, runtime) do
    case Keyword.get(runtime, :http_get_text) do
      fun when is_function(fun, 1) -> fun.(url)
      _ -> default_get_text(url)
    end
  end

  defp download(url, path, runtime) do
    case Keyword.get(runtime, :download_file) do
      fun when is_function(fun, 2) -> fun.(url, path)
      _ -> default_download(url, path)
    end
  end

  defp default_get_json(url) do
    case Req.get(url, headers: headers(), receive_timeout: @timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> decode_json(body)
      {:ok, %{status: status}} -> {:error, "GitHub returned HTTP #{status}"}
      {:error, reason} -> {:error, Exception.message(reason)}
    end
  end

  defp decode_json(body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, "invalid GitHub JSON: #{Exception.message(reason)}"}
    end
  end

  defp default_get_text(url) do
    case Req.get(url, headers: headers(), receive_timeout: @timeout, decode_body: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "GitHub returned HTTP #{status}"}

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  defp default_download(url, path) do
    File.open(path, [:write, :binary], fn io ->
      Req.get(url,
        headers: headers(),
        receive_timeout: @timeout,
        raw: true,
        into: fn {:data, data}, {req, resp} ->
          IO.binwrite(io, data)
          {:cont, {req, resp}}
        end
      )
    end)
    |> case do
      {:ok, {:ok, %{status: status}}} when status in 200..299 -> :ok
      {:ok, {:ok, %{status: status}}} -> {:error, "download returned HTTP #{status}"}
      {:ok, {:error, reason}} -> {:error, Exception.message(reason)}
      {:error, reason} -> {:error, "failed to write update: #{inspect(reason)}"}
    end
  end

  defp headers do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "raxol-cli-updater"}
    ]
  end

  defp base_version(version) do
    version
    |> to_string()
    |> String.trim_leading("v")
    |> String.split("+", parts: 2)
    |> hd()
  end

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
    release, verifies SHA256SUMS, and replaces the running binary.
    """)
  end
end
