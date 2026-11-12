defmodule Raxol.System.Updater.Manifest do
  @moduledoc """
  Where a self-update comes from and what a release has to contain.

  Every URL the updater fetches is built here, from the manifest and a
  validated version, never from a release's own `browser_download_url`. A
  release listing therefore cannot point a download at another repository
  or another tag.

  The default manifest is the `raxol` CLI release channel: `raxol-cli-v*`
  tags on `DROOdotFOO/raxol`, one raw binary per platform plus `SHA256SUMS`
  and the Sigstore bundle `raxol-cli-attestation.sigstore.json`, as
  `.github/workflows/release-raxol-cli.yml` and
  `scripts/build_cli_release_manifest.mjs` publish them. The installed
  version is read from the `:raxol_cli` application.

  The manifest also says who must have built a release. With
  `provenance: :required` (the default) an asset is installed only when
  the release's `attestation_asset` proves, via
  `Raxol.System.Updater.Provenance`, that `signer_workflow` in `repo` built
  it for the release's tag. `provenance: :off` turns that off, for a
  channel that publishes no attestation.

  An application that ships its own binary configures its own channel:

      config :raxol, :updater_manifest,
        repo: "acme/widget",
        tag_prefix: "v",
        app: :widget,
        assets: %{"linux-x64" => "widget-linux-x64.tar.gz"},
        format: {:tar_gz, "widget"},
        attestation_asset: "widget.sigstore.json",
        signer_workflow: ".github/workflows/release.yml"

  Base URLs must be `https`. Plain `http` is accepted only for loopback
  hosts, which is what the updater's own tests serve releases from.
  """

  @type platform :: String.t()
  @type format :: :binary | {:tar_gz, String.t()} | {:zip, String.t()}

  @type t :: %__MODULE__{
          repo: String.t(),
          tag_prefix: String.t(),
          app: atom(),
          assets: %{platform() => String.t()},
          checksums_asset: String.t(),
          format: format(),
          provenance: :required | :off,
          attestation_asset: String.t(),
          signer_workflow: String.t(),
          api_base: String.t(),
          download_base: String.t()
        }

  defstruct repo: "DROOdotFOO/raxol",
            tag_prefix: "raxol-cli-v",
            app: :raxol_cli,
            assets: %{
              "darwin-arm64" => "raxol_cli_macos",
              "linux-x64" => "raxol_cli_linux",
              "linux-arm64" => "raxol_cli_linux_arm",
              "win32-x64" => "raxol_cli_windows.exe"
            },
            checksums_asset: "SHA256SUMS",
            format: :binary,
            provenance: :required,
            attestation_asset: "raxol-cli-attestation.sigstore.json",
            signer_workflow: ".github/workflows/release-raxol-cli.yml",
            api_base: "https://api.github.com",
            download_base: "https://github.com"

  @loopback_hosts ["127.0.0.1", "localhost", "::1"]
  @version_re ~r/\A\d+\.\d+\.\d+\z/
  @repo_re ~r/\A[A-Za-z0-9](?:[A-Za-z0-9._-]*)\/[A-Za-z0-9._-]+\z/
  @name_re ~r/\A[A-Za-z0-9._-]+\z/
  @prefix_re ~r/\A[A-Za-z0-9._-]*\z/
  @workflow_re ~r/\A\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml\z/

  @doc """
  The manifest for this call: `opts[:manifest]` (a struct or overrides),
  else `config :raxol, :updater_manifest`, else the default channel.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    case Keyword.get(opts, :manifest) do
      %__MODULE__{} = manifest -> validate(manifest)
      nil -> :raxol |> Application.get_env(:updater_manifest, []) |> new()
      overrides -> new(overrides)
    end
  end

  @doc "Builds a validated manifest from overrides of the default channel."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(overrides) do
    overrides = Map.new(overrides)
    known = %__MODULE__{} |> Map.from_struct() |> Map.keys()

    case Map.keys(overrides) -- known do
      [] -> validate(struct(__MODULE__, overrides))
      unknown -> {:error, {:unknown_manifest_keys, unknown}}
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = m) do
    case Enum.find(checks(m), fn {_field, valid?} -> not valid? end) do
      nil ->
        {:ok, m}

      {field, false} ->
        {:error, {:invalid_manifest, field, Map.fetch!(m, field)}}
    end
  end

  defp checks(m) do
    [
      repo: match_string?(@repo_re, m.repo),
      tag_prefix: match_string?(@prefix_re, m.tag_prefix),
      app: is_atom(m.app),
      assets: valid_assets?(m.assets),
      checksums_asset: safe_name?(m.checksums_asset),
      format: valid_format?(m.format),
      provenance: m.provenance in [:required, :off],
      attestation_asset: safe_name?(m.attestation_asset),
      signer_workflow: match_string?(@workflow_re, m.signer_workflow),
      api_base: allowed_base?(m.api_base),
      download_base: allowed_base?(m.download_base)
    ]
  end

  @doc """
  Normalizes a version (`"1.2.3"`, `"v1.2.3"`, `"1.2.3+abc"`) to
  `MAJOR.MINOR.PATCH` and refuses anything else, so a version can never
  smuggle a path segment into a release URL. Build metadata carries no
  ordering and is dropped; pre-release versions are refused.
  """
  @spec normalize_version(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_version(version) when is_binary(version) do
    normalized =
      version
      |> String.trim_leading("v")
      |> String.split("+", parts: 2)
      |> hd()

    if Regex.match?(@version_re, normalized),
      do: {:ok, normalized},
      else: {:error, {:invalid_version, version}}
  end

  def normalize_version(version), do: {:error, {:invalid_version, version}}

  @spec tag(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def tag(%__MODULE__{tag_prefix: prefix}, version) do
    with {:ok, v} <- normalize_version(version), do: {:ok, prefix <> v}
  end

  @doc "The version a tag on this channel names, or `:error` for any other tag."
  @spec version_from_tag(t(), term()) :: {:ok, String.t()} | :error
  def version_from_tag(%__MODULE__{tag_prefix: prefix}, tag)
      when is_binary(tag) do
    with true <- String.starts_with?(tag, prefix),
         version =
           binary_part(
             tag,
             byte_size(prefix),
             byte_size(tag) - byte_size(prefix)
           ),
         true <- Regex.match?(@version_re, version) do
      {:ok, version}
    else
      _ -> :error
    end
  end

  def version_from_tag(_manifest, _tag), do: :error

  @spec releases_url(t()) :: String.t()
  def releases_url(%__MODULE__{} = m),
    do: "#{m.api_base}/repos/#{m.repo}/releases?per_page=30"

  @spec release_url(t(), String.t()) :: String.t()
  def release_url(%__MODULE__{} = m, tag),
    do: "#{m.api_base}/repos/#{m.repo}/releases/tags/#{tag}"

  @spec asset_url(t(), String.t(), String.t()) :: String.t()
  def asset_url(%__MODULE__{} = m, tag, name),
    do: "#{m.download_base}/#{m.repo}/releases/download/#{tag}/#{name}"

  @doc "The human-facing releases page, for error messages."
  @spec releases_page_url(t()) :: String.t()
  def releases_page_url(%__MODULE__{} = m),
    do: "#{m.download_base}/#{m.repo}/releases"

  @spec release_page_url(t(), String.t()) :: String.t()
  def release_page_url(%__MODULE__{} = m, tag),
    do: "#{m.download_base}/#{m.repo}/releases/tag/#{tag}"

  @spec asset(t(), platform()) :: {:ok, String.t()} | {:error, term()}
  def asset(%__MODULE__{assets: assets}, platform) do
    case Map.fetch(assets, platform) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:unsupported_platform, platform}}
    end
  end

  @doc "The installed version of the manifest's application."
  @spec installed_version(t()) :: {:ok, String.t()} | {:error, term()}
  def installed_version(%__MODULE__{app: app}) do
    case Application.spec(app, :vsn) do
      nil -> {:error, {:unknown_installed_version, app}}
      vsn -> normalize_version(to_string(vsn))
    end
  end

  @doc "The platform key of the running host, in the manifest's naming."
  @spec host_platform() :: {:ok, platform()} | {:error, term()}
  def host_platform do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    case platform_for(:os.type(), arch_family(arch)) do
      nil -> {:error, {:unsupported_platform, "#{inspect(:os.type())} #{arch}"}}
      platform -> {:ok, platform}
    end
  end

  @spec windows_platform?(platform()) :: boolean()
  def windows_platform?(platform), do: String.starts_with?(platform, "win32")

  defp arch_family(arch) do
    cond do
      String.contains?(arch, ["aarch64", "arm64"]) -> :arm64
      String.contains?(arch, ["x86_64", "amd64"]) -> :x64
      true -> :other
    end
  end

  defp platform_for({:unix, :darwin}, :arm64), do: "darwin-arm64"
  defp platform_for({:unix, :darwin}, _arch), do: nil
  defp platform_for({:unix, _os}, :x64), do: "linux-x64"
  defp platform_for({:unix, _os}, :arm64), do: "linux-arm64"
  defp platform_for({:win32, _os}, _arch), do: "win32-x64"
  defp platform_for(_os, _arch), do: nil

  defp valid_assets?(assets) when is_map(assets) and map_size(assets) > 0 do
    Enum.all?(assets, fn {platform, name} ->
      safe_name?(platform) and safe_name?(name)
    end)
  end

  defp valid_assets?(_assets), do: false

  defp valid_format?(:binary), do: true

  defp valid_format?({kind, exe}) when kind in [:tar_gz, :zip],
    do: safe_name?(exe)

  defp valid_format?(_format), do: false

  defp safe_name?(name),
    do: match_string?(@name_re, name) and name not in [".", ".."]

  defp match_string?(re, value),
    do: is_binary(value) and Regex.match?(re, value)

  defp allowed_base?(base) when is_binary(base) do
    case URI.parse(base) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and host != "" and path in [nil, ""] ->
        true

      %URI{
        scheme: "http",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when host in @loopback_hosts and path in [nil, ""] ->
        true

      _ ->
        false
    end
  end

  defp allowed_base?(_base), do: false
end
