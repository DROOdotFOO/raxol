defmodule Raxol.Playground.Demos.TabsDemo do
  @moduledoc "Playground demo: tab bar with keyboard switching and content panels."
  use Raxol.Core.Runtime.Application

  @tab_labels ["Overview", "Details", "Settings", "Help"]
  @tab_count length(@tab_labels)
  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_content_box_width 40

  @tab_content %{
    0 => "Welcome to the overview panel.\nThis shows a summary.",
    1 => "Detailed information goes here.\nRow 1: value\nRow 2: value",
    2 => "Settings panel.\nTheme: dark\nFont: mono",
    3 => "Press h/l to switch tabs.\nPress 1-4 for direct access."
  }

  @impl true
  def init(_context) do
    %{active: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match(:char, char: c)
      when c in ["1", "2", "3", "4"] ->
        {%{model | active: String.to_integer(c) - 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: k}} when k in [:left] ->
        {prev_tab(model), []}

      key_match("h") ->
        {prev_tab(model), []}

      key_match(:right) ->
        {next_tab(model), []}

      key_match("l") ->
        {next_tab(model), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    # snippet:start
    tabs =
      @tab_labels
      |> Enum.with_index()
      |> Enum.map(fn {label, idx} ->
        if idx == model.active do
          text("[ #{label} ]", style: [:bold, :underline])
        else
          text("  #{label}  ")
        end
      end)

    # snippet:end

    content_lines =
      @tab_content
      |> Map.get(model.active, "")
      |> String.split("\n")
      |> Enum.map(&text/1)

    column style: %{gap: 1} do
      [
        text("Tabs Demo", style: [:bold]),
        divider(),
        row style: %{gap: 0} do
          tabs
        end,
        box style: %{
              border: :single,
              padding: 1,
              width: effective_width(model, @default_content_box_width)
            } do
          column style: %{gap: 0} do
            content_lines
          end
        end,
        text("Tab #{model.active + 1}/#{length(@tab_labels)}"),
        text("[h/l] prev/next  [1-4] direct  [arrows] navigate", style: [:dim])
      ]
    end
  end

  defp prev_tab(model),
    do: %{model | active: rem(model.active - 1 + @tab_count, @tab_count)}

  defp next_tab(model), do: %{model | active: rem(model.active + 1, @tab_count)}

  @impl true
  def subscribe(_model), do: []
end
