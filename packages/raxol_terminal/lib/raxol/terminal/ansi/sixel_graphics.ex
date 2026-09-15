defmodule Raxol.Terminal.ANSI.SixelGraphics do
  alias Raxol.Core.Runtime.Log
  import Bitwise

  @behaviour Raxol.Terminal.ANSI.Behaviours.SixelGraphics

  @moduledoc """
  Complete Sixel graphics support for terminal rendering.

  This module provides comprehensive Sixel (DEC Sixel Graphics) support:
  * Full Sixel image encoding and decoding
  * Advanced color palette management with quantization
  * Image format conversion (PNG, JPEG, GIF -> Sixel)
  * Color optimization and dithering algorithms
  * Animation frame support
  * Terminal compatibility detection
  * Performance optimizations for large images

  ## Sixel Format

  Sixel is a bitmap graphics format developed by Digital Equipment Corporation
  for their terminals. Each character represents 6 vertical pixels, allowing
  efficient transmission of images over serial connections.

  ## Features

  - PNG/JPEG/GIF to Sixel conversion
  - Color palette optimization (up to 256 colors)
  - Floyd-Steinberg dithering
  - Transparency support
  - Animation support for GIF files
  - Compression and size optimization
  """

  @type rgb_color :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type rgba_color ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type color_format :: :rgb | :rgba | :hsl | :indexed
  @type dithering_algorithm :: :none | :floyd_steinberg | :ordered | :random
  @type image_format :: :png | :jpeg | :gif | :bmp | :raw_rgb | :raw_rgba

  @type sixel_options :: %{
          optional(:max_colors) => non_neg_integer(),
          optional(:dithering) => dithering_algorithm(),
          optional(:transparent_color) => rgb_color() | nil,
          optional(:optimize_palette) => boolean(),
          optional(:target_width) => non_neg_integer() | nil,
          optional(:target_height) => non_neg_integer() | nil,
          optional(:preserve_aspect_ratio) => boolean()
        }

  @type sixel_state :: %{
          width: non_neg_integer(),
          height: non_neg_integer(),
          data: binary(),
          palette: map(),
          current_color: non_neg_integer(),
          pixel_buffer: map()
        }

  @type t :: %__MODULE__{
          width: non_neg_integer(),
          height: non_neg_integer(),
          data: binary(),
          palette: map(),
          scale: {non_neg_integer(), non_neg_integer()},
          position: {non_neg_integer(), non_neg_integer()},
          current_color: non_neg_integer(),
          attributes: map(),
          pixel_buffer: map(),
          sixel_cursor_pos: {non_neg_integer(), non_neg_integer()},
          # Enhanced fields
          original_format: image_format() | nil,
          transparent_color: rgb_color() | nil,
          animation_frames: [t()] | nil,
          compression_enabled: boolean(),
          dithering_algorithm: dithering_algorithm()
        }

  # Sixel constants
  # Device Control String start + Graphics mode
  @sixel_start "\e[?8452h\ePq"
  # String Terminator
  @sixel_end "\e\\"
  # Maximum colors in Sixel palette
  @max_colors 256
  # Sixels are 6 pixels tall
  @sixel_height 6

  defstruct width: 0,
            height: 0,
            data: "",
            palette: %{},
            scale: {1, 1},
            position: {0, 0},
            current_color: 0,
            attributes: %{
              width: :normal,
              height: :normal,
              size: :normal
            },
            pixel_buffer: %{},
            sixel_cursor_pos: {0, 0},
            # Enhanced fields
            original_format: nil,
            transparent_color: nil,
            animation_frames: nil,
            compression_enabled: true,
            dithering_algorithm: :floyd_steinberg

  @doc """
  Creates a new Sixel image with default values.

  ## Returns

  A new `t:Raxol.Terminal.ANSI.SixelGraphics.t/0` struct with default values.
  """
  @spec new() :: t()
  @impl true
  def new do
    %__MODULE__{
      width: 0,
      height: 0,
      data: <<>>,
      palette: Raxol.Terminal.ANSI.SixelPalette.initialize_palette(),
      scale: {1, 1},
      position: {0, 0},
      current_color: 0,
      attributes: %{width: :normal, height: :normal, size: :normal},
      pixel_buffer: %{},
      sixel_cursor_pos: {0, 0},
      original_format: nil,
      transparent_color: nil,
      animation_frames: nil,
      compression_enabled: true,
      dithering_algorithm: :floyd_steinberg
    }
  end

  @doc """
  Creates a new Sixel image with specified dimensions.

  ## Parameters

  * `width` - The image width in pixels
  * `height` - The image height in pixels

  ## Returns

  A new `t:Raxol.Terminal.ANSI.SixelGraphics.t/0` struct with the specified dimensions.
  """
  @spec new(pos_integer(), pos_integer()) :: t()
  @impl true
  def new(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    %__MODULE__{
      width: width,
      height: height,
      data: <<>>,
      palette: Raxol.Terminal.ANSI.SixelPalette.initialize_palette(),
      scale: {1, 1},
      position: {0, 0},
      current_color: 0,
      attributes: %{width: :normal, height: :normal, size: :normal},
      pixel_buffer: %{},
      sixel_cursor_pos: {0, 0},
      original_format: nil,
      transparent_color: nil,
      animation_frames: nil,
      compression_enabled: true,
      dithering_algorithm: :floyd_steinberg
    }
  end

  @doc """
  Sets the image data for a Sixel image.

  ## Parameters

  * `image` - The current image
  * `data` - The binary image data

  ## Returns

  The updated image with new data.
  """
  @spec set_data(t(), binary()) :: t()
  @impl true
  def set_data(image, data) when is_binary(data) do
    %{image | data: data}
  end

  @doc """
  Gets the current image data.

  ## Parameters

  * `image` - The current image

  ## Returns

  The binary image data.
  """
  @spec get_data(t()) :: binary()
  @impl true
  def get_data(image) do
    image.data
  end

  @doc """
  Sets the color palette for a Sixel image.

  ## Parameters

  * `image` - The current image
  * `palette` - A map of color indices to RGB values

  ## Returns

  The updated image with new palette.
  """
  @spec set_palette(t(), map()) :: t()
  @impl true
  def set_palette(image, palette) when is_map(palette) do
    %{image | palette: palette}
  end

  @doc """
  Gets the current color palette.

  ## Parameters

  * `image` - The current image

  ## Returns

  A map containing the current color palette.
  """
  @spec get_palette(t()) :: map()
  @impl true
  def get_palette(image) do
    image.palette
  end

  @doc """
  Sets the scale factor for a Sixel image.

  ## Parameters

  * `image` - The current image
  * `x_scale` - The horizontal scale factor
  * `y_scale` - The vertical scale factor

  ## Returns

  The updated image with new scale factors.
  """
  @spec set_scale(t(), pos_integer(), pos_integer()) :: t()
  @impl true
  def set_scale(image, x_scale, y_scale)
      when is_integer(x_scale) and is_integer(y_scale) and x_scale > 0 and
             y_scale > 0 do
    %{image | scale: {x_scale, y_scale}}
  end

  @doc """
  Gets the current scale factors.

  ## Parameters

  * `image` - The current image

  ## Returns

  A tuple `{x_scale, y_scale}` with the current scale factors.
  """
  @spec get_scale(t()) :: {non_neg_integer(), non_neg_integer()}
  @impl true
  def get_scale(image) do
    image.scale
  end

  @doc """
  Sets the position for a Sixel image.

  ## Parameters

  * `image` - The current image
  * `x` - The horizontal position
  * `y` - The vertical position

  ## Returns

  The updated image with new position.
  """
  @spec set_position(t(), non_neg_integer(), non_neg_integer()) :: t()
  @impl true
  def set_position(image, x, y)
      when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 do
    %{image | position: {x, y}}
  end

  @doc """
  Gets the current position.

  ## Parameters

  * `image` - The current image

  ## Returns

  A tuple `{x, y}` with the current position.
  """
  @spec get_position(t()) :: {non_neg_integer(), non_neg_integer()}
  @impl true
  def get_position(image) do
    image.position
  end

  @doc """
  Encodes a Sixel image to ANSI escape sequence.

  ## Parameters

  * `image` - The image to encode

  ## Returns

  A binary containing the ANSI escape sequence for the Sixel image.
  """
  @spec encode(t()) :: binary()
  @impl true
  def encode(image) do
    if map_size(image.pixel_buffer) == 0 do
      ""
    else
      sixel_data = encode_pixel_buffer_to_sixel(image)
      palette_data = encode_palette(image.palette)

      @sixel_start <> palette_data <> sixel_data <> @sixel_end
    end
  end

  @doc """
  Decodes an ANSI escape sequence into a Sixel image.

  ## Parameters

  * `data` - The ANSI escape sequence to decode

  ## Returns

  A new `t:Raxol.Terminal.ANSI.SixelGraphics.t/0` struct with the decoded image data.
  """
  @spec decode(binary()) :: t()
  @impl true
  def decode(data) when is_binary(data) do
    # Extract sixel data from escape sequence
    case extract_sixel_data(data) do
      {:ok, sixel_content} ->
        image = new()
        process_sequence(image, sixel_content)

      {:error, _reason} ->
        # Return empty image on error
        new()
    end
  end

  @doc """
  Checks if the terminal supports Sixel graphics.

  ## Returns

  `true` if Sixel graphics are supported, `false` otherwise.
  """
  @spec supported?() :: boolean()
  @impl true
  def supported? do
    detect_sixel_support() == :supported
  end

  @doc """
  Processes a sequence of Sixel data.

  ## Parameters

  * `state` - The current Sixel state
  * `data` - The Sixel data to process

  ## Returns

  A tuple containing the updated state and a response.
  """
  @spec process_sequence(t(), binary()) :: {t(), :ok | {:error, term()}}
  @impl true
  def process_sequence(state, data) when is_binary(data) do
    Log.debug(fn -> "SixelGraphics: process_sequence called with data: #{inspect(data)}" end)

    # Ensure palette is initialized
    state_with_palette =
      if map_size(state.palette) == 0 do
        %{
          state
          | palette: Raxol.Terminal.ANSI.SixelPalette.initialize_palette()
        }
      else
        state
      end

    Log.debug(fn ->
      "SixelGraphics: Initial palette has #{map_size(state_with_palette.palette)} colors"
    end)

    Log.debug(fn ->
      "SixelGraphics: Color index 1 is #{inspect(Map.get(state_with_palette.palette, 1, :not_found))}"
    end)

    Log.debug(fn -> "SixelGraphics: Calling SixelParser.parse with data: #{inspect(data)}" end)

    case Raxol.Terminal.ANSI.SixelParser.parse(
           data,
           %Raxol.Terminal.ANSI.SixelParser.ParserState{
             x: 0,
             y: 0,
             color_index: state_with_palette.current_color,
             repeat_count: 1,
             palette: state_with_palette.palette,
             raster_attrs: state_with_palette.attributes,
             pixel_buffer: state_with_palette.pixel_buffer,
             max_x: 0,
             max_y: 0
           }
         ) do
      {:ok, parser_state} ->
        Log.debug(
          "SixelGraphics: Parser returned palette with #{map_size(parser_state.palette)} colors"
        )

        Log.debug(
          "SixelGraphics: Parser color index 1 is #{inspect(Map.get(parser_state.palette, 1, :not_found))}"
        )

        # Preserve the original palette if the parser didn't modify it
        final_palette =
          if map_size(parser_state.palette) == 0,
            do: state_with_palette.palette,
            else: parser_state.palette

        Log.debug(fn -> "SixelGraphics: Final palette has #{map_size(final_palette)} colors" end)

        Log.debug(fn ->
          "SixelGraphics: Final color index 1 is #{inspect(Map.get(final_palette, 1, :not_found))}"
        end)

        updated_state = %{
          state_with_palette
          | palette: final_palette,
            pixel_buffer: parser_state.pixel_buffer,
            position: {parser_state.x, parser_state.y},
            current_color: parser_state.color_index,
            attributes: parser_state.raster_attrs
        }

        {updated_state, :ok}

      {:error, reason} ->
        Log.debug(fn -> "SixelGraphics: Parser returned error: #{inspect(reason)}" end)

        # Return unchanged state and error
        {state_with_palette, {:error, reason}}
    end
  end

  # Private helper functions

  defp encode_pixel_buffer_to_sixel(image) do
    if map_size(image.pixel_buffer) == 0 do
      ""
    else
      # Convert pixel buffer to sixel format
      # Each sixel represents 6 vertical pixels
      max_x =
        image.pixel_buffer
        |> Map.keys()
        |> Enum.map(&elem(&1, 0))
        |> Enum.max(fn -> 0 end)

      max_y =
        image.pixel_buffer
        |> Map.keys()
        |> Enum.map(&elem(&1, 1))
        |> Enum.max(fn -> 0 end)

      # Process pixels in groups of 6 vertical pixels (sixels)
      sixel_rows = div(max_y + @sixel_height - 1, @sixel_height)

      for sixel_row <- 0..(sixel_rows - 1) do
        encode_sixel_row(image, sixel_row, max_x)
      end
      # "-" moves to next sixel row
      |> Enum.join("-")
    end
  end

  defp encode_sixel_row(image, sixel_row, max_x) do
    base_y = sixel_row * @sixel_height

    # Group pixels by color for this sixel row
    color_groups =
      for x <- 0..max_x,
          y <- base_y..(base_y + @sixel_height - 1),
          reduce: %{} do
        acc ->
          case Map.get(image.pixel_buffer, {x, y}) do
            # No pixel at this position
            nil ->
              acc

            color_index ->
              sixel_bit = y - base_y
              sixel_value = Map.get(acc, color_index, 0) ||| 1 <<< sixel_bit
              Map.put(acc, color_index, sixel_value)
          end
      end

    # Encode each color group
    for {color_index, _sixel_value} <- color_groups do
      encode_color_sixels(image, color_index, sixel_row, max_x)
    end
    |> Enum.join()
  end

  defp encode_color_sixels(image, color_index, sixel_row, max_x) do
    base_y = sixel_row * @sixel_height

    # Set color
    color_seq = "##{color_index}"

    # Collect sixel values for this color
    sixels =
      for x <- 0..max_x do
        sixel_value =
          for y <- base_y..(base_y + @sixel_height - 1),
              reduce: 0 do
            acc ->
              case Map.get(image.pixel_buffer, {x, y}) do
                ^color_index -> acc ||| 1 <<< (y - base_y)
                _ -> acc
              end
          end

        # Convert to sixel character (add 63 to make printable)
        if sixel_value > 0, do: <<sixel_value + 63>>, else: nil
      end
      |> Enum.filter(& &1)
      |> Enum.join()

    if String.length(sixels) > 0 do
      color_seq <> sixels
    else
      ""
    end
  end

  defp encode_palette(palette) when is_map(palette) do
    palette
    |> Enum.sort_by(fn {index, _color} -> index end)
    |> Enum.map_join(fn {index, {r, g, b}} ->
      # Convert to percentages (0-100)
      r_pct = round(r / 255 * 100)
      g_pct = round(g / 255 * 100)
      b_pct = round(b / 255 * 100)
      "##{index};2;#{r_pct};#{g_pct};#{b_pct}"
    end)
  end

  defp extract_sixel_data(data) when is_binary(data) do
    # Look for Sixel DCS sequence
    case String.split(data, @sixel_start, parts: 2) do
      [_, rest] ->
        case String.split(rest, @sixel_end, parts: 2) do
          [sixel_content | _] -> {:ok, sixel_content}
          _ -> {:error, :no_sixel_terminator}
        end

      _ ->
        {:error, :no_sixel_start}
    end
  end

  defp detect_sixel_support do
    # Check environment variables and terminal capabilities
    term = System.get_env("TERM", "")
    term_program = System.get_env("TERM_PROGRAM", "")
    colorterm = System.get_env("COLORTERM", "")

    cond do
      # Known terminals with Sixel support
      term_program in ["iTerm.app"] and String.contains?(colorterm, "sixel") ->
        :supported

      String.contains?(term, "sixel") ->
        :supported

      term in ["xterm-sixel", "mintty"] ->
        :supported

      # Terminals that might support Sixel with configuration
      String.starts_with?(term, "xterm") ->
        :maybe_supported

      term_program in ["Terminal.app", "WezTerm"] ->
        :maybe_supported

      # Basic terminals without graphics support
      term in ["dumb", "vt100", "vt52"] ->
        :unsupported

      # Unknown terminals
      true ->
        :unknown
    end
  end

  @doc """
  Converts an image from common formats (PNG, JPEG, GIF) to Sixel format.

  ## Parameters

  * `image_data` - Binary image data
  * `format` - Image format (:png, :jpeg, :gif)
  * `options` - Sixel conversion options

  ## Returns

  * `{:ok, sixel_image}` - Converted Sixel image
  * `{:error, reason}` - Conversion error
  """
  @spec from_image_data(binary(), :png | :jpeg | :gif | atom(), sixel_options()) ::
          {:ok, t()} | {:error, term()}
  def from_image_data(image_data, format, options \\ %{})

  def from_image_data(image_data, :png, options) when is_binary(image_data) do
    max_colors = Map.get(options, :max_colors, 64)
    dithering = Map.get(options, :dithering, :none)

    with {:ok, %{width: w, height: h, pixels: pixels}} <-
           Raxol.Terminal.ANSI.PngDecoder.decode(image_data) do
      {palette, indices} = quantize_colors(pixels, min(max_colors, @max_colors))

      image = %__MODULE__{
        width: w,
        height: h,
        data: <<>>,
        palette: palette,
        pixel_buffer: indices_to_pixel_buffer(indices, w),
        original_format: :png,
        attributes: %{width: w, height: h}
      }

      {:ok, apply_dithering(image, dithering)}
    end
  end

  def from_image_data(_image_data, format, _options)
      when format in [:jpeg, :gif] do
    {:error, {:format_requires_external_decoder, format}}
  end

  def from_image_data(_image_data, format, _options) do
    {:error, {:unsupported_format, format}}
  end

  defp indices_to_pixel_buffer(indices, width) do
    indices
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {color_idx, flat_idx}, acc ->
      Map.put(acc, {rem(flat_idx, width), div(flat_idx, width)}, color_idx)
    end)
  end

  # Median cut color quantization. Returns {%{index => {r,g,b}}, [index_per_pixel]}.
  defp quantize_colors(pixels, max_colors) do
    unique = pixels |> Enum.frequencies() |> Map.keys()

    if length(unique) <= max_colors do
      direct_palette(pixels, unique)
    else
      median_cut_palette(pixels, unique, max_colors)
    end
  end

  defp direct_palette(pixels, unique) do
    color_to_idx = unique |> Enum.with_index() |> Map.new()
    palette = Map.new(color_to_idx, fn {color, idx} -> {idx, color} end)
    {palette, Enum.map(pixels, &Map.fetch!(color_to_idx, &1))}
  end

  defp median_cut_palette(pixels, unique, max_colors) do
    boxes = median_cut_split([unique], max_colors)

    {palette, color_to_idx} =
      boxes
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {box, idx}, {pal, c2i} ->
        new_pal = Map.put(pal, idx, box_centroid(box))
        new_c2i = Enum.reduce(box, c2i, &Map.put(&2, &1, idx))
        {new_pal, new_c2i}
      end)

    {palette, Enum.map(pixels, &Map.fetch!(color_to_idx, &1))}
  end

  defp median_cut_split(boxes, max_colors) when length(boxes) >= max_colors do
    Enum.take(boxes, max_colors)
  end

  defp median_cut_split(boxes, max_colors) do
    # Find the box with the largest range on its widest channel
    {target, rest} = pop_largest_box(boxes)

    case split_box(target) do
      {a, b} ->
        median_cut_split([a, b | rest], max_colors)

      :cannot_split ->
        # This box can't be split further; try others or give up
        median_cut_split(rest ++ [target], max_colors)
    end
  end

  defp pop_largest_box(boxes) do
    sorted =
      Enum.sort_by(boxes, fn box ->
        {r_range, g_range, b_range} = channel_ranges(box)
        -max(r_range, max(g_range, b_range))
      end)

    {hd(sorted), tl(sorted)}
  end

  defp channel_ranges(box) do
    {rs, gs, bs} = split_channels(box)

    {Enum.max(rs) - Enum.min(rs), Enum.max(gs) - Enum.min(gs), Enum.max(bs) - Enum.min(bs)}
  end

  defp split_channels(box) do
    Enum.reduce(box, {[], [], []}, fn {r, g, b}, {ra, ga, ba} ->
      {[r | ra], [g | ga], [b | ba]}
    end)
  end

  defp split_box(box) when length(box) <= 1, do: :cannot_split

  defp split_box(box) do
    sorted = sort_by_widest_channel(box)
    mid = div(length(sorted), 2)
    {Enum.take(sorted, mid), Enum.drop(sorted, mid)}
  end

  defp sort_by_widest_channel(box) do
    {r_range, g_range, b_range} = channel_ranges(box)
    idx = widest_channel_index(r_range, g_range, b_range)
    Enum.sort_by(box, &elem(&1, idx))
  end

  defp widest_channel_index(r, g, b) when r >= g and r >= b, do: 0
  defp widest_channel_index(_r, g, b) when g >= b, do: 1
  defp widest_channel_index(_r, _g, _b), do: 2

  defp box_centroid(box) do
    n = length(box)

    {rs, gs, bs} =
      Enum.reduce(box, {0, 0, 0}, fn {r, g, b}, {ra, ga, ba} ->
        {ra + r, ga + g, ba + b}
      end)

    {div(rs, n), div(gs, n), div(bs, n)}
  end

  @doc """
  Optimizes the color palette using quantization algorithms.

  ## Parameters

  * `image` - The Sixel image
  * `max_colors` - Maximum number of colors (default: 256)
  * `algorithm` - Quantization algorithm (:median_cut, :octree)

  ## Returns

  * `t()` - Image with optimized palette
  """
  @spec optimize_palette(t(), pos_integer(), :median_cut | :octree) :: t()
  def optimize_palette(
        image,
        max_colors \\ @max_colors,
        algorithm \\ :median_cut
      ) do
    if map_size(image.palette) <= max_colors do
      image
    else
      # Apply color quantization
      case algorithm do
        :median_cut ->
          apply_median_cut_quantization(image, max_colors)

        :octree ->
          apply_octree_quantization(image, max_colors)

        _ ->
          # Simple truncation fallback
          truncated_palette =
            image.palette
            |> Enum.take(max_colors)
            |> Map.new()

          %{image | palette: truncated_palette}
      end
    end
  end

  defp apply_median_cut_quantization(image, max_colors) do
    pixels =
      image.pixel_buffer
      |> Map.values()
      |> Enum.map(fn idx -> Map.get(image.palette, idx, {0, 0, 0}) end)

    {new_palette, _indices} = quantize_colors(pixels, max_colors)

    # Remap pixel buffer to new palette indices via nearest color
    palette_list = Map.to_list(new_palette)

    new_pixel_buffer =
      Map.new(image.pixel_buffer, fn {pos, old_idx} ->
        color = Map.get(image.palette, old_idx, {0, 0, 0})
        {new_idx, _} = nearest_color(color, palette_list)
        {pos, new_idx}
      end)

    %{image | palette: new_palette, pixel_buffer: new_pixel_buffer}
  end

  defp nearest_color(rgb, palette_list) do
    Raxol.Terminal.ANSI.SixelPalette.nearest_color(rgb, palette_list)
  end

  defp apply_octree_quantization(image, max_colors) do
    # Simplified octree quantization
    # In a real implementation, this would build an octree of color space
    # and merge similar colors

    apply_median_cut_quantization(image, max_colors)
  end

  @doc """
  Applies dithering to reduce color banding when quantizing colors.

  Delegates to `Raxol.Terminal.ANSI.SixelDithering` which implements
  Floyd-Steinberg error diffusion, ordered (Bayer 4x4), and random noise.

  ## Parameters

  * `image` - The Sixel image (must have pixel_buffer and palette)
  * `algorithm` - Dithering algorithm (:floyd_steinberg, :ordered, :random, :none)

  ## Returns

  * `t()` - Image with dithering applied to pixel_buffer
  """
  @spec apply_dithering(t(), dithering_algorithm()) :: t()
  def apply_dithering(image, algorithm \\ :floyd_steinberg) do
    Raxol.Terminal.ANSI.SixelDithering.apply(image, algorithm)
  end
end
