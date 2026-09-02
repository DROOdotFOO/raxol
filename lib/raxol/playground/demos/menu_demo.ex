defmodule Raxol.Playground.Demos.MenuDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.Menu` — the real component,
  nested submenus and all. The demo holds no cursor state of its own: every
  key event forwards into `Menu.handle_event/3` and the view draws whatever
  `Menu.render/2` returns.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Input.Menu

  @info_box_width 35

  @impl true
  def init(_context) do
    # snippet:start
    {:ok, menu} =
      Menu.init(
        id: :playground_menu,
        items: [
          item(:file, "File", [
            item(:new, "New"),
            item(:open, "Open"),
            item(:save, "Save"),
            item(:exit, "Exit")
          ]),
          item(:edit, "Edit", [item(:undo, "Undo"), item(:redo, "Redo")]),
          item(:view, "View", [item(:sidebar, "Sidebar")]),
          item(:help, "Help", [item(:about, "About"), item(:docs, "Docs")])
        ]
      )

    # Keys route through Menu.handle_event/3; Menu.render/2 draws it.
    # snippet:end
    %{menu: menu}
  end

  defp item(id, label, children \\ []) do
    %{id: id, label: label, children: children, disabled: false, shortcut: nil}
  end

  @impl true
  def update(message, model) do
    case message do
      %Event{type: :key} = event ->
        {menu, _commands} = Menu.handle_event(event, model.menu, %{})
        {%{model | menu: menu}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{gap: 1} do
      [
        text("Menu Demo", style: [:bold]),
        divider(),
        Menu.render(model.menu, %{}),
        divider(),
        box style: %{border: :single, padding: 1, width: @info_box_width} do
          column style: %{gap: 0} do
            [
              text("Cursor: #{model.menu.cursor}", style: [:bold]),
              open_line(model.menu)
            ]
          end
        end,
        text("[up/down] move  [right/Enter] open  [left/Esc] close",
          style: [:dim]
        )
      ]
    end
  end

  defp open_line(%{open_path: []}), do: text("(press Enter to expand)")

  defp open_line(%{open_path: path}),
    do: text("Open: #{Enum.join(path, " > ")}")

  @impl true
  def subscribe(_model), do: []
end
