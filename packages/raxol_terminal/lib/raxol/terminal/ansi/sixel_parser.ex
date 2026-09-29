defmodule Raxol.Terminal.ANSI.SixelParser do
  @moduledoc """
  Handles the parsing logic for Sixel graphics data streams within a DCS sequence.

  Sixel data is untrusted and compressed: a repeat (`!Pn`) or a run of rows
  asks for pixels in proportion to a number, not to the bytes sent. So the
  decoder keeps only pixels inside the parse's extent (`max_width` by
  `max_height`, at most `Raxol.Core.Defaults.image_size_ceiling/0`; the
  emulator passes the screen area right and below the cursor, which is all
  of an image it can draw), draws at most `pixels_left` pixels in one parse,
  and never lets the kept pixel buffer grow past the ceiling's pixel count.
  Numeric parameters are bounded as control sequence parameters are
  (`Raxol.Terminal.Parser.ParserState`): at most 30, each clamped to 65535.
  """
  require Logger

  alias Raxol.Core.Defaults
  alias Raxol.Terminal.ANSI.SixelPalette
  alias Raxol.Terminal.ANSI.Utils.SixelPatternMap

  @image_ceiling Defaults.image_size_ceiling()
  @max_pixels @image_ceiling.pixels
  @max_params 30
  @max_param_value 65_535
  @max_param_digits 5

  defmodule ParserState do
    @moduledoc """
    Represents the state during the parsing of a Sixel graphics data stream.
    Tracks position, color, palette, and pixel buffer information, and the
    bounds of what one parse may draw (see `Raxol.Terminal.ANSI.SixelParser`).
    """

    @image_ceiling Raxol.Core.Defaults.image_size_ceiling()

    @type t :: %__MODULE__{
            x: integer(),
            y: integer(),
            color_index: integer(),
            repeat_count: integer(),
            palette: map(),
            raster_attrs: map(),
            pixel_buffer: map(),
            max_x: integer(),
            max_y: integer(),
            max_width: non_neg_integer(),
            max_height: non_neg_integer(),
            pixels_left: non_neg_integer(),
            terminator_found: boolean()
          }

    defstruct [
      :x,
      :y,
      :color_index,
      :repeat_count,
      :palette,
      :raster_attrs,
      :pixel_buffer,
      :max_x,
      :max_y,
      max_width: @image_ceiling.width,
      max_height: @image_ceiling.height,
      pixels_left: @image_ceiling.pixels,
      terminator_found: false
    ]
  end

  @spec parse(binary(), ParserState.t()) ::
          {:ok, ParserState.t()} | {:error, atom()}
  def parse(data, state) when is_binary(data) do
    palette_size = map_size(state.palette)
    Logger.debug("SixelParser: palette has #{palette_size} colors")

    case data do
      <<>> ->
        {:ok, state}

      <<"\eP", rest::binary>> ->
        handle_dcs_start(rest, state)

      <<"\e\\", _rest::binary>> ->
        {:ok, state}

      <<" ", rest::binary>> ->
        parse(rest, state)

      _ ->
        handle_command(data, state)
    end
  end

  defp handle_dcs_start(rest, state) do
    case rest do
      <<"q", rest::binary>> -> parse(rest, state)
      _ -> {:error, :missing_or_misplaced_q}
    end
  end

  defp handle_command(data, state) do
    case data do
      <<"\"", rest::binary>> ->
        handle_raster_attributes(rest, state)

      <<"#", rest::binary>> ->
        handle_color_definition(rest, state)

      <<"!", rest::binary>> ->
        handle_repeat_command(rest, state)

      <<"$", rest::binary>> ->
        handle_carriage_return(rest, state)

      <<"-", rest::binary>> ->
        handle_new_line(rest, state)

      <<char_byte, remaining_data::binary>> ->
        handle_data_character(char_byte, remaining_data, state)
    end
  end

  defp handle_raster_attributes(rest, state) do
    {:ok, params, remaining_data} = consume_integer_params(rest)
    parse(remaining_data, %{state | raster_attrs: create_raster_attrs(params)})
  end

  defp create_raster_attrs([pan, pad, ph, pv]),
    do: %{
      aspect_num: pan || 1,
      aspect_den: pad || 1,
      width: ph,
      height: pv
    }

  defp create_raster_attrs(params),
    do: %{
      aspect_num: Enum.at(params, 0) || 1,
      aspect_den: Enum.at(params, 1) || 1,
      width: Enum.at(params, 2),
      height: Enum.at(params, 3)
    }

  defp handle_color_definition(rest, state) do
    case consume_integer_params(rest) do
      {:ok, [pc | color_params], remaining_data} ->
        case color_params do
          [] -> handle_color_selection([pc], remaining_data, state)
          _ -> handle_color_params(pc, color_params, remaining_data, state)
        end

      {:ok, params, remaining_data} ->
        handle_color_selection(params, remaining_data, state)
    end
  end

  defp handle_color_params(pc, color_params, remaining_data, state) do
    case pc >= 0 and pc <= SixelPalette.max_colors() do
      true ->
        color_space = Enum.at(color_params, 0) || 1
        px = Enum.at(color_params, 1) || 0
        py = Enum.at(color_params, 2) || 0
        pz = Enum.at(color_params, 3) || 0

        case SixelPalette.convert_color(color_space, px, py, pz) do
          {:ok, {r, g, b}} ->
            new_palette = Map.put(state.palette, pc, {r, g, b})

            parse(remaining_data, %{
              state
              | palette: new_palette,
                color_index: pc
            })

          {:error, reason} ->
            Logger.warning(
              "Sixel Parser: Invalid color definition ##{inspect(pc)}: #{inspect(reason)}. Skipping."
            )

            parse(remaining_data, state)
        end

      false ->
        Logger.warning("Sixel Parser: Invalid color index ##{inspect(pc)}. Skipping.")

        parse(remaining_data, state)
    end
  end

  defp handle_color_selection(params, remaining_data, state) do
    max_colors = SixelPalette.max_colors()

    case params do
      [pc] when pc >= 0 and pc <= max_colors ->
        parse(remaining_data, %{state | color_index: pc})

      [] ->
        parse(remaining_data, %{state | color_index: 0})

      _ ->
        Logger.warning(
          "Sixel Parser: Unexpected params for Color Definition: #{inspect(params)}. Skipping."
        )

        parse(remaining_data, state)
    end
  end

  # A repeat takes its first parameter; a second one used to match no clause
  # and crash the parse.
  defp handle_repeat_command(rest, state) do
    case consume_integer_params(rest) do
      {:ok, [pn | _], remaining_data} when pn > 0 ->
        parse(remaining_data, %{state | repeat_count: pn})

      {:ok, [pn | _], remaining_data} ->
        Logger.warning(
          "Sixel Parser: Invalid repeat count found (!#{inspect(pn)}). Skipping repeat command."
        )

        parse(remaining_data, state)

      {:ok, [], remaining_data} ->
        parse(remaining_data, state)
    end
  end

  defp handle_carriage_return(rest, state) do
    new_y = state.y + 6

    parse(rest, %{
      state
      | x: 0,
        y: new_y,
        max_y: max(state.max_y, new_y + 5)
    })
  end

  defp handle_new_line(rest, state) do
    new_y = state.y + 6

    parse(rest, %{
      state
      | x: 0,
        y: new_y,
        max_y: max(state.max_y, new_y + 5)
    })
  end

  defp handle_data_character(char_byte, remaining_data, state) do
    Logger.debug("SixelParser: processing data character")

    case SixelPatternMap.get_pattern(char_byte) do
      pattern_int when is_integer(pattern_int) ->
        parse(remaining_data, draw_sixel(state, pattern_int))

      nil ->
        Logger.debug("SixelParser: ignored unknown data character")
        skip_unknown_character(remaining_data, state)
    end
  end

  # An unknown byte is skipped as long as the data is terminated. Once a
  # terminator is known to lie ahead it stays ahead until the parse reaches
  # it, so only the first unknown byte searches for it: searching the rest
  # for every one was quadratic in the payload.
  defp skip_unknown_character(remaining_data, %ParserState{terminator_found: true} = state),
    do: parse(remaining_data, state)

  defp skip_unknown_character(remaining_data, state) do
    case :binary.match(remaining_data, "\e\\") do
      :nomatch -> {:error, :missing_st}
      _found -> parse(remaining_data, %{state | terminator_found: true})
    end
  end

  # Draws one sixel `repeat_count` columns wide. Only the rows and columns
  # inside the extent are drawn, and no more pixels than this parse has left;
  # past them the position still advances, at no cost.
  defp draw_sixel(state, pattern) do
    %ParserState{x: x, y: y, repeat_count: repeat} = state

    rows =
      for bit <- 0..5,
          Bitwise.band(pattern, Bitwise.bsl(1, bit)) != 0,
          y + bit < state.max_height,
          do: y + bit

    columns =
      case rows do
        [] -> 0
        _ -> min(max(min(repeat, state.max_width - x), 0), div(state.pixels_left, length(rows)))
      end

    %{
      state
      | x: x + repeat,
        repeat_count: 1,
        pixel_buffer: draw_columns(state.pixel_buffer, x, columns, rows, state.color_index),
        pixels_left: state.pixels_left - columns * length(rows),
        max_x: max(state.max_x, x + repeat - 1),
        max_y: max(state.max_y, y + 5)
    }
  end

  defp draw_columns(buffer, _x, 0, _rows, _color), do: buffer

  defp draw_columns(buffer, x, columns, rows, color) do
    for column <- x..(x + columns - 1)//1, row <- rows, reduce: buffer do
      acc -> put_pixel(acc, {column, row}, color)
    end
  end

  # The pixel buffer outlives a parse (the emulator keeps it between images),
  # so it is capped as a whole: once full, only pixels it already holds change.
  defp put_pixel(buffer, key, color) when map_size(buffer) < @max_pixels,
    do: Map.put(buffer, key, color)

  defp put_pixel(buffer, key, color) when is_map_key(buffer, key),
    do: %{buffer | key => color}

  defp put_pixel(buffer, _key, _color), do: buffer

  @doc """
  Reads the numeric parameters (`Pn;Pn;...`) at the start of `input_binary`.

  The whole run of digits and semicolons is consumed. An empty parameter
  reads as 0; at most #{@max_params} are returned, each clamped to
  #{@max_param_value}.
  """
  @spec consume_integer_params(binary()) :: {:ok, [non_neg_integer()], binary()}
  def consume_integer_params(input_binary) do
    section_length = param_section_length(input_binary, 0)
    <<section::binary-size(^section_length), rest::binary>> = input_binary

    params =
      case section do
        "" ->
          []

        _ ->
          section
          |> String.split(";", parts: @max_params + 1)
          |> Enum.take(@max_params)
          |> Enum.map(&clamp_param/1)
      end

    {:ok, params, rest}
  end

  defp param_section_length(binary, offset) do
    case binary do
      <<_::binary-size(^offset), byte, _::binary>> when byte in ?0..?9 or byte == ?; ->
        param_section_length(binary, offset + 1)

      _ ->
        offset
    end
  end

  defp clamp_param(digits) do
    case String.trim_leading(digits, "0") do
      "" -> 0
      significant when byte_size(significant) > @max_param_digits -> @max_param_value
      significant -> min(String.to_integer(significant), @max_param_value)
    end
  end
end
