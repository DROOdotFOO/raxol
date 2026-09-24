defmodule Raxol.System.Updater.Network do
  @moduledoc """
  The updater's I/O: release lookup, `SHA256SUMS`, downloads, checksum
  verification, and replacing the running executable.

  Every URL comes from `Raxol.System.Updater.Manifest`. HTTPS requests verify
  the server certificate and hostname against the OS trust store. A
  downloaded file is only ever used after `verify_file/3` has matched it to
  its `SHA256SUMS` entry.
  """

  alias Raxol.System.Updater.Manifest

  @timeout 30_000

  @type release :: %{
          version: String.t(),
          tag: String.t(),
          assets: %{String.t() => non_neg_integer()}
        }

  @doc """
  The newest published (non-draft, non-prerelease) release on the channel,
  or the release for an explicit version.
  """
  @spec fetch_release(Manifest.t(), :latest | String.t()) ::
          {:ok, release()} | {:error, term()}
  def fetch_release(manifest, :latest) do
    with {:ok, releases} <- get_json(Manifest.releases_url(manifest)) do
      releases
      |> List.wrap()
      |> Enum.filter(&published?/1)
      |> Enum.flat_map(&List.wrap(normalize_release(manifest, &1)))
      |> Enum.max_by(&Version.parse!(&1.version), Version, fn -> nil end)
      |> case do
        nil -> {:error, {:no_release_found, manifest.tag_prefix}}
        release -> {:ok, release}
      end
    end
  end

  def fetch_release(manifest, version) do
    with {:ok, tag} <- Manifest.tag(manifest, version),
         {:ok, release} <- get_json(Manifest.release_url(manifest, tag)) do
      case normalize_release(manifest, release) do
        %{tag: ^tag} = normalized -> {:ok, normalized}
        _other -> {:error, {:release_tag_mismatch, tag}}
      end
    end
  end

  @spec fetch_checksums(Manifest.t(), release()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def fetch_checksums(manifest, release) do
    url = Manifest.asset_url(manifest, release.tag, manifest.checksums_asset)

    with {:ok, body} <- get_text(url), do: parse_checksums(body)
  end

  @doc """
  Parses `sha256sum` output strictly: every non-blank line must be
  `<64 hex> <name>` (an optional `*` binary marker), and a name may appear
  once. One malformed or duplicated line rejects the whole file.
  """
  @spec parse_checksums(String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def parse_checksums(body) when is_binary(body) do
    body
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, &add_checksum_line/2)
    |> require_entries()
  end

  defp add_checksum_line(line, {:ok, acc}) do
    case Regex.run(~r/\A([0-9A-Fa-f]{64})\s+\*?(\S+)\z/, line) do
      nil ->
        {:halt, {:error, {:invalid_checksum_line, line}}}

      [_, _sha, name] when is_map_key(acc, name) ->
        {:halt, {:error, {:duplicate_checksum, name}}}

      [_, sha, name] ->
        {:cont, {:ok, Map.put(acc, name, String.downcase(sha))}}
    end
  end

  defp require_entries({:ok, sums}) when map_size(sums) == 0,
    do: {:error, :empty_checksums}

  defp require_entries(result), do: result

  @spec checksum_for(%{String.t() => String.t()}, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def checksum_for(sums, name) do
    case Map.fetch(sums, name) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, {:missing_checksum, name}}
    end
  end

  @spec download(String.t(), Path.t()) :: :ok | {:error, term()}
  def download(url, destination) do
    ensure_started()
    _ = File.rm(destination)

    case :httpc.request(:get, {to_charlist(url), headers()}, http_options(url),
           stream: to_charlist(destination)
         ) do
      {:ok, :saved_to_file} ->
        :ok

      {:ok, {{_, status, _}, _headers, _body}} ->
        _ = File.rm(destination)
        {:error, {:http_status, status, url}}

      {:error, reason} ->
        _ = File.rm(destination)
        {:error, {:download_failed, url, reason}}
    end
  end

  @doc "Streams `path` through SHA-256 and compares with `expected` (hex)."
  @spec verify_file(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def verify_file(path, expected, name) do
    if sha256_file(path) == String.downcase(expected),
      do: :ok,
      else: {:error, {:checksum_mismatch, name}}
  rescue
    e in File.Error -> {:error, {:unreadable, name, e.reason}}
  end

  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Installs `new_exe` over `current_exe`.

  With a `backup_dir`, the current executable is first copied to
  `<backup_dir>/previous_version`, which is what rollback restores. The new
  file is staged next to the executable and renamed over it: a rename is
  atomic, and it never writes into the running binary's inode (Linux refuses
  that with `ETXTBSY`). On Windows the running executable cannot be
  replaced, so a detached batch file moves it into place after exit.
  """
  @spec install_executable(
          Path.t(),
          Path.t(),
          Path.t() | nil,
          Manifest.platform()
        ) ::
          :ok | {:error, term()}
  def install_executable(current_exe, new_exe, backup_dir, platform) do
    staged = staged_path(current_exe)

    with :ok <- backup(current_exe, backup_dir),
         :ok <- copy(new_exe, staged),
         :ok <- chmod(staged),
         :ok <- swap(staged, current_exe, Manifest.windows_platform?(platform)) do
      :ok
    else
      error ->
        _ = File.rm(staged)
        error
    end
  end

  defp backup(_current_exe, nil), do: :ok

  defp backup(current_exe, backup_dir) do
    with :ok <- File.mkdir_p(backup_dir),
         {:ok, _bytes} <-
           File.copy(current_exe, Path.join(backup_dir, "previous_version")) do
      :ok
    else
      {:error, reason} -> {:error, {:backup_failed, reason}}
    end
  end

  defp copy(source, dest) do
    case File.copy(source, dest) do
      {:ok, _bytes} -> :ok
      {:error, reason} -> {:error, {:stage_failed, reason}}
    end
  end

  defp chmod(path) do
    case File.chmod(path, 0o755) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod_failed, reason}}
    end
  end

  defp swap(staged, current_exe, false = _windows?) do
    case File.rename(staged, current_exe) do
      :ok -> :ok
      {:error, reason} -> {:error, {:replace_failed, reason}}
    end
  end

  defp swap(staged, current_exe, true = _windows?) do
    bat =
      Path.join(
        System.tmp_dir!(),
        "raxol-updater-#{System.unique_integer([:positive])}.bat"
      )

    body = """
    @echo off
    timeout /t 2 /nobreak > nul
    move /y "#{Path.expand(staged)}" "#{Path.expand(current_exe)}" > nul
    del "%~f0"
    """

    with :ok <- File.write(bat, body),
         {_output, 0} <- System.cmd("cmd", ["/c", "start", "/b", bat]) do
      :ok
    else
      {:error, reason} -> {:error, {:replace_failed, reason}}
      {output, status} -> {:error, {:replace_failed, {:cmd, status, output}}}
    end
  end

  defp staged_path(current_exe) do
    dir = Path.dirname(current_exe)
    base = Path.basename(current_exe)
    Path.join(dir, ".#{base}.#{System.unique_integer([:positive])}.update")
  end

  defp published?(%{"draft" => true}), do: false
  defp published?(%{"prerelease" => true}), do: false
  defp published?(%{"tag_name" => tag}) when is_binary(tag), do: true
  defp published?(_release), do: false

  # Only the tag and the asset names/sizes are taken from the API response;
  # download URLs are rebuilt from the manifest.
  defp normalize_release(manifest, %{"tag_name" => tag} = release) do
    case Manifest.version_from_tag(manifest, tag) do
      {:ok, version} ->
        %{version: version, tag: tag, assets: asset_sizes(release)}

      :error ->
        nil
    end
  end

  defp normalize_release(_manifest, _release), do: nil

  defp asset_sizes(%{"assets" => assets}) when is_list(assets) do
    for %{"name" => name} = asset <- assets, is_binary(name), into: %{} do
      {name, Map.get(asset, "size", 0)}
    end
  end

  defp asset_sizes(_release), do: %{}

  defp get_json(url) do
    with {:ok, body} <- get_text(url) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _reason} -> {:error, {:invalid_json, url}}
      end
    end
  end

  defp get_text(url) do
    ensure_started()

    case :httpc.request(:get, {to_charlist(url), headers()}, http_options(url),
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_status, status, url}}

      {:error, reason} ->
        {:error, {:request_failed, url, reason}}
    end
  end

  defp headers do
    [
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"user-agent", ~c"raxol-updater"}
    ]
  end

  defp http_options(url) do
    base = [timeout: @timeout, connect_timeout: @timeout, autoredirect: true]

    case URI.parse(url) do
      %URI{scheme: "https"} -> [{:ssl, ssl_options()} | base]
      _loopback_http -> base
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end
end
