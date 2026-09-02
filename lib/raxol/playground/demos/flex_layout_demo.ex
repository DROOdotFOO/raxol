defmodule Raxol.Playground.Demos.FlexLayoutDemo do
  @moduledoc """
  Playground demo: the section-9.7 flex engine.

  A fixed-size flex row holds items of different content widths, including
  one unbreakable long word. Toggle `flex_wrap`, `align_content`, `gap`,
  and `flex: 1` growth to see how they interact -- and how the unbreakable
  word never shrinks below its own min-content width no matter what the
  other controls do.
  """
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  @container_width 26
  @container_height 18

  @wraps [:nowrap, :wrap]
  @aligns [:flex_start, :center, :space_between, :stretch]
  @gaps [0, 1, 2]

  @items [
    {"Alpha", 8},
    {"Beta", 8},
    {"Gamma", 8},
    {"Supercalifragilistic", :auto},
    {"Delta", 8},
    {"Zeta", 8}
  ]

  @impl true
  def init(_context) do
    %{wrap_index: 1, align_index: 0, gap_index: 1, grow?: false}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("w") -> {cycle(model, :wrap_index, length(@wraps)), []}
      key_match("a") -> {cycle(model, :align_index, length(@aligns)), []}
      key_match("g") -> {cycle(model, :gap_index, length(@gaps)), []}
      key_match("f") -> {%{model | grow?: not model.grow?}, []}
      _ -> {model, []}
    end
  end

  defp cycle(model, key, count) do
    Map.update!(model, key, &DemoHelpers.cycle_next(&1, count))
  end

  @impl true
  def view(model) do
    # snippet:start
    wrap = Enum.at(@wraps, model.wrap_index)
    align = Enum.at(@aligns, model.align_index)
    gap = Enum.at(@gaps, model.gap_index)

    items = Enum.map(@items, &item_box(&1, model.grow?))

    container =
      box style: %{
            border: :single,
            width: @container_width,
            height: @container_height
          } do
        row style: %{flex_wrap: wrap, align_content: align, gap: gap} do
          items
        end
      end

    # snippet:end

    column style: %{gap: 1} do
      [
        text("Flex Layout Demo", style: [:bold]),
        divider(),
        container,
        text(
          "wrap=#{wrap}  align_content=#{align}  gap=#{gap}  flex_grow=#{model.grow?}"
        ),
        text(floor_hint(wrap, model.grow?), style: [:dim]),
        text(
          "[w] flex_wrap  [a] align_content  [g] gap  [f] toggle flex:1 grow",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp item_box({label, width}, grow?) do
    style =
      case {grow?, width} do
        {true, _} -> %{border: :single, flex: 1}
        {false, :auto} -> %{border: :single}
        {false, w} -> %{border: :single, width: w}
      end

    box style: style do
      text(label)
    end
  end

  defp floor_hint(_wrap, true) do
    "flex: 1 sets min-content to 0 -- equal columns win over the long word."
  end

  defp floor_hint(:nowrap, false) do
    "nowrap: fixed items can't shrink below their own width; " <>
      "\"Supercalifragilistic\" floors at its own min-content and overflows."
  end

  defp floor_hint(:wrap, false) do
    "\"Supercalifragilistic\" never shrinks below its content width -- " <>
      "it wraps to its own line instead."
  end
end
