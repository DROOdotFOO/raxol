defmodule Raxol.UI.ColorIntent do
  @moduledoc """
  A color *intent* — `(hue, chroma, prominence)`, not a literal color — that
  rides the same `fg:`/`bg:` slots literal colors occupy in a style map or a
  cell tuple. Resolved to bytes exactly once, at the render choke point
  (`Raxol.UI.ColorResolver`), against the ground that is actually known at
  that point (terminal background, capability tier, region/focus state).

  See `docs/core/RENDERING.md`'s "Region prominence" section for the
  resolution model. This module is the struct only — no resolution
  logic lives here; that stays in `Raxol.UI.ColorResolver` so this module has
  no dependency on `Raxol.UI.Theming.Salience`'s solver internals.

  ## Fields

    * `:h` - hue in degrees (`0..360`), or `nil` for an achromatic intent.
    * `:c` - chroma (`0.0` = neutral / no color, i.e. achromatic).
    * `:tier` - a `Raxol.UI.Theming.Salience.tier/0` (`:alarm`, `:recede`,
      `:differentiate`, `:baseline`, `:anchor`), or `nil`.
    * `:prominence` - an explicit scalar `0.0..1.0` (component-own `p`), or
      `nil`.
    * `:role` - a semantic role atom for ANSI-16 slot pinning (e.g.
      `:error`, `:accent`), consumed by `Raxol.UI.Theming.Ansi16Salience`.
      Not consulted by the truecolor resolution path.
    * `:floor` - the legibility floor class: `:none` (pure fade, the
      default), `:ui` (`Raxol.UI.Harness.Prominence.floor_ratio/0`, `3.0`),
      `:text` (WCAG AA normal text, `4.5`), or `{:ratio, float()}`
      for an explicit override.

  `tier` and `prominence` are two entries to the same axis — a component
  states *either* ("I am `:recede` chrome") *or* ("I am this row at 0.6").
  When `tier` is set, `prominence` (if also set) is the component's own `p`
  on the fade line from that tier's full-strength target. When `tier` is
  unset, `prominence` fades from the **baseline**-tier target. A bare
  `%ColorIntent{}` therefore resolves as a baseline-tier neutral at full
  prominence.

  ## The `{:fixed, color}` escape hatch

  `{:fixed, color}` is not a struct — it is a plain 2-tuple wrapper
  convention recognized directly by `Raxol.UI.ColorResolver`. It exempts
  `color` (a literal) from ALL resolution and region fading: the resolver
  unwraps it to the literal, byte-identical, unconditionally. This is the "I
  really mean these exact bytes" hatch (e.g. syntax-highlight themes under
  screenshot goldens). It composes with nothing — a fixed color glares
  through region dims and modal fades by design; that is what "fixed" means.

      # a literal, participates in region fading (once regions land)
      fg: "#c1712c"

      # the same literal, exempt from all fading forever
      fg: {:fixed, "#c1712c"}

  ## Backward compatibility

  Literal colors (hex strings, `{r, g, b}` tuples, ANSI atoms, 256-palette
  integers) remain valid in every slot a `ColorIntent` can occupy — the cell
  tuple already carries heterogeneous terms, so intents ride the existing
  slots with no shape change. `Raxol.UI.ColorResolver` passes literals
  through unchanged: an app that never triggers an attr-less fg/bg default,
  never focuses a region, and never opens an overlay renders
  byte-identically to no-resolver, by construction.
  """

  alias Raxol.UI.Theming.Salience

  @type floor_class :: :none | :ui | :text | {:ratio, float()}

  @type t :: %__MODULE__{
          h: (0..360 | float()) | nil,
          c: float(),
          tier: Salience.tier() | nil,
          prominence: float() | nil,
          role: atom() | nil,
          floor: floor_class()
        }

  defstruct h: nil,
            c: 0.0,
            tier: nil,
            prominence: nil,
            role: nil,
            floor: :none

  @doc """
  Wraps `color` in the `{:fixed, color}` escape-hatch convention -- exempts
  it from all resolution/fading in `Raxol.UI.ColorResolver`. See moduledoc.
  """
  @spec fixed(term()) :: {:fixed, term()}
  def fixed(color), do: {:fixed, color}

  @doc "True if `term` is the `{:fixed, _}` escape-hatch wrapper."
  @spec fixed?(term()) :: boolean()
  def fixed?({:fixed, _color}), do: true
  def fixed?(_term), do: false
end
