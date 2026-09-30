defmodule Raxol.Terminal.ANSI.Behaviours do
  @moduledoc """
  Consolidated ANSI behaviours for terminal functionality.
  Consolidates: SixelGraphics.Behaviour, TerminalStateBehaviour, TextFormattingBehaviour.
  """

  defmodule SixelGraphics do
    @moduledoc """
    Behaviour for Sixel graphics support.
    """

    @type t :: map()

    @callback new() :: t()
    @callback new(pos_integer(), pos_integer()) :: t()
    @callback set_data(t(), binary()) :: t()
    @callback get_data(t()) :: binary()
    @callback set_palette(t(), map()) :: t()
    @callback get_palette(t()) :: map()
    @callback set_scale(t(), non_neg_integer(), non_neg_integer()) :: t()
    @callback get_scale(t()) :: {non_neg_integer(), non_neg_integer()}
    @callback set_position(t(), non_neg_integer(), non_neg_integer()) :: t()
    @callback get_position(t()) :: {non_neg_integer(), non_neg_integer()}
    @callback encode(t()) :: binary()
    @callback decode(binary()) :: t()
    @callback supported?() :: boolean()
    @callback process_sequence(t(), binary()) ::
                t() | {t(), :ok | {:error, term()}}
  end

  defmodule KittyGraphics do
    @moduledoc """
    Behaviour for Kitty graphics protocol support.

    The Kitty Graphics Protocol enables pixel-level graphics rendering
    with superior features to Sixel including native animation support,
    better compression, and more flexible placement.
    """

    @type t :: map()

    @type action :: :transmit | :display | :delete | :query
    @type format :: :rgb | :rgba | :png
    @type compression :: :none | :zlib

    @callback new() :: t()
    @callback new(pos_integer(), pos_integer()) :: t()
    @callback set_data(t(), binary()) :: t()
    @callback get_data(t()) :: binary()
    @callback encode(t()) :: binary()
    @callback decode(binary()) :: t()
    @callback supported?() :: boolean()
    @callback process_sequence(t(), binary()) ::
                {t(), :ok | {:error, term()}}

    # Kitty-specific callbacks
    @callback transmit_image(t(), map()) :: t()
    @callback place_image(t(), map()) :: t()
    @callback delete_image(t(), non_neg_integer()) :: t()
    @callback query_image(t(), non_neg_integer()) ::
                {:ok, map()} | {:error, term()}
    @callback add_animation_frame(t(), binary()) :: t()

    @optional_callbacks [
      transmit_image: 2,
      place_image: 2,
      delete_image: 2,
      query_image: 2,
      add_animation_frame: 2
    ]
  end

  defmodule TextFormatting do
    @moduledoc """
    Defines the behaviour for text formatting in the terminal.
    This includes handling text attributes, colors, and special text modes.
    """

    @type color ::
            :black
            | :red
            | :green
            | :yellow
            | :blue
            | :magenta
            | :cyan
            | :white
            | {:rgb, non_neg_integer(), non_neg_integer(), non_neg_integer()}
            | {:index, non_neg_integer()}
            | nil

    # text_style can be a struct or plain map with style attributes
    @type text_style :: map()

    @callback new() :: text_style()
    @callback set_foreground(text_style(), color()) :: text_style()
    @callback set_background(text_style(), color()) :: text_style()
    @callback get_foreground(text_style()) :: color()
    @callback get_background(text_style()) :: color()
    @callback set_double_width(text_style()) :: text_style()
    @callback set_double_height_top(text_style()) :: text_style()
    @callback set_double_height_bottom(text_style()) :: text_style()
    @callback reset_size(text_style()) :: text_style()
    @callback apply_attribute(text_style(), atom()) :: text_style()
    @callback set_bold(text_style()) :: text_style()
    @callback set_faint(text_style()) :: text_style()
    @callback set_italic(text_style()) :: text_style()
    @callback set_underline(text_style()) :: text_style()
    @callback set_blink(text_style()) :: text_style()
    @callback set_reverse(text_style()) :: text_style()
    @callback set_conceal(text_style()) :: text_style()
    @callback set_strikethrough(text_style()) :: text_style()
    @callback set_fraktur(text_style()) :: text_style()
    @callback set_double_underline(text_style()) :: text_style()
    @callback set_framed(text_style()) :: text_style()
    @callback set_encircled(text_style()) :: text_style()
    @callback set_overlined(text_style()) :: text_style()
    @callback set_hyperlink(text_style(), String.t() | nil) :: text_style()
    @callback reset_attributes(text_style()) :: text_style()
    @callback set_attributes(text_style(), list(atom())) :: text_style()
    @callback set_custom(text_style(), atom(), any()) :: text_style()
    @callback update_attrs(text_style(), map()) :: text_style()
    @callback validate(text_style()) ::
                {:ok, text_style()} | {:error, String.t()}
    @callback reset_bold(text_style()) :: text_style()
    @callback reset_italic(text_style()) :: text_style()
    @callback reset_underline(text_style()) :: text_style()
    @callback reset_blink(text_style()) :: text_style()
    @callback reset_reverse(text_style()) :: text_style()
    @callback reset_framed_encircled(text_style()) :: text_style()
    @callback reset_overlined(text_style()) :: text_style()
  end

  # Note: Use Raxol.Terminal.ANSI.TextFormatting directly for actual text formatting operations.
  # This module only defines the behaviour contracts.
end
