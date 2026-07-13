defmodule Raxol.Terminal.ANSI.SGRProcessor do
  @moduledoc """
  Processes SGR (Select Graphic Rendition) ANSI escape sequences.

  SGR sequences control text formatting attributes like colors, bold, italic, etc.
  This module handles parsing SGR parameters and updating terminal styles accordingly.
  """

  @doc """
  Handles SGR parameters and updates the style state.

  ## Parameters
    - params: String of SGR parameters (e.g., "31", "1;4;31;48;5;196")
    - style: Current style state (can be nil or a map)

  ## Returns
    Updated style map
  """
  @spec handle_sgr(String.t(), any()) :: map()
  def handle_sgr(params, style) when is_binary(params) do
    style = ensure_style_map(style)

    params
    |> parse_params()
    |> process_params(style)
  end

  @doc """
  Process SGR codes with parsed parameters.

  ## Parameters
    - codes: List of integer SGR codes
    - style: Current style map

  ## Returns
    Updated style map
  """
  @spec process_sgr_codes(list(integer()), map()) :: map()
  def process_sgr_codes(codes, style) do
    style = ensure_style_map(style)
    process_params(codes, style)
  end

  # Private functions

  defp ensure_style_map(nil), do: default_style()
  defp ensure_style_map(style) when is_map(style), do: style
  defp ensure_style_map(_), do: default_style()

  defp default_style do
    %{
      foreground: nil,
      background: nil,
      bold: false,
      italic: false,
      underline: false,
      blink: false,
      reverse: false,
      hidden: false,
      strikethrough: false,
      dim: false,
      faint: false,
      conceal: false,
      fraktur: false,
      double_underline: false,
      framed: false,
      encircled: false,
      overlined: false,
      # Extended attributes
      underline_color: nil,
      underline_style: :single,
      overline: false
    }
  end

  defp parse_params(""), do: [0]

  defp parse_params(params) do
    params
    |> String.split(";")
    |> Enum.map(&parse_segment/1)
    |> Enum.reject(&is_nil/1)
  end

  # A ";"-delimited segment containing ":" is a colon-subparameter group,
  # e.g. "4:3" -> {4, [3]} or "38:2::255:0:0" -> {38, [2, nil, 255, 0, 0]}.
  # The empty slot in "::" (ECMA-48 colorspace-id quirk) parses to nil.
  defp parse_segment(segment) do
    case String.contains?(segment, ":") do
      true ->
        case String.split(segment, ":") do
          [code_str | subparam_strs] ->
            case parse_int(code_str) do
              nil -> nil
              code -> {code, Enum.map(subparam_strs, &parse_int/1)}
            end
        end

      false ->
        parse_int(segment)
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp process_params([], style), do: style

  defp process_params([{code, subparams} | rest], style) do
    updated_style = apply_sgr_colon_code(code, subparams, style)
    process_params(rest, updated_style)
  end

  defp process_params([code | rest], style) do
    updated_style = apply_sgr_code(code, style, rest)
    {_consumed, remaining} = get_consumed_params(code, rest)
    process_params(remaining, updated_style)
  end

  # Styled underline (colon form only): 4:0 none, 4:1 single, 4:2 double,
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
      {:ok, color} -> Map.put(style, :foreground, color)
      :error -> style
    end
  end

  defp apply_sgr_colon_code(48, subparams, style) do
    case parse_colon_color(subparams) do
      {:ok, color} -> Map.put(style, :background, color)
      :error -> style
    end
  end

  defp apply_sgr_colon_code(58, subparams, style) do
    case parse_colon_color(subparams) do
      {:ok, color} -> Map.put(style, :underline_color, color)
      :error -> style
    end
  end

  defp apply_sgr_colon_code(_code, _subparams, style), do: style

  # 5;n (256-color)
  defp parse_colon_color([5, n]) when n >= 0 and n <= 255,
    do: {:ok, {:indexed, n}}

  # 2;colorspace;r;g;b (truecolor); colorspace slot may be empty (nil) or an
  # explicit id -- either way it's ignored here.
  defp parse_colon_color([2, _colorspace, r, g, b])
       when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and
              b <= 255,
       do: {:ok, {:rgb, r, g, b}}

  # 2;r;g;b (truecolor, no colorspace slot)
  defp parse_colon_color([2, r, g, b])
       when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and
              b <= 255,
       do: {:ok, {:rgb, r, g, b}}

  defp parse_colon_color(_), do: :error

  defp apply_sgr_code(0, _style, _rest), do: default_style()

  # Text attributes
  defp apply_sgr_code(1, style, _rest), do: Map.put(style, :bold, true)
  defp apply_sgr_code(2, style, _rest), do: %{style | dim: true, faint: true}
  defp apply_sgr_code(3, style, _rest), do: Map.put(style, :italic, true)
  defp apply_sgr_code(4, style, _rest), do: Map.put(style, :underline, true)
  defp apply_sgr_code(5, style, _rest), do: Map.put(style, :blink, true)
  # Rapid blink
  defp apply_sgr_code(6, style, _rest), do: Map.put(style, :blink, true)
  defp apply_sgr_code(7, style, _rest), do: Map.put(style, :reverse, true)

  defp apply_sgr_code(8, style, _rest),
    do: %{style | hidden: true, conceal: true}

  defp apply_sgr_code(9, style, _rest), do: Map.put(style, :strikethrough, true)

  # Extended text attributes
  defp apply_sgr_code(20, style, _rest), do: Map.put(style, :fraktur, true)

  defp apply_sgr_code(21, style, _rest),
    do: %{style | double_underline: true, underline: false}

  # Reset specific attributes
  defp apply_sgr_code(22, style, _rest),
    do: %{style | bold: false, dim: false, faint: false}

  defp apply_sgr_code(23, style, _rest),
    do: %{style | italic: false, fraktur: false}

  defp apply_sgr_code(24, style, _rest),
    do: %{style | underline: false, double_underline: false}

  defp apply_sgr_code(25, style, _rest), do: Map.put(style, :blink, false)
  defp apply_sgr_code(27, style, _rest), do: Map.put(style, :reverse, false)

  defp apply_sgr_code(28, style, _rest),
    do: %{style | hidden: false, conceal: false}

  defp apply_sgr_code(29, style, _rest),
    do: Map.put(style, :strikethrough, false)

  # Framed, encircled, overlined attributes
  defp apply_sgr_code(51, style, _rest), do: Map.put(style, :framed, true)
  defp apply_sgr_code(52, style, _rest), do: Map.put(style, :encircled, true)

  defp apply_sgr_code(53, style, _rest),
    do: %{style | overlined: true, overline: true}

  defp apply_sgr_code(54, style, _rest),
    do: %{style | framed: false, encircled: false}

  defp apply_sgr_code(55, style, _rest),
    do: %{style | overlined: false, overline: false}

  # Basic foreground colors (30-37)
  defp apply_sgr_code(code, style, _rest) when code >= 30 and code <= 37 do
    Map.put(style, :foreground, basic_color(code - 30))
  end

  # Extended foreground color (38)
  defp apply_sgr_code(38, style, [5, color | _rest])
       when color >= 0 and color <= 255 do
    Map.put(style, :foreground, {:indexed, color})
  end

  defp apply_sgr_code(38, style, [2, r, g, b | _rest])
       when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255 do
    Map.put(style, :foreground, {:rgb, r, g, b})
  end

  # Default foreground (39)
  defp apply_sgr_code(39, style, _rest), do: Map.put(style, :foreground, nil)

  # Basic background colors (40-47)
  defp apply_sgr_code(code, style, _rest) when code >= 40 and code <= 47 do
    Map.put(style, :background, basic_color(code - 40))
  end

  # Extended background color (48)
  defp apply_sgr_code(48, style, [5, color | _rest])
       when color >= 0 and color <= 255 do
    Map.put(style, :background, {:indexed, color})
  end

  defp apply_sgr_code(48, style, [2, r, g, b | _rest])
       when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255 do
    Map.put(style, :background, {:rgb, r, g, b})
  end

  # Default background (49)
  defp apply_sgr_code(49, style, _rest), do: Map.put(style, :background, nil)

  # Underline color (58)
  defp apply_sgr_code(58, style, [5, color | _rest])
       when color >= 0 and color <= 255 do
    Map.put(style, :underline_color, {:indexed, color})
  end

  defp apply_sgr_code(58, style, [2, r, g, b | _rest])
       when r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255 do
    Map.put(style, :underline_color, {:rgb, r, g, b})
  end

  # Default underline color (59)
  defp apply_sgr_code(59, style, _rest),
    do: Map.put(style, :underline_color, nil)

  # Bright foreground colors (90-97) - set base color and bold
  defp apply_sgr_code(code, style, _rest) when code >= 90 and code <= 97 do
    %{style | foreground: basic_color(code - 90), bold: true}
  end

  # Bright background colors (100-107) - just set base color, no bold
  defp apply_sgr_code(code, style, _rest) when code >= 100 and code <= 107 do
    Map.put(style, :background, basic_color(code - 100))
  end

  # Unhandled codes - return style unchanged
  defp apply_sgr_code(_code, style, _rest), do: style

  defp get_consumed_params(38, [5, _ | rest]), do: {2, rest}
  defp get_consumed_params(38, [2, _, _, _ | rest]), do: {4, rest}
  defp get_consumed_params(48, [5, _ | rest]), do: {2, rest}
  defp get_consumed_params(48, [2, _, _, _ | rest]), do: {4, rest}
  defp get_consumed_params(58, [5, _ | rest]), do: {2, rest}
  defp get_consumed_params(58, [2, _, _, _ | rest]), do: {4, rest}
  defp get_consumed_params(_, rest), do: {0, rest}

  defp basic_color(0), do: :black
  defp basic_color(1), do: :red
  defp basic_color(2), do: :green
  defp basic_color(3), do: :yellow
  defp basic_color(4), do: :blue
  defp basic_color(5), do: :magenta
  defp basic_color(6), do: :cyan
  defp basic_color(7), do: :white
  defp basic_color(_), do: nil
end
