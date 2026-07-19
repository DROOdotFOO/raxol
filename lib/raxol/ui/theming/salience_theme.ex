defmodule Raxol.UI.Theming.SalienceTheme do
  @moduledoc """
  Builds a `Raxol.UI.Theming.Theme` from salience-tier seeds solved against
  the terminal's actual background.

  Colors are expressed as `(hue, chroma, tier)` seeds — hue carries identity,
  tier carries importance — and `Raxol.UI.Theming.Salience` solves the
  lightness of every color so each tier reads perceptually level on the
  detected ground. Works on dark and light terminals from one seed table.

  Ground detection is optional and reads the unified
  `Raxol.Terminal.Capabilities` session record (native-palette-riding, see
  `docs/proposals/in-flight/native-palette-riding.md` §3/§7) via the guarded
  cross-package pattern (`Code.ensure_loaded?/1` +
  `@compile {:no_warn_undefined, ...}`, map-shape matching per
  `lib/raxol/ui/theming/palette.ex`'s convention). Fallback ladder, cheapest
  and most authoritative first:

    1. Record `background/0` (`{r, g, b}` from OSC 11) → H-K apparent
       lightness (`Salience.apparent_lightness_of_rgb/3`, not nominal OKLCH
       `L` -- a tinted background, e.g. a green terminal, reads brighter
       than its bare `L` once chroma is folded in).
    2. Record `polarity_seed/0` (`$COLORFGBG`, `:dark` | `:light` | `nil`)
       → `Salience.reference_ground/0` for `:dark`, `@light_reference_ground`
       for `:light`.
    3. `Salience.reference_ground/0` (no terminal package, no record cached,
       or no seed either — headless, LiveView, tests).
  """

  alias Raxol.UI.Theming.Ansi16Salience
  alias Raxol.UI.Theming.Salience
  alias Raxol.UI.Theming.Theme

  @compile {:no_warn_undefined, Raxol.Terminal.Capabilities}

  # Documented light-canvas reference ground (amendment A1/§2 rung 2) used
  # only when polarity_seed/0 says :light and no OSC 11 background reading
  # is available. Mirrors reference_ground/0's role for :dark, just on the
  # light side of the 0.5 cutoff.
  @light_reference_ground 0.95

  # Semantic seed table. Hues follow the compensated-Darcula family:
  # orange 57 (warning), yellow 77 (emphasis), green 134 (success),
  # blue 242 (accent), neutral-blue 250 (text), red 25 (error).
  @seeds [
    %{name: :foreground, h: 250, c: 0.022, tier: :baseline},
    %{name: :accent, h: 242, c: 0.074, tier: :differentiate},
    %{name: :error, h: 25, c: 0.16, tier: :alarm},
    %{name: :warning, h: 57, c: 0.13, tier: :differentiate},
    %{name: :success, h: 134, c: 0.075, tier: :differentiate},
    %{name: :emphasis, h: 77, c: 0.125, tier: :anchor},
    %{name: :muted, h: 250, c: 0.0, tier: :recede},
    %{name: :border, h: 250, c: 0.0, tier: :recede}
  ]

  @doc "The default semantic seed table."
  @spec seeds() :: [map()]
  def seeds, do: @seeds

  @doc """
  Detected ground: H-K apparent lightness (`Salience.apparent_lightness_of_rgb/3`,
  not nominal OKLCH `L`) of the `Raxol.Terminal.Capabilities` record's OSC 11
  background reading, falling back through the ladder documented in the
  moduledoc when a reading is unavailable. Using apparent lightness rather
  than bare `L` matters for tinted backgrounds (a green-on-green terminal,
  say) -- the ground the solver ranks tiers against is what a human
  actually perceives as bright, not the nominal lightness coordinate.
  """
  @spec detect_ground() :: float()
  def detect_ground do
    case detect_ground_from_background() do
      {:ok, al} -> al
      :error -> detect_ground_from_polarity_seed()
    end
  end

  defp detect_ground_from_background do
    with true <- Code.ensure_loaded?(Raxol.Terminal.Capabilities),
         {r, g, b} <- Raxol.Terminal.Capabilities.background() do
      {:ok, Salience.apparent_lightness_of_rgb(r, g, b)}
    else
      _ -> :error
    end
  end

  defp detect_ground_from_polarity_seed do
    with true <- Code.ensure_loaded?(Raxol.Terminal.Capabilities),
         seed <- Raxol.Terminal.Capabilities.polarity_seed(),
         true <- seed in [:dark, :light] do
      seed_to_ground(seed)
    else
      _ -> Salience.reference_ground()
    end
  end

  defp seed_to_ground(:dark), do: Salience.reference_ground()
  defp seed_to_ground(:light), do: @light_reference_ground

  @doc """
  Detected canvas polarity from the detected ground, using the same `0.5`
  hard cutoff `Ansi16Salience.polarity/1` uses (native-palette-riding §5 /
  amendment A5) -- delegates to it rather than re-deriving the threshold,
  so the two can never drift apart. `detect_ground/0` feeds this apparent
  lightness (not nominal `L`), which is the correct perceptual input for
  the cutoff: polarity is a judgment about how bright the ground *looks*,
  and a tinted background can sit on the opposite side of `0.5` from where
  its nominal `L` alone would place it.
  """
  @spec detect_polarity() :: Ansi16Salience.polarity()
  def detect_polarity, do: Ansi16Salience.polarity(detect_ground())

  @doc """
  Detected native foreground apparent lightness (H-K, via
  `Salience.apparent_lightness_of_rgb/3`) of the `Raxol.Terminal.Capabilities`
  record's OSC 10 foreground reading, or `nil` when no record is cached or
  no foreground was reported.

  OSC 10 foregrounds are typically near-achromatic (chroma ~0), in which
  case apparent lightness collapses to nominal OKLCH `L` by construction --
  the H-K chroma term vanishes (`apparent_L = L + 0.14 * C * hue_factor(h)`,
  `C ≈ 0`). Routed through the shared apparent-lightness helper anyway (not
  a bare `rgb_to_oklch/3` + `L` read) so a tinted foreground is handled
  correctly too, and so this can't silently drift from `detect_ground/0`'s
  treatment of the background.
  """
  @spec detect_foreground_al() :: float() | nil
  def detect_foreground_al do
    with true <- Code.ensure_loaded?(Raxol.Terminal.Capabilities),
         {r, g, b} <- Raxol.Terminal.Capabilities.foreground() do
      Salience.apparent_lightness_of_rgb(r, g, b)
    else
      _ -> nil
    end
  end

  @doc """
  Builds a Theme with every color solved against the ground.

  ## Options

    * `:ground` - ground lightness override (default: `detect_ground/0`)
    * `:seeds` - seed table override (default: `seeds/0`)
    * `:id` / `:name` - theme identity (default `:salience`)
    * `:foreground_l` - native foreground apparent-lightness override
      (default: `detect_foreground_al/0`). Amendment A1: when present and on
      the solving side of `ground` (a fg lighter than a dark ground when
      solving up, darker than a light ground when solving down -- anything
      else is nonsense and is ignored), headroom compression solves every
      tier toward the terminal's own foreground instead of the absolute
      `0.97`/`0.03` displayable bound (`Salience.tier_target/4`'s
      `:far_bound`).
  """
  @spec build(keyword()) :: Theme.t()
  def build(opts \\ []) do
    ground = Keyword.get_lazy(opts, :ground, &detect_ground/0)
    seeds = Keyword.get(opts, :seeds, @seeds)
    fg_al = Keyword.get_lazy(opts, :foreground_l, &detect_foreground_al/0)

    solve_opts = [ground: ground] ++ far_bound_opt(ground, fg_al)
    palette = Salience.solve_palette(seeds, solve_opts)

    background = Salience.oklch_to_hex(ground, 0.0, 0.0)

    Theme.new(%{
      id: Keyword.get(opts, :id, :salience),
      name: Keyword.get(opts, :name, "salience"),
      colors: %{
        background: background,
        foreground: palette.foreground,
        accent: palette.accent,
        error: palette.error,
        warning: palette.warning,
        success: palette.success,
        emphasis: palette.emphasis,
        muted: palette.muted
      },
      component_styles: %{
        text_input: %{
          background: background,
          foreground: palette.foreground,
          border: palette.border,
          focus: palette.accent
        },
        button: %{
          background: palette.accent,
          foreground: background,
          hover: palette.emphasis,
          active: palette.accent
        },
        checkbox: %{
          background: background,
          foreground: palette.foreground,
          border: palette.border,
          checked: palette.accent
        },
        table: %{
          border: :single,
          header_foreground: palette.emphasis,
          row_foreground: palette.foreground,
          selected_row_foreground: palette.accent
        },
        focus: %{border: :single, border_fg: palette.accent},
        disabled: %{fg: palette.muted}
      }
    })
  end

  # Amendment A1's nonsense-fg guard: a fg apparent lightness only bounds
  # the solve when it sits on the *solving* side of ground -- the same
  # `ground < 0.5` cutoff `Salience.tier_target/4`'s :auto polarity uses
  # (solving up / lighter) vs its complement (solving down / darker). A fg
  # darker than a dark ground (or lighter than a light ground) is not a
  # usable far bound; fall through to the absolute 0.97/0.03 default by
  # omitting :far_bound entirely.
  defp far_bound_opt(ground, fg_al) when is_number(fg_al) do
    cond do
      ground < 0.5 and fg_al > ground -> [far_bound: fg_al]
      ground >= 0.5 and fg_al < ground -> [far_bound: fg_al]
      true -> []
    end
  end

  defp far_bound_opt(_ground, _fg_al), do: []
end
