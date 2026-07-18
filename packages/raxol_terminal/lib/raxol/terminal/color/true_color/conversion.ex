defmodule Raxol.Terminal.Color.TrueColor.Conversion do
  @moduledoc """
  Color space math for TrueColor: RGB/HSL/HSV/XYZ/Lab conversions
  and luminance calculations.
  """

  @doc """
  Converts HSL (h in 0..360, s/l in 0..1) to normalized RGB (0..1 each).
  """
  def hsl_to_rgb(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs(rem(trunc(h / 60), 2) - 1))
    m = l - c / 2

    {r_prime, g_prime, b_prime} = hue_segment(h, c, x)

    {r_prime + m, g_prime + m, b_prime + m}
  end

  @doc """
  Converts normalized RGB (0..1 each) to HSL tuple {h, s, l}
  where h is 0..360, s and l are 0..100.
  """
  def rgb_to_hsl(r, g, b) do
    max_val = max(max(r, g), b)
    min_val = min(min(r, g), b)
    delta = max_val - min_val

    l = (max_val + min_val) / 2

    calculate_hsl_values(delta, l, max_val, min_val, r, g, b)
  end

  @doc """
  Converts HSV (h in 0..360, s/v in 0..1) to normalized RGB (0..1 each).
  """
  def hsv_to_rgb(h, s, v) do
    c = v * s
    x = c * (1 - abs(rem(trunc(h / 60), 2) - 1))
    m = v - c

    {r_prime, g_prime, b_prime} = hue_segment(h, c, x)

    {r_prime + m, g_prime + m, b_prime + m}
  end

  @doc """
  Converts normalized RGB (0..1 each) to HSV tuple {h, s, v}
  where h is 0..360, s and v are 0..100.
  """
  def rgb_to_hsv(r, g, b) do
    max_val = max(max(r, g), b)
    min_val = min(min(r, g), b)
    delta = max_val - min_val

    v = max_val
    s = calculate_saturation(max_val, delta)
    h = calculate_hsv_hue(delta, max_val, r, g, b)

    {round(h * 60), round(s * 100), round(v * 100)}
  end

  @doc """
  Converts an 8-bit RGB struct to XYZ color space.
  """
  def to_xyz(r, g, b) do
    [r, g, b]
    |> Enum.map(fn c ->
      s = c / 255
      linear_xyz(s)
    end)
    |> then(fn [r_l, g_l, b_l] ->
      x = r_l * 0.4124 + g_l * 0.3576 + b_l * 0.1805
      y = r_l * 0.2126 + g_l * 0.7152 + b_l * 0.0722
      z = r_l * 0.0193 + g_l * 0.1192 + b_l * 0.9505
      {x, y, z}
    end)
  end

  @doc """
  Converts XYZ to CIELAB (L*, a*, b*) using D65 illuminant.
  """
  def xyz_to_lab(x, y, z) do
    # Observer = 2 degrees, Illuminant = D65
    x_n = 0.95047
    y_n = 1.00000
    z_n = 1.08883

    fx = lab_f(x / x_n)
    fy = lab_f(y / y_n)
    fz = lab_f(z / z_n)

    l = 116 * fy - 16
    a = 500 * (fx - fy)
    b = 200 * (fy - fz)

    {l, a, b}
  end

  @doc """
  Calculates relative luminance for an 8-bit RGB color (WCAG formula).
  """
  def relative_luminance(r, g, b) do
    [r, g, b]
    |> Enum.map(fn c ->
      s = c / 255
      linear_rgb(s)
    end)
    |> then(fn [r_l, g_l, b_l] ->
      0.2126 * r_l + 0.7152 * g_l + 0.0722 * b_l
    end)
  end

  # -- Private helpers --

  defp lab_f(t) do
    threshold = :math.pow(6 / 29, 3)

    if t > threshold,
      do: :math.pow(t, 1 / 3),
      else: 1 / 3 * :math.pow(29 / 6, 2) * t + 4 / 29
  end

  defp linear_rgb(s) when s <= 0.03928, do: s / 12.92
  defp linear_rgb(s), do: :math.pow((s + 0.055) / 1.055, 2.4)

  defp linear_xyz(s) when s > 0.04045, do: :math.pow((s + 0.055) / 1.055, 2.4)
  defp linear_xyz(s), do: s / 12.92

  # Maps the hue sextant div(h, 60) to the RGB-prime ordering shared by
  # HSL and HSV conversion. h outside 0..359 falls through to {0, 0, 0}.
  defp hue_segment(h, c, x) do
    case div(h, 60) do
      0 -> {c, x, 0}
      1 -> {x, c, 0}
      2 -> {0, c, x}
      3 -> {0, x, c}
      4 -> {x, 0, c}
      5 -> {c, 0, x}
      _ -> {0, 0, 0}
    end
  end

  defp calculate_hsl_values(delta, l, max_val, min_val, r, g, b) do
    if delta == 0.0 do
      {0, 0, round(l * 100)}
    else
      s = calculate_hsl_saturation(l, delta, max_val, min_val)
      h = calculate_hue(max_val, delta, r, g, b)
      {round(h * 60), round(s * 100), round(l * 100)}
    end
  end

  defp calculate_hsl_saturation(l, delta, max_val, min_val) when l > 0.5 do
    delta / (2 - max_val - min_val)
  end

  defp calculate_hsl_saturation(_l, delta, max_val, min_val) do
    delta / (max_val + min_val)
  end

  defp calculate_hue(max_val, delta, r, g, b) when max_val == r do
    rem(trunc((g - b) / delta + adjust_for_negative_hue(g, b)), 6)
  end

  defp calculate_hue(max_val, delta, r, g, b) when max_val == g do
    (b - r) / delta + 2
  end

  defp calculate_hue(_max_val, delta, r, g, _b) do
    (r - g) / delta + 4
  end

  defp calculate_saturation(max_val, delta) do
    if max_val == 0.0, do: 0.0, else: delta / max_val
  end

  defp calculate_hsv_hue(delta, max_val, r, g, b) do
    if delta == 0.0 do
      0
    else
      cond do
        max_val == r ->
          rem(trunc((g - b) / delta + adjust_for_negative_hue(g, b)), 6)

        max_val == g ->
          (b - r) / delta + 2

        max_val == b ->
          (r - g) / delta + 4

        true ->
          0
      end
    end
  end

  defp adjust_for_negative_hue(g, b) when g < b, do: 6
  defp adjust_for_negative_hue(_g, _b), do: 0
end
