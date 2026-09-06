defmodule Raxol.Core.Accessibility.Projection do
  @moduledoc """
  Projects a declaration Element tree into an accessibility tree.

  The accessibility tree is a role/label/state descriptor tree that Surfaces
  (MCP, Browser) serialize to drive assistive technology. It is derived from the
  same Element tree that `Raxol.MCP.TreeWalker` walks (the `view/1` output synced
  to the Dispatcher), so a node here carries the discrete Component props.

  For each Element the projection either calls the Component's
  `Raxol.Core.Accessibility.Provider.a11y_node/1` (for the ~15 Components that
  implement it) or falls back to a default extraction driven by
  `Raxol.Core.Accessibility.Roles`. The projection is **total**: it never raises
  for any input, defaulting unknown types to `:generic` and rescuing a Provider
  that itself raises.

  ## Dependency direction

  This lives in raxol_core (which Browser and MCP both depend on, but which does
  NOT depend on main raxol). The `type -> module` map names Component modules in
  main raxol; they are resolved at runtime only when loaded, guarded by
  `Provider.provider?/1`, so raxol_core stays free of a main-raxol dependency.
  """

  require Logger

  alias Raxol.Core.Accessibility.{Provider, Roles}

  @type accessibility_node :: %{
          role: atom(),
          label: String.t() | nil,
          state: %{optional(atom()) => boolean() | atom()},
          value: term() | nil,
          children: [accessibility_node()],
          live?: boolean(),
          id: String.t() | nil
        }

  # Mirrors Raxol.MCP.TreeWalker's @default_type_map. Declaration type -> the
  # Component module that implements the Provider behaviour.
  @compile {:no_warn_undefined,
            [
              Raxol.UI.Components.Input.Button,
              Raxol.UI.Components.Input.TextInput,
              Raxol.UI.Components.Input.TextArea,
              Raxol.UI.Components.Input.PasswordField,
              Raxol.UI.Components.Input.SelectList,
              Raxol.UI.Components.Input.Checkbox,
              Raxol.UI.Components.Input.Menu,
              Raxol.UI.Components.Input.Tabs,
              Raxol.UI.Components.Modal,
              Raxol.UI.Components.Table,
              Raxol.UI.Components.Display.Tree,
              Raxol.UI.Components.Display.Viewport,
              Raxol.UI.Charts.BarChart,
              Raxol.UI.Charts.LineChart,
              Raxol.UI.Charts.ScatterChart,
              Raxol.UI.Components.Input.Scrubber
            ]}

  @default_type_map %{
    button: Raxol.UI.Components.Input.Button,
    text_input: Raxol.UI.Components.Input.TextInput,
    text_area: Raxol.UI.Components.Input.TextArea,
    password_field: Raxol.UI.Components.Input.PasswordField,
    select_list: Raxol.UI.Components.Input.SelectList,
    checkbox: Raxol.UI.Components.Input.Checkbox,
    menu: Raxol.UI.Components.Input.Menu,
    tabs: Raxol.UI.Components.Input.Tabs,
    modal: Raxol.UI.Components.Modal,
    table: Raxol.UI.Components.Table,
    tree: Raxol.UI.Components.Display.Tree,
    viewport: Raxol.UI.Components.Display.Viewport,
    bar_chart: Raxol.UI.Charts.BarChart,
    line_chart: Raxol.UI.Charts.LineChart,
    scatter_chart: Raxol.UI.Charts.ScatterChart,
    scrubber: Raxol.UI.Components.Input.Scrubber
  }

  # State keys whose `false` is meaningful (aria-checked=false differs from
  # absent); all other keys are dropped when false. `playing?` belongs here
  # for the same reason: a paused transport has to say so, and an absent key
  # reads as "this widget has no transport".
  @keep_false [:checked?, :selected?, :expanded?, :pressed?, :playing?]

  @doc """
  Projects an Element (or list of Elements) into an accessibility node (or list).

  ## Options

    * `:type_map` - override the declaration-type -> Component-module map
      (defaults to the built-in 16-Component map). Mirrors
      `Raxol.MCP.TreeWalker`'s `context.type_map`.
  """
  @spec project(map() | [map()] | nil, keyword()) ::
          accessibility_node() | [accessibility_node()] | nil
  def project(tree, opts \\ [])

  def project(nil, _opts), do: []

  def project(nodes, opts) when is_list(nodes) do
    Enum.map(nodes, &project(&1, opts))
  end

  def project(node, opts) when is_map(node) do
    type_map = Keyword.get(opts, :type_map, @default_type_map)
    build_node(node, type_map, opts)
  end

  def project(_other, _opts), do: nil

  @doc """
  Projects a single Element's own descriptor -- role/label/state/value/live?/id
  -- WITHOUT recursing its children (children is always `[]`).

  For Surfaces that walk the Element tree themselves (e.g. MCP
  `StructuredScreenshot`) and only need per-node a11y fields folded in.
  """
  @spec descriptor(map(), keyword()) :: accessibility_node() | nil
  def descriptor(node, opts \\ [])

  def descriptor(node, opts) when is_map(node) do
    type_map = Keyword.get(opts, :type_map, @default_type_map)
    type = Map.get(node, :type)

    raw =
      case provider_for(type, type_map) do
        {:ok, module} -> safe_provider(module, node)
        :none -> default_extract(node, type)
      end

    finalize(raw, [], node_id(node))
  end

  def descriptor(_node, _opts), do: nil

  @doc """
  Flat `id -> accessibility_node` map for Surfaces that key ARIA by Element id.

  Only nodes with a non-empty binary id are included.
  """
  @spec by_id(map() | [map()] | nil, keyword()) ::
          %{optional(String.t()) => accessibility_node()}
  def by_id(tree, opts \\ []) do
    tree
    |> project(opts)
    |> List.wrap()
    |> collect_by_id(%{})
  end

  # -- tree walk ---------------------------------------------------------------

  defp build_node(node, type_map, opts) do
    type = Map.get(node, :type)

    raw =
      case provider_for(type, type_map) do
        {:ok, module} -> safe_provider(module, node)
        :none -> default_extract(node, type)
      end

    # A Provider may synthesize its own children (SelectList options, Tabs, Table
    # rows); otherwise the projection recurses the Element's own children.
    children =
      case Map.fetch(raw, :children) do
        {:ok, kids} when is_list(kids) -> finalize_supplied(kids)
        _ -> project_children(Map.get(node, :children), type_map, opts)
      end

    finalize(raw, children, node_id(node))
  end

  # Normalizes a raw node (from a Provider or default extraction) into a complete
  # accessibility node, filling missing keys.
  defp finalize(raw, children, id) do
    role = Map.get(raw, :role, Roles.default_role())

    %{
      role: role,
      label: normalize_label(Map.get(raw, :label)),
      state: compact_state(Map.get(raw, :state, %{})),
      value: Map.get(raw, :value),
      children: children,
      live?: Map.get(raw, :live?, Roles.live?(role)),
      id: id
    }
  end

  # Provider-supplied children are terse maps; normalize each (recursively) so a
  # Provider can return %{role: :option, label: "x", state: %{selected?: true}}.
  defp finalize_supplied(kids) when is_list(kids) do
    kids |> Enum.map(&finalize_supplied_node/1) |> Enum.reject(&is_nil/1)
  end

  defp finalize_supplied_node(child) when is_map(child) do
    grandkids =
      case Map.fetch(child, :children) do
        {:ok, kids} when is_list(kids) -> finalize_supplied(kids)
        _ -> []
      end

    finalize(child, grandkids, node_id(child))
  end

  defp finalize_supplied_node(_child), do: nil

  defp project_children(kids, type_map, opts) when is_list(kids) do
    opts = Keyword.put(opts, :type_map, type_map)
    kids |> Enum.map(&project(&1, opts)) |> Enum.reject(&is_nil/1)
  end

  defp project_children(_other, _type_map, _opts), do: []

  defp collect_by_id(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_by_id/2)
  end

  defp collect_by_id(%{} = node, acc) do
    acc =
      case node[:id] do
        id when is_binary(id) and id != "" -> Map.put(acc, id, node)
        _ -> acc
      end

    collect_by_id(node[:children] || [], acc)
  end

  defp collect_by_id(_other, acc), do: acc

  # -- provider dispatch -------------------------------------------------------

  defp provider_for(type, type_map) when is_atom(type) do
    case Map.get(type_map, type) do
      nil -> :none
      module -> if Provider.provider?(module), do: {:ok, module}, else: :none
    end
  end

  defp provider_for(_type, _type_map), do: :none

  defp safe_provider(module, node) do
    module.a11y_node(node)
  rescue
    error ->
      Logger.debug("a11y_node/1 raised in #{inspect(module)}: #{inspect(error)}")
      default_extract(node, Map.get(node, :type))
  end

  # -- default extraction ------------------------------------------------------

  defp default_extract(node, type) do
    role = Roles.role_for(type)

    %{
      role: role,
      label: default_label(node),
      state: default_state(node),
      value: default_value(node, role),
      live?: Roles.live?(role)
    }
  end

  defp default_label(node) do
    node[:label] || node[:aria_label] || fetch_attr(node, :label) ||
      fetch_attr(node, :aria_label) || node[:content] || fetch_attr(node, :content)
  end

  # Default extraction surfaces only flags that are literally true; it never
  # invents `selected?: false` on Elements with no selection concept. Tri-state
  # `false` (aria-checked/selected) is the Provider's job, not the fallback's.
  defp default_state(node) do
    %{}
    |> put_flag(:disabled?, node[:disabled] || fetch_attr(node, :disabled))
    |> put_flag(:focused?, node[:focused] || fetch_attr(node, :focused))
    |> put_flag(:required?, node[:required] || fetch_attr(node, :required))
    |> put_flag(:selected?, node[:selected] || fetch_attr(node, :selected))
  end

  defp put_flag(state, key, true), do: Map.put(state, key, true)
  defp put_flag(state, _key, _value), do: state

  defp default_value(node, :textbox),
    do: node[:value] || fetch_attr(node, :value) || node[:content]

  defp default_value(node, :progressbar),
    do: node[:value] || fetch_attr(node, :value)

  defp default_value(_node, _role), do: nil

  # -- helpers -----------------------------------------------------------------

  defp fetch_attr(%{attrs: %{} = attrs}, key), do: Map.get(attrs, key)
  defp fetch_attr(_node, _key), do: nil

  defp node_id(node) do
    case Map.get(node, :id) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp normalize_label(label) when is_binary(label), do: label
  defp normalize_label(_label), do: nil

  defp compact_state(state) when is_map(state) do
    Enum.reduce(state, %{}, fn
      {_k, nil}, acc -> acc
      {k, false}, acc -> if k in @keep_false, do: Map.put(acc, k, false), else: acc
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp compact_state(_state), do: %{}
end
