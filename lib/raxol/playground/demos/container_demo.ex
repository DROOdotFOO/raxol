defmodule Raxol.Playground.Demos.ContainerDemo do
  @moduledoc """
  Playground demo: scrollable container with viewport controls.

  Keeps its own `Enum.slice/3`-based windowing rather than embedding
  `Raxol.UI.Components.Display.Viewport`: the box's D6 overflow clip
  (`docs/core/LAYOUT.md` section 2) only clips from the container's
  main-end edge, it can't show an arbitrary mid-list offset window, and
  `Viewport` is a stateful `Base.Component` (its own `init/1`/`render/2`
  lifecycle) rather than a plain View DSL element -- embedding it here
  would mean moving scroll ownership out of this demo's TEA model, a
  much bigger rework than the offset-window slicing this demo already
  does correctly.
  """
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  @total 30
  @initial_visible 10
  @min_visible 3
  @max_visible 20
  @scrollbar_width 20
  @content_box_width 30

  @impl true
  def init(_context) do
    items =
      Enum.map(
        1..@total,
        &"Item #{String.pad_leading(Integer.to_string(&1), 2, "0")}"
      )

    %{items: items, scroll_offset: 0, visible_count: @initial_visible}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("j") -> {scroll_down(model), []}
      key_match(:down) -> {scroll_down(model), []}
      key_match("k") -> {scroll_up(model), []}
      key_match(:up) -> {scroll_up(model), []}
      _ -> handle_viewport_keys(message, model)
    end
  end

  defp handle_viewport_keys(message, model) do
    case message do
      key_match("g") -> {%{model | scroll_offset: 0}, []}
      key_match("G") -> {scroll_to_end(model), []}
      key_match("=") -> {grow_visible(model), []}
      key_match("-") -> {shrink_visible(model), []}
      _ -> {model, []}
    end
  end

  defp scroll_down(model) do
    max_offset = length(model.items) - model.visible_count

    %{
      model
      | scroll_offset: DemoHelpers.cursor_down(model.scroll_offset, max_offset)
    }
  end

  defp scroll_up(model) do
    %{model | scroll_offset: DemoHelpers.cursor_up(model.scroll_offset)}
  end

  defp scroll_to_end(model) do
    %{model | scroll_offset: length(model.items) - model.visible_count}
  end

  defp grow_visible(model) do
    %{model | visible_count: min(model.visible_count + 1, @max_visible)}
  end

  defp shrink_visible(model) do
    %{model | visible_count: max(model.visible_count - 1, @min_visible)}
  end

  @impl true
  def view(model) do
    total = length(model.items)
    first = model.scroll_offset + 1
    last = min(model.scroll_offset + model.visible_count, total)

    visible =
      model.items
      |> Enum.slice(model.scroll_offset, model.visible_count)
      |> Enum.map(&text("  #{&1}"))

    scrollbar = build_scrollbar(model.scroll_offset, model.visible_count, total)

    column style: %{gap: 1} do
      [
        text("Container Demo", style: [:bold]),
        divider(),
        text("Showing #{first}-#{last} of #{total}"),
        box style: %{
              border: :single,
              padding: 1,
              width: DemoHelpers.effective_width(model, @content_box_width)
            } do
          column style: %{gap: 0} do
            visible
          end
        end,
        text(scrollbar),
        row style: %{gap: 2} do
          [
            text("Offset: #{model.scroll_offset}"),
            text("Visible: #{model.visible_count}")
          ]
        end,
        text("[j/k] scroll  [g/G] top/bottom  [=/-] visible count",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp build_scrollbar(offset, visible, total) do
    bar_len = @scrollbar_width
    thumb_size = max(1, round(visible / total * bar_len))
    thumb_pos = round(offset / max(total - visible, 1) * (bar_len - thumb_size))

    chars =
      Enum.map(0..(bar_len - 1), fn i ->
        if i >= thumb_pos and i < thumb_pos + thumb_size, do: "#", else: "-"
      end)

    "[" <> Enum.join(chars) <> "]"
  end
end
