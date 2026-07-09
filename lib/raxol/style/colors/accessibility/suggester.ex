defmodule Raxol.Style.Colors.Accessibility.Suggester do
  @moduledoc """
  Suggests accessible color alternatives based on WCAG contrast requirements.

  Extracted from Raxol.Style.Colors.Accessibility.
  """

  alias Raxol.Style.Colors.Accessibility
  alias Raxol.Style.Colors.Color
  alias Raxol.Style.Colors.Utilities

  @doc """
  Suggests an appropriate text color (black or white) for a given background.

  Ensures minimum AA contrast.
  """
  def suggest_text_color(background) when is_binary(background) do
    bg = Color.from_hex(background)
    Utilities.best_bw_contrast(bg)
  end

  def suggest_text_color(background) do
    Utilities.best_bw_contrast(background)
  end

  @doc """
  Suggests a color with good contrast (at least AA) to the base color.

  Prioritizes complementary color, then black/white.
  """
  def suggest_contrast_color(color) when is_binary(color) do
    case Color.from_hex(color) do
      %Color{} = c -> suggest_contrast_color(c)
      _ -> Color.from_hex("#000000")
    end
  end

  def suggest_contrast_color(%Color{} = color) do
    complement = Color.complement(color)

    select_contrast_color(
      Accessibility.readable?(color, complement, :aa),
      complement,
      color
    )
  end

  defp select_contrast_color(true, complement, _color), do: complement

  defp select_contrast_color(false, _complement, color) do
    suggest_text_color(color)
  end

  @doc """
  Finds an accessible color pair (foreground/background) based on a base color and WCAG level.
  """
  def accessible_color_pair(base_color, level \\ :aa)

  def accessible_color_pair(base_color, level) when is_binary(base_color) do
    case Color.from_hex(base_color) do
      %Color{} = c ->
        accessible_color_pair(c, level)

      _ ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Accessibility: Could not find accessible color pair for #{inspect(base_color)}",
          %{}
        )

        nil
    end
  end

  def accessible_color_pair(%Color{} = base_color, level) do
    white = Color.from_hex("#FFFFFF")
    black = Color.from_hex("#000000")

    contrast_with_white = Accessibility.contrast_ratio(base_color, white)
    contrast_with_black = Accessibility.contrast_ratio(base_color, black)
    min_ratio = min_contrast(level)

    choose_accessible_pair(
      base_color,
      white,
      black,
      contrast_with_white,
      contrast_with_black,
      min_ratio
    )
  end

  defp min_contrast(:aaa), do: 7.0
  defp min_contrast(_level), do: 4.5

  defp choose_accessible_pair(
         base_color,
         white,
         _black,
         contrast_with_white,
         _contrast_with_black,
         min_ratio
       )
       when contrast_with_white >= min_ratio,
       do: {white, base_color}

  defp choose_accessible_pair(
         base_color,
         _white,
         black,
         _contrast_with_white,
         contrast_with_black,
         min_ratio
       )
       when contrast_with_black >= min_ratio,
       do: {black, base_color}

  defp choose_accessible_pair(
         base_color,
         _white,
         _black,
         _contrast_with_white,
         _contrast_with_black,
         _min_ratio
       ) do
    Raxol.Core.Runtime.Log.debug(
      "Could not find accessible pair for color: #{inspect(base_color)}"
    )

    nil
  end

  @doc """
  Returns the optimal text color (black or white hex) for a given background.
  """
  def get_optimal_text_color(background) do
    bg = convert_to_color(is_binary(background), background)

    black = Color.from_hex("#000000")
    white = Color.from_hex("#FFFFFF")

    ratio_with_white = Accessibility.contrast_ratio(bg, white)
    ratio_with_black = Accessibility.contrast_ratio(bg, black)

    choose_optimal_contrast(ratio_with_white >= ratio_with_black)
  end

  defp convert_to_color(true, background), do: Color.from_hex(background)
  defp convert_to_color(false, background), do: background

  defp choose_optimal_contrast(true), do: "#FFFFFF"
  defp choose_optimal_contrast(false), do: "#000000"

  # --- Suggest Accessible Color ---

  def suggest_accessible_color(color, background) when is_binary(background) do
    suggest_accessible_color(color, background: background)
  end

  def suggest_accessible_color(color, opts) when is_list(opts) do
    color = normalize_color(color)
    {bg, min_ratio} = extract_options(opts)

    case Accessibility.check_contrast(color, bg, Keyword.get(opts, :level, :aa)) do
      {:ok, _} -> color.hex
      _ -> find_accessible_color(color, bg, min_ratio)
    end
  end

  # --- Lighten/Darken Until Contrast ---

  def lighten_until_contrast(color, background, target_ratio) do
    adjust_until_contrast(
      color,
      background,
      target_ratio,
      &Raxol.Style.Colors.HSL.lighten/2,
      :lighter
    )
  end

  def darken_until_contrast(color, background, target_ratio) do
    adjust_until_contrast(
      color,
      background,
      target_ratio,
      &Raxol.Style.Colors.HSL.darken/2,
      :darker
    )
  end

  # --- Private Helpers ---

  defp normalize_color(color) when is_binary(color), do: Color.from_hex(color)
  defp normalize_color(color), do: color

  defp extract_options(opts) do
    bg = normalize_color(Keyword.get(opts, :background) || "#FFFFFF")

    min_ratio =
      case Keyword.get(opts, :level, :aa) do
        :aaa -> 7.0
        :aa -> 4.5
      end

    {bg, min_ratio}
  end

  defp find_accessible_color(color, bg, min_ratio) do
    bg_lum = Accessibility.relative_luminance(bg)
    select_strategy_by_luminance(bg_lum < 0.5, color, bg, min_ratio)
  end

  defp select_strategy_by_luminance(true, color, bg, min_ratio) do
    try_lighten_then_darken(color, bg, min_ratio)
  end

  defp select_strategy_by_luminance(false, color, bg, min_ratio) do
    try_darken_then_lighten(color, bg, min_ratio)
  end

  defp try_lighten_then_darken(color, bg, min_ratio) do
    lightened = lighten_until_contrast(color, bg, min_ratio)

    select_lightened_or_darkened(
      valid_adjustment?(lightened, color, bg, min_ratio, :lighter),
      lightened,
      color,
      bg,
      min_ratio
    )
  end

  defp try_darken_then_lighten(color, bg, min_ratio) do
    darkened = darken_until_contrast(color, bg, min_ratio)

    select_darkened_or_lightened(
      valid_adjustment?(darkened, color, bg, min_ratio, :darker),
      darkened,
      color,
      bg,
      min_ratio
    )
  end

  defp select_lightened_or_darkened(true, lightened, _color, _bg, _min_ratio) do
    lightened.hex
  end

  defp select_lightened_or_darkened(false, _lightened, color, bg, min_ratio) do
    darkened = darken_until_contrast(color, bg, min_ratio)

    select_final_color(
      valid_adjustment?(darkened, color, bg, min_ratio, :darker),
      darkened.hex,
      "#FFFFFF"
    )
  end

  defp select_darkened_or_lightened(true, darkened, _color, _bg, _min_ratio) do
    darkened.hex
  end

  defp select_darkened_or_lightened(false, _darkened, color, bg, min_ratio) do
    lightened = lighten_until_contrast(color, bg, min_ratio)

    select_final_color(
      valid_adjustment?(lightened, color, bg, min_ratio, :lighter),
      lightened.hex,
      "#000000"
    )
  end

  defp select_final_color(true, color_hex, _fallback), do: color_hex
  defp select_final_color(false, _color_hex, fallback), do: fallback

  defp valid_adjustment?(adjusted, original, bg, min_ratio, direction) do
    adjusted &&
      Accessibility.contrast_ratio(adjusted, bg) >= min_ratio &&
      luminance_changed?(original, adjusted, direction) &&
      adjusted.hex != original.hex
  end

  defp luminance_changed?(orig, adjusted, :lighter),
    do:
      Accessibility.relative_luminance(adjusted) >
        Accessibility.relative_luminance(orig)

  defp luminance_changed?(orig, adjusted, :darker),
    do:
      Accessibility.relative_luminance(adjusted) <
        Accessibility.relative_luminance(orig)

  defp adjust_until_contrast(
         color,
         background,
         target_ratio,
         adjust_fun,
         direction,
         max_steps \\ 30,
         step \\ 0.7
       ) do
    do_adjust_until_contrast(
      color,
      background,
      target_ratio,
      adjust_fun,
      direction,
      max_steps,
      step
    )
  end

  defp do_adjust_until_contrast(
         color,
         _background,
         _target_ratio,
         _adjust_fun,
         _direction,
         0,
         _step
       ),
       do: color

  defp do_adjust_until_contrast(
         color,
         background,
         target_ratio,
         adjust_fun,
         direction,
         steps,
         step
       ) do
    adjusted = adjust_fun.(color, step)
    orig_lum = Accessibility.relative_luminance(color)
    adj_lum = Accessibility.relative_luminance(adjusted)

    handle_contrast_adjustment(
      meets_contrast_and_direction?(
        adjusted,
        background,
        target_ratio,
        direction,
        adj_lum,
        orig_lum
      ),
      adjusted,
      background,
      target_ratio,
      adjust_fun,
      direction,
      steps,
      step
    )
  end

  defp meets_contrast_and_direction?(
         adjusted,
         background,
         target_ratio,
         direction,
         adj_lum,
         orig_lum
       ) do
    Accessibility.contrast_ratio(adjusted, background) >= target_ratio and
      ((direction == :lighter and adj_lum > orig_lum) or
         (direction == :darker and adj_lum < orig_lum))
  end

  defp handle_contrast_adjustment(
         true,
         adjusted,
         _background,
         _target_ratio,
         _adjust_fun,
         _direction,
         _steps,
         _step
       ) do
    adjusted
  end

  defp handle_contrast_adjustment(
         false,
         adjusted,
         background,
         target_ratio,
         adjust_fun,
         direction,
         steps,
         step
       ) do
    do_adjust_until_contrast(
      adjusted,
      background,
      target_ratio,
      adjust_fun,
      direction,
      steps - 1,
      min(step * 1.5, 1.0)
    )
  end
end
