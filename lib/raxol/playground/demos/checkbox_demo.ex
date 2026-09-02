defmodule Raxol.Playground.Demos.CheckboxDemo do
  @moduledoc "Playground demo: toggle checkboxes with keyboard navigation."
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  @impl true
  def init(_context) do
    %{
      items: [
        %{label: "Enable notifications", checked: false},
        %{label: "Dark mode", checked: true},
        %{label: "Auto-save", checked: false},
        %{label: "Show line numbers", checked: true},
        %{label: "Word wrap", checked: false}
      ],
      cursor: 0
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("j") ->
        {%{
           model
           | cursor:
               DemoHelpers.cursor_down(model.cursor, length(model.items) - 1)
         }, []}

      key_match("k") ->
        {%{model | cursor: DemoHelpers.cursor_up(model.cursor)}, []}

      key_match(" ") ->
        items = List.update_at(model.items, model.cursor, &toggle/1)
        {%{model | items: items}, []}

      key_match("a") ->
        {toggle_all(model), []}

      _ ->
        {model, []}
    end
  end

  defp toggle_all(model) do
    all_checked? = Enum.all?(model.items, & &1.checked)
    items = Enum.map(model.items, &%{&1 | checked: not all_checked?})
    %{model | items: items}
  end

  defp toggle(item), do: %{item | checked: not item.checked}

  @impl true
  def view(model) do
    checked_count = Enum.count(model.items, & &1.checked)

    # snippet:start
    item_rows =
      model.items
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        prefix = DemoHelpers.cursor_prefix(i, model.cursor)
        mark = if item.checked, do: "[x]", else: "[ ]"
        text("#{prefix}#{mark} #{item.label}")
      end)

    # snippet:end

    column style: %{gap: 1} do
      [
        text("Checkbox Demo", style: [:bold]),
        divider(),
        column(style: %{gap: 0}, do: item_rows),
        divider(),
        text("Checked: #{checked_count}/#{length(model.items)}",
          style: [:bold]
        ),
        text("[j/k] navigate  [space] toggle  [a] toggle all", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
