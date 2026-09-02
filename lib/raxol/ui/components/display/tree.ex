defmodule Raxol.UI.Components.Display.Tree do
  @moduledoc """
  A tree view component with expand/collapse and keyboard navigation.

  Displays hierarchical data as an indented tree. Nodes can be expanded and
  collapsed. The cursor tracks the currently selected visible node.

  Node data format:
      %{id: atom, label: string, children: [node], data: any}

  Keyboard bindings:
  - Up/Down: move cursor through visible nodes
  - Right: expand collapsed node (if it has children)
  - Left: collapse expanded node, or move to parent
  - Enter/Space: toggle expand/collapse; fire on_select for leaf nodes
  - Home/End: jump to first/last visible node
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @type tree_node :: %{
          id: atom(),
          label: String.t(),
          children: [tree_node()],
          data: any()
        }

  @type t :: %{
          id: String.t() | atom(),
          nodes: [tree_node()],
          expanded: MapSet.t(),
          cursor: atom() | nil,
          focused: boolean(),
          indent_size: non_neg_integer(),
          on_select: (atom(), any() -> any()) | nil,
          on_expand: (atom() -> any()) | nil,
          on_collapse: (atom() -> any()) | nil,
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    nodes = Keyword.get(props, :nodes, [])

    state = %{
      id: Keyword.get_lazy(props, :id, fn -> Raxol.Core.ID.next("tree") end),
      nodes: nodes,
      expanded: Keyword.get(props, :expanded, MapSet.new()),
      cursor: Keyword.get(props, :cursor, first_node_id(nodes)),
      focused: Keyword.get(props, :focused, false),
      indent_size: Keyword.get(props, :indent_size, 2),
      on_select: Keyword.get(props, :on_select),
      on_expand: Keyword.get(props, :on_expand),
      on_collapse: Keyword.get(props, :on_collapse),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # Down arrow -- next visible node
  @impl true
  def handle_event(%Event{type: :key, data: %{key: :down}}, state, _context) do
    visible = visible_nodes(state)
    new_cursor = next_in_list(visible, state.cursor)
    {%{state | cursor: new_cursor}, []}
  end

  # Up arrow -- previous visible node
  def handle_event(%Event{type: :key, data: %{key: :up}}, state, _context) do
    visible = visible_nodes(state)
    new_cursor = prev_in_list(visible, state.cursor)
    {%{state | cursor: new_cursor}, []}
  end

  # Right arrow -- expand current node
  def handle_event(%Event{type: :key, data: %{key: :right}}, state, _context) do
    handle_expand(state)
  end

  # Left arrow -- collapse current node or move to parent
  def handle_event(%Event{type: :key, data: %{key: :left}}, state, _context) do
    handle_collapse_or_parent(state)
  end

  # Enter/Space -- toggle expand/collapse; on leaf fire on_select
  def handle_event(%Event{type: :key, data: %{key: :enter}}, state, _context) do
    handle_activate(state)
  end

  def handle_event(%Event{type: :key, data: %{key: :space}}, state, _context) do
    handle_activate(state)
  end

  # Home -- first visible node
  def handle_event(%Event{type: :key, data: %{key: :home}}, state, _context) do
    visible = visible_nodes(state)

    case visible do
      [{node, _depth} | _] -> {%{state | cursor: node.id}, []}
      [] -> {state, []}
    end
  end

  # End -- last visible node
  def handle_event(%Event{type: :key, data: %{key: :end}}, state, _context) do
    visible = visible_nodes(state)

    case List.last(visible) do
      {node, _depth} -> {%{state | cursor: node.id}, []}
      nil -> {state, []}
    end
  end

  # Focus/blur
  def handle_event(%Event{type: :focus}, state, _context) do
    {%{state | focused: true}, []}
  end

  def handle_event(%Event{type: :blur}, state, _context) do
    {%{state | focused: false}, []}
  end

  # Pass-through
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    focused = Raxol.UI.FocusHelper.focused?(state.id, context) or state.focused
    state = %{state | focused: focused}

    base_style =
      StyleHelper.merge_component_styles_with_focus(state, context, :tree)

    visible = visible_nodes(state)
    children = build_children(state, visible)

    %{
      type: :column,
      style: base_style,
      children: children
    }
  end

  # --- Public helpers ---

  @doc """
  Returns a flat list of `{node, depth}` tuples for all currently visible nodes,
  respecting the expanded set. Children of collapsed nodes are omitted.
  """
  @spec visible_nodes(t()) :: [{tree_node(), non_neg_integer()}]
  def visible_nodes(%{nodes: nodes, expanded: expanded}) do
    flatten_visible(nodes, expanded, 0)
  end

  @doc """
  Recursively searches for a node by id in the tree.
  """
  @spec find_node([tree_node()], atom()) :: tree_node() | nil
  def find_node([], _id), do: nil

  def find_node([%{id: id} = node | _rest], id), do: node

  def find_node([%{children: children} | rest], id) do
    case find_node(children, id) do
      nil -> find_node(rest, id)
      found -> found
    end
  end

  def find_node([_ | rest], id), do: find_node(rest, id)

  @doc """
  Finds the parent of a node by id. Returns nil if the node is a root or not found.
  """
  @spec find_parent([tree_node()], atom()) :: tree_node() | nil
  def find_parent(nodes, id) do
    find_parent_in(nodes, id, nil)
  end

  # --- Private helpers ---

  defp first_node_id([]), do: nil
  defp first_node_id([%{id: id} | _]), do: id

  defp flatten_visible([], _expanded, _depth), do: []

  defp flatten_visible([node | rest], expanded, depth) do
    entry = [{node, depth}]

    child_entries =
      if MapSet.member?(expanded, node.id) and node.children != [] do
        flatten_visible(node.children, expanded, depth + 1)
      else
        []
      end

    entry ++ child_entries ++ flatten_visible(rest, expanded, depth)
  end

  defp next_in_list(visible, cursor) do
    case Enum.drop_while(visible, fn {node, _} -> node.id != cursor end) do
      [_current, {next, _} | _] -> next.id
      _ -> cursor
    end
  end

  defp prev_in_list(visible, cursor) do
    visible
    |> Enum.reduce_while({:searching, cursor}, fn {node, _}, {_, prev} ->
      if node.id == cursor do
        {:halt, {:found, prev}}
      else
        {:cont, {:searching, node.id}}
      end
    end)
    |> case do
      {:found, prev_id} -> prev_id
      _ -> cursor
    end
  end

  defp handle_expand(state) do
    node = find_node(state.nodes, state.cursor)

    cond do
      node == nil ->
        {state, []}

      node.children != [] and not MapSet.member?(state.expanded, state.cursor) ->
        new_expanded = MapSet.put(state.expanded, state.cursor)
        fire_callback(state.on_expand, state.cursor)
        {%{state | expanded: new_expanded}, []}

      true ->
        {state, []}
    end
  end

  defp handle_collapse_or_parent(state) do
    if MapSet.member?(state.expanded, state.cursor) do
      new_expanded = MapSet.delete(state.expanded, state.cursor)
      fire_callback(state.on_collapse, state.cursor)
      {%{state | expanded: new_expanded}, []}
    else
      parent = find_parent(state.nodes, state.cursor)

      if parent do
        {%{state | cursor: parent.id}, []}
      else
        {state, []}
      end
    end
  end

  defp handle_activate(state) do
    node = find_node(state.nodes, state.cursor)

    cond do
      node == nil ->
        {state, []}

      node.children == [] ->
        fire_select(state.on_select, node.id, node[:data])
        {state, []}

      MapSet.member?(state.expanded, state.cursor) ->
        new_expanded = MapSet.delete(state.expanded, state.cursor)
        fire_callback(state.on_collapse, state.cursor)
        {%{state | expanded: new_expanded}, []}

      true ->
        new_expanded = MapSet.put(state.expanded, state.cursor)
        fire_callback(state.on_expand, state.cursor)
        {%{state | expanded: new_expanded}, []}
    end
  end

  defp fire_callback(nil, _id), do: :ok
  defp fire_callback(cb, id) when is_function(cb, 1), do: cb.(id)

  defp fire_select(nil, _id, _data), do: :ok
  defp fire_select(cb, id, data) when is_function(cb, 2), do: cb.(id, data)

  defp find_parent_in([], _id, _parent), do: nil

  defp find_parent_in([%{id: id} | _rest], id, parent), do: parent

  defp find_parent_in([%{children: children} = node | rest], id, parent) do
    case find_parent_in(children, id, node) do
      nil -> find_parent_in(rest, id, parent)
      found -> found
    end
  end

  defp find_parent_in([_ | rest], id, parent) do
    find_parent_in(rest, id, parent)
  end

  defp build_children(_state, []), do: []

  defp build_children(state, visible) do
    Enum.map(visible, fn {node, depth} ->
      indent = String.duplicate(" ", depth * state.indent_size)
      icon = node_icon(node, state.expanded)

      line_style =
        if node.id == state.cursor do
          Raxol.Core.Defaults.selected_style()
        else
          %{}
        end

      Raxol.View.Components.text(
        id: "#{state.id}-node-#{node.id}",
        content: "#{indent}#{icon} #{node.label}",
        style: line_style
      )
    end)
  end

  defp node_icon(%{children: []}, _expanded), do: " "

  defp node_icon(%{id: id}, expanded) do
    if MapSet.member?(expanded, id), do: "▼", else: "▶"
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(_state) do
    [
      %{
        name: "expand",
        description: "Expand a tree node by ID",
        inputSchema: %{
          type: "object",
          properties: %{
            node_id: %{type: "string", description: "Node ID to expand"}
          },
          required: ["node_id"]
        }
      },
      %{
        name: "collapse",
        description: "Collapse a tree node by ID",
        inputSchema: %{
          type: "object",
          properties: %{
            node_id: %{type: "string", description: "Node ID to collapse"}
          },
          required: ["node_id"]
        }
      },
      %{
        name: "select_node",
        description: "Select a tree node by ID",
        inputSchema: %{
          type: "object",
          properties: %{
            node_id: %{type: "string", description: "Node ID to select"}
          },
          required: ["node_id"]
        }
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("expand", %{"node_id" => node_id}, context) do
    {:ok, "Expanded node '#{node_id}'",
     [{:tree_expand, context.widget_id, node_id}]}
  end

  def handle_tool_call("collapse", %{"node_id" => node_id}, context) do
    {:ok, "Collapsed node '#{node_id}'",
     [{:tree_collapse, context.widget_id, node_id}]}
  end

  def handle_tool_call("select_node", %{"node_id" => node_id}, context) do
    {:ok, "Selected node '#{node_id}'",
     [{:tree_select, context.widget_id, node_id}]}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    %{
      role: :tree,
      label: node[:aria_label] || node[:label],
      children: a11y_tree_items(node[:nodes] || [], node[:expanded])
    }
  end

  defp a11y_tree_items(nodes, expanded) do
    Enum.map(nodes, fn tree_node ->
      children = tree_node[:children] || []
      is_expanded = a11y_expanded?(expanded, tree_node[:id])

      %{
        role: :treeitem,
        label: a11y_cell_text(tree_node[:label]),
        id: a11y_atom_id(tree_node[:id]),
        state: if(children == [], do: %{}, else: %{expanded?: is_expanded}),
        children:
          if(is_expanded, do: a11y_tree_items(children, expanded), else: [])
      }
    end)
  end

  defp a11y_expanded?(%MapSet{} = set, id), do: MapSet.member?(set, id)
  defp a11y_expanded?(list, id) when is_list(list), do: id in list
  defp a11y_expanded?(_expanded, _id), do: false

  defp a11y_atom_id(id) when is_binary(id), do: id

  defp a11y_atom_id(id) when is_atom(id) and not is_nil(id),
    do: Atom.to_string(id)

  defp a11y_atom_id(_id), do: nil

  defp a11y_cell_text(text) when is_binary(text), do: text
  defp a11y_cell_text(nil), do: nil
  defp a11y_cell_text(text), do: to_string(text)
end
