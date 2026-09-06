defmodule Raxol.UI.Theming.BorderChars do
  @moduledoc """
  Single canonical source for box-drawing glyph sets.

  Sibling to `Raxol.UI.Theming.Palette`, which is deliberately restricted to
  color *values*; these are characters, not colors.

  ## Why this module exists

  The same glyph sets were written out in three places:

    * `Raxol.Core.Box` (`lib/raxol/core/box_compat.ex`) -- `single`, `double`,
      `rounded`, `heavy`, `dashed`
    * `Raxol.Core.Renderer.View.ViewTypes.border_chars/0` -- `single`,
      `double`, `rounded`, `bold`, `dashed`, rebuilt on every call
    * `Raxol.UI.BorderRenderer.get_border_chars/1` -- `single`, `double`,
      `rounded`, `ascii`, `none`, as function clauses

  `single`, `double` and `rounded` were byte-identical in all three. `heavy`
  and `bold` are the same six glyphs under two names. Only `dashed` genuinely
  disagreed, so both variants are kept under distinct names rather than one
  being silently chosen:

    * `:dashed` -- `╌` / `╎` (double dash), the `Raxol.Core.Box` form
    * `:dashed_fine` -- `┄` / `┆` (triple dash), the `ViewTypes` form

  Each caller derives its own accepted style set from this table and keeps
  the key names it already accepted, so no caller's behaviour changes. That
  is why `:bold` and `:heavy` both resolve here instead of one being renamed.
  """

  @typedoc "The six glyphs that define a rectangular border."
  @type chars :: %{
          top_left: String.t(),
          top_right: String.t(),
          bottom_left: String.t(),
          bottom_right: String.t(),
          horizontal: String.t(),
          vertical: String.t()
        }

  @typedoc "Canonical glyph-set names. `:bold` is an alias of `:heavy`."
  @type style ::
          :single
          | :double
          | :rounded
          | :heavy
          | :bold
          | :dashed
          | :dashed_fine
          | :ascii
          | :none

  @single %{
    top_left: "┌",
    top_right: "┐",
    bottom_left: "└",
    bottom_right: "┘",
    horizontal: "─",
    vertical: "│"
  }

  @double %{
    top_left: "╔",
    top_right: "╗",
    bottom_left: "╚",
    bottom_right: "╝",
    horizontal: "═",
    vertical: "║"
  }

  @rounded %{
    top_left: "╭",
    top_right: "╮",
    bottom_left: "╰",
    bottom_right: "╯",
    horizontal: "─",
    vertical: "│"
  }

  @heavy %{
    top_left: "┏",
    top_right: "┓",
    bottom_left: "┗",
    bottom_right: "┛",
    horizontal: "━",
    vertical: "┃"
  }

  # `Raxol.Core.Box`'s dashed: double-dash horizontals and verticals.
  @dashed %{
    top_left: "┌",
    top_right: "┐",
    bottom_left: "└",
    bottom_right: "┘",
    horizontal: "╌",
    vertical: "╎"
  }

  # `ViewTypes`' dashed: triple-dash. A finer texture at the same weight.
  @dashed_fine %{
    top_left: "┌",
    top_right: "┐",
    bottom_left: "└",
    bottom_right: "┘",
    horizontal: "┄",
    vertical: "┆"
  }

  # For terminals with no box-drawing support, and the explicit no-border
  # case. Both are `BorderRenderer`-only today.
  @ascii %{
    top_left: "+",
    top_right: "+",
    bottom_left: "+",
    bottom_right: "+",
    horizontal: "-",
    vertical: "|"
  }

  @none %{
    top_left: " ",
    top_right: " ",
    bottom_left: " ",
    bottom_right: " ",
    horizontal: " ",
    vertical: " "
  }

  @all %{
    single: @single,
    double: @double,
    rounded: @rounded,
    heavy: @heavy,
    bold: @heavy,
    dashed: @dashed,
    dashed_fine: @dashed_fine,
    ascii: @ascii,
    none: @none
  }

  @doc """
  Every glyph set, keyed by style name. `:bold` and `:heavy` map to the same
  value.
  """
  @spec all() :: %{style() => chars()}
  def all, do: @all

  @doc """
  The glyph set for `style`, or `nil` when the style is unknown.

  Callers decide their own fallback: `Raxol.Core.Box` falls back to `:single`,
  `Raxol.UI.BorderRenderer` to `:none`.
  """
  @spec get(style() | atom()) :: chars() | nil
  def get(style), do: Map.get(@all, style)

  @doc """
  The glyph sets for `styles` only, keyed by the names given.

  Lets a caller expose exactly the style names it already accepted, so
  collapsing onto this module changes no caller's public surface.

      iex> Raxol.UI.Theming.BorderChars.subset([:single, :double]) |> Map.keys()
      [:double, :single]
  """
  @spec subset([style()]) :: %{style() => chars()}
  def subset(styles), do: Map.new(styles, &{&1, Map.fetch!(@all, &1)})
end
