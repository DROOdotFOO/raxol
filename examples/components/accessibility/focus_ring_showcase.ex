defmodule Raxol.Examples.FocusRingShowcase do
  @moduledoc """
  Showcase for focus ring styling options.

  Demonstrates different animation types and accessibility settings
  using the TEA pattern.
  """

  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @animation_types [:none, :pulse, :blink, :fade, :glow, :bounce]
  @component_types [:button, :text_input, :checkbox]

  @impl true
  def init(_context) do
    %{
      animation_idx: 1,
      component_idx: 0,
      high_contrast: false,
      reduced_motion: false,
      demo_tick: 0
    }
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "a"}} ->
        next = rem(model.animation_idx + 1, length(@animation_types))
        {%{model | animation_idx: next}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "t"}} ->
        next = rem(model.component_idx + 1, length(@component_types))
        {%{model | component_idx: next}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "h"}} ->
        {%{model | high_contrast: !model.high_contrast}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "m"}} ->
        {%{model | reduced_motion: !model.reduced_motion}, []}

      :tick ->
        {%{model | demo_tick: model.demo_tick + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    animation = Enum.at(@animation_types, model.animation_idx)
    component = Enum.at(@component_types, model.component_idx)
    # Simulate focus ring with text characters
    ring = if model.high_contrast, do: "##", else: ">>"
    pulse = if rem(model.demo_tick, 2) == 0, do: ring, else: "  "

    indicator =
      if model.reduced_motion or animation == :none, do: ring, else: pulse

    column style: %{padding: 1, gap: 1} do
      [
        text("FocusRing Showcase", style: [:bold]),
        box title: "Controls", style: %{border: :single, padding: 1} do
          column style: %{gap: 1} do
            [
              text("[a] Animation: #{animation}"),
              text("[t] Component: #{component}"),
              text("[h] High contrast: #{model.high_contrast}"),
              text("[m] Reduced motion: #{model.reduced_motion}")
            ]
          end
        end,
        box title: "Preview", style: %{border: :single, padding: 1} do
          column style: %{gap: 1} do
            [
              text("Component type: #{component}"),
              text("Focus ring: #{indicator} [#{component}] #{indicator}"),
              text("Animation: #{animation} | Tick: #{model.demo_tick}")
            ]
          end
        end,
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(500, :tick)]
  end
end
