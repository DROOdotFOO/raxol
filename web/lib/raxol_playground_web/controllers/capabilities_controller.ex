defmodule RaxolPlaygroundWeb.CapabilitiesController do
  @moduledoc """
  Machine-readable endpoints for agent discovery.
  /.well-known/raxol.json: capability manifest
  /api/capabilities: detailed capabilities
  /llms.txt: LLM-friendly project summary

  All facts derive from `RaxolPlayground.Capabilities` (the single source of
  truth), so these endpoints never restate surfaces, packages, or backends.
  """
  use RaxolPlaygroundWeb, :controller

  alias RaxolPlayground.Capabilities

  @llms_txt_path Path.join(:code.priv_dir(:raxol_playground), "static/llms.txt")
  @llms_full_path Path.join(
                    :code.priv_dir(:raxol_playground),
                    "static/llms-full.txt"
                  )

  def manifest(conn, _params) do
    json(conn, %{
      name: "raxol",
      description: "Multi-surface runtime for Elixir on OTP",
      version: Capabilities.version(),
      surfaces: Capabilities.surface_names(),
      links: Capabilities.links(),
      packages: Capabilities.package_specs(),
      mcp: Capabilities.mcp()
    })
  end

  def capabilities(conn, _params) do
    components = Raxol.Playground.Catalog.list_components()
    categories = Raxol.Playground.Catalog.list_categories()

    json(conn, %{
      surfaces: Capabilities.surfaces(),
      agent: Capabilities.agent(),
      packages: Capabilities.package_specs(),
      widgets: %{
        count: length(components),
        categories: Enum.map(categories, &to_string/1),
        names: Enum.map(components, & &1.name)
      }
    })
  end

  def llms_txt(conn, _params), do: serve_text(conn, @llms_txt_path, "llms.txt")

  def llms_full(conn, _params),
    do: serve_text(conn, @llms_full_path, "llms-full.txt")

  defp serve_text(conn, path, name) do
    content =
      case File.read(path) do
        {:ok, data} ->
          data

        {:error, _} ->
          "# Raxol\n\n#{name} not found. Run `mix raxol.docs.llms`."
      end

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, content)
  end
end
