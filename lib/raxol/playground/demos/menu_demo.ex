defmodule Raxol.Playground.Demos.MenuDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.Menu` — the REAL component,
  mounted controlled (state lives in this demo's model, every key routes
  through `Menu.handle_event/3`).

  Menu is a nested vertical menu: one open submenu chain at a time. Items
  are `%{id, label, children, disabled, shortcut}`. Leaves fire
  `on_select` without mutating state; parents open on Enter/Space/Right.

  Stories shown: interactive nested menu (File → Recent → docs, Edit with
  a disabled Redo), last-selected readout.

  Contract warts: `Menu.init/1` takes a keyword list. Leaf activation
  returns unchanged state (`{state, []}`) after calling `on_select` — the
  demo therefore watches the cursor + key to log selections (callbacks
  cannot update the TEA model). Disabled items are skipped in navigation.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Input.Menu

  @impl true
  def init(_context) do
    items = menu_items()

    {:ok, menu} =
      Menu.init(
        id: "menu-main",
        items: items,
        focused: true
      )

    %{
      menu: menu,
      last_selected: nil,
      event_log: []
    }
  end

  defp menu_items do
    [
      %{
        id: :file,
        label: "File",
        disabled: false,
        shortcut: nil,
        children: [
          %{id: :new, label: "New", disabled: false, shortcut: "Ctrl+N", children: []},
          %{id: :open, label: "Open", disabled: false, shortcut: "Ctrl+O", children: []},
          %{
            id: :recent,
            label: "Recent",
            disabled: false,
            shortcut: nil,
            children: [
              %{id: :doc1, label: "doc1.txt", disabled: false, shortcut: nil, children: []},
              %{id: :doc2, label: "doc2.txt", disabled: false, shortcut: nil, children: []}
            ]
          },
          %{id: :exit, label: "Exit", disabled: false, shortcut: "Ctrl+Q", children: []}
        ]
      },
      %{
        id: :edit,
        label: "Edit",
        disabled: false,
        shortcut: nil,
        children: [
          %{id: :undo, label: "Undo", disabled: false, shortcut: "Ctrl+Z", children: []},
          %{id: :redo, label: "Redo", disabled: true, shortcut: "Ctrl+Y", children: []},
          %{id: :cut, label: "Cut", disabled: false, shortcut: "Ctrl+X", children: []},
          %{id: :copy, label: "Copy", disabled: false, shortcut: "Ctrl+C", children: []},
          %{id: :paste, label: "Paste", disabled: false, shortcut: "Ctrl+V", children: []}
        ]
      },
      %{
        id: :view,
        label: "View",
        disabled: false,
        shortcut: nil,
        children: [
          %{id: :sidebar, label: "Sidebar", disabled: false, shortcut: nil, children: []},
          %{id: :terminal, label: "Terminal", disabled: false, shortcut: nil, children: []},
          %{id: :minimap, label: "Minimap", disabled: false, shortcut: nil, children: []}
        ]
      },
      %{
        id: :help,
        label: "Help",
        disabled: false,
        shortcut: nil,
        children: [
          %{id: :about, label: "About", disabled: false, shortcut: nil, children: []},
          %{id: :docs, label: "Docs", disabled: false, shortcut: "F1", children: []}
        ]
      }
    ]
  end

  @impl true
  def update(message, model) do
    case menu_event(message) do
      nil ->
        {model, []}

      {event, summary} ->
        apply_menu(model, event, summary)
    end
  end

  # Playground keys -> Menu's %Event{type: :key, data: %{key: ...}} vocabulary.
  # Also accept vim-style hjkl as aliases for the real arrow keys.
  defp menu_event(%Event{type: :key, data: data}) do
    case data do
      %{key: :down} -> {%Event{type: :key, data: %{key: :down}}, "key :down"}
      %{key: :up} -> {%Event{type: :key, data: %{key: :up}}, "key :up"}
      %{key: :left} -> {%Event{type: :key, data: %{key: :left}}, "key :left"}
      %{key: :right} -> {%Event{type: :key, data: %{key: :right}}, "key :right"}
      %{key: :enter} -> {%Event{type: :key, data: %{key: :enter}}, "key :enter"}
      %{key: :space} -> {%Event{type: :key, data: %{key: :space}}, "key :space"}
      %{key: :escape} -> {%Event{type: :key, data: %{key: :escape}}, "key :escape"}
      %{key: :home} -> {%Event{type: :key, data: %{key: :home}}, "key :home"}
      %{key: :end} -> {%Event{type: :key, data: %{key: :end}}, "key :end"}
      %{key: :char, char: "j"} -> {%Event{type: :key, data: %{key: :down}}, "key j→:down"}
      %{key: :char, char: "k"} -> {%Event{type: :key, data: %{key: :up}}, "key k→:up"}
      %{key: :char, char: "h"} -> {%Event{type: :key, data: %{key: :left}}, "key h→:left"}
      %{key: :char, char: "l"} -> {%Event{type: :key, data: %{key: :right}}, "key l→:right"}
      %{key: :char, char: " "} -> {%Event{type: :key, data: %{key: :space}}, "key space"}
      _ -> nil
    end
  end

  defp menu_event(_other), do: nil

  defp apply_menu(model, event, summary) do
    before = model.menu
    result = Menu.handle_event(event, before, %{})
    menu = unwrap(result, before)

    {last_selected, select_note} = detect_select(before, menu, event)

    outcome =
      cond do
        select_note != nil ->
          "#{summary} -> select #{select_note}"

        menu.cursor != before.cursor or menu.open_path != before.open_path ->
          "#{summary} -> cursor=#{inspect(menu.cursor)} open=#{inspect(menu.open_path)}"

        true ->
          "#{summary} -> (no change) cursor=#{inspect(menu.cursor)}"
      end

    model =
      model
      |> Map.put(:menu, menu)
      |> Map.put(:last_selected, last_selected || model.last_selected)
      |> DemoHelpers.log_event(outcome)

    {model, []}
  end

  # Leaf activation does not mutate Menu state; infer selection from key + cursor.
  defp detect_select(before, _after_menu, %Event{type: :key, data: %{key: key}})
       when key in [:enter, :space] do
    item = Menu.find_item(before.items, before.cursor)

    cond do
      is_nil(item) ->
        {nil, nil}

      Map.get(item, :disabled, false) ->
        {nil, nil}

      item.children == [] ->
        {item.id, inspect(item.id)}

      true ->
        {nil, nil}
    end
  end

  defp detect_select(_before, _after, _event), do: {nil, nil}

  defp unwrap({:noreply, state}, _fallback), do: state
  defp unwrap({:ok, state}, _fallback), do: state
  defp unwrap({:handled, state}, _fallback), do: state
  defp unwrap({state, _cmds}, _fallback) when is_map(state), do: state

  @impl true
  def view(model) do
    last =
      case model.last_selected do
        nil -> "(none yet)"
        id -> inspect(id)
      end

    column style: %{gap: 0} do
      [
        text("Menu — Raxol.UI.Components.Input.Menu", style: [:bold]),
        text(
          " (nested items, disabled skip, one open submenu chain)",
          style: [:dim]
        ),
        text(""),
        text(
          " interactive (cursor=#{inspect(model.menu.cursor)} open=#{inspect(model.menu.open_path)}):",
          style: [:dim]
        ),
        Menu.render(model.menu, %{}),
        text(""),
        text(" last selected: #{last}", style: [:bold]),
        text(""),
        text(
          " [↑↓/jk] move  [→/l enter space] open/activate  [←/h esc] close  [home end] jump",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
