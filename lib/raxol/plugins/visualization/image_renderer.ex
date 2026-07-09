defmodule Raxol.Plugins.Visualization.ImageRenderer do
  @moduledoc """
  Handles rendering logic for image visualization within the VisualizationPlugin.
  Supports both sixel and kitty protocols for terminal image rendering.
  """

  # Mogrify is an optional dependency (image decode/resize). Guard the undefined
  # warnings so the compile stays clean when it is absent.
  @compile {:no_warn_undefined, Mogrify}

  alias Raxol.Plugins.Visualization.DrawingUtils
  alias Raxol.Terminal.ANSI.KittyGraphics
  alias Raxol.Terminal.Cell

  @doc """
  Public entry point for rendering image content.
  Handles bounds checking and calls the internal drawing logic.
  Expects bounds map: %{width: w, height: h}.
  """
  def render_image_content(data, opts, %{width: w, height: h} = bounds, state)
      when w < 1 or h < 1 do
    Raxol.Core.Runtime.Log.warning_with_context(
      "[ImageRenderer] Bounds too small for image rendering: #{inspect(bounds)}",
      %{}
    )

    _ = {data, opts, state}
    []
  end

  def render_image_content(data, opts, bounds, state) do
    title = Map.get(opts, :title, "Image")
    protocol = Map.get(opts, :protocol, detect_protocol(state))
    do_render_image(data, bounds, opts, title, protocol)
  end

  defp do_render_image(data, bounds, opts, title, protocol) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           render_by_protocol(protocol, data, bounds, opts, title)
         end) do
      {:ok, result} ->
        result

      {:error, e} ->
        Raxol.Core.Runtime.Log.error(
          "[ImageRenderer] Error rendering image: #{inspect(e)}"
        )

        DrawingUtils.draw_box_with_text("[Render Error]", bounds)
    end
  end

  defp render_by_protocol(:sixel, data, bounds, opts, _t),
    do: render_sixel(data, bounds, opts)

  defp render_by_protocol(:kitty, data, bounds, opts, _t),
    do: render_kitty(data, bounds, opts)

  defp render_by_protocol(_, data, bounds, _opts, title),
    do: draw_placeholder(data, title, bounds)

  defp detect_protocol(state) do
    case {supports_kitty?(state), supports_sixel?(state)} do
      {true, _} -> :kitty
      {_, true} -> :sixel
      {false, false} -> :placeholder
    end
  end

  defp supports_kitty?(state) do
    # Check for kitty protocol support
    term_program = get_in(state, [:terminal, :program])
    term_program == "kitty" or String.contains?(term_program || "", "kitty")
  end

  defp supports_sixel?(state) do
    # Check for sixel support
    _term_program = get_in(state, [:terminal, :program])
    term_features = get_in(state, [:terminal, :features]) || []
    "sixel" in term_features
  end

  defp render_sixel(data, bounds, opts) do
    # Check if data is already a Sixel sequence (starts with DCS)
    case sixel_sequence?(data) do
      true ->
        # Data is already Sixel - use it directly
        create_sixel_cells(data, bounds)

      false ->
        # Try to load and convert image data to Sixel
        case load_image_data(data) do
          {:ok, image_data} ->
            # Convert image to sixel format
            sixel_data = convert_to_sixel(image_data, bounds)
            # Create cells with sixel escape sequence
            create_sixel_cells(sixel_data, bounds)

          {:error, reason} ->
            Raxol.Core.Runtime.Log.error(
              "[ImageRenderer] Failed to load image: #{inspect(reason)}"
            )

            draw_placeholder(data, Map.get(opts, :title, "Image"), bounds)
        end
    end
  end

  @doc false
  defp sixel_sequence?(data) when is_binary(data) do
    # Check for DCS Sixel start sequence
    String.starts_with?(data, "\e[") or String.starts_with?(data, "\eP")
  end

  defp sixel_sequence?(_), do: false

  defp render_kitty(data, bounds, opts) do
    case load_image_data(data) do
      {:ok, image_data} ->
        # Convert image to kitty format
        kitty_data = convert_to_kitty(image_data, bounds)
        # Create cells with kitty escape sequence
        create_kitty_cells(kitty_data, bounds)

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[ImageRenderer] Failed to load image: #{inspect(reason)}"
        )

        draw_placeholder(data, Map.get(opts, :title, "Image"), bounds)
    end
  end

  defp load_image_data(data) when is_binary(data) do
    # First try as file path, then as raw data
    case File.read(data) do
      {:ok, content} -> {:ok, content}
      # Assume it's raw image data
      {:error, _reason} -> {:ok, data}
    end
  end

  defp load_image_data(_), do: {:error, :invalid_data}

  defp convert_to_sixel(image_data, bounds) do
    # Decode and resize image to fit bounds
    with {:ok, image} <- decode_image(image_data),
         resized_image <- resize_image(image, bounds) do
      encode_sixel(resized_image)
    else
      _ -> "Failed to convert image to sixel format"
    end
  end

  defp decode_image(data) do
    # Use Mogrify to decode image data
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           Mogrify.open(data)
         end) do
      {:ok, image} -> {:ok, image}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  defp resize_image(image, %{width: width, height: height}) do
    # Resize image to fit terminal bounds
    image
    |> Mogrify.resize("#{width}x#{height}")
    |> Mogrify.format("png")
    |> Mogrify.save()
  end

  defp encode_sixel(_image) do
    # For now, we rely on external Sixel encoders or pre-generated Sixel data
    # A full implementation would convert Mogrify image to pixel data
    # and build a SixelGraphics state with pixel_buffer, then encode it

    # This is a simple test pattern for demonstration
    # In practice, users should provide Sixel-encoded data or use external tools
    state = Raxol.Terminal.ANSI.SixelGraphics.new(10, 10)

    # Create a simple pattern in pixel buffer
    pixel_buffer =
      for x <- 0..9, y <- 0..9, into: %{} do
        {{x, y}, rem(x + y, 4)}
      end

    state_with_pixels = %{state | pixel_buffer: pixel_buffer}

    # Encode to Sixel format
    Raxol.Terminal.ANSI.SixelGraphics.encode(state_with_pixels)
  end

  defp convert_to_kitty(image_data, bounds) do
    with {:ok, image} <- decode_image(image_data),
         resized_image <- resize_image(image, bounds),
         {:ok, raw_data} <- File.read(resized_image.path) do
      # Create KittyGraphics state with image data
      state =
        KittyGraphics.new(bounds.width, bounds.height)
        |> KittyGraphics.set_data(raw_data)
        |> KittyGraphics.set_format(:png)
        |> KittyGraphics.transmit_image(%{})

      # Encode to Kitty escape sequence
      KittyGraphics.encode(state)
    else
      _ -> "Failed to convert image to kitty format"
    end
  end

  defp create_sixel_cells(sixel_data, bounds) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           create_sixel_cells_from_buffer(sixel_data, bounds)
         end) do
      {:ok, cells} ->
        cells

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[ImageRenderer] Error creating Sixel cells: #{inspect(reason)}"
        )

        empty_cell_grid(bounds.width, bounds.height)
    end
  end

  @doc false
  defp create_sixel_cells_from_buffer(sixel_data, %{
         width: width,
         height: height
       }) do
    state = Raxol.Terminal.ANSI.SixelGraphics.new()

    case Raxol.Terminal.ANSI.SixelGraphics.process_sequence(state, sixel_data) do
      {updated_state, :ok} ->
        pixel_buffer_to_cells(updated_state, width, height)

      {_state, {:error, reason}} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[ImageRenderer] Sixel processing failed: #{inspect(reason)}",
          %{}
        )

        empty_cell_grid(width, height)
    end
  end

  @doc false
  @spec pixel_buffer_to_cells(map(), non_neg_integer(), non_neg_integer()) :: [
          [Cell.t()]
        ]
  defp pixel_buffer_to_cells(
         %{pixel_buffer: buffer, palette: palette},
         width,
         height
       ) do
    for y <- 0..(height - 1) do
      for x <- 0..(width - 1) do
        build_cell(buffer, palette, x, y)
      end
    end
  end

  @doc false
  defp build_cell(buffer, palette, x, y) do
    with color_index when not is_nil(color_index) <- Map.get(buffer, {x, y}),
         {r, g, b} <- Map.get(palette, color_index) do
      Cell.new_sixel(
        " ",
        %Raxol.Terminal.ANSI.TextFormatting{background: {:rgb, r, g, b}}
      )
    else
      nil -> Cell.new(" ")
      _ -> Cell.new_sixel(" ")
    end
  end

  @doc false
  @spec empty_cell_grid(non_neg_integer(), non_neg_integer()) :: [[Cell.t()]]
  defp empty_cell_grid(width, height) do
    List.duplicate(List.duplicate(Cell.new(" "), width), height)
  end

  defp create_kitty_cells(kitty_data, %{width: width, height: height}) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           create_kitty_cells_from_sequence(kitty_data, width, height)
         end) do
      {:ok, cells} ->
        cells

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[ImageRenderer] Error creating Kitty cells: #{inspect(reason)}"
        )

        empty_cell_grid(width, height)
    end
  end

  @doc false
  defp create_kitty_cells_from_sequence(kitty_data, width, height) do
    # If kitty_data is an encoded escape sequence, process it
    state = KittyGraphics.new()

    case KittyGraphics.process_sequence(state, kitty_data) do
      {updated_state, :ok} ->
        # Convert kitty graphics state to cell grid
        kitty_state_to_cells(updated_state, width, height)

      {_state, {:error, reason}} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[ImageRenderer] Kitty processing failed: #{inspect(reason)}",
          %{}
        )

        empty_cell_grid(width, height)
    end
  end

  @doc false
  defp kitty_state_to_cells(
         %KittyGraphics{pixel_buffer: buffer} = state,
         width,
         height
       )
       when byte_size(buffer) > 0 do
    # Get format to determine bytes per pixel
    bytes_per_pixel =
      case state.format do
        :rgba -> 4
        :rgb -> 3
        _ -> 4
      end

    stride = state.width * bytes_per_pixel

    for y <- 0..(height - 1) do
      for x <- 0..(width - 1) do
        build_kitty_cell(
          buffer,
          x,
          y,
          stride,
          bytes_per_pixel,
          state.width,
          state.height
        )
      end
    end
  end

  defp kitty_state_to_cells(_state, width, height) do
    empty_cell_grid(width, height)
  end

  @doc false
  defp build_kitty_cell(
         buffer,
         x,
         y,
         stride,
         bytes_per_pixel,
         img_width,
         img_height
       )
       when x < img_width and y < img_height do
    offset = y * stride + x * bytes_per_pixel

    case buffer do
      <<_::binary-size(^offset), r, g, b, _::binary>>
      when bytes_per_pixel >= 3 ->
        Cell.new_sixel(
          " ",
          %Raxol.Terminal.ANSI.TextFormatting{background: {:rgb, r, g, b}}
        )

      _ ->
        Cell.new(" ")
    end
  end

  defp build_kitty_cell(_buffer, _x, _y, _stride, _bpp, _img_w, _img_h) do
    Cell.new(" ")
  end

  # --- Private Image Drawing Logic ---

  @doc false
  # Draws a placeholder box indicating where the image would be.
  defp draw_placeholder(_data, title, bounds) do
    DrawingUtils.draw_box_with_text(title, bounds)
  end
end
