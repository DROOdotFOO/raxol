defmodule Raxol.UI.Harness.Prominence do
  @moduledoc """
  Maps a continuous `prominence` (`0.0..1.0`) attribute onto a resolved hex
  color through the `Raxol.UI.Theming.Salience` H-K solver.

  ## Ground-aware fade

  Fading a foreground color toward a hardcoded reference ground (rather
  than the terminal's *actual* background) gets the direction wrong on a
  light theme: fading toward a dark reference moves a dark foreground
  *away* from a light background, so contrast rises as prominence drops
  instead of falling. `resolve/3` (and `fade/3`) take the real ground as
  an argument, threaded to `Salience.solve_lightness/3` the same way
  `Salience.solve/4` already accepts `:ground` -- the formula
  `faded_apparent = ground + (apparent - ground) * prominence` interpolates
  APPARENT lightness toward the ground point, which is direction-correct on
  either side (dark ground: fades down toward it; light ground: fades up
  toward it) as long as `ground` is the real one, not a hardcoded reference.

  ## Two modes -- pure fade (default) vs floored (opt-in)

  This is the load-bearing design decision of this module. The salience
  gradient *is the point*: context text is *meant* to recede as its
  prominence drops, and "faded but not lost" means **recoverable when a
  caller later raises the block back to prominence 1.0** (e.g. on focus),
  NOT readable-at-a-glance. A universal legibility floor would fight that
  gradient -- flattening the very tier separation the gradient exists to
  create. So:

    * **Pure fade (default).** `resolve(hex, prominence)` and `resolve(hex,
      prominence, ground: g)` apply *only* the ground-aware fade. No
      floor. The output recedes monotonically toward the ground as
      `prominence` drops -- the gradient callers depend on, with no tier
      collapse. Only guaranteed legible **on promotion** (raising the
      block back to prominence 1.0 = identity = the seed), not at rest.
      At `prominence: 0.0` with the floor off, the color fades all the way
      to ground -- effectively invisible against the background. This is
      an intentional boundary of the pure-fade contract, not a bug.

    * **Floored (opt-in, `legibility_floor: true`).** Additionally clamps
      the output to a WCAG-style contrast floor. Callers engage this
      **only for acting / interactive content** -- the tiers where
      blind-reading risk actually lives -- while context/history content
      fades free. A floored output is guaranteed legible **at rest**.

  ## The legibility clamp (opt-in), and why it is opt-in

  A `prominence` scalar floors the INPUT multiplier, not the OUTPUT
  contrast: `|faded_apparent - ground| = |apparent - ground| * prominence`,
  which depends on how much contrast the source color started with. A
  low-apparent-contrast source (a receding neutral, or any near-ground
  seed) can drop below any legibility threshold. When `legibility_floor:
  true`, `resolve/3` clamps the *WCAG-style relative-luminance contrast
  ratio* (`Salience.relative_luminance/1`, Rec. 709 -- an external check the
  solver's own apparent-lightness model cannot self-certify) against
  `FLOOR_RATIO`: if the raw fade falls short, the clamp walks *back up the
  fade line* toward higher prominence until the floor is met, via bisection
  (the fade-to-clamped mapping isn't analytically invertible once gamut
  shrink is in play). "The fade line" is the one-parameter family
  `fade_color(t) = build_hex(ground + (apparent - ground) * t, c * t, h)`
  for `t` running from the requested `prominence` up to `1.0` -- it moves
  BOTH apparent lightness and chroma together, so its endpoint at `t = 1.0`
  is the **true full-chroma prominence:1.0 color** (≈ the input `hex`
  itself, up to gamut round-trip), NOT a reduced-chroma proxy. That makes
  the ceiling exact: the clamp never manufactures more contrast than the
  color's own full-strength self, and the floor-reachability check is run
  against that true ceiling. When even the full-strength color misses the
  floor (a genuinely low-contrast seed against this ground -- a
  palette-design gap the clamp cannot paper over without exceeding its own
  ceiling), `resolve/3` returns that true full-chroma ceiling as documented
  best effort.

  `FLOOR_RATIO` (`#{3.0}`, `#{3.0}:1`) is a **placeholder**, pending
  ratification by a human-eye review pass -- the first playground matrix
  run picks the highest ratio at which every cell is legible and pins it
  here permanently.

  ## Truecolor-only floor; 256-color deferred

  The clamp guarantees the floor on the **24-bit hex it emits** -- it is
  truecolor-only. **256-color survival is out of scope for this module,
  and callers must not assume the clamp survives quantization:**
  downsampling a floored hex to the xterm-256 cube can drop it back under
  the floor (and can collapse adjacent fade tiers). The eventual answer is
  a redistributed per-ground tier ladder for 256-color (fewer,
  wider-spaced tiers chosen in-palette), not a post-hoc clamp on a
  quantized value -- deferred here because it needs a quantization-pipeline
  decision this module does not make.

  ## Scope

  This module resolves a single foreground color; it does not decide
  *which* prominence a block gets nor *whether* the floor is engaged for it
  (that's the caller's policy -- it owns the acting-vs-context call and
  passes `legibility_floor:` accordingly), nor whether a sealed block may
  be restyled at all (that's separate fold/authorization territory).
  """

  alias Raxol.UI.Theming.Salience
  alias Raxol.UI.Theming.SalienceTheme

  # WCAG AA large-text / UI-component minimum -- a placeholder pending a
  # human-eye ratification pass (see moduledoc).
  @floor_ratio 3.0

  @clamp_iterations 24

  @type opts :: [
          ground: float(),
          legibility_floor: boolean(),
          floor_ratio: float()
        ]

  @doc "The placeholder WCAG-style legibility floor ratio (see moduledoc)."
  @spec floor_ratio() :: float()
  def floor_ratio, do: @floor_ratio

  @doc """
  Resolves `hex` at `prominence` (`0.0..1.0`) against a ground.

  Default is the **pure ground-aware fade** (the salience gradient) -- no
  legibility floor. Pass `legibility_floor: true` to additionally clamp the
  output to a WCAG contrast floor; callers engage this only for acting /
  interactive tiers. See the moduledoc's "Two modes" section.

  ## Options

    * `:ground` - ground (background) OKLCH lightness. Default: the
      OSC-11-detected terminal background
      (`Raxol.UI.Theming.SalienceTheme.detect_ground/0`), falling back to
      `Salience.reference_ground/0` when detection is unavailable. Pass
      explicitly to test against a specific ground without touching
      `:persistent_term`. A non-numeric `:ground` (a color string, an
      atom, ...) can't feed the fade math -- it is treated as absent and
      falls back to the same lazy default instead of reaching the fade
      math and raising.
    * `:legibility_floor` - `true` engages the opt-in legibility clamp
      (default `false` = pure fade).
    * `:floor_ratio` - override the legibility floor ratio (default
      `#{@floor_ratio}`); only consulted when `legibility_floor: true`.

  `prominence >= 1.0` is the identity (byte-identical `hex` back, no ground
  lookup, no clamp, regardless of `:legibility_floor`) -- a neutrality
  guarantee: a caller that never sets `prominence` below `1.0` sees zero
  change. `prominence < 0.0` is clamped to `0.0` -- a negative prominence
  would extrapolate past the ground rather than fade toward it, which is
  gamut-undefined.
  """
  @spec resolve(String.t(), number(), opts()) :: String.t()
  def resolve(hex, prominence, opts \\ [])

  def resolve(hex, prominence, _opts) when prominence >= 1.0, do: hex

  def resolve(hex, prominence, opts) do
    prominence = clamp_prominence(prominence)
    ground = resolve_ground(opts)
    {l, c, h} = Salience.hex_to_oklch(hex)
    apparent = Salience.apparent_lightness(l, c, h)
    faded_hex = fade_color(apparent, c, h, ground, prominence)

    if legibility_floor?(opts) do
      clamp_to_floor(faded_hex, apparent, c, h, ground, prominence, opts)
    else
      faded_hex
    end
  end

  @doc """
  The raw ground-aware fade -- identical to `resolve/3`'s default (pure
  fade) mode, and exposed as its own name so callers/tests can name the
  intent explicitly, with no chance of the opt-in floor engaging. A
  non-numeric `ground` falls back to the same lazy default as `resolve/3`.
  """
  @spec fade(String.t(), number(), term()) :: String.t()
  def fade(hex, prominence, _ground) when prominence >= 1.0, do: hex

  def fade(hex, prominence, ground) do
    ground = normalize_ground(ground)
    {l, c, h} = Salience.hex_to_oklch(hex)
    apparent = Salience.apparent_lightness(l, c, h)
    fade_color(apparent, c, h, ground, prominence)
  end

  # A single point on the fade line: apparent lightness AND chroma both
  # scaled toward the ground by `t`. At `t = 1.0` this is the true
  # full-chroma color (≈ the original hex, up to gamut round-trip); at
  # `t = 0.0` it collapses to the ground. Both `fade/3` and the clamp
  # bisection walk this same line so the clamp's ceiling is exact.
  defp fade_color(apparent, c, h, ground, t) do
    build_hex(ground + (apparent - ground) * t, c * t, h)
  end

  @doc """
  WCAG-style contrast ratio between two hex colors: sRGB relative luminance
  (`Salience.relative_luminance/1`, Rec. 709), `(max(Y) + 0.05) / (min(Y) + 0.05)`.
  This is the external, standards-based legibility check, distinct from the
  solver's own internal apparent-lightness model. Raises `ArgumentError` if
  either hex string is malformed (see `Salience.relative_luminance/1`).
  """
  @spec wcag_ratio(String.t(), String.t()) :: float()
  def wcag_ratio(hex_a, hex_b) do
    y_a = Salience.relative_luminance(hex_a)
    y_b = Salience.relative_luminance(hex_b)
    (max(y_a, y_b) + 0.05) / (min(y_a, y_b) + 0.05)
  end

  defp resolve_ground(opts) do
    opts
    |> Keyword.get_lazy(:ground, &SalienceTheme.detect_ground/0)
    |> normalize_ground()
  end

  # A `:ground` opt (or `fade/3`'s positional `ground`) that isn't a number
  # -- a color string, an atom, ... -- can't feed the fade math (it flows
  # straight into float arithmetic in `fade_color/5`). Treat it as absent
  # and fall back to the same lazy default rather than letting it reach
  # that arithmetic and raise.
  defp normalize_ground(ground) when is_number(ground), do: ground
  defp normalize_ground(_invalid), do: SalienceTheme.detect_ground()

  # A negative prominence would extrapolate PAST the ground rather than
  # fade toward it (`ground + (apparent - ground) * t` with `t < 0` moves
  # apparent lightness away from both `apparent` and `ground`), which is
  # gamut-undefined. Clamp to the `t = 0.0` floor -- full fade to ground --
  # instead.
  defp clamp_prominence(prominence) when prominence < 0.0, do: 0.0
  defp clamp_prominence(prominence), do: prominence

  defp legibility_floor?(opts), do: Keyword.get(opts, :legibility_floor, false)

  defp resolve_floor_ratio(opts),
    do: Keyword.get(opts, :floor_ratio, @floor_ratio)

  defp build_hex(apparent_lightness, c, h) do
    l = Salience.solve_lightness(apparent_lightness, c, h)
    Salience.oklch_to_hex(l, c, h)
  end

  # The legibility-floor guard: if the raw fade's contrast ratio against
  # ground already meets the floor, it passes through unchanged. Otherwise
  # walk the fade line back up toward `t = 1.0` (the TRUE full-chroma
  # prominence:1.0 color) until the floor is met -- never past `t = 1.0`,
  # so the clamp never manufactures more contrast than the color's own
  # full-strength self. The reachability check is run against that same
  # true ceiling.
  defp clamp_to_floor(faded_hex, apparent, c, h, ground, prominence, opts) do
    floor_ratio = resolve_floor_ratio(opts)
    ground_hex = build_hex(ground, 0.0, 0.0)

    if wcag_ratio(faded_hex, ground_hex) >= floor_ratio do
      faded_hex
    else
      # The true prominence:1.0 color: full chroma AND full apparent
      # lightness, the `t = 1.0` endpoint of the fade line.
      ceiling_hex = fade_color(apparent, c, h, ground, 1.0)

      if wcag_ratio(ceiling_hex, ground_hex) < floor_ratio do
        # Even the full-strength color misses the floor (a genuinely
        # low-contrast seed against this ground -- a palette-design gap) --
        # best effort: the true ceiling, the most contrast this color has
        # to give, never more.
        ceiling_hex
      else
        ctx = %{
          apparent: apparent,
          c: c,
          h: h,
          ground: ground,
          ground_hex: ground_hex,
          floor: floor_ratio
        }

        bisect_floor(ctx, prominence, 1.0, @clamp_iterations)
      end
    end
  end

  # Bisection over `t` on the fade line between the (failing) requested
  # prominence `lo` and the (passing) full-strength `hi = 1.0` -- not
  # solved in closed form because gamut-shrink (`Salience.oklch_to_rgb/3`'s
  # chroma clamp) makes the WCAG ratio a non-analytic function of `t`. `hi`
  # always denotes a `t` already verified to pass; `fade_color/5` at `hi`
  # is the return value once the interval has collapsed to tolerance, so
  # the result is always floor-meeting and always at `t <= 1.0` (never
  # exceeding the true ceiling). `ctx` carries the loop invariants.
  defp bisect_floor(ctx, _lo, hi, 0),
    do: fade_color(ctx.apparent, ctx.c, ctx.h, ctx.ground, hi)

  defp bisect_floor(ctx, lo, hi, n) do
    mid = (lo + hi) / 2
    hex = fade_color(ctx.apparent, ctx.c, ctx.h, ctx.ground, mid)

    if wcag_ratio(hex, ctx.ground_hex) >= ctx.floor do
      bisect_floor(ctx, lo, mid, n - 1)
    else
      bisect_floor(ctx, mid, hi, n - 1)
    end
  end
end
