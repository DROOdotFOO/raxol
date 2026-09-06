defmodule Raxol.Core.Renderer.View.Types do
  @moduledoc """
  Type definitions for the Raxol view system.
  """

  alias Raxol.Core.Renderer.Color

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type size :: {non_neg_integer(), non_neg_integer()}
  @type color :: Color.color()
  @type style :: [atom()]
  @type border_style :: :none | :single | :double | :rounded | :bold | :dashed
  @type layout_type :: :flex | :grid | :flow | :absolute
  @type position_type :: :relative | :absolute | :fixed
  @type z_index :: integer()

  @type view :: %{
          type: atom(),
          position: position() | nil,
          position_type: position_type(),
          z_index: z_index(),
          size: size() | nil,
          style: style(),
          fg: color() | nil,
          bg: color() | nil,
          border: border_style(),
          padding: padding(),
          margin: margin(),
          children: [view()],
          content: term()
        }

  @type padding ::
          non_neg_integer()
          | {non_neg_integer(), non_neg_integer()}
          | {non_neg_integer(), non_neg_integer(), non_neg_integer(),
             non_neg_integer()}
  @type margin :: padding()

  # Glyph sets come from `Raxol.UI.Theming.BorderChars`, resolved at compile
  # time. This was a nested map literal built inside `border_chars/0`, so
  # every call allocated five inner maps to hand back a constant.
  #
  # The key names this module exposed are preserved: `:bold` (whose glyphs
  # are the same six as `Raxol.Core.Box`'s `:heavy`) and `:dashed` mapped to
  # the finer `┄`/`┆` variant, which `BorderChars` keeps as `:dashed_fine`.
  @border_chars %{
    single: Raxol.UI.Theming.BorderChars.get(:single),
    double: Raxol.UI.Theming.BorderChars.get(:double),
    rounded: Raxol.UI.Theming.BorderChars.get(:rounded),
    bold: Raxol.UI.Theming.BorderChars.get(:heavy),
    dashed: Raxol.UI.Theming.BorderChars.get(:dashed_fine)
  }

  @doc """
  Returns the border characters for different border styles.
  """
  def border_chars, do: @border_chars
end
