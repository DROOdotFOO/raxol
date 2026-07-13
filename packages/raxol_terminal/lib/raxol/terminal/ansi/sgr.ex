defmodule Raxol.Terminal.ANSI.SGR do
  @moduledoc """
  Consolidated SGR (Select Graphic Rendition) handling for ANSI escape sequences.
  Combines: SGR formatting, SGRHandler, and SGRProcessor functionality.
  """

  alias Raxol.Terminal.ANSI.TextFormatting

  defmodule Formatter do
    @moduledoc """
    SGR parameter formatting for the Raxol Terminal ANSI TextFormatting module.
    Handles SGR parameter parsing, formatting, and attribute handling.
    """

    alias Raxol.Terminal.ANSI.TextFormatting.{Colors, Core}

    @sgr_style_map %{
      bold: 1,
      italic: 3,
      underline: 4,
      blink: 5,
      reverse: 7,
      conceal: 8,
      strikethrough: 9
    }

    @doc """
    Formats a style into SGR (Select Graphic Rendition) parameters.
    Returns a string of ANSI SGR codes.
    """
    @spec format_sgr_params(TextFormatting.text_style()) :: String.t()
    def format_sgr_params(style) do
      style_codes = build_style_codes(style)
      fg_codes = Colors.build_foreground_codes(style.foreground)
      bg_codes = Colors.build_background_codes(style.background)

      (style_codes ++ fg_codes ++ bg_codes)
      |> Enum.join(";")
    end

    @doc """
    Parses an SGR parameter and applies it to the given style.
    """
    @spec parse_sgr_param(integer(), TextFormatting.text_style()) ::
            TextFormatting.text_style()
    def parse_sgr_param(param, style) when is_integer(param) do
      case param do
        0 ->
          Core.reset_attributes(style)

        1 ->
          %{style | bold: true}

        2 ->
          %{style | faint: true}

        3 ->
          %{style | italic: true}

        4 ->
          %{style | underline: true}

        5 ->
          %{style | blink: true}

        6 ->
          %{style | blink: true}

        7 ->
          %{style | reverse: true}

        8 ->
          %{style | conceal: true}

        9 ->
          %{style | strikethrough: true}

        20 ->
          %{style | fraktur: true}

        21 ->
          %{style | double_underline: true}

        22 ->
          %{style | bold: false, faint: false}

        23 ->
          %{style | italic: false, fraktur: false}

        24 ->
          %{style | underline: false, double_underline: false}

        25 ->
          %{style | blink: false}

        27 ->
          %{style | reverse: false}

        28 ->
          %{style | conceal: false}

        29 ->
          %{style | strikethrough: false}

        51 ->
          %{style | framed: true}

        52 ->
          %{style | encircled: true}

        53 ->
          %{style | overlined: true}

        54 ->
          %{style | framed: false, encircled: false}

        55 ->
          %{style | overlined: false}

        # Foreground colors
        n when n >= 30 and n <= 37 ->
          %{style | foreground: color_from_sgr(n - 30)}

        # Background colors
        n when n >= 40 and n <= 47 ->
          %{style | background: color_from_sgr(n - 40)}

        # Bright foreground colors
        n when n >= 90 and n <= 97 ->
          %{style | foreground: bright_color_from_sgr(n - 90)}

        # Bright background colors
        n when n >= 100 and n <= 107 ->
          %{style | background: bright_color_from_sgr(n - 100)}

        # Default foreground/background
        39 ->
          %{style | foreground: nil}

        49 ->
          %{style | background: nil}

        _ ->
          style
      end
    end

    defp build_style_codes(style) do
      @sgr_style_map
      |> Enum.filter(fn {attr, _code} -> Map.get(style, attr, false) end)
      |> Enum.map(fn {_attr, code} -> code end)
    end

    defp color_from_sgr(n) do
      case n do
        0 -> :black
        1 -> :red
        2 -> :green
        3 -> :yellow
        4 -> :blue
        5 -> :magenta
        6 -> :cyan
        7 -> :white
        _ -> nil
      end
    end

    defp bright_color_from_sgr(n) do
      case n do
        0 -> :bright_black
        1 -> :bright_red
        2 -> :bright_green
        3 -> :bright_yellow
        4 -> :bright_blue
        5 -> :bright_magenta
        6 -> :bright_cyan
        7 -> :bright_white
        _ -> nil
      end
    end
  end

  defmodule Handler do
    @moduledoc """
    Handles parsing of SGR (Select Graphic Rendition) ANSI escape sequences.
    Translates SGR codes into updates on a TextFormatting style map.
    """

    alias Raxol.Terminal.ANSI.TextFormatting

    @text_style_map %{
      20 => :fraktur,
      21 => :double_underline,
      22 => :normal_intensity,
      23 => :no_italic_fraktur,
      24 => :no_underline,
      25 => :no_blink,
      27 => :no_reverse,
      28 => :reveal,
      29 => :no_strikethrough
    }

    @fg_color_map %{
      30 => :black,
      31 => :red,
      32 => :green,
      33 => :yellow,
      34 => :blue,
      35 => :magenta,
      36 => :cyan,
      37 => :white,
      38 => :default_fg,
      39 => :default_fg,
      90 => :bright_black,
      91 => :bright_red,
      92 => :bright_green,
      93 => :bright_yellow,
      94 => :bright_blue,
      95 => :bright_magenta,
      96 => :bright_cyan,
      97 => :bright_white
    }

    @bg_color_map %{
      40 => :black,
      41 => :red,
      42 => :green,
      43 => :yellow,
      44 => :blue,
      45 => :magenta,
      46 => :cyan,
      47 => :white,
      48 => :default_bg,
      49 => :default_bg,
      100 => :bright_black,
      101 => :bright_red,
      102 => :bright_green,
      103 => :bright_yellow,
      104 => :bright_blue,
      105 => :bright_magenta,
      106 => :bright_cyan,
      107 => :bright_white
    }

    @doc """
    Handles an SGR sequence by parsing parameters and applying style changes.
    """
    @spec handle_sgr(binary(), TextFormatting.t()) :: TextFormatting.t()
    def handle_sgr(params, style) do
      parse_params(params)
      |> Enum.reduce(style || TextFormatting.new(), &apply_sgr_code/2)
    end

    @doc """
    Applies a single SGR code to the style.
    """
    @spec apply_sgr_code(integer(), TextFormatting.t()) :: TextFormatting.t()
    def apply_sgr_code(code, style) do
      cond do
        # Reset all attributes
        code == 0 ->
          TextFormatting.reset_attributes(style)

        # Basic text attributes (1-9)
        code == 1 ->
          TextFormatting.set_bold(style)

        code == 2 ->
          TextFormatting.set_faint(style)

        code == 3 ->
          TextFormatting.set_italic(style)

        code == 4 ->
          TextFormatting.set_underline(style)

        code == 5 ->
          TextFormatting.set_blink(style)

        code == 7 ->
          TextFormatting.set_reverse(style)

        code == 8 ->
          TextFormatting.set_conceal(style)

        code == 9 ->
          TextFormatting.set_strikethrough(style)

        # Extended text attributes
        Map.has_key?(@text_style_map, code) ->
          apply_text_style(style, @text_style_map[code])

        # Foreground colors
        Map.has_key?(@fg_color_map, code) ->
          TextFormatting.set_foreground(style, @fg_color_map[code])

        # Background colors
        Map.has_key?(@bg_color_map, code) ->
          TextFormatting.set_background(style, @bg_color_map[code])

        # Default case
        true ->
          style
      end
    end

    defp parse_params(params) when is_binary(params) do
      params
      |> String.split(";", trim: true)
      |> Enum.map(&parse_single_param/1)
      |> Enum.filter(& &1)
    end

    defp parse_single_param(param) do
      case Integer.parse(param) do
        {value, _} -> value
        :error -> nil
      end
    end

    defp apply_text_style(style, attribute) do
      case attribute do
        :fraktur -> TextFormatting.set_fraktur(style)
        :double_underline -> TextFormatting.set_double_underline(style)
        :normal_intensity -> %{style | bold: false, faint: false}
        :no_italic_fraktur -> %{style | italic: false, fraktur: false}
        :no_underline -> TextFormatting.reset_underline(style)
        :no_blink -> TextFormatting.reset_blink(style)
        :no_reverse -> TextFormatting.reset_reverse(style)
        :reveal -> %{style | conceal: false}
        :no_strikethrough -> %{style | strikethrough: false}
        _ -> style
      end
    end

    @doc """
    Processes extended color sequences (256 color or RGB).
    """
    @spec handle_extended_color(
            list(integer()),
            TextFormatting.t(),
            :foreground | :background
          ) :: TextFormatting.t()
    def handle_extended_color([5 | rest], style, type) do
      # 256-color mode
      case rest do
        [n] when n >= 0 and n <= 255 ->
          color = {:index, n}

          case type do
            :foreground -> TextFormatting.set_foreground(style, color)
            :background -> TextFormatting.set_background(style, color)
          end

        _ ->
          style
      end
    end

    def handle_extended_color([2 | rest], style, type) do
      # RGB color mode
      case rest do
        [r, g, b]
        when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255 ->
          color = {:rgb, r, g, b}

          case type do
            :foreground -> TextFormatting.set_foreground(style, color)
            :background -> TextFormatting.set_background(style, color)
          end

        _ ->
          style
      end
    end

    def handle_extended_color(_, style, _type), do: style
  end

  defmodule Processor do
    @moduledoc """
    Optimized SGR (Select Graphic Rendition) processor for ANSI escape sequences.
    Uses compile-time optimizations and pattern matching for maximum performance.
    """

    alias Raxol.Terminal.ANSI.TextFormatting

    @doc """
    Processes SGR parameters and applies them to the current style.
    """
    @spec handle_sgr(binary(), TextFormatting.t()) :: TextFormatting.t()
    def handle_sgr(params, style) do
      params
      |> parse_sgr_string()
      |> process_params(style)
    end

    @doc """
    Processes already-parsed SGR parameters, as produced by
    `Raxol.Terminal.Commands.CommandsParser.parse_params/1`: a list mixing
    plain integer codes with colon-subparameter groups (nested lists, e.g.
    `[4, 3]` for the raw sequence `4:3`) and `nil` placeholders for empty
    segments/slots.
    """
    @spec process_params(list(), TextFormatting.t()) :: TextFormatting.t()
    def process_params(params, style) do
      style = style || TextFormatting.new()

      params
      |> Enum.reject(&is_nil/1)
      |> process_codes(style)
    end

    # Parses a raw SGR parameter string, honoring colon subparameters, e.g.
    # "1;4:3;58:2::255:0:0" -> [1, [4, 3], [58, 2, nil, 255, 0, 0]]
    defp parse_sgr_string(params) do
      params
      |> String.split(";")
      |> Enum.map(&parse_param_segment/1)
    end

    defp parse_param_segment(segment) do
      case String.contains?(segment, ":") do
        true -> segment |> String.split(":") |> Enum.map(&parse_int_or_nil/1)
        false -> parse_int_or_nil(segment)
      end
    end

    defp parse_int_or_nil(str) do
      case Integer.parse(str) do
        {int, _} -> int
        :error -> nil
      end
    end

    defp process_codes([], style), do: style

    # Colon-subparameter group, e.g. "4:3" -> [4, 3] or
    # "58:2::255:0:0" -> [58, 2, nil, 255, 0, 0]
    defp process_codes([[code | subparams] | rest], style)
         when is_integer(code) do
      new_style = apply_sgr_colon_code(code, subparams, style)
      process_codes(rest, new_style)
    end

    defp process_codes([code | rest], style) do
      new_style = apply_sgr_code(code, style, rest)

      # Handle extended sequences that consume additional parameters
      remaining =
        case code do
          38 when length(rest) >= 2 ->
            Enum.drop(rest, extended_color_params_count(rest))

          48 when length(rest) >= 2 ->
            Enum.drop(rest, extended_color_params_count(rest))

          58 when length(rest) >= 2 ->
            Enum.drop(rest, extended_color_params_count(rest))

          _ ->
            rest
        end

      process_codes(remaining, new_style)
    end

    # 5;n format
    defp extended_color_params_count([5 | _rest]), do: 2
    # 2;r;g;b format
    defp extended_color_params_count([2 | _rest]), do: 4
    defp extended_color_params_count(_), do: 0

    # Underline style (colon form only): 4:0 none, 4:1 single, 4:2 double,
    # 4:3 curly, 4:4 dotted, 4:5 dashed
    defp apply_sgr_colon_code(4, [0 | _], style) do
      %{style | underline: false, double_underline: false, underline_style: :none}
    end

    defp apply_sgr_colon_code(4, [1 | _], style) do
      %{style | underline: true, double_underline: false, underline_style: :single}
    end

    defp apply_sgr_colon_code(4, [2 | _], style) do
      %{style | underline: true, double_underline: true, underline_style: :double}
    end

    defp apply_sgr_colon_code(4, [3 | _], style) do
      %{style | underline: true, double_underline: false, underline_style: :curly}
    end

    defp apply_sgr_colon_code(4, [4 | _], style) do
      %{style | underline: true, double_underline: false, underline_style: :dotted}
    end

    defp apply_sgr_colon_code(4, [5 | _], style) do
      %{style | underline: true, double_underline: false, underline_style: :dashed}
    end

    defp apply_sgr_colon_code(38, subparams, style) do
      case parse_colon_color(subparams) do
        {:ok, color} -> TextFormatting.set_foreground(style, color)
        :error -> style
      end
    end

    defp apply_sgr_colon_code(48, subparams, style) do
      case parse_colon_color(subparams) do
        {:ok, color} -> TextFormatting.set_background(style, color)
        :error -> style
      end
    end

    defp apply_sgr_colon_code(58, subparams, style) do
      case parse_colon_color(subparams) do
        {:ok, color} -> TextFormatting.set_underline_color(style, color)
        :error -> style
      end
    end

    defp apply_sgr_colon_code(_code, _subparams, style), do: style

    # 5;n (256-color)
    defp parse_colon_color([5, n])
         when is_integer(n) and n >= 0 and n <= 255,
         do: {:ok, {:index, n}}

    # 2;colorspace;r;g;b (truecolor); colorspace slot may be empty (nil, the
    # ECMA-48 "::" quirk) or an explicit id -- either way it's ignored here.
    defp parse_colon_color([2, _colorspace, r, g, b])
         when is_integer(r) and is_integer(g) and is_integer(b) and
                r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and
                b <= 255,
         do: {:ok, {:rgb, r, g, b}}

    # 2;r;g;b (truecolor, no colorspace slot)
    defp parse_colon_color([2, r, g, b])
         when is_integer(r) and is_integer(g) and is_integer(b) and
                r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and
                b <= 255,
         do: {:ok, {:rgb, r, g, b}}

    defp parse_colon_color(_), do: :error

    # Generate optimized pattern matching for SGR codes
    for code <- 0..107 do
      case code do
        0 ->
          defp apply_sgr_code(0, _style, _rest), do: TextFormatting.new()

        1 ->
          defp apply_sgr_code(1, style, _rest),
            do: TextFormatting.set_bold(style)

        2 ->
          defp apply_sgr_code(2, style, _rest),
            do: TextFormatting.set_faint(style)

        3 ->
          defp apply_sgr_code(3, style, _rest),
            do: TextFormatting.set_italic(style)

        4 ->
          defp apply_sgr_code(4, style, _rest),
            do: TextFormatting.set_underline(style)

        5 ->
          defp apply_sgr_code(5, style, _rest),
            do: TextFormatting.set_blink(style)

        6 ->
          defp apply_sgr_code(6, style, _rest),
            do: TextFormatting.set_blink(style)

        7 ->
          defp apply_sgr_code(7, style, _rest),
            do: TextFormatting.set_reverse(style)

        8 ->
          defp apply_sgr_code(8, style, _rest),
            do: TextFormatting.set_conceal(style)

        9 ->
          defp apply_sgr_code(9, style, _rest),
            do: TextFormatting.set_strikethrough(style)

        # Extended attributes
        20 ->
          defp apply_sgr_code(20, style, _rest),
            do: TextFormatting.set_fraktur(style)

        21 ->
          defp apply_sgr_code(21, style, _rest),
            do: TextFormatting.set_double_underline(style)

        # Reset attributes
        22 ->
          defp apply_sgr_code(22, style, _rest),
            do: TextFormatting.reset_bold(style)

        23 ->
          defp apply_sgr_code(23, style, _rest),
            do: TextFormatting.reset_italic(style)

        24 ->
          defp apply_sgr_code(24, style, _rest),
            do: TextFormatting.reset_underline(style)

        25 ->
          defp apply_sgr_code(25, style, _rest),
            do: TextFormatting.reset_blink(style)

        27 ->
          defp apply_sgr_code(27, style, _rest),
            do: TextFormatting.reset_reverse(style)

        28 ->
          defp apply_sgr_code(28, style, _rest),
            do: TextFormatting.reset_conceal(style)

        29 ->
          defp apply_sgr_code(29, style, _rest),
            do: TextFormatting.reset_strikethrough(style)

        # Standard foreground colors (30-37)
        30 ->
          defp apply_sgr_code(30, style, _rest),
            do: TextFormatting.set_foreground(style, :black)

        31 ->
          defp apply_sgr_code(31, style, _rest),
            do: TextFormatting.set_foreground(style, :red)

        32 ->
          defp apply_sgr_code(32, style, _rest),
            do: TextFormatting.set_foreground(style, :green)

        33 ->
          defp apply_sgr_code(33, style, _rest),
            do: TextFormatting.set_foreground(style, :yellow)

        34 ->
          defp apply_sgr_code(34, style, _rest),
            do: TextFormatting.set_foreground(style, :blue)

        35 ->
          defp apply_sgr_code(35, style, _rest),
            do: TextFormatting.set_foreground(style, :magenta)

        36 ->
          defp apply_sgr_code(36, style, _rest),
            do: TextFormatting.set_foreground(style, :cyan)

        37 ->
          defp apply_sgr_code(37, style, _rest),
            do: TextFormatting.set_foreground(style, :white)

        # Extended foreground color
        38 ->
          defp apply_sgr_code(38, style, rest) do
            handle_extended_foreground(rest, style)
          end

        # Default foreground
        39 ->
          defp apply_sgr_code(39, style, _rest) do
            TextFormatting.set_foreground(style, nil)
          end

        # Standard background colors (40-47)
        40 ->
          defp apply_sgr_code(40, style, _rest),
            do: TextFormatting.set_background(style, :black)

        41 ->
          defp apply_sgr_code(41, style, _rest),
            do: TextFormatting.set_background(style, :red)

        42 ->
          defp apply_sgr_code(42, style, _rest),
            do: TextFormatting.set_background(style, :green)

        43 ->
          defp apply_sgr_code(43, style, _rest),
            do: TextFormatting.set_background(style, :yellow)

        44 ->
          defp apply_sgr_code(44, style, _rest),
            do: TextFormatting.set_background(style, :blue)

        45 ->
          defp apply_sgr_code(45, style, _rest),
            do: TextFormatting.set_background(style, :magenta)

        46 ->
          defp apply_sgr_code(46, style, _rest),
            do: TextFormatting.set_background(style, :cyan)

        47 ->
          defp apply_sgr_code(47, style, _rest),
            do: TextFormatting.set_background(style, :white)

        # Extended background color
        48 ->
          defp apply_sgr_code(48, style, rest) do
            handle_extended_background(rest, style)
          end

        # Default background
        49 ->
          defp apply_sgr_code(49, style, _rest) do
            TextFormatting.set_background(style, nil)
          end

        # Framed, encircled, overlined attributes
        51 ->
          defp apply_sgr_code(51, style, _rest),
            do: TextFormatting.set_framed(style)

        52 ->
          defp apply_sgr_code(52, style, _rest),
            do: TextFormatting.set_encircled(style)

        53 ->
          defp apply_sgr_code(53, style, _rest),
            do: TextFormatting.set_overlined(style)

        54 ->
          defp apply_sgr_code(54, style, _rest),
            do: TextFormatting.reset_framed_encircled(style)

        55 ->
          defp apply_sgr_code(55, style, _rest),
            do: TextFormatting.reset_overlined(style)

        # Bright foreground colors (90-97)
        90 ->
          defp apply_sgr_code(90, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_black)

        91 ->
          defp apply_sgr_code(91, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_red)

        92 ->
          defp apply_sgr_code(92, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_green)

        93 ->
          defp apply_sgr_code(93, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_yellow)

        94 ->
          defp apply_sgr_code(94, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_blue)

        95 ->
          defp apply_sgr_code(95, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_magenta)

        96 ->
          defp apply_sgr_code(96, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_cyan)

        97 ->
          defp apply_sgr_code(97, style, _rest),
            do: TextFormatting.set_foreground(style, :bright_white)

        # Bright background colors (100-107)
        100 ->
          defp apply_sgr_code(100, style, _rest),
            do: TextFormatting.set_background(style, :bright_black)

        101 ->
          defp apply_sgr_code(101, style, _rest),
            do: TextFormatting.set_background(style, :bright_red)

        102 ->
          defp apply_sgr_code(102, style, _rest),
            do: TextFormatting.set_background(style, :bright_green)

        103 ->
          defp apply_sgr_code(103, style, _rest),
            do: TextFormatting.set_background(style, :bright_yellow)

        104 ->
          defp apply_sgr_code(104, style, _rest),
            do: TextFormatting.set_background(style, :bright_blue)

        105 ->
          defp apply_sgr_code(105, style, _rest),
            do: TextFormatting.set_background(style, :bright_magenta)

        106 ->
          defp apply_sgr_code(106, style, _rest),
            do: TextFormatting.set_background(style, :bright_cyan)

        107 ->
          defp apply_sgr_code(107, style, _rest),
            do: TextFormatting.set_background(style, :bright_white)

        _ ->
          # Unhandled codes
          nil
      end
    end

    # Underline color (58): 256-color and truecolor semicolon forms
    defp apply_sgr_code(58, style, [5, n | _rest])
         when is_integer(n) and n >= 0 and n <= 255 do
      TextFormatting.set_underline_color(style, {:index, n})
    end

    defp apply_sgr_code(58, style, [2, r, g, b | _rest])
         when is_integer(r) and is_integer(g) and is_integer(b) and
                r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and
                b <= 255 do
      TextFormatting.set_underline_color(style, {:rgb, r, g, b})
    end

    defp apply_sgr_code(58, style, _rest), do: style

    # Default underline color (59)
    defp apply_sgr_code(59, style, _rest) do
      TextFormatting.set_underline_color(style, nil)
    end

    # Catch-all for unhandled codes
    defp apply_sgr_code(_, style, _rest), do: style

    defp handle_extended_foreground([5, index | _], style)
         when index >= 0 and index <= 255 do
      TextFormatting.set_foreground(style, {:index, index})
    end

    defp handle_extended_foreground([2, r, g, b | _], style)
         when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and
                b <= 255 do
      TextFormatting.set_foreground(style, {:rgb, r, g, b})
    end

    defp handle_extended_foreground(_, style), do: style

    defp handle_extended_background([5, index | _], style)
         when index >= 0 and index <= 255 do
      TextFormatting.set_background(style, {:index, index})
    end

    defp handle_extended_background([2, r, g, b | _], style)
         when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and
                b <= 255 do
      TextFormatting.set_background(style, {:rgb, r, g, b})
    end

    defp handle_extended_background(_, style), do: style
  end

  # Main module convenience functions - delegate to appropriate sub-module
  defdelegate format_sgr_params(style), to: Formatter
  defdelegate parse_sgr_param(param, style), to: Formatter
  defdelegate handle_sgr(params, style), to: Processor
  defdelegate apply_sgr_code(code, style), to: Handler
end
