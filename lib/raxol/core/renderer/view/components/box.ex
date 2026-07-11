defmodule Raxol.Core.Renderer.View.Components.Box do
  @moduledoc """
  Constructs `:box`-tagged View DSL nodes (`new/1`) with content, padding,
  border, and margin metadata for the box model.

  N15 (flex rework Phase D, `docs/proposals/in-flight/flex-spec-convergence.md`):
  the layout-calculation half of this module (`calculate_layout/2` and its
  private box-model algorithm) was deleted here as production-dead --
  zero callers outside tests. `new/1` survives; the live engine
  (`Raxol.UI.Layout.Engine`) computes positions for `:box` elements
  independently of this module.
  """

  @doc """
  Creates a new box view.

  ## Options
    * `:children` - List of child views
    * `:title` - Optional title rendered in the top border
    * `:padding` - Padding around content (integer or {top, right, bottom, left})
    * `:margin` - Margin around box (integer or {top, right, bottom, left})
    * `:border` - Border style (:none, :single, :double, :rounded, :bold, :dashed)
    * `:fg` - Foreground color
    * `:bg` - Background color
    * `:size` - Box size {width, height}

  ## Examples

      Box.new(children: [view1, view2], padding: 1)
      Box.new(padding: {1, 2, 1, 2}, border: :single)
  """
  def new(opts \\ []) do
    style = Keyword.get(opts, :style, [])
    style_map = if is_map(style), do: style, else: Map.new(style)
    border = Map.get(style_map, :border, Keyword.get(opts, :border, :none))
    padding = Map.get(style_map, :padding, Keyword.get(opts, :padding, 0))

    animation_hints = build_animation_hints(opts)

    %{
      type: :box,
      children: Keyword.get(opts, :children, []),
      title: Keyword.get(opts, :title),
      padding: normalize_spacing(padding),
      margin: normalize_spacing(Keyword.get(opts, :margin, 0)),
      border: border,
      fg: Keyword.get(opts, :fg),
      bg: Keyword.get(opts, :bg),
      size: Keyword.get(opts, :size),
      style: style,
      animation_hints: animation_hints
    }
  end

  # Helper function to normalize spacing values
  defp build_animation_hints(opts) do
    existing = Keyword.get(opts, :animation_hints, [])

    if Keyword.get(opts, :border_beam, false) do
      beam_opts = Keyword.get(opts, :border_beam_opts, [])

      hint = %{
        type: :border_beam,
        effect: Keyword.get(beam_opts, :effect, :stroke),
        variant: Keyword.get(beam_opts, :variant, :colorful),
        size: Keyword.get(beam_opts, :size, :full),
        strength: Keyword.get(beam_opts, :strength, 0.8),
        duration_ms: Keyword.get(beam_opts, :duration, 2000),
        period_ms: Keyword.get(beam_opts, :period_ms, 1800),
        density: Keyword.get(beam_opts, :density, 0.75),
        frequency: Keyword.get(beam_opts, :frequency, 25),
        bucket_ms: Keyword.get(beam_opts, :bucket_ms, 60),
        softness: Keyword.get(beam_opts, :softness, 0.45),
        brightness: Keyword.get(beam_opts, :brightness, 1.3),
        saturation: Keyword.get(beam_opts, :saturation, 1.2),
        hue_range: Keyword.get(beam_opts, :hue_range, 30),
        active: Keyword.get(beam_opts, :active, true),
        static_colors: Keyword.get(beam_opts, :static_colors, false)
      }

      [hint | existing]
    else
      existing
    end
  end

  defp normalize_spacing(n) when is_integer(n) and n >= 0, do: {n, n, n, n}
  defp normalize_spacing({n}) when is_integer(n) and n >= 0, do: {n, n, n, n}

  defp normalize_spacing({h, v})
       when is_integer(h) and is_integer(v) and h >= 0 and v >= 0,
       do: {h, v, h, v}

  defp normalize_spacing({t, r, b, l})
       when is_integer(t) and is_integer(r) and is_integer(b) and is_integer(l) and
              t >= 0 and r >= 0 and b >= 0 and l >= 0,
       do: {t, r, b, l}

  defp normalize_spacing(_), do: {0, 0, 0, 0}
end
