defmodule Raxol.Terminal.ANSI.SixelRenderer do
  @moduledoc """
  Handles rendering Sixel graphics data from a pixel buffer.
  """

  import Bitwise

  @doc """
  Renders the image stored in the pixel_buffer as a Sixel data stream.
  """
  @spec render_image(%{pixel_buffer: map(), palette: map(), attributes: map()}) ::
          {:ok, binary()}
  def render_image(state) do
    %{pixel_buffer: pixel_buffer, palette: palette, attributes: attrs} = state

    case map_size(pixel_buffer) do
      0 ->
        {:ok, ""}

      _ ->
        {width, height, used_colors} = calculate_dimensions(pixel_buffer)
        {pan, pad, ph, pv} = get_raster_attributes(attrs, width, height)
        dcs_start = create_dcs_start(pan, pad, ph, pv)
        color_definitions = create_color_definitions(palette, used_colors)

        sixel_pixel_data =
          generate_pixel_data(pixel_buffer, width, height, used_colors)

        dcs_end = "\e\\"

        {:ok,
         IO.iodata_to_binary([
           dcs_start,
           color_definitions,
           sixel_pixel_data,
           dcs_end
         ])}
    end
  end

  defp calculate_dimensions(pixel_buffer) do
    {max_x, max_y, used_colors} =
      Enum.reduce(pixel_buffer, {0, 0, MapSet.new()}, fn {{x, y}, color_index},
                                                         {acc_max_x, acc_max_y, acc_colors} ->
        {max(x, acc_max_x), max(y, acc_max_y), MapSet.put(acc_colors, color_index)}
      end)

    {max_x + 1, max_y + 1, used_colors}
  end

  defp get_raster_attributes(attrs, width, height) do
    pan = Map.get(attrs, :aspect_num, 1)
    pad = Map.get(attrs, :aspect_den, 1)
    ph = get_dimension(attrs, :width, 0, width)
    pv = get_dimension(attrs, :height, 1, height)
    {pan, pad, ph, pv}
  end

  defp get_dimension(attrs, key, _tuple_index, default) when is_map(attrs) do
    Map.get(attrs, key, default)
  end

  defp create_dcs_start(pan, pad, ph, pv) do
    <<"\eP", Integer.to_string(pan)::binary, ";", Integer.to_string(pad)::binary, ";",
      Integer.to_string(ph)::binary, ";", Integer.to_string(pv)::binary, "q">>
  end

  defp create_color_definitions(palette, used_colors) do
    used_colors
    |> MapSet.to_list()
    |> Enum.map_join("", &create_color_definition(palette, &1))
  end

  defp create_color_definition(palette, color_index) do
    case get_palette_color(palette, color_index) do
      {:ok, {r, g, b}} ->
        sixel_r = round(r * 100 / 255)
        sixel_g = round(g * 100 / 255)
        sixel_b = round(b * 100 / 255)

        <<"#", Integer.to_string(color_index)::binary, ";2;", Integer.to_string(sixel_r)::binary,
          ";", Integer.to_string(sixel_g)::binary, ";", Integer.to_string(sixel_b)::binary>>

      {:error, _} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Sixel Render: Color index #{color_index} not found in palette.",
          %{}
        )

        ""
    end
  end

  defp generate_pixel_data(pixel_buffer, width, height, _used_colors) do
    sixel_bands = generate_sixel_bands(pixel_buffer, width, height)
    final_data = remove_trailing_dollar(sixel_bands)
    IO.iodata_to_binary(List.flatten(final_data))
  end

  defp generate_sixel_bands(pixel_buffer, width, height) do
    for band_y <- 0..(height - 1)//6 do
      current_band_height = min(6, height - band_y * 6)

      {final_band_commands, _final_last_color, final_last_char, final_repeat_count} =
        process_band_columns(pixel_buffer, width, band_y, current_band_height)

      final_output =
        format_band_output(
          final_last_char,
          final_repeat_count,
          final_band_commands
        )

      [IO.iodata_to_binary(final_output), "$"]
    end
  end

  defp process_band_columns(pixel_buffer, width, band_y, current_band_height) do
    initial_acc = {[], nil, nil, 0}

    for x <- 0..(width - 1), reduce: initial_acc do
      acc -> process_column(pixel_buffer, x, band_y, current_band_height, acc)
    end
  end

  defp process_column(
         pixel_buffer,
         x,
         band_y,
         current_band_height,
         {acc_commands, last_color, last_char, repeat_count}
       ) do
    column_pixels =
      collect_column_pixels(pixel_buffer, x, band_y, current_band_height)

    handle_column_rle(
      column_pixels,
      acc_commands,
      last_color,
      last_char,
      repeat_count
    )
  end

  defp collect_column_pixels(pixel_buffer, x, band_y, current_band_height) do
    (band_y * 6)..(band_y * 6 + current_band_height - 1)
    |> Enum.reduce(%{}, fn y, acc ->
      case Map.get(pixel_buffer, {x, y}) do
        nil ->
          acc

        color_index ->
          Map.update(acc, color_index, [{y, 1}], fn existing ->
            [{y, 1} | existing]
          end)
      end
    end)
    |> Map.new(fn {color_index, y_coords} ->
      bitmask = calculate_bitmask(y_coords)
      {color_index, bitmask}
    end)
  end

  defp calculate_bitmask(y_coords) do
    Enum.reduce(y_coords, 0, fn {y, _}, mask_acc ->
      row_in_band = rem(y, 6)
      mask_acc ||| Bitwise.bsl(1, row_in_band)
    end)
  end

  defp handle_column_rle(
         column_pixels,
         acc_commands,
         last_color,
         last_char,
         repeat_count
       ) do
    simple_column? = map_size(column_pixels) == 1

    {current_color, current_char} =
      get_column_values(column_pixels, simple_column?)

    case {simple_column?, current_color == last_color, current_char == last_char} do
      {true, true, true} ->
        {acc_commands, last_color, last_char, repeat_count + 1}

      _ ->
        output_commands = format_output_commands(repeat_count, last_char)
        current_commands = format_current_commands(column_pixels)

        {[acc_commands, output_commands, current_commands], current_color, current_char, 1}
    end
  end

  defp get_column_values(column_pixels, simple_column?) do
    case simple_column? do
      true ->
        [{color, bitmask}] = Map.to_list(column_pixels)
        {color, <<bitmask + 63>>}

      false ->
        {nil, nil}
    end
  end

  defp format_output_commands(0, _), do: []
  defp format_output_commands(_, nil), do: []
  defp format_output_commands(1, char), do: [char]

  defp format_output_commands(count, char),
    do: [<<"!", Integer.to_string(count)::binary>>, char]

  defp format_current_commands(column_pixels) do
    commands =
      Enum.flat_map(column_pixels, fn {color_index, bitmask} ->
        [<<"#", Integer.to_string(color_index)::binary>>, <<bitmask + 63>>]
      end)

    case map_size(column_pixels) > 1 do
      true -> [commands, "-"]
      false -> commands
    end
  end

  defp format_band_output(nil, _, commands), do: commands
  defp format_band_output("", _, commands), do: commands
  defp format_band_output(char, 0, commands), do: [commands, char]
  defp format_band_output(char, 1, commands), do: [commands, char]

  defp format_band_output(char, count, commands),
    do: [commands, <<"!", Integer.to_string(count)::binary>>, char]

  defp remove_trailing_dollar(sixel_bands) do
    case List.last(sixel_bands) do
      [data, "$"] -> List.replace_at(sixel_bands, -1, [data])
      _ -> sixel_bands
    end
  end

  defp get_palette_color(palette, index)
       when is_integer(index) and index >= 0 and index <= 255 do
    case Map.get(palette, index) do
      nil -> {:error, :invalid_color_index}
      color -> {:ok, color}
    end
  end

  defp get_palette_color(_palette, _index), do: {:error, :invalid_color_index}
end
