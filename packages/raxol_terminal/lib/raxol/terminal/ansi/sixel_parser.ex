defmodule Raxol.Terminal.ANSI.SixelParser do
  @moduledoc """
  Handles the parsing logic for Sixel graphics data streams within a DCS sequence.
  """
  require Logger

  alias Raxol.Terminal.ANSI.SixelPalette
  alias Raxol.Terminal.ANSI.Utils.SixelPatternMap

  defmodule ParserState do
    @moduledoc """
    Represents the state during the parsing of a Sixel graphics data stream.
    Tracks position, color, palette, and pixel buffer information.
    """

    @type t :: %__MODULE__{
            x: integer(),
            y: integer(),
            color_index: integer(),
            repeat_count: integer(),
            palette: map(),
            raster_attrs: map(),
            pixel_buffer: map(),
            max_x: integer(),
            max_y: integer()
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
      :max_y
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
    case consume_integer_params(rest) do
      {:ok, params, remaining_data} ->
        new_attrs = create_raster_attrs(params)
        parse(remaining_data, %{state | raster_attrs: new_attrs})

      {:error, reason, _} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Sixel Parser: Error parsing Raster Attributes: #{inspect(reason)}. Skipping.",
          %{}
        )

        parse(rest, state)
    end
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

      {:error, reason, _} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Sixel Parser: Error parsing Color Definition: #{inspect(reason)}. Skipping.",
          %{}
        )

        parse(rest, state)
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
            Raxol.Core.Runtime.Log.warning_with_context(
              "Sixel Parser: Invalid color definition (payload redacted): #{inspect(reason)}. Skipping.",
              %{}
            )

            parse(remaining_data, state)
        end

      false ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Sixel Parser: Invalid color index (payload redacted). Skipping.",
          %{}
        )

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
        Raxol.Core.Runtime.Log.warning_with_context(
          "Sixel Parser: Unexpected color definition params (payload redacted). Skipping.",
          %{}
        )

        parse(remaining_data, state)
    end
  end

  defp handle_repeat_command(rest, state) do
    case consume_integer_params(rest) do
      {:ok, [pn], remaining_data} when pn > 0 ->
        parse(remaining_data, %{state | repeat_count: pn})

      {:ok, [_pn], remaining_data} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Sixel Parser: Invalid repeat count (payload redacted). Skipping repeat command.",
          %{}
        )

        parse(remaining_data, state)

      {:ok, [], remaining_data} ->
        parse(remaining_data, state)

      {:error, reason, _} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Sixel Parser: Error parsing Repeat Command: #{inspect(reason)}. Skipping.",
          %{}
        )

        parse(rest, state)
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
        {final_buffer, final_x, final_max_x} =
          generate_repeated_pixels(
            pattern_int,
            state.x,
            state.y,
            state.color_index,
            state.repeat_count,
            state.pixel_buffer,
            state.max_x
          )

        Logger.debug("SixelParser: Generated pixels, buffer size: #{map_size(final_buffer)}")

        parse(remaining_data, %{
          state
          | x: final_x,
            repeat_count: 1,
            pixel_buffer: final_buffer,
            max_x: final_max_x,
            max_y: max(state.max_y, state.y + 5)
        })

      nil ->
        Logger.debug("SixelParser: ignored unknown data character")

        case remaining_data do
          <<"\e\\", _::binary>> ->
            parse(remaining_data, state)

          _ ->
            case String.contains?(remaining_data, "\e\\") do
              true -> parse(remaining_data, state)
              false -> {:error, :missing_st}
            end
        end
    end
  end

  defp generate_pixels_for_pattern(pattern_int, x, y, color) do
    pixels =
      Enum.reduce(0..5, %{}, fn bit_index, acc ->
        set? = Bitwise.band(pattern_int, Bitwise.bsl(1, bit_index)) != 0

        case set? do
          true -> Map.put(acc, {x, y + bit_index}, color)
          false -> acc
        end
      end)

    {pixels, x, y + 5}
  end

  defp generate_repeated_pixels(
         pattern_int,
         start_x,
         y,
         color,
         repeat,
         buffer,
         max_x
       ) do
    Enum.reduce(0..(repeat - 1), {buffer, start_x, max_x}, fn _i,
                                                              {current_buffer, current_x,
                                                               current_max_x} ->
      {pixels, _, _} =
        generate_pixels_for_pattern(pattern_int, current_x, y, color)

      merged_buffer = Map.merge(current_buffer, pixels)
      {merged_buffer, current_x + 1, max(current_max_x, current_x)}
    end)
  end

  def consume_integer_params(input_binary) do
    case Regex.run(~r/^([0-9;]*)(.*)/s, input_binary) do
      [_full_match, param_section, rest_of_binary] when param_section != "" ->
        case Raxol.Core.ErrorHandling.safe_call(fn ->
               params =
                 param_section
                 |> String.split(";", trim: false)
                 |> Enum.map(fn
                   "" -> 0
                   str -> String.to_integer(str)
                 end)

               {:ok, params, rest_of_binary}
             end) do
          {:ok, result} ->
            result

          {:error, reason} ->
            {:error, {"Invalid integer parameter in '#{param_section}'", reason}, input_binary}
        end

      [_full_match, "", rest_of_binary] ->
        {:ok, [], rest_of_binary}

      nil ->
        {:ok, [], input_binary}
    end
  end
end
