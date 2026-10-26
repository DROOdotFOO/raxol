defmodule Raxol.MCP.ContextTree do
  @moduledoc """
  Assembles a structured context tree from multiple sources.

  The context tree provides a unified view of session state for AI agents.
  Different sources contribute subtrees (model projections, widget tree,
  tools, agents, notifications). Built on demand -- no cached state.

  ## Sources

  - `:model` -- TEA model projections from registered resources: what the
    app chose to expose in `mcp_resources/0`, each also readable at its own
    `raxol://session/<id>/model/<key>` URI. A secret an app projects there is
    exposed by that choice; nothing here redacts it.
  - `:widgets` -- current widget tree (types, IDs, bounds), without
    callbacks, and without the `:value` (on the node or in its `:attrs`) of
    a node that holds a secret: a `:password_field`, or a node with a
    `mask_char` (on the node or in its `:attrs`), as a masked
    `:text_input` has
  - `:tools` -- list of available MCP tools
  - `:session` -- session metadata (id, uptime)

  ## Roles

  `filter_for_role/2` restricts the tree based on a role atom:

  - `:full` -- everything (default)
  - `:observer` -- model + widgets + session (no tools)
  - `:operator` -- model + widgets + tools + session
  """

  alias Raxol.MCP.Registry

  @type source :: :model | :widgets | :tools | :session
  @type role :: :full | :observer | :operator
  @type context :: %{
          registry: GenServer.server(),
          session_id: term(),
          view_tree: map() | list() | nil,
          model: map() | nil
        }

  @doc """
  Build a context tree from the given sources.

  The `context` map must include `:registry` and `:session_id`.
  Optional keys: `:view_tree`, `:model`.
  """
  @spec build([source()], context()) :: map()
  def build(sources, context) do
    sources
    |> Enum.reduce(%{}, fn source, acc ->
      Map.put(acc, source, build_source(source, context))
    end)
  end

  @doc """
  Build a full context tree with all sources.
  """
  @spec build_all(context()) :: map()
  def build_all(context) do
    build([:model, :widgets, :tools, :session], context)
  end

  @doc """
  Filter a context tree for a given role.
  """
  @spec filter_for_role(map(), role()) :: map()
  def filter_for_role(tree, :full), do: tree
  def filter_for_role(tree, :observer), do: Map.take(tree, [:model, :widgets, :session])
  def filter_for_role(tree, :operator), do: Map.take(tree, [:model, :widgets, :tools, :session])

  # -- Source builders ---------------------------------------------------------

  defp build_source(:model, context) do
    prefix = "raxol://session/#{context.session_id}/model/"

    context.registry
    |> Registry.list_resources()
    |> Enum.filter(fn r -> String.starts_with?(r.uri, prefix) end)
    |> Enum.reduce(%{}, fn r, acc ->
      key = String.replace_prefix(r.uri, prefix, "")

      case Registry.read_resource(context.registry, r.uri) do
        {:ok, value} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp build_source(:widgets, %{view_tree: nil}), do: []

  defp build_source(:widgets, %{view_tree: tree}) do
    sanitize_tree(tree)
  end

  defp build_source(:tools, context) do
    Registry.list_tools(context.registry)
  end

  defp build_source(:session, context) do
    %{
      id: context.session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Strip callbacks and non-serializable values from a view tree, and the
  # value of a secret node: masked text is still the plaintext in the tree.
  defp sanitize_tree(node) when is_map(node) do
    node
    |> Map.drop([:callback, :on_click, :on_change, :on_submit])
    |> drop_secret_value()
    |> Map.new(fn {k, v} -> {k, sanitize_tree(v)} end)
  end

  defp sanitize_tree(nodes) when is_list(nodes) do
    Enum.map(nodes, &sanitize_tree/1)
  end

  defp sanitize_tree(other), do: other

  defp drop_secret_value(node) do
    attrs = Map.get(node, :attrs)

    if Map.get(node, :type) == :password_field or masked?(node) or
         (is_map(attrs) and masked?(attrs)) do
      node |> Map.delete(:value) |> drop_attrs_value()
    else
      node
    end
  end

  defp masked?(map), do: Map.get(map, :mask_char) != nil

  defp drop_attrs_value(%{attrs: %{} = attrs} = node),
    do: %{node | attrs: Map.delete(attrs, :value)}

  defp drop_attrs_value(node), do: node
end
