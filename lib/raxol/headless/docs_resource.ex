defmodule Raxol.Headless.DocsResource do
  @moduledoc """
  Exposes the Raxol documentation tree as MCP resources under `raxol://docs/...`.

  An agent connected to `mix mcp.server` can pull Raxol's own docs mid-task
  (`resources/read` on `raxol://docs/features/CODING_AGENT.md`, and so on),
  because doc-serving is just another registry surface alongside the headless
  tools. Neither a static `llms.txt` nor a hosted docs site can do this.

  Docs are read from the repo `docs/` tree, located relative to the working
  directory. When no `docs/` tree is present (a Hex-installed library rather
  than a checkout), no resources are registered and this is a no-op.
  """

  @compile {:no_warn_undefined, Raxol.MCP.Registry}

  # Curated doc set exposed as resources. Files are used as-is; directories
  # expand to their top-level `*.md` files.
  @curated ["README.md", "getting-started", "features", "reference"]

  @doc """
  Register the docs resources with the MCP registry. Safe to call when
  `raxol_mcp` is unavailable or no `docs/` tree is found: returns `:ok`.
  """
  @spec register(GenServer.server()) :: :ok
  def register(registry \\ Raxol.MCP.Registry) do
    with true <- Code.ensure_loaded?(Raxol.MCP.Registry),
         root when is_binary(root) <- docs_root(),
         [_ | _] = resources <- resources(root) do
      Raxol.MCP.Registry.register_resources(registry, resources)
    else
      _ -> :ok
    end
  end

  @doc "Build the resource definitions from a `docs/` root, without registering."
  @spec resources(String.t()) :: [map()]
  def resources(root) do
    root
    |> curated_files()
    |> Enum.map(fn path ->
      rel = Path.relative_to(path, root)

      %{
        uri: "raxol://docs/" <> rel,
        name: doc_title(path),
        description: "Raxol documentation: docs/" <> rel,
        callback: fn -> read(path) end
      }
    end)
  end

  # --- helpers --------------------------------------------------------------

  defp curated_files(root) do
    @curated
    |> Enum.flat_map(fn entry ->
      path = Path.join(root, entry)

      cond do
        File.dir?(path) ->
          path |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()

        File.regular?(path) ->
          [path]

        true ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp doc_title(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", parts: 30)
        |> Enum.find_value(fn line ->
          case String.trim(line) do
            "# " <> title -> title
            _ -> nil
          end
        end)
        |> Kernel.||(Path.basename(path))

      _ ->
        Path.basename(path)
    end
  end

  defp docs_root do
    candidate = Path.join(File.cwd!(), "docs")
    if File.dir?(candidate), do: candidate, else: nil
  end
end
