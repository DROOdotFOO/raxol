defmodule Raxol.Playground.Demos.SelectListDemo do
  @moduledoc "Playground demo: dropdown select list with keyboard navigation."
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  @dropdown_width 30

  @impl true
  def init(_context) do
    %{
      options: ["Elixir", "Rust", "Go", "Python", "TypeScript"],
      selected: 0,
      confirmed: nil,
      open: false
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("o") ->
        {%{model | open: not model.open}, []}

      key_match("j")
      when model.open ->
        {%{
           model
           | selected:
               DemoHelpers.cursor_down(
                 model.selected,
                 length(model.options) - 1
               )
         }, []}

      key_match("k")
      when model.open ->
        {%{model | selected: DemoHelpers.cursor_up(model.selected)}, []}

      key_match(:enter)
      when model.open ->
        value = Enum.at(model.options, model.selected)
        {%{model | confirmed: value, open: false}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    current = Enum.at(model.options, model.selected)
    arrow = if model.open, do: "v", else: ">"
    display = model.confirmed || "Select a language..."

    # snippet:start
    dropdown_items =
      if model.open do
        model.options
        |> Enum.with_index()
        |> Enum.map(fn {opt, i} ->
          prefix = DemoHelpers.cursor_prefix(i, model.selected)
          text("#{prefix}#{opt}")
        end)
      else
        []
      end

    # snippet:end

    column style: %{gap: 1} do
      [
        text("SelectList Demo", style: [:bold]),
        divider(),
        text("Selected: #{display}", style: [:bold]),
        box style: %{border: :single, padding: 1, width: @dropdown_width} do
          column style: %{gap: 0} do
            [text("[#{arrow}] #{current}") | dropdown_items]
          end
        end,
        confirmed_view(model.confirmed),
        text("[o] open/close  [j/k] navigate  [enter] confirm", style: [:dim])
      ]
    end
  end

  defp confirmed_view(nil), do: text("")
  defp confirmed_view(value), do: text("Confirmed: #{value}", style: [:bold])

  @impl true
  def subscribe(_model), do: []
end
