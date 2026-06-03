defmodule Raxol.UI.Components.Input.Menu do
  @moduledoc """
  A nested menu component with keyboard navigation.

  Supports flat and nested menus with the same component. Only one submenu
  chain can be open at a time (standard menu behavior).

  Item data format:

      %{id: atom, label: string, children: [item], disabled: boolean, shortcut: string | nil}

  - `children: []` = leaf (selectable action item)
  - `children: [...]` = submenu parent
  - `disabled: true` = rendered dimmed, skipped during navigation
  - `shortcut` = optional hint text rendered right-aligned (e.g. "Ctrl+S")

  Keyboard bindings:
  - Up/Down: move cursor through visible items (skip disabled), clamped
  - Right: open submenu of current item (if it has children)
  - Left: close current submenu level, move cursor to parent
  - Enter/Space: fire on_select for leaf items; open submenu for parents
  - Home/End: jump to first/last visible non-disabled item
  - Escape: close deepest open submenu (or pass through)
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider

  @type menu_item :: %{
          id: atom(),
          label: String.t(),
          children: [menu_item()],
          disabled: boolean(),
          shortcut: String.t() | nil
        }

  @type t :: %{
          id: String.t() | atom(),
          items: [menu_item()],
          cursor: atom() | nil,
          open_path: [atom()],
          focused: boolean(),
          on_select: (atom() -> any()) | nil,
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    items = Keyword.get(props, :items, [])

    state = %{
      id:
        Keyword.get(props, :id, "menu-#{:erlang.unique_integer([:positive])}"),
      items: items,
      cursor: Keyword.get(props, :cursor, first_enabled_id(items)),
      open_path: Keyword.get(props, :open_path, []),
      focused: Keyword.get(props, :focused, false),
      on_select: Keyword.get(props, :on_select),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # Down arrow -- next visible enabled item
  @impl true
  def handle_event(%Event{type: :key, data: %{key: :down}}, state, _context) do
    visible = visible_items(state)
    new_cursor = next_enabled(visible, state.cursor)
    {%{state | cursor: new_cursor}, []}
  end

  # Up arrow -- previous visible enabled item
  def handle_event(%Event{type: :key, data: %{key: :up}}, state, _context) do
    visible = visible_items(state)
    new_cursor = prev_enabled(visible, state.cursor)
    {%{state | cursor: new_cursor}, []}
  end

  # Right arrow -- open submenu
  def handle_event(%Event{type: :key, data: %{key: :right}}, state, _context) do
    handle_open_submenu(state)
  end

  # Left arrow -- close submenu, move to parent
  def handle_event(%Event{type: :key, data: %{key: :left}}, state, _context) do
    handle_close_submenu(state)
  end

  # Enter/Space -- activate current item
  def handle_event(%Event{type: :key, data: %{key: :enter}}, state, _context) do
    handle_activate(state)
  end

  def handle_event(%Event{type: :key, data: %{key: :space}}, state, _context) do
    handle_activate(state)
  end

  # Escape -- close deepest submenu
  def handle_event(%Event{type: :key, data: %{key: :escape}}, state, _context) do
    case state.open_path do
      [] ->
        {state, []}

      path ->
        closed_id = List.last(path)
        new_path = Enum.drop(path, -1)
        {%{state | open_path: new_path, cursor: closed_id}, []}
    end
  end

  # Home -- first visible enabled item
  def handle_event(%Event{type: :key, data: %{key: :home}}, state, _context) do
    visible = visible_items(state)

    case first_enabled_in(visible) do
      nil -> {state, []}
      id -> {%{state | cursor: id}, []}
    end
  end

  # End -- last visible enabled item
  def handle_event(%Event{type: :key, data: %{key: :end}}, state, _context) do
    visible = visible_items(state)

    case last_enabled_in(visible) do
      nil -> {state, []}
      id -> {%{state | cursor: id}, []}
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
      StyleHelper.merge_component_styles_with_focus(state, context, :menu)

    visible = visible_items(state)
    children = build_children(state, visible)

    %{
      type: :column,
      style: base_style,
      children: children
    }
  end

  # --- Public helpers ---

  @doc """
  Returns a flat list of `{item, depth}` tuples for all currently visible items,
  respecting the open_path. Only the single open submenu chain is expanded.
  """
  @spec visible_items(t()) :: [{menu_item(), non_neg_integer()}]
  def visible_items(%{items: items, open_path: open_path}) do
    flatten_visible(items, open_path, 0)
  end

  @doc """
  Recursively searches for an item by id.
  """
  @spec find_item([menu_item()], atom()) :: menu_item() | nil
  def find_item([], _id), do: nil

  def find_item([%{id: id} = item | _rest], id), do: item

  def find_item([%{children: children} | rest], id) do
    case find_item(children, id) do
      nil -> find_item(rest, id)
      found -> found
    end
  end

  def find_item([_ | rest], id), do: find_item(rest, id)

  @doc """
  Finds the parent of an item by id. Returns nil if it's a root item or not found.
  """
  @spec find_parent([menu_item()], atom()) :: menu_item() | nil
  def find_parent(nodes, id) do
    find_parent_in(nodes, id, nil)
  end

  # --- Private helpers ---

  defp first_enabled_id([]), do: nil

  defp first_enabled_id([%{disabled: true} | rest]), do: first_enabled_id(rest)
  defp first_enabled_id([%{id: id} | _rest]), do: id

  defp flatten_visible([], _open_path, _depth), do: []

  defp flatten_visible([item | rest], open_path, depth) do
    entry = [{item, depth}]

    child_entries =
      if item.id in open_path and item.children != [] do
        flatten_visible(item.children, open_path, depth + 1)
      else
        []
      end

    entry ++ child_entries ++ flatten_visible(rest, open_path, depth)
  end

  defp next_enabled(visible, cursor) do
    case Enum.drop_while(visible, fn {item, _} -> item.id != cursor end) do
      [_current | rest] ->
        Enum.find_value(rest, cursor, fn {item, _} ->
          if Map.get(item, :disabled, false), do: nil, else: item.id
        end)

      [] ->
        cursor
    end
  end

  defp prev_enabled(visible, cursor) do
    visible
    |> Enum.take_while(fn {item, _} -> item.id != cursor end)
    |> Enum.reverse()
    |> Enum.find_value(cursor, fn {item, _} ->
      if Map.get(item, :disabled, false), do: nil, else: item.id
    end)
  end

  defp first_enabled_in(visible) do
    Enum.find_value(visible, fn {item, _} ->
      if not Map.get(item, :disabled, false), do: item.id
    end)
  end

  defp last_enabled_in(visible) do
    visible
    |> Enum.reverse()
    |> Enum.find_value(fn {item, _} ->
      if not Map.get(item, :disabled, false), do: item.id
    end)
  end

  defp handle_open_submenu(state) do
    item = find_item(state.items, state.cursor)

    cond do
      item == nil ->
        {state, []}

      item.children != [] and item.id not in state.open_path ->
        # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
        new_path = state.open_path ++ [item.id]
        first_child = first_enabled_id(item.children)
        new_cursor = first_child || state.cursor
        {%{state | open_path: new_path, cursor: new_cursor}, []}

      true ->
        {state, []}
    end
  end

  defp handle_close_submenu(state) do
    case state.open_path do
      [] ->
        {state, []}

      path ->
        closed_id = List.last(path)
        new_path = Enum.drop(path, -1)
        {%{state | open_path: new_path, cursor: closed_id}, []}
    end
  end

  defp handle_activate(state) do
    item = find_item(state.items, state.cursor)

    cond do
      item == nil ->
        {state, []}

      Map.get(item, :disabled, false) ->
        {state, []}

      item.children == [] ->
        fire_on_select(state.on_select, item.id)
        {state, []}

      item.id not in state.open_path ->
        # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
        new_path = state.open_path ++ [item.id]
        first_child = first_enabled_id(item.children)
        new_cursor = first_child || state.cursor
        {%{state | open_path: new_path, cursor: new_cursor}, []}

      true ->
        {state, []}
    end
  end

  defp fire_on_select(nil, _id), do: :ok
  defp fire_on_select(cb, id) when is_function(cb, 1), do: cb.(id)

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
    Enum.map(visible, fn {item, depth} ->
      indent = String.duplicate("  ", depth)
      has_children = item.children != []
      disabled = Map.get(item, :disabled, false)
      shortcut = Map.get(item, :shortcut)

      suffix =
        cond do
          has_children and shortcut -> " > " <> shortcut
          has_children -> " >"
          shortcut -> "  " <> shortcut
          true -> ""
        end

      line_style =
        cond do
          item.id == state.cursor -> Raxol.Core.Defaults.selected_style()
          disabled -> %{fg: :gray}
          true -> %{}
        end

      Raxol.View.Components.text(
        id: "#{state.id}-item-#{item.id}",
        content: "#{indent}#{item.label}#{suffix}",
        style: line_style
      )
    end)
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(_state) do
    [
      %{
        name: "select",
        description: "Select a menu item by ID",
        inputSchema: %{
          type: "object",
          properties: %{item_id: %{type: "string", description: "Menu item ID"}},
          required: ["item_id"]
        }
      },
      %{
        name: "get_items",
        description: "Get available menu items",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("select", %{"item_id" => item_id}, context) do
    {:ok, "Selected menu item '#{item_id}'",
     [{:menu_select, context.widget_id, item_id}]}
  end

  def handle_tool_call("get_items", _args, context) do
    items = context.widget_state[:items] || []
    labels = collect_item_labels(items, 0)
    {:ok, labels}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  defp collect_item_labels(items, depth) do
    Enum.flat_map(items, fn item ->
      prefix = String.duplicate("  ", depth)
      entry = %{id: item[:id], label: "#{prefix}#{item[:label]}"}
      children = collect_item_labels(item[:children] || [], depth + 1)
      [entry | children]
    end)
  end
end
