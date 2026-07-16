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
  role's category. (`:running` is reserved for activity state -- no RGB
  seed exists in the harness yet, which is why measured naive-collapse
  counts say "11 fields" while `roles/0` returns 12.)

  ## Legibility floor

  Every slot assignment meets a WCAG-style 3:1 contrast ratio against its
  polarity's canonical ground, measured on the module's reference palette
  (`Raxol.UI.Theming.Colors.ansi_to_rgb/1`), with one small, named
  exemption set on light polarity only:

    * Green/yellow state roles on light ground: no green or yellow slot in
      the reference palette is legible on light ground (best available:
      normal green 1.98:1, normal yellow 1.56:1). The best-effort normal
      slots (2 and 3) are pinned anyway, because swapping hue family would
      be a category lie worse than low contrast for a state signal, and
      gray would erase the signal entirely. Real light-mode terminal
      themes darken these slots; the pin keeps the category-true handle
      for them to interpret.
    * Muted/border recede chrome on light ground: silver is a subtle
      light-UI border by design; receding below the floor is these roles'
      function.

  Dark polarity has NO exemptions: every dark-canvas assignment meets the
  floor outright. The ranked priority throughout the table is explicit:
  legibility > category preservation > tier separation.

  ## Polarity-awareness

  ANSI16 offers a normal-intensity slot (1-7) and a bright-intensity slot
  (9-15) per hue. Which one reads as "the loud one" depends on the canvas:
  bright variants pop on a dark background, normal variants pop on a light
  background. `polarity/1` derives the canvas from ground OKLCH lightness
  using the same threshold as `Raxol.UI.Theming.Salience`'s `:auto`
  polarity resolution (`ground < 0.5` is dark). Because a 16-color path is
  a fallback, `polarity/1` must not crash when the OSC 11 background probe
  has no reading: `nil` falls back to the reference ground's polarity;
  other non-numbers still raise.

  ## Tier degradation

  The shipped prominence ladder has four tiers (1.0 / 0.8 / 0.6 / 0.4),
  but 16-color can express at most two distinguishable steps per hue. The
  ladder folds pairwise at `loud_threshold/0` (0.8): prominence `>= 0.8`
  resolves to the loud tier, everything below resolves to the soft tier.

  Which roles keep distinct 1.0 vs 0.6 slots is per polarity. On dark, all
  roles stay distinct except `:muted` and `:border`, which already sit at
  the dimmest legible slot (the recede floor -- intentional fold). On
  light, the reference palette leaves single legible slots for several
  families, so the fold list grows: `:muted`, `:border`, `:warning`,
  `:success`, `:diff_add`, `:running`, `:foreground`, and `:chrome` all
  trade tier separation for the legibility floor.

  ## Accepted losses

  This is a lossy degradation and it accepts specific losses in exchange
  for never lying about hue and never dropping below legibility where the
  palette allows:

    * Sub-hue detail is dropped -- an orange warning and a yellow warning
      both land on the yellow slot.
    * `:diff_add` folds onto `:success`'s green family and `:diff_del`
      folds onto `:error`'s red family; these are in-family folds, not
      category lies.
    * `:accent` renders on the cyan slots on a dark canvas: the palette's
      normal blue (slot 4, #0000EE) is illegible on black -- the classic
      blue-on-black problem -- and the bright blue slot alone cannot
      express two tiers. Cyan is the adjacent cool slot and no other role
      occupies it; the role's category stays `:blue`.
    * `:emphasis` trades its warm (yellow-adjacent) seed hue for the
      max-contrast neutral slot at its loudest tier, so it can never be
      mistaken for the `:warning` state signal -- the yellow slot is
      reserved for warning. `:emphasis` keeps its anchor function (it is
      still the loudest role in the ramp) without competing for a hue.
    * The neutral ramp merges. On dark at the soft tier, `:foreground`,
      `:chrome`, `:muted`, and `:border` all share slot 8 -- receded body
      text merges into recede chrome, because slot 8 is the only legible
      sub-body neutral on dark. On light the whole mid-ramp compresses
      onto slot 8: the palette has exactly two legible neutrals on light
      ground (black and dark gray), so foreground and chrome fold onto
      dark gray at both tiers.
    * `:running` is reserved for activity/in-progress state and given its
      own hue family (magenta), separate from the alarm/success/warning
      triad.

  ## Scope

  This table is the only supported 16-color path for semantic role colors.
  `Raxol.UI.Theming.Colors.find_closest_basic_color/1` (nearest-RGB) must
  not be used for semantic roles -- see its `@doc` for the pointer back
  here. Truecolor and 256-color rendering are unaffected; this module is
  additive. Note the table is not yet consumed by the render path (wiring
  the capability gate is a follow-up); until then
  `find_closest_basic_color/1` remains the live -- lossy -- 16-color
  fallback.

  ## Unknown roles

  `roles/0` is the closed, compile-time set of roles this table knows
  about. `slot/2`, `slot/3`, and `category/1` intentionally have no
  fallback clause for atoms outside that set -- they raise
  `FunctionClauseError` rather than silently guessing a slot.
  """

  alias Raxol.UI.Theming.Salience

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

  # Explicit per-polarity per-tier slot pins. The design is no longer one
  # intensity-flip formula: legibility against the canonical ground
  # (measured on Colors.ansi_to_rgb/1) overrides the flip wherever the
  # palette leaves a family without two -- or any -- legible slots.
  #
  # Dark canvas: bright-loud / normal-soft for every family it works for;
  # accent moves to the cyan slots (normal blue is 1.93:1 on black).
  #
  # Light canvas: the flip holds only where the bright variant stays
  # legible (red, blue); warning/success/diff_add/running fold both tiers
  # onto their single best slot; the neutral mid-ramp compresses onto
  # dark gray (slot 8).
  @slot_table %{
    dark: %{
      loud: %{
        error: 9,
        diff_del: 9,
        success: 10,
        diff_add: 10,
        warning: 11,
        accent: 14,
        running: 13,
        emphasis: 15,
        foreground: 7,
        chrome: 7,
        muted: 8,
        border: 8
      },
      soft: %{
        error: 1,
        diff_del: 1,
        success: 2,
        diff_add: 2,
        warning: 3,
        accent: 6,
        running: 5,
        emphasis: 7,
        foreground: 8,
        chrome: 8,
        muted: 8,
        border: 8
      }
    },
    light: %{
      loud: %{
        error: 1,
        diff_del: 1,
        success: 2,
        diff_add: 2,
        warning: 3,
        accent: 4,
        running: 5,
        emphasis: 0,
        foreground: 8,
        chrome: 8,
        muted: 7,
        border: 7
      },
      soft: %{
        error: 9,
        diff_del: 9,
        success: 2,
        diff_add: 2,
        warning: 3,
        accent: 12,
        running: 5,
        emphasis: 8,
        foreground: 8,
        chrome: 8,
        muted: 7,
        border: 7
      }
    }
  }

  @roles Map.keys(@slot_table.dark.loud)

  @doc "The semantic salience roles this table covers."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Derives canvas polarity from ground OKLCH lightness.

  Mirrors `Raxol.UI.Theming.Salience`'s `:auto` polarity threshold: a
  ground lightness below `0.5` is a dark canvas, `0.5` and above is light.

  A 16-color path is a fallback and must not crash when ground detection
  (the OSC 11 background probe) has no reading: `nil` falls back to the
  reference ground's polarity. Other non-numbers raise
  `FunctionClauseError` -- fail-loud on garbage, graceful on the
  documented unknown.
  """
  @spec polarity(number() | nil) :: polarity()
  def polarity(nil), do: polarity(Salience.reference_ground())

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
      when is_number(prominence) and role in @roles do
    @slot_table
    |> Map.fetch!(polarity)
    |> Map.fetch!(tier(prominence))
    |> Map.fetch!(role)
  end

  @doc "The full role -> slot map for a given polarity and prominence."
  @spec table(polarity(), number()) :: %{role() => slot()}
  def table(polarity, prominence \\ 1.0) when is_number(prominence) do
    @slot_table |> Map.fetch!(polarity) |> Map.fetch!(tier(prominence))
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
end
