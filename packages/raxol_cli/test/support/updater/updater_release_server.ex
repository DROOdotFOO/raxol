defmodule Raxol.Test.UpdaterReleaseServer do
  @moduledoc """
  A GitHub-shaped release channel served over real HTTP (cowboy on an
  ephemeral loopback port) for the self-updater tests.

  Routes are request paths, so the same fixture answers whatever base URL
  the manifest is pointed at. Each request path is relayed to the test
  process as `{:release_request, path}`; anything unrouted is a 404.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    send(opts[:test_pid], {:release_request, conn.request_path})

    case Map.fetch(opts[:routes], conn.request_path) do
      {:ok, body} -> send_resp(conn, 200, body)
      :error -> send_resp(conn, 404, "not found")
    end
  end

  @doc "Serves `routes`; returns the base URL to put in the manifest."
  @spec start(%{String.t() => binary()}) :: String.t()
  def start(routes) do
    ref = :"updater_release_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Plug.Cowboy.http(__MODULE__, [test_pid: self(), routes: routes],
        port: 0,
        ip: {127, 0, 0, 1},
        ref: ref
      )

    ExUnit.Callbacks.on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{:ranch.get_port(ref)}"
  end

  @doc """
  The API and download routes for one release: `tag` on `repo`, carrying
  `assets` (`name => bytes`) plus a `SHA256SUMS` computed from them unless
  `:checksums` overrides it. Every asset's `browser_download_url` points at
  a foreign host, so a download that trusted it would never arrive.

  `:listing` adds extra release objects to the `/releases` listing.
  """
  @spec release_routes(
          String.t(),
          String.t(),
          %{String.t() => binary()},
          keyword()
        ) ::
          %{String.t() => binary()}
  def release_routes(repo, tag, assets, opts \\ []) do
    sums = Keyword.get_lazy(opts, :checksums, fn -> sha256sums(assets) end)
    files = Map.put(assets, "SHA256SUMS", sums)
    release = release_json(tag, files)

    api = %{
      "/repos/#{repo}/releases/tags/#{tag}" => Jason.encode!(release),
      "/repos/#{repo}/releases" =>
        Jason.encode!([release | Keyword.get(opts, :listing, [])])
    }

    downloads =
      for {name, bytes} <- files, into: %{} do
        {"/#{repo}/releases/download/#{tag}/#{name}", bytes}
      end

    Map.merge(api, downloads)
  end

  @doc "A release object as the GitHub releases API returns it."
  @spec release_json(String.t(), %{String.t() => binary()}, keyword()) :: map()
  def release_json(tag, files, opts \\ []) do
    %{
      "tag_name" => tag,
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false),
      "assets" =>
        for {name, bytes} <- files do
          %{
            "name" => name,
            "size" => byte_size(bytes),
            "browser_download_url" => "https://attacker.invalid/#{name}"
          }
        end
    }
  end

  @spec sha256sums(%{String.t() => binary()}) :: String.t()
  def sha256sums(assets) do
    Enum.map_join(assets, fn {name, bytes} -> "#{sha256(bytes)}  #{name}\n" end)
  end

  @spec sha256(binary()) :: String.t()
  def sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
