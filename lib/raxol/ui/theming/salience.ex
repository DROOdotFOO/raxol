defmodule Raxol.UI.Theming.Salience do
  @moduledoc """
  Salience-tier color solver: OKLCH colors leveled through a two-lobe
  Helmholtz-Kohlrausch apparent-lightness model.

  Instead of hand-picking lightness per color, a palette is expressed as
  `(hue, chroma, tier)` seeds. Each tier is an apparent-lightness *contrast
  delta* away from the ground (background) lightness; the solver compensates
  for the H-K effect (chromatic colors — especially blues — read darker than
  their nominal OKLCH `L` suggests) so every color on one tier appears equally
  bright to the eye.

  The model is ported verbatim from Delta's `foundation.css` two-lobe
  formulation (via dappsnap `bake-darcula.mjs`):

      apparent_L = L - 0.14 * C * hue_factor(h)

  Tiers generalize to any ground: on dark grounds tiers solve *up* (lighter
  than ground), on light grounds *down*, chosen automatically by headroom.
  Deltas compress proportionally when the ground leaves too little headroom
  (mid-gray grounds), preserving tier ordering.

  Ground lightness is a runtime input — pair with an OSC 11 background query
  to solve the palette against the terminal's actual background.
  """

  @hk_k 0.14

  # Apparent-lightness contrast deltas per tier, derived from the reference
  # dark-ground targets (ground L = 0.2): recede 0.55, alarm 0.53,
  # differentiate 0.62, baseline 0.77, anchor 0.85.
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
  Two-lobe H-K hue factor: warm cosine fundamental plus a Gaussian bump
  around blue (h = 255), clamped to [0.3, 1.2].
  """
  @spec hue_factor(number()) :: float()
  def hue_factor(h) do
    hn = h / 360
    warm = :math.cos((hn * 3 - 1) * 2 * :math.pi()) * 0.45 + 0.75
    blue = 0.25 * :math.exp(-:math.pow(abs(h - 255) / 35, 2))
    min(1.2, max(0.3, warm + blue))
  end

  @doc "Apparent lightness of an OKLCH color under the two-lobe H-K model."
  @spec apparent_lightness(number(), number(), number()) :: float()
  def apparent_lightness(l, c, h), do: l - @hk_k * c * hue_factor(h)

  @doc """
  Nominal OKLCH `L` that lands a `(C, h)` color on a target apparent
  lightness.
  """
  @spec solve_lightness(number(), number(), number()) :: float()
  def solve_lightness(target_al, c, h),
    do: target_al + @hk_k * c * hue_factor(h)

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
      "#c1712c"

      iex> Raxol.UI.Theming.Salience.solve(:baseline, 0.0, 250)
      "#b4b4b4"
  """
  @spec solve(tier(), number(), number(), keyword()) :: String.t()
  def solve(tier, c, h, opts \\ []) do
    ground = Keyword.get(opts, :ground, @reference_ground)
    polarity = Keyword.get(opts, :polarity, :auto)

    target = tier_target(tier, ground, polarity)
    l = solve_lightness(target, c, h)
    oklch_to_hex(l, c, h)
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

  Seeds are maps with `:name`, `:h`, `:c`, `:tier` (plus any extra keys,
  which are carried through). Returns `%{name => hex}`.
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

  defp cube(x), do: x * x * x

  defp cbrt(x) when x < 0, do: -:math.pow(-x, 1 / 3)
  defp cbrt(x), do: :math.pow(x, 1 / 3)
end
