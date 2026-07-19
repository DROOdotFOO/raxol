defmodule Raxol.UI.Theming.Salience do
  @moduledoc """
  Salience-tier color solver: OKLCH colors leveled through a
  Helmholtz-Kohlrausch apparent-lightness model.

  Instead of hand-picking lightness per color, a palette is expressed as
  `(hue, chroma, tier)` seeds. Each tier is an apparent-lightness *contrast
  delta* away from the ground (background) lightness; the solver compensates
  for the H-K effect (chromatic colors — especially reds and blues — read
  brighter than their nominal OKLCH `L` suggests, since OKLab does not model
  H-K) so every color on one tier appears equally bright to the eye.

  The hue dependence of the effect (`hue_factor/1`) is a 3-harmonic Fourier
  fit of the Nayatani (1997) VAC data — weakest near yellow, strongest near
  purple — combined with chroma via:

      apparent_L = L + 0.14 * C * hue_factor(h)

  Tiers generalize to any ground: on dark grounds tiers solve *up* (lighter
  than ground), on light grounds *down*, chosen automatically by headroom.
  Deltas compress proportionally when the ground leaves too little headroom
  (mid-gray grounds), preserving tier ordering.

  Ground lightness is a runtime input — pair with an OSC 11 background query
  to solve the palette against the terminal's actual background.
  """

  @hk_k 0.14

  # Apparent-lightness contrast deltas per tier. At the reference ground
  # (L = 0.2) these produce apparent-lightness targets of recede 0.55,
  # alarm 0.53, differentiate 0.62, baseline 0.77, anchor 0.85 -- i.e.
  # ground + delta, not the deltas themselves.
  @tier_deltas %{
    alarm: 0.33,
    recede: 0.35,
    differentiate: 0.42,
    baseline: 0.57,
    anchor: 0.65
  }

  @reference_ground 0.2
  # Displayable apparent-lightness bounds used for headroom compression.
  @al_min 0.03
  @al_max 0.97
  @max_delta 0.65

  @type tier :: :alarm | :recede | :differentiate | :baseline | :anchor
  @type polarity :: :auto | :up | :down

  @doc "Tier names ordered by increasing contrast from ground."
  @spec tiers() :: [tier()]
  def tiers, do: [:alarm, :recede, :differentiate, :baseline, :anchor]

  @doc """
  The reference near-black ground OKLCH lightness the tier deltas were
  derived against (`#{@reference_ground}`). Exposed so callers that need
  a fallback ground (e.g. no OSC 11 detection) don't duplicate the number.
  """
  @spec reference_ground() :: float()
  def reference_ground, do: @reference_ground

  @doc "Apparent-lightness contrast delta for a tier."
  @spec tier_delta(tier()) :: float()
  def tier_delta(tier), do: Map.fetch!(@tier_deltas, tier)

  @doc """
  H-K hue factor: a 3-harmonic Fourier fit of the Nayatani (1997)
  VAC (visually-adjusted-contrast) hue dependence data (source: dappsnap
  `delta-css` `foundation.css` `--🧮hue-factor`). `h` is in degrees;
  intrinsically bounded to roughly `[0.45, 1.11]` across the hue circle
  (minimum near yellow at h≈110, maximum near purple at h≈310), so no
  clamp is applied.
  """
  @spec hue_factor(number()) :: float()
  def hue_factor(h) do
    hr = h * :math.pi() / 180

    0.77911 + 0.08091 * :math.cos(hr) - 0.13593 * :math.sin(hr) +
      0.06202 * :math.cos(2 * hr) - 0.00365 * :math.sin(2 * hr) -
      0.01415 * :math.cos(3 * hr) + 0.03377 * :math.sin(3 * hr)
  end

  @doc "Apparent lightness of an OKLCH color under the H-K model."
  @spec apparent_lightness(number(), number(), number()) :: float()
  def apparent_lightness(l, c, h), do: l + @hk_k * c * hue_factor(h)

  @doc """
  Nominal OKLCH `L` that lands a `(C, h)` color on a target apparent
  lightness.
  """
  @spec solve_lightness(number(), number(), number()) :: float()
  def solve_lightness(target_al, c, h),
    do: target_al - @hk_k * c * hue_factor(h)

  @doc """
  Solves a `(C, h)` seed on a salience tier against a ground lightness and
  returns a hex color.

  ## Options

    * `:ground` - ground (background) OKLCH lightness. Default `#{@reference_ground}`
      (the reference near-black ground the tier deltas were derived against).
    * `:polarity` - `:up` (tiers lighter than ground), `:down` (darker), or
      `:auto` (default): whichever side of the ground has more headroom.

  ## Examples

      iex> Raxol.UI.Theming.Salience.solve(:differentiate, 0.13, 57)
      "#bb6b25"

      iex> Raxol.UI.Theming.Salience.solve(:baseline, 0.0, 250)
      "#b4b4b4"
  """
  @spec solve(tier(), number(), number(), keyword()) :: String.t()
  def solve(tier, c, h, opts \\ []) do
    ground = Keyword.get(opts, :ground, @reference_ground)
    polarity = Keyword.get(opts, :polarity, :auto)

    target = tier_target(tier, ground, polarity)
    {l, c} = solve_lightness_for_achievable_chroma(target, c, h)
    oklch_to_hex(l, c, h)
  end

  # Gamut-mapping shrinks chroma at a fixed L (see shrink_chroma/3), but
  # apparent_lightness/3 depends on C -- so a color whose chroma got shrunk
  # to fit sRGB no longer lands on the solved apparent-lightness target.
  # Re-solve L against the chroma actually achievable at that L/h and
  # iterate; this converges in 2-3 steps, capped at 4.
  @chroma_resolve_iterations 4
  @chroma_resolve_epsilon 1.0e-6

  defp solve_lightness_for_achievable_chroma(target, c, h) do
    l = solve_lightness(target, c, h)
    resolve_chroma_step(target, l, c, h, @chroma_resolve_iterations)
  end

  defp resolve_chroma_step(_target, l, c, _h, 0), do: {l, c}

  defp resolve_chroma_step(target, l, c, h, iterations_left) do
    actual_c = achieved_chroma(l, c, h)

    if abs(actual_c - c) < @chroma_resolve_epsilon do
      {l, c}
    else
      new_l = solve_lightness(target, actual_c, h)
      resolve_chroma_step(target, new_l, actual_c, h, iterations_left - 1)
    end
  end

  # The chroma oklch_to_rgb/3 would actually render at (l, c, h) after
  # gamut-mapping, without paying for the rest of the rgb/hex conversion.
  defp achieved_chroma(l, c, h_deg) do
    h = h_deg * :math.pi() / 180
    l = min(0.999, max(0.001, l))
    shrink_chroma(l, c, h)
  end

  @doc """
  Target apparent lightness for a tier against a ground, with headroom
  compression: when the ground leaves less than the full delta range on the
  chosen side, all deltas scale down proportionally (ordering preserved).
  """
  @spec tier_target(tier(), number(), polarity()) :: float()
  def tier_target(tier, ground, polarity \\ :auto) do
    sign = resolve_polarity(ground, polarity)

    headroom =
      case sign do
        1 -> @al_max - ground
        -1 -> ground - @al_min
      end

    scale = min(1.0, max(0.0, headroom) / @max_delta)
    ground + sign * tier_delta(tier) * scale
  end

  defp resolve_polarity(_ground, :up), do: 1
  defp resolve_polarity(_ground, :down), do: -1
  defp resolve_polarity(ground, :auto), do: if(ground < 0.5, do: 1, else: -1)

  @doc """
  Solves a seed list into a palette map.

  Seeds are maps with `:name`, `:h`, `:c`, `:tier` (extra keys are ignored).
  Returns `%{name => hex}`.
  """
  @spec solve_palette([map()], keyword()) :: %{atom() => String.t()}
  def solve_palette(seeds, opts \\ []) do
    Map.new(seeds, fn %{name: name, h: h, c: c, tier: tier} ->
      {name, solve(tier, c, h, opts)}
    end)
  end

  # ---- OKLCH <-> sRGB ----

  @doc """
  Converts OKLCH to a gamut-mapped sRGB `{r, g, b}` tuple (0-255 per
  channel), clamping `L` into displayable range and shrinking chroma until
  the color fits the sRGB gamut.
  """
  @spec oklch_to_rgb(number(), number(), number()) ::
          {0..255, 0..255, 0..255}
  def oklch_to_rgb(l, c, h_deg) do
    h = h_deg * :math.pi() / 180
    l = min(0.999, max(0.001, l))
    c = shrink_chroma(l, c, h)

    {r, g, b} = oklab_to_linear(l, c * :math.cos(h), c * :math.sin(h))

    [r, g, b]
    |> Enum.map(fn x -> round(min(1.0, max(0.0, linear_to_srgb(x))) * 255) end)
    |> List.to_tuple()
  end

  @doc """
  Converts OKLCH to a sRGB hex string, clamping `L` into displayable range
  and shrinking chroma until the color fits the sRGB gamut.
  """
  @spec oklch_to_hex(number(), number(), number()) :: String.t()
  def oklch_to_hex(l, c, h_deg) do
    {r, g, b} = oklch_to_rgb(l, c, h_deg)

    [r, g, b]
    |> Enum.map_join(fn x ->
      x
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(2, "0")
    end)
    |> then(&("#" <> &1))
  end

  @doc """
  Converts a `#rrggbb` hex string (or any struct/map with integer `r`, `g`,
  `b` components, e.g. `Raxol.Style.Colors.Color`) to `{l, c, h}` OKLCH.
  """
  @spec hex_to_oklch(String.t() | %{r: 0..255, g: 0..255, b: 0..255}) ::
          {float(), float(), float()}
  def hex_to_oklch(%{r: r, g: g, b: b})
      when is_integer(r) and is_integer(g) and is_integer(b) do
    rgb_to_oklch(r / 255, g / 255, b / 255)
  end

  def hex_to_oklch("#" <> hex), do: hex_to_oklch(hex)

  def hex_to_oklch(<<r::binary-2, g::binary-2, b::binary-2>>) do
    [r, g, b] = Enum.map([r, g, b], &(String.to_integer(&1, 16) / 255))
    rgb_to_oklch(r, g, b)
  end

  @doc """
  Converts sRGB components in `0.0..1.0` to `{l, c, h}` OKLCH
  (`h` in degrees, `0.0 <= h < 360.0`).
  """
  @spec rgb_to_oklch(number(), number(), number()) ::
          {float(), float(), float()}
  def rgb_to_oklch(r, g, b) do
    [r, g, b] = Enum.map([r, g, b], &srgb_to_linear/1)

    l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

    l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

    c = :math.sqrt(a * a + b * b)
    h = :math.atan2(b, a) * 180 / :math.pi()
    h = if h < 0, do: h + 360, else: h
    {l, c, h}
  end

  @doc """
  Converts sRGB components in `0.0..1.0` to `{l, a, b}` OKLab (Cartesian).

  This is the same transform as `rgb_to_oklch/3` up to the polar step --
  provided separately (rather than deriving Cartesian from polar, or vice
  versa) so callers that want Euclidean OKLab ΔE, e.g.
  `Raxol.UI.Theming.Colors`'s nearest-palette-color quantizers, skip a
  redundant `cos`/`sin` round-trip per comparison.
  """
  @spec rgb_to_oklab(number(), number(), number()) ::
          {float(), float(), float()}
  def rgb_to_oklab(r, g, b) do
    [r, g, b] = Enum.map([r, g, b], &srgb_to_linear/1)

    l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

    l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

    {l, a, b}
  end

  defp shrink_chroma(l, c, h) when c > 0 do
    rgb = oklab_to_linear(l, c * :math.cos(h), c * :math.sin(h))

    if in_gamut?(rgb), do: c, else: shrink_chroma(l, c - 0.002, h)
  end

  defp shrink_chroma(_l, c, _h), do: max(c, 0.0)

  defp in_gamut?({r, g, b}) do
    Enum.all?([r, g, b], fn x -> x >= -1.0e-4 and x <= 1 + 1.0e-4 end)
  end

  defp oklab_to_linear(l, a, b) do
    l_ = cube(l + 0.3963377774 * a + 0.2158037573 * b)
    m_ = cube(l - 0.1055613458 * a - 0.0638541728 * b)
    s_ = cube(l - 0.0894841775 * a - 1.291485548 * b)

    {
      4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
      -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
      -0.0041960863 * l_ - 0.7034186147 * m_ + 1.707614701 * s_
    }
  end

  defp linear_to_srgb(c) do
    if c <= 0.0031308,
      do: 12.92 * c,
      else: 1.055 * :math.pow(c, 1 / 2.4) - 0.055
  end

  defp srgb_to_linear(c) do
    if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
  end

  @doc """
  sRGB relative luminance (Rec. 709 coefficients) of a `#rrggbb` hex color,
  per the WCAG contrast-ratio formula (`(L1 + 0.05) / (L2 + 0.05)`).

  This is intentionally a different lens than `apparent_lightness/3`: the
  H-K apparent-lightness model is the solver's *internal* notion of equal
  brightness (used for tier uniformity/monotonicity), while relative
  luminance is the *external*, standards-based check a caller can use for a
  legibility floor that the solver's own model cannot self-certify.

  Raises `ArgumentError` (with the malformed value in the message) when
  `hex` isn't exactly 6 hex digits, optionally `#`-prefixed -- a
  programming-error contract, not a runtime-input one: callers are
  expected to pass already-resolved hex colors, not raw user input.
  """
  @spec relative_luminance(String.t()) :: float()
  def relative_luminance("#" <> hex), do: relative_luminance(hex)

  def relative_luminance(hex) when is_binary(hex) do
    case parse_hex6(hex) do
      {:ok, {r, g, b}} ->
        [r, g, b] = Enum.map([r, g, b], &(&1 / 255))

        0.2126 * srgb_to_linear(r) + 0.7152 * srgb_to_linear(g) +
          0.0722 * srgb_to_linear(b)

      :error ->
        raise ArgumentError,
              "invalid hex color #{inspect(hex)}: expected 6 hex digits " <>
                "(e.g. \"1e1e1e\"), optionally prefixed with \"#\""
    end
  end

  defp parse_hex6(<<r::binary-2, g::binary-2, b::binary-2>>) do
    with {:ok, rv} <- parse_hex_byte(r),
         {:ok, gv} <- parse_hex_byte(g),
         {:ok, bv} <- parse_hex_byte(b) do
      {:ok, {rv, gv, bv}}
    end
  end

  defp parse_hex6(_other), do: :error

  defp parse_hex_byte(byte) do
    case Integer.parse(byte, 16) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp cube(x), do: x * x * x

  defp cbrt(x) when x < 0, do: -:math.pow(-x, 1 / 3)
  defp cbrt(x), do: :math.pow(x, 1 / 3)
end
