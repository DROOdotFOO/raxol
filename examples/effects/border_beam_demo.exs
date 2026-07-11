# Border Beam Demo
#
# Single-card playground for the border-effect family. Cycle through
# 5 distinct effects, 7 palettes, 3 sizes, and a small range of speeds.
#
# Effects (press t to cycle forward, T for back):
#   stroke    -- comet sweeping the perimeter (default; CTAs, primary actions)
#   pulse     -- whole border breathing in unison (ambient, listening states)
#   flames    -- chars climbing the bottom edge (errors, danger, warnings)
#   electric  -- random sparks at perimeter positions (loading, processing)
#   clouds    -- soft slow drift, low contrast (passive, calm states)
#
# Usage:
#   mix run examples/effects/border_beam_demo.exs
#
# Tip: ~80 cols x 18 rows is a good size for marketing recordings.

defmodule BorderBeamDemo do
  use Raxol.Core.Runtime.Application

  @effects [:stroke, :pulse, :flames, :electric, :clouds]
  @variants [:colorful, :mono, :ocean, :sunset, :electric, :neon, :matrix]
  @sizes [:full, :compact, :line]

  @impl true
  def init(_context) do
    %{
      effect_idx: 0,
      variant_idx: 0,
      size_idx: 0,
      duration_ms: 1500,
      active: true
    }
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        {model, []}

      %{type: :key, data: %{key: :char, char: c}}
      when c in ["1", "2", "3", "4", "5", "6", "7"] ->
        {%{model | variant_idx: String.to_integer(c) - 1}, []}

      %{type: :key, data: %{key: :char, char: "t"}} ->
        {%{model | effect_idx: rem(model.effect_idx + 1, length(@effects))}, []}

      %{type: :key, data: %{key: :char, char: "T"}} ->
        new_idx = rem(model.effect_idx - 1 + length(@effects), length(@effects))
        {%{model | effect_idx: new_idx}, []}

      %{type: :key, data: %{key: :char, char: "z"}} ->
        {%{model | size_idx: rem(model.size_idx + 1, length(@sizes))}, []}

      %{type: :key, data: %{key: :char, char: "x"}} ->
        new_idx = rem(model.size_idx - 1 + length(@sizes), length(@sizes))
        {%{model | size_idx: new_idx}, []}

      %{type: :key, data: %{key: :char, char: "s"}} ->
        {%{model | duration_ms: min(model.duration_ms + 250, 4000)}, []}

      %{type: :key, data: %{key: :char, char: "f"}} ->
        {%{model | duration_ms: max(model.duration_ms - 250, 500)}, []}

      %{type: :key, data: %{key: :char, char: " "}} ->
        {%{model | active: not model.active}, []}

      %{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %{type: :key, data: %{key: :char, char: "c", ctrl: true}} ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    effect = Enum.at(@effects, model.effect_idx)
    variant = Enum.at(@variants, model.variant_idx)
    size = Enum.at(@sizes, model.size_idx)
    state_label = if model.active, do: "running", else: "paused"

    column style: %{padding: 1, gap: 1} do
      [
        text("border beam", style: [:bold]),
        box style: %{border: :rounded, padding: 1},
            border_beam: true,
            border_beam_opts: [
              effect: effect,
              variant: variant,
              size: size,
              duration: model.duration_ms,
              period_ms: model.duration_ms,
              active: model.active,
              strength: 0.95
            ] do
          [
            column style: %{padding: 1, gap: 0} do
              [
                text(""),
                text(""),
                text("        build anything", style: [:bold]),
                text(""),
                text("        wrap your hero CTA in a beam"),
                text(""),
                text("")
              ]
            end
          ]
        end,
        text(
          "  effect  #{pad(effect, 9)}  variant  #{pad(variant, 9)}  size  #{pad(size, 8)}  speed  #{model.duration_ms}ms",
          style: [:dim]
        ),
        text(
          "  t/T effect   1-7 variant   z/x size   s/f speed   space #{state_label}   q quit",
          style: [:dim]
        )
      ]
    end
  end

  defp pad(atom, width) do
    str = Atom.to_string(atom)
    # display width, not String.length -- correct even if a label goes wide
    str <>
      String.duplicate(
        " ",
        max(width - Raxol.UI.TextMeasure.display_width(str), 0)
      )
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(50, :tick)]
end

{:ok, pid} = Raxol.start_link(BorderBeamDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
