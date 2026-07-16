defmodule Raxol.UI.Theming.Ansi16Salience do
  @moduledoc """
  Polarity-preserving 16-color (ANSI16) degradation table for semantic
  salience roles.

  ## Why this module exists

  On a 16-color terminal, naive nearest-RGB quantization of the solved
  salience palette (`Raxol.UI.Theming.Colors.find_closest_basic_color/1`)
  collapses most semantic fields onto the gray ramp: measured on this
  codebase, 8 of the 11 harness-painted fields (success, accent, emphasis,
  diff add/del, chrome, ...) gray out on the dark reference ground, and the
  survivors lie about their hue -- solved `error` nearest-RGB-quantizes to
  ANSI 3 (yellow), not any red slot. Averaging RGB channels down to 16 flat
  swatches erases the hue information that carries semantic meaning.

  This module replaces that lossy path for semantic colors. Instead of
  measuring distance in RGB space, each semantic role is PINNED to a
  hue-preserving ANSI slot chosen so the role's category (red/green/yellow/
  blue/magenta/neutral) is never lost and never confused with another
  role's category.

  ## Polarity-awareness

  ANSI16 offers a normal-intensity slot (1-7) and a bright-intensity slot
  (9-15) per hue. Which one reads as "the loud one" depends on the canvas:
  bright variants pop on a dark background, normal variants pop on a light
  background. `polarity/1` derives the canvas from ground OKLCH lightness
  using the same threshold as `Raxol.UI.Theming.Salience`'s `:auto` polarity
  resolution (`ground < 0.5` is dark).

  ## Tier degradation

  The shipped prominence ladder has four tiers (1.0 / 0.8 / 0.6 / 0.4), but
  16-color can only express two distinguishable steps per hue (normal vs.
  bright). The ladder folds pairwise at `loud_threshold/0` (0.8): prominence
  `>= 0.8` resolves to the loud tier, everything below resolves to the soft
  tier. That fold keeps `1.0` and `0.6` -- the coarsest separation the
  instrument requires -- on distinct slots for every role except `:muted`
  and `:border`, which already sit at the dimmest slot that stays legible
  (the recede floor); folding them is intentional, not a gap.

  ## Accepted losses

  This is a lossy degradation and it accepts specific losses in exchange
  for never lying about hue:

    * Sub-hue detail is dropped -- an orange warning and a yellow warning
      both land on the yellow slot.
    * `:diff_add` folds onto `:success`'s green family and `:diff_del`
      folds onto `:error`'s red family; these are in-family folds, not
      category lies.
    * `:emphasis` trades its warm (yellow-adjacent) seed hue for the
      max-contrast neutral slot at its loudest tier, so it can never be
      mistaken for the `:warning` state signal -- the yellow slot is
      reserved for warning. `:emphasis` keeps its anchor function (it is
      still the loudest role in the ramp) without competing for a hue.
    * `:running` is reserved for activity/in-progress state and given its
      own hue family (magenta), separate from the alarm/success/warning
      triad.

  ## Scope

  This table is the only supported 16-color path for semantic role colors.
  `Raxol.UI.Theming.Colors.find_closest_basic_color/1` (nearest-RGB) must
  not be used for semantic roles -- see its `@doc` for the pointer back
  here. Truecolor and 256-color rendering are unaffected; this module is
  additive.

  ## Unknown roles

  `roles/0` is the closed, compile-time set of roles this table knows
  about. `slot/2`, `slot/3`, and `category/1` intentionally have no
  fallback clause for atoms outside that set -- they raise
  `FunctionClauseError` rather than silently guessing a slot.
  """

  @type role ::
          :foreground
          | :accent
          | :error
          | :warning
          | :success
          | :emphasis
          | :muted
          | :border
          | :chrome
          | :diff_add
          | :diff_del
          | :running

  @type polarity :: :dark | :light
  @type slot :: 0..15
  @type category :: :red | :green | :yellow | :blue | :magenta | :neutral
  @type tier :: :loud | :soft

  # Prominence >= this value resolves to the loud tier; below is soft. The
  # shipped 4-tier ladder (1.0 / 0.8 / 0.6 / 0.4) folds pairwise here:
  # {1.0, 0.8} -> loud, {0.6, 0.4, ...} -> soft.
  @loud_threshold 0.8

  # Chromatic roles and their base ANSI hue slot (the normal-intensity
  # 1-5 range). Dark canvas: loud = bright variant (base + 8), soft =
  # normal (base). Light canvas: the polarity flip -- loud = normal,
  # soft = bright.
  @chromatic_base %{
    error: 1,
    diff_del: 1,
    success: 2,
    diff_add: 2,
    warning: 3,
    accent: 4,
    running: 5
  }

  @chromatic_roles Map.keys(@chromatic_base)

  # Neutral roles: explicit {loud, soft} slot per polarity. Emphasis is
  # the anchor tier (max-contrast slot); foreground/chrome sit one step
  # below it; muted/border are the recede tier at the dimmest readable
  # slot (their floor -- loud and soft intentionally coincide there).
  @neutral_table %{
    dark: %{
      emphasis: {15, 7},
      foreground: {7, 8},
      chrome: {7, 8},
      muted: {8, 8},
      border: {8, 8}
    },
    light: %{
      emphasis: {0, 8},
      foreground: {8, 7},
      chrome: {8, 7},
      muted: {7, 7},
      border: {7, 7}
    }
  }

  @neutral_roles Map.keys(@neutral_table.dark)

  @roles @chromatic_roles ++ @neutral_roles

  @doc "The semantic salience roles this table covers."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Derives canvas polarity from ground OKLCH lightness.

  Mirrors `Raxol.UI.Theming.Salience`'s `:auto` polarity threshold: a
  ground lightness below `0.5` is a dark canvas, `0.5` and above is light.
  """
  @spec polarity(number()) :: polarity()
  def polarity(ground_lightness) when is_number(ground_lightness) do
    if ground_lightness < 0.5, do: :dark, else: :light
  end

  @doc """
  Prominence at or above this value resolves to the loud tier; below it
  resolves to the soft tier.
  """
  @spec loud_threshold() :: float()
  def loud_threshold, do: @loud_threshold

  @doc "Same as `slot/3` at full (`1.0`) prominence."
  @spec slot(role(), polarity()) :: slot()
  def slot(role, polarity), do: slot(role, polarity, 1.0)

  @doc """
  Resolves a semantic role to its ANSI16 slot for the given canvas
  polarity and prominence.
  """
  @spec slot(role(), polarity(), number()) :: slot()
  def slot(role, polarity, prominence)
      when is_number(prominence) and role in @chromatic_roles do
    base = Map.fetch!(@chromatic_base, role)
    chromatic_slot(polarity, tier(prominence), base)
  end

  def slot(role, polarity, prominence)
      when is_number(prominence) and role in @neutral_roles do
    {loud, soft} = @neutral_table[polarity][role]

    case tier(prominence) do
      :loud -> loud
      :soft -> soft
    end
  end

  @doc "The full role -> slot map for a given polarity and prominence."
  @spec table(polarity(), number()) :: %{role() => slot()}
  def table(polarity, prominence \\ 1.0) do
    Map.new(@roles, fn role -> {role, slot(role, polarity, prominence)} end)
  end

  @doc "The hue family a role belongs to."
  @spec category(role()) :: category()
  def category(:error), do: :red
  def category(:diff_del), do: :red
  def category(:success), do: :green
  def category(:diff_add), do: :green
  def category(:warning), do: :yellow
  def category(:accent), do: :blue
  def category(:running), do: :magenta
  def category(:foreground), do: :neutral
  def category(:chrome), do: :neutral
  def category(:emphasis), do: :neutral
  def category(:muted), do: :neutral
  def category(:border), do: :neutral

  @spec tier(number()) :: tier()
  defp tier(prominence) when prominence >= @loud_threshold, do: :loud
  defp tier(_prominence), do: :soft

  @spec chromatic_slot(polarity(), tier(), non_neg_integer()) :: slot()
  defp chromatic_slot(:dark, :loud, base), do: base + 8
  defp chromatic_slot(:dark, :soft, base), do: base
  defp chromatic_slot(:light, :loud, base), do: base
  defp chromatic_slot(:light, :soft, base), do: base + 8
end
