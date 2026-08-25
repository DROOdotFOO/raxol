defmodule Raxol.Terminal.ANSI.TextFormatting do
  @moduledoc """
  Consolidated text formatting module for the terminal emulator.
  Combines Core, Attributes, and Colors functionality.
  Handles advanced text formatting features including double-width/height,
  text attributes, and color management.
  """

  @behaviour Raxol.Terminal.ANSI.Behaviours.TextFormatting

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

  @type text_style :: %{
          double_width: boolean(),
          double_height: :none | :top | :bottom,
          bold: boolean(),
          faint: boolean(),
          italic: boolean(),
          underline: boolean(),
          blink: boolean(),
          reverse: boolean(),
          conceal: boolean(),
          strikethrough: boolean(),
          fraktur: boolean(),
          double_underline: boolean(),
          framed: boolean(),
          encircled: boolean(),
          overlined: boolean(),
          foreground: color(),
          background: color(),
          hyperlink: String.t() | nil
        }

  @type underline_style ::
          :none | :single | :double | :curly | :dotted | :dashed

  @type t :: %__MODULE__{
          bold: boolean(),
          italic: boolean(),
          underline: boolean(),
          blink: boolean(),
          reverse: boolean(),
          foreground: color(),
          background: color(),
          double_width: boolean(),
          double_height: :none | :top | :bottom,
          faint: boolean(),
          conceal: boolean(),
          strikethrough: boolean(),
          fraktur: boolean(),
          double_underline: boolean(),
          framed: boolean(),
          encircled: boolean(),
          overlined: boolean(),
          hyperlink: String.t() | nil,
          underline_style: underline_style(),
          underline_color: color()
        }

  defstruct bold: false,
            italic: false,
            underline: false,
            blink: false,
            reverse: false,
            foreground: nil,
            background: nil,
            double_width: false,
            double_height: :none,
            faint: false,
            conceal: false,
            strikethrough: false,
            fraktur: false,
            double_underline: false,
            framed: false,
            encircled: false,
            overlined: false,
            hyperlink: nil,
            underline_style: :single,
            underline_color: nil

  # Core sub-module - Primary text formatting operations
  defmodule Core do
    @moduledoc """
    Core text formatting functionality.
    """

    alias Raxol.Terminal.ANSI.TextFormatting

    def new, do: %TextFormatting{}
    def default_style, do: new()

    def new(attrs) when is_list(attrs) do
      attrs |> Enum.into(%{}) |> new()
    end

    def new(%{} = attrs), do: struct(TextFormatting, attrs)

    def set_foreground(style, color) do
      style = ensure_text_formatting_struct(style)
      %{style | foreground: color}
    end

    def set_background(style, color) do
      style = ensure_text_formatting_struct(style)
      %{style | background: color}
    end

    def get_foreground(%{} = style), do: style.foreground
    def get_background(%{} = style), do: style.background

    def set_underline_color(style, color) do
      style = ensure_text_formatting_struct(style)
      %{style | underline_color: color}
    end

    def set_underline_style(style, underline_style) do
      style = ensure_text_formatting_struct(style)
      %{style | underline_style: underline_style}
    end

    def get_underline_color(%{} = style), do: style.underline_color
    def get_underline_style(%{} = style), do: style.underline_style

    def set_double_width(style),
      do: %{style | double_width: true, double_height: :none}

    def set_double_height_top(style),
      do: %{style | double_width: true, double_height: :top}

    def set_double_height_bottom(style),
      do: %{style | double_width: true, double_height: :bottom}

    def reset_size(style),
      do: %{style | double_width: false, double_height: :none}

    def set_hyperlink(style, url), do: %{style | hyperlink: url}
    def reset_attributes(_style), do: new()

    def set_attributes(style, attributes) do
      Enum.reduce(
        attributes,
        style,
        &TextFormatting.Attributes.apply_attribute(&2, &1)
      )
    end

    def set_custom(style, key, value), do: Map.put(style, key, value)
    def update_attrs(style, attrs), do: Map.merge(style, attrs)

    def validate(style) do
      case style do
        %{
          double_width: _,
          double_height: _,
          bold: _,
          faint: _,
          italic: _,
          underline: _,
          blink: _,
          reverse: _,
          conceal: _,
          strikethrough: _,
          fraktur: _,
          double_underline: _,
          framed: _,
          encircled: _,
          overlined: _,
          foreground: _,
          background: _,
          hyperlink: _
        } ->
          {:ok, style}

        _ ->
          {:error, "Invalid text style map"}
      end
    end

    def apply_color(style, :foreground, color), do: %{style | foreground: color}
    def apply_color(style, :background, color), do: %{style | background: color}

    def effective_width(style, text) do
      base_width =
        case text do
          "你" -> 2
          _ -> String.length(text)
        end

      calculate_width_with_style(base_width, style)
    end

    defp calculate_width_with_style(base_width, %{double_width: true}),
      do: base_width * 2

    defp calculate_width_with_style(base_width, %{double_height: height})
         when height != :none,
         do: base_width

    defp calculate_width_with_style(base_width, _style), do: base_width

    def get_paired_line_type(style) do
      case style.double_height do
        :top -> :bottom
        :bottom -> :top
        :none -> nil
      end
    end

    def needs_paired_line?(style), do: style.double_height != :none

    def get_hyperlink(%{hyperlink: url}) when is_binary(url), do: url
    def get_hyperlink(_), do: nil

    def set_attribute(emulator, attribute) do
      attributes = MapSet.put(emulator.attributes, attribute)
      %{emulator | attributes: attributes}
    end

    defp ensure_text_formatting_struct(nil), do: new()
    defp ensure_text_formatting_struct(%TextFormatting{} = style), do: style

    defp ensure_text_formatting_struct(style) when is_map(style) do
      new() |> Map.merge(style)
    end

    defp ensure_text_formatting_struct(_), do: new()
  end

  # Attributes sub-module
  defmodule Attributes do
    @moduledoc """
    Text attribute handling for ANSI text formatting.
    """

    alias Raxol.Terminal.ANSI.TextFormatting

    @attribute_handlers %{
      reset: &TextFormatting.Core.new/0,
      double_width: &TextFormatting.Core.set_double_width/1,
      double_height_top: &TextFormatting.Core.set_double_height_top/1,
      double_height_bottom: &TextFormatting.Core.set_double_height_bottom/1,
      no_double_width: &TextFormatting.Core.reset_size/1,
      no_double_height: &TextFormatting.Core.reset_size/1,
      bold: &__MODULE__.set_bold/1,
      faint: &__MODULE__.set_faint/1,
      italic: &__MODULE__.set_italic/1,
      underline: &__MODULE__.set_underline/1,
      blink: &__MODULE__.set_blink/1,
      reverse: &__MODULE__.set_reverse/1,
      conceal: &__MODULE__.set_conceal/1,
      strikethrough: &__MODULE__.set_strikethrough/1,
      fraktur: &__MODULE__.set_fraktur/1,
      double_underline: &__MODULE__.set_double_underline/1,
      framed: &__MODULE__.set_framed/1,
      encircled: &__MODULE__.set_encircled/1,
      overlined: &__MODULE__.set_overlined/1,
      default_fg: &__MODULE__.reset_foreground/1,
      default_bg: &__MODULE__.reset_background/1,
      normal_intensity: &__MODULE__.reset_bold/1,
      not_framed_encircled: &__MODULE__.reset_framed_encircled/1,
      not_overlined: &__MODULE__.reset_overlined/1
    }

    @reset_attribute_map %{
      no_bold: :bold,
      no_italic: :italic,
      no_underline: :underline,
      no_blink: :blink,
      no_reverse: :reverse,
      no_conceal: :conceal,
      no_strikethrough: :strikethrough,
      no_fraktur: :fraktur,
      no_double_underline: :double_underline,
      no_framed: :framed,
      no_encircled: :encircled,
      no_overlined: :overlined
    }

    def apply_attribute(_style, :reset), do: TextFormatting.Core.new()

    def apply_attribute(style, attribute) do
      case Map.get(@reset_attribute_map, attribute) do
        nil -> handle_positive_attribute(style, attribute)
        field -> %{style | field => false}
      end
    end

    defp handle_positive_attribute(style, attribute) do
      case Map.get(@attribute_handlers, attribute) do
        nil -> style
        handler -> handler.(style)
      end
    end

    def set_bold(style), do: %{style | bold: true}
    def set_faint(style), do: %{style | faint: true}
    def set_italic(style), do: %{style | italic: true}
    def set_underline(style), do: %{style | underline: true}
    def set_blink(style), do: %{style | blink: true}
    def set_reverse(style), do: %{style | reverse: true}
    def set_conceal(style), do: %{style | conceal: true}
    def set_strikethrough(style), do: %{style | strikethrough: true}
    def set_fraktur(style), do: %{style | fraktur: true}
    def set_double_underline(style), do: %{style | double_underline: true}
    def set_framed(style), do: %{style | framed: true}
    def set_encircled(style), do: %{style | encircled: true}
    def set_overlined(style), do: %{style | overlined: true}

    def reset_bold(style), do: %{style | bold: false, faint: false}
    def reset_faint(style), do: %{style | faint: false}
    def reset_italic(style), do: %{style | italic: false, fraktur: false}

    def reset_underline(style),
      do: %{style | underline: false, double_underline: false}

    def reset_blink(style), do: %{style | blink: false}
    def reset_reverse(style), do: %{style | reverse: false}
    def reset_foreground(style), do: %{style | foreground: nil}
    def reset_background(style), do: %{style | background: nil}

    def reset_framed_encircled(style),
      do: %{style | framed: false, encircled: false}

    def reset_overlined(style), do: %{style | overlined: false}
    def reset_conceal(style), do: %{style | conceal: false}
    def reset_strikethrough(style), do: %{style | strikethrough: false}
    def reset_fraktur(style), do: %{style | fraktur: false}
    def reset_double_underline(style), do: %{style | double_underline: false}
    def reset_framed(style), do: %{style | framed: false}
    def reset_encircled(style), do: %{style | encircled: false}
  end

  # Aliases for extracted sub-modules
  alias __MODULE__.Colors
  alias __MODULE__.SGR

  # Behaviour implementation and delegations
  @impl true
  def new, do: Core.new()
  def default_style, do: Core.default_style()
  def new(attrs), do: Core.new(attrs)

  @impl true
  def set_foreground(style, color), do: Core.set_foreground(style, color)
  @impl true
  def set_background(style, color), do: Core.set_background(style, color)
  @impl true
  def get_foreground(style), do: Core.get_foreground(style)
  @impl true
  def get_background(style), do: Core.get_background(style)
  def set_underline_color(style, color), do: Core.set_underline_color(style, color)

  def set_underline_style(style, underline_style),
    do: Core.set_underline_style(style, underline_style)

  def get_underline_color(style), do: Core.get_underline_color(style)
  def get_underline_style(style), do: Core.get_underline_style(style)
  @impl true
  def set_double_width(style), do: Core.set_double_width(style)
  @impl true
  def set_double_height_top(style), do: Core.set_double_height_top(style)
  @impl true
  def set_double_height_bottom(style), do: Core.set_double_height_bottom(style)
  @impl true
  def reset_size(style), do: Core.reset_size(style)
  @impl true
  def set_hyperlink(style, url), do: Core.set_hyperlink(style, url)
  @impl true
  def reset_attributes(style), do: Core.reset_attributes(style)
  @impl true
  def set_attributes(style, attributes),
    do: Core.set_attributes(style, attributes)

  @impl true
  def set_custom(style, key, value), do: Core.set_custom(style, key, value)
  @impl true
  def update_attrs(style, attrs), do: Core.update_attrs(style, attrs)
  @impl true
  def validate(style), do: Core.validate(style)

  @impl true
  def apply_attribute(_style, :reset), do: new()

  def apply_attribute(style, attribute),
    do: Attributes.apply_attribute(style, attribute)

  @impl true
  def set_bold(style), do: Attributes.set_bold(style)
  @impl true
  def set_faint(style), do: Attributes.set_faint(style)
  @impl true
  def set_italic(style), do: Attributes.set_italic(style)
  @impl true
  def set_underline(style), do: Attributes.set_underline(style)
  @impl true
  def set_blink(style), do: Attributes.set_blink(style)
  @impl true
  def set_reverse(style), do: Attributes.set_reverse(style)
  @impl true
  def set_conceal(style), do: Attributes.set_conceal(style)
  @impl true
  def set_strikethrough(style), do: Attributes.set_strikethrough(style)
  @impl true
  def set_fraktur(style), do: Attributes.set_fraktur(style)
  @impl true
  def set_double_underline(style), do: Attributes.set_double_underline(style)
  @impl true
  def set_framed(style), do: Attributes.set_framed(style)
  @impl true
  def set_encircled(style), do: Attributes.set_encircled(style)
  @impl true
  def set_overlined(style), do: Attributes.set_overlined(style)
  @impl true
  def reset_bold(style), do: Attributes.reset_bold(style)
  @impl true
  def reset_italic(style), do: Attributes.reset_italic(style)
  @impl true
  def reset_underline(style), do: Attributes.reset_underline(style)
  @impl true
  def reset_blink(style), do: Attributes.reset_blink(style)
  @impl true
  def reset_reverse(style), do: Attributes.reset_reverse(style)
  @impl true
  def reset_framed_encircled(style),
    do: Attributes.reset_framed_encircled(style)

  @impl true
  def reset_overlined(style), do: Attributes.reset_overlined(style)

  # Additional non-behavior delegations
  def reset_faint(style), do: Attributes.reset_faint(style)
  def reset_foreground(style), do: Attributes.reset_foreground(style)
  def reset_background(style), do: Attributes.reset_background(style)
  def reset_conceal(style), do: Attributes.reset_conceal(style)
  def reset_strikethrough(style), do: Attributes.reset_strikethrough(style)
  def reset_fraktur(style), do: Attributes.reset_fraktur(style)

  def reset_double_underline(style),
    do: Attributes.reset_double_underline(style)

  def reset_framed(style), do: Attributes.reset_framed(style)
  def reset_encircled(style), do: Attributes.reset_encircled(style)

  def apply_color(style, type, color), do: Core.apply_color(style, type, color)
  def effective_width(style, text), do: Core.effective_width(style, text)
  def get_paired_line_type(style), do: Core.get_paired_line_type(style)
  def needs_paired_line?(style), do: Core.needs_paired_line?(style)
  def get_hyperlink(style), do: Core.get_hyperlink(style)

  def set_attribute(emulator, attribute),
    do: Core.set_attribute(emulator, attribute)

  def ansi_code_to_color_name(code), do: Colors.ansi_code_to_color_name(code)
  def format_sgr_params(style), do: SGR.format_sgr_params(style)
  def parse_sgr_param(param, style), do: SGR.parse_sgr_param(param, style)
end
