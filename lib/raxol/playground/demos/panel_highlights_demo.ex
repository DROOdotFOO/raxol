defmodule Raxol.Playground.Demos.PanelHighlightsDemo do
  @moduledoc "Playground demo: panel focus highlighting with border styles."
  use Raxol.Core.Runtime.Application

  @cols 3
  @panel_width 22
  @panels [
    %{title: "Status", border: :single, content: "System OK"},
    %{title: "Logs", border: :double, content: "No errors"},
    %{title: "Metrics", border: :rounded, content: "CPU: 42%"},
    %{title: "Network", border: :heavy, content: "Latency: 12ms"},
    %{title: "Storage", border: :dashed, content: "Disk: 67%"},
    %{title: "Config", border: :none, content: "3 overrides"}
  ]

  @impl true
  def init(_context) do
    %{focused: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match(:left) ->
        {%{model | focused: navigate(model.focused, :left)}, []}

      key_match(:right) ->
        {%{model | focused: navigate(model.focused, :right)}, []}

      key_match(:up) ->
        {%{model | focused: navigate(model.focused, :up)}, []}

      key_match(:down) ->
        {%{model | focused: navigate(model.focused, :down)}, []}

      _ ->
        {model, []}
    end
  end

  defp navigate(focused, :left) do
    if rem(focused, @cols) == 0, do: focused + @cols - 1, else: focused - 1
  end

  defp navigate(focused, :right) do
    if rem(focused, @cols) == @cols - 1,
      do: focused - @cols + 1,
      else: focused + 1
  end

  defp navigate(focused, :up) do
    if focused >= @cols, do: focused - @cols, else: focused
  end

  defp navigate(focused, :down) do
    if focused < @cols, do: focused + @cols, else: focused
  end

  @impl true
  def view(model) do
    column style: %{gap: 1} do
      [
        text("Panel Highlights Demo", style: [:bold]),
        text("Navigate with arrow keys to focus panels", style: [:dim]),
        panel_grid(model),
        text("[arrows] navigate focus", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp panel_grid(model) do
    top_row = panel_row(model, 0..(@cols - 1))
    bottom_row = panel_row(model, @cols..(2 * @cols - 1))

    column style: %{gap: 1} do
      [top_row, bottom_row]
    end
  end

  defp panel_row(model, range) do
    row style: %{gap: 1} do
      Enum.map(range, fn idx ->
        panel = Enum.at(@panels, idx)
        render_panel(panel, idx, idx == model.focused)
      end)
    end
  end

  defp render_panel(panel, _idx, true) do
    border = normalize_border(panel.border)
    fallback = if border != panel.border, do: " (=> #{border})", else: ""
    title = "[*] #{panel.title} :#{panel.border}#{fallback}"

    # snippet:start
    box style: %{border: border, fg: :cyan, width: @panel_width} do
      column style: %{gap: 0} do
        [
          text(title, style: [:bold], fg: :cyan),
          text(panel.content)
        ]
      end
    end

    # snippet:end
  end

  defp render_panel(panel, _idx, false) do
    border = normalize_border(panel.border)
    fallback = if border != panel.border, do: " (=> #{border})", else: ""

    box style: %{border: border, fg: :white, width: @panel_width} do
      column style: %{gap: 0} do
        [
          text("#{panel.title} :#{panel.border}#{fallback}", style: [:dim]),
          text(panel.content, style: [:dim])
        ]
      end
    end
  end

  defp normalize_border(:heavy), do: :single
  defp normalize_border(:dashed), do: :single
  defp normalize_border(:none), do: :single
  defp normalize_border(style), do: style
end
