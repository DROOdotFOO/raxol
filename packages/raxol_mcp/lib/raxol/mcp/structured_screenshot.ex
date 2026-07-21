defmodule Raxol.MCP.StructuredScreenshot do
  @moduledoc """
  Converts a view tree into a clean, JSON-friendly widget summary.

  Used by the `raxol_screenshot` MCP tool to return structured content
  alongside the plain text capture. Strips callbacks and normalizes
  widget nodes to a consistent shape.
  """

  alias Raxol.Core.Accessibility.Projection
  alias Raxol.MCP.NodeChildren

  @type widget_summary :: %{
          required(:type) => atom(),
          required(:id) => String.t() | nil,
          required(:children) => [widget_summary()],
          optional(:content) => String.t(),
          optional(:animation_hints) => [map()],
          optional(:role) => atom(),
          optional(:label) => String.t(),
          optional(:state) => %{optional(atom()) => boolean() | atom()},
          optional(:value) => term(),
          optional(:focused) => boolean(),
          optional(:live) => boolean()
        }

  @doc """
  Convert a view tree map to a list of widget summaries.

  Each node retains `:type`, `:id`, `:content` (if text), and recursed
  `:children`. All callbacks and style details are stripped. Accessibility
  fields (`:role`, `:label`, `:state`, `:value`, `:focused`, `:live`) are folded
  in per node via `Raxol.Core.Accessibility.Projection` so agents get a
  machine-readable role/state alongside the structural tree.

  ## Options

    * `:focused_id` - Element id currently focused; marks that node `focused: true`
      in addition to any Component-reported focus.
    * `:type_map` - override the projection's declaration-type -> Component map.
  """
  @spec from_view_tree(map() | list() | nil, keyword()) :: [widget_summary()]
  def from_view_tree(tree, opts \\ [])

  def from_view_tree(nil, _opts), do: []

  def from_view_tree(nodes, opts) when is_list(nodes),
    do: Enum.map(nodes, &summarize_node(&1, opts))

  def from_view_tree(node, opts) when is_map(node), do: [summarize_node(node, opts)]

  @doc """
  Encode a widget summary list to a JSON string.
  """
  @spec to_json([widget_summary()]) :: String.t()
  def to_json(summaries) do
    case Jason.encode(summaries, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> "[]"
    end
  end

  # -- Private -----------------------------------------------------------------

  defp summarize_node(node, opts) when is_map(node) do
    # Direct + absolute-layer children come from the shared `NodeChildren`
    # walk so this resource can never disagree with `TreeWalker`'s tool
    # derivation about which widgets a node parents.
    children =
      node
      |> NodeChildren.child_nodes()
      |> Enum.map(&summarize_node(&1, opts))

    %{
      type: Map.get(node, :type, :unknown),
      id: Map.get(node, :id),
      children: children
    }
    |> maybe_put_content(Map.get(node, :content))
    |> maybe_put_hints(Map.get(node, :animation_hints))
    |> put_a11y(node, opts)
  end

  defp summarize_node(_node, _opts), do: %{type: :unknown, id: nil, children: []}

  # Folds the per-node accessibility descriptor into the summary. Additive: only
  # meaningful fields are attached (role always, others when present/truthy).
  defp put_a11y(summary, node, opts) do
    case Projection.descriptor(node, Keyword.take(opts, [:type_map])) do
      nil ->
        summary

      desc ->
        focused_id = Keyword.get(opts, :focused_id)

        focused =
          desc.state[:focused?] == true or
            (is_binary(focused_id) and desc.id == focused_id)

        summary
        |> Map.put(:role, desc.role)
        |> maybe_put(:label, desc.label)
        |> put_state(desc.state)
        |> maybe_put(:value, desc.value)
        |> maybe_put_focused(focused)
        |> maybe_put_live(desc.live?)
    end
  end

  defp put_state(summary, state) when map_size(state) == 0, do: summary
  defp put_state(summary, state), do: Map.put(summary, :state, state)

  defp maybe_put_focused(summary, true), do: Map.put(summary, :focused, true)
  defp maybe_put_focused(summary, _focused), do: summary

  defp maybe_put_live(summary, true), do: Map.put(summary, :live, true)
  defp maybe_put_live(summary, _live), do: summary

  defp maybe_put_content(summary, content) when is_binary(content),
    do: Map.put(summary, :content, content)

  defp maybe_put_content(summary, _), do: summary

  defp maybe_put_hints(summary, [_ | _] = hints) do
    case hints |> Enum.map(&serialize_hint/1) |> Enum.reject(&is_nil/1) do
      [] -> summary
      serialized -> Map.put(summary, :animation_hints, serialized)
    end
  end

  defp maybe_put_hints(summary, _), do: summary

  defp serialize_hint(%{type: :border_beam} = hint) do
    base = %{
      type: :border_beam,
      effect: Map.get(hint, :effect, :stroke),
      variant: Map.get(hint, :variant, :colorful),
      size: Map.get(hint, :size, :full),
      strength: Map.get(hint, :strength, 0.8),
      duration_ms: Map.get(hint, :duration_ms, 2000),
      active: Map.get(hint, :active, true)
    }

    base
    |> maybe_put(:brightness, Map.get(hint, :brightness))
    |> maybe_put(:saturation, Map.get(hint, :saturation))
    |> maybe_put(:hue_range, Map.get(hint, :hue_range))
    |> maybe_put(:static_colors, Map.get(hint, :static_colors))
    |> maybe_put(:period_ms, Map.get(hint, :period_ms))
    |> maybe_put(:density, Map.get(hint, :density))
    |> maybe_put(:frequency, Map.get(hint, :frequency))
    |> maybe_put(:bucket_ms, Map.get(hint, :bucket_ms))
    |> maybe_put(:softness, Map.get(hint, :softness))
  end

  defp serialize_hint(%{property: property} = hint) do
    %{
      property: property,
      duration_ms: Map.get(hint, :duration_ms, 300),
      easing: Map.get(hint, :easing, :ease_out_cubic),
      delay_ms: Map.get(hint, :delay_ms, 0)
    }
    |> maybe_put(:from, Map.get(hint, :from))
    |> maybe_put(:to, Map.get(hint, :to))
  end

  defp serialize_hint(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
