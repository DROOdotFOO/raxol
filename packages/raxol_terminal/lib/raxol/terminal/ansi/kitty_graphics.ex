defmodule Raxol.Terminal.ANSI.KittyGraphics do
  @moduledoc """
  Complete Kitty graphics protocol support for terminal rendering.

  This module provides comprehensive Kitty Graphics Protocol support:
  * Full image encoding and decoding
  * RGB, RGBA, and PNG format support
  * Zlib compression support
  * Multi-chunk transmission for large images
  * Image placement and positioning
  * Image deletion and management
  * Animation frame support

  ## Kitty Graphics Protocol

  The Kitty Graphics Protocol is a modern graphics protocol that enables
  pixel-level graphics rendering in compatible terminals. It uses APC
  (Application Program Command) escape sequences and supports:

  * Multiple image formats (RGB, RGBA, PNG)
  * Compression (zlib)
  * Chunked transmission for large images
  * Image placement at cell or pixel level
  * Z-index layering
  * Animation support

  ## Usage

      # Create a new image
      image = KittyGraphics.new(100, 100)

      # Set image data
      image = KittyGraphics.set_data(image, pixel_data)

      # Encode for transmission
      escape_sequence = KittyGraphics.encode(image)
  """

  @behaviour Raxol.Terminal.ANSI.Behaviours.KittyGraphics

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.ANSI.KittyParser

  # APC escape sequence markers
  # APC start + Kitty graphics indicator
  @kitty_start "\e_G"
  # String Terminator
  @kitty_end "\e\\"
  # Maximum chunk size for transmission (4KB base64 encoded)
  @max_chunk_size 4096

  @type action ::
          :transmit | :transmit_display | :display | :delete | :query | :frame
  @type format :: :rgb | :rgba | :png
  @type compression :: :none | :zlib
  @type transmission :: :direct | :file | :temp_file | :shared_memory

  @type t :: %__MODULE__{
          width: non_neg_integer(),
          height: non_neg_integer(),
          data: binary(),
          format: format(),
          compression: compression(),
          image_id: non_neg_integer() | nil,
          placement_id: non_neg_integer() | nil,
          position: {non_neg_integer(), non_neg_integer()},
          cell_position: {non_neg_integer(), non_neg_integer()} | nil,
          z_index: integer(),
          pixel_buffer: binary(),
          animation_frames: [binary()],
          current_frame: non_neg_integer()
        }

  defstruct width: 0,
            height: 0,
            data: <<>>,
            format: :rgba,
            compression: :none,
            image_id: nil,
            placement_id: nil,
            position: {0, 0},
            cell_position: nil,
            z_index: 0,
            pixel_buffer: <<>>,
            animation_frames: [],
            current_frame: 0

  # ============================================================================
  # Behaviour Implementation
  # ============================================================================

  @doc """
  Creates a new Kitty image with default values.

  ## Returns

  A new `t:Raxol.Terminal.ANSI.KittyGraphics.t/0` struct with default values.
  """
  @impl true
  def new do
    %__MODULE__{
      width: 0,
      height: 0,
      data: <<>>,
      format: :rgba,
      compression: :none,
      image_id: nil,
      placement_id: nil,
      position: {0, 0},
      cell_position: nil,
      z_index: 0,
      pixel_buffer: <<>>,
      animation_frames: [],
      current_frame: 0
    }
  end

  @doc """
  Creates a new Kitty image with specified dimensions.

  ## Parameters

  * `width` - The image width in pixels
  * `height` - The image height in pixels

  ## Returns

  A new `t:Raxol.Terminal.ANSI.KittyGraphics.t/0` struct with the specified dimensions.
  """
  @impl true
  def new(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    %__MODULE__{
      width: width,
      height: height,
      data: <<>>,
      format: :rgba,
      compression: :none,
      image_id: nil,
      placement_id: nil,
      position: {0, 0},
      cell_position: nil,
      z_index: 0,
      pixel_buffer: <<>>,
      animation_frames: [],
      current_frame: 0
    }
  end

  @doc """
  Sets the image data for a Kitty image.

  ## Parameters

  * `image` - The current image
  * `data` - The binary image data (raw pixels or PNG)

  ## Returns

  The updated image with new data.
  """
  @impl true
  def set_data(image, data) when is_binary(data) do
    %{image | data: data, pixel_buffer: data}
  end

  @doc """
  Gets the current image data.

  ## Parameters

  * `image` - The current image

  ## Returns

  The binary image data.
  """
  @impl true
  def get_data(image) do
    image.data
  end

  @doc """
  Encodes a Kitty image to APC escape sequence.

  Generates the complete escape sequence for transmitting the image
  to a Kitty-compatible terminal.

  ## Parameters

  * `image` - The image to encode

  ## Returns

  A binary containing the APC escape sequence for the Kitty image.
  """
  @impl true
  def encode(image) do
    case byte_size(image.pixel_buffer) do
      0 ->
        <<>>

      size when size <= @max_chunk_size ->
        encode_single_chunk(image)

      _ ->
        encode_chunked(image)
    end
  end

  @doc """
  Decodes an APC escape sequence into a Kitty image.

  ## Parameters

  * `data` - The APC escape sequence to decode

  ## Returns

  A new `t:Raxol.Terminal.ANSI.KittyGraphics.t/0` struct with the decoded image data.
  """
  @impl true
  def decode(data) when is_binary(data) do
    case extract_kitty_data(data) do
      {:ok, kitty_content} ->
        image = new()
        {result_image, _status} = process_sequence(image, kitty_content)
        result_image

      {:error, _reason} ->
        new()
    end
  end

  @doc """
  Checks if the terminal supports Kitty graphics.

  ## Returns

  `true` if Kitty graphics are supported, `false` otherwise.
  """
  @impl true
  def supported? do
    detect_kitty_support() == :supported
  end

  @doc """
  Processes a Kitty graphics protocol sequence.

  ## Parameters

  * `state` - The current Kitty graphics state
  * `data` - The Kitty graphics data to process (control + payload)

  ## Returns

  A tuple containing the updated state and a response:
  * `{updated_state, :ok}` - Successful processing
  * `{state, {:error, reason}}` - Processing error
  """
  @impl true
  def process_sequence(state, data) when is_binary(data) do
    Log.debug("[KittyGraphics] Processing sequence: #{inspect(truncate_for_log(data))}")

    parser_state = %KittyParser.ParserState{
      width: state.width,
      height: state.height,
      compression: state.compression,
      format: state.format
    }

    case KittyParser.parse(data, parser_state) do
      {:ok, parsed_state} ->
        updated_state = apply_parsed_state(state, parsed_state)
        {updated_state, :ok}

      {:error, reason, _error_state} ->
        Log.warning("[KittyGraphics] Parse error: #{inspect(reason)}")
        {state, {:error, reason}}
    end
  end

  # ============================================================================
  # Kitty-Specific Functions
  # ============================================================================

  @doc """
  Transmits an image to the terminal.

  ## Parameters

  * `image` - The current image state
  * `opts` - Transmission options:
    * `:format` - Image format (:rgb, :rgba, :png)
    * `:compression` - Compression method (:none, :zlib)
    * `:id` - Optional image ID for later reference

  ## Returns

  The updated image state.
  """
  @impl true
  def transmit_image(image, opts \\ %{}) do
    format = Map.get(opts, :format, image.format)
    compression = Map.get(opts, :compression, image.compression)
    image_id = Map.get(opts, :id, generate_image_id())

    %{image | format: format, compression: compression, image_id: image_id}
  end

  @doc """
  Places an image at a specific position.

  ## Parameters

  * `image` - The current image state
  * `opts` - Placement options:
    * `:x` - Pixel X offset within cell
    * `:y` - Pixel Y offset within cell
    * `:cell_x` - Cell column position
    * `:cell_y` - Cell row position
    * `:z` - Z-index for layering

  ## Returns

  The updated image state with placement information.
  """
  @impl true
  def place_image(image, opts \\ %{}) do
    x = Map.get(opts, :x, 0)
    y = Map.get(opts, :y, 0)
    cell_x = Map.get(opts, :cell_x)
    cell_y = Map.get(opts, :cell_y)
    z = Map.get(opts, :z, image.z_index)

    cell_position =
      case {cell_x, cell_y} do
        {nil, nil} -> nil
        _ -> {cell_x || 0, cell_y || 0}
      end

    %{image | position: {x, y}, cell_position: cell_position, z_index: z}
  end

  @doc """
  Deletes an image by its ID.

  ## Parameters

  * `image` - The current image state
  * `image_id` - The ID of the image to delete

  ## Returns

  The updated image state (cleared if ID matches).
  """
  @impl true
  def delete_image(image, image_id) do
    case image.image_id do
      ^image_id ->
        %{image | pixel_buffer: <<>>, data: <<>>}

      _ ->
        image
    end
  end

  @doc """
  Queries information about an image.

  ## Parameters

  * `image` - The current image state
  * `image_id` - The ID of the image to query

  ## Returns

  * `{:ok, info_map}` - Image information if found
  * `{:error, :not_found}` - Image not found
  """
  @impl true
  def query_image(image, image_id) do
    case image.image_id do
      ^image_id ->
        {:ok,
         %{
           id: image_id,
           width: image.width,
           height: image.height,
           format: image.format,
           size: byte_size(image.pixel_buffer)
         }}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Adds an animation frame to the image.

  ## Parameters

  * `image` - The current image state
  * `frame_data` - Binary data for the new frame

  ## Returns

  The updated image with the new frame added.
  """
  @impl true
  def add_animation_frame(image, frame_data) when is_binary(frame_data) do
    %{image | animation_frames: image.animation_frames ++ [frame_data]}
  end

  # ============================================================================
  # Additional Public Functions
  # ============================================================================

  @doc """
  Sets the image format.

  ## Parameters

  * `image` - The current image
  * `format` - The format (:rgb, :rgba, :png)

  ## Returns

  The updated image with the new format.
  """
  def set_format(image, format) when format in [:rgb, :rgba, :png] do
    %{image | format: format}
  end

  @doc """
  Sets the compression method.

  ## Parameters

  * `image` - The current image
  * `compression` - The compression method (:none, :zlib)

  ## Returns

  The updated image with the new compression setting.
  """
  def set_compression(image, compression) when compression in [:none, :zlib] do
    %{image | compression: compression}
  end

  @doc """
  Gets the current animation frame.

  ## Parameters

  * `image` - The current image

  ## Returns

  The binary data for the current animation frame, or nil if no frames.
  """
  def get_current_frame(image) do
    case Enum.at(image.animation_frames, image.current_frame) do
      nil -> image.pixel_buffer
      frame -> frame
    end
  end

  @doc """
  Advances to the next animation frame.

  ## Parameters

  * `image` - The current image

  ## Returns

  The updated image with the next frame selected.
  """
  def next_frame(image) do
    total_frames = length(image.animation_frames)

    case total_frames do
      0 ->
        image

      n ->
        next = rem(image.current_frame + 1, n)
        %{image | current_frame: next}
    end
  end

  @doc """
  Generates a delete command for an image.

  ## Parameters

  * `image_id` - The ID of the image to delete
  * `opts` - Delete options:
    * `:delete_action` - What to delete (:all, :id, :placement, :z_index, :cell, :animation)

  ## Returns

  The APC escape sequence for the delete command.
  """
  def generate_delete_command(image_id, opts \\ %{}) do
    delete_action = Map.get(opts, :delete_action, :id)

    control =
      case delete_action do
        :all -> "a=d,d=A"
        :id -> "a=d,d=i,i=#{image_id}"
        :placement -> "a=d,d=p,i=#{image_id}"
        :z_index -> "a=d,d=z,z=#{Map.get(opts, :z, 0)}"
        :cell -> "a=d,d=c"
        :animation -> "a=d,d=f,i=#{image_id}"
        _ -> "a=d,d=i,i=#{image_id}"
      end

    @kitty_start <> control <> @kitty_end
  end

  @doc """
  Generates a query command for image capabilities.

  ## Returns

  The APC escape sequence for querying terminal capabilities.
  """
  def generate_query_command do
    @kitty_start <> "a=q,t=d,i=0" <> @kitty_end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp encode_single_chunk(image) do
    encoded_data =
      Base.encode64(maybe_compress(image.pixel_buffer, image.compression))

    control = build_control_string(image, false)

    @kitty_start <> control <> ";" <> encoded_data <> @kitty_end
  end

  defp encode_chunked(image) do
    compressed_data = maybe_compress(image.pixel_buffer, image.compression)
    chunks = chunk_data(compressed_data, @max_chunk_size)
    total_chunks = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.map_join("", fn {chunk, index} ->
      is_last = index == total_chunks - 1
      encoded_chunk = Base.encode64(chunk)

      control =
        case index do
          0 -> build_control_string(image, not is_last)
          _ -> "m=#{if is_last, do: 0, else: 1}"
        end

      @kitty_start <> control <> ";" <> encoded_chunk <> @kitty_end
    end)
  end

  defp build_control_string(image, more_data) do
    parts =
      [
        "a=T",
        "f=#{format_code(image.format)}",
        image.compression == :zlib && "o=z",
        image.width > 0 && "s=#{image.width}",
        image.height > 0 && "v=#{image.height}",
        image.image_id && "i=#{image.image_id}",
        image.placement_id && "p=#{image.placement_id}",
        elem(image.position, 0) > 0 && "x=#{elem(image.position, 0)}",
        elem(image.position, 1) > 0 && "y=#{elem(image.position, 1)}",
        image.cell_position && "X=#{elem(image.cell_position, 0)}",
        image.cell_position && "Y=#{elem(image.cell_position, 1)}",
        image.z_index != 0 && "z=#{image.z_index}",
        more_data && "m=1"
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, ",")
  end

  defp format_code(:rgb), do: "24"
  defp format_code(:rgba), do: "32"
  defp format_code(:png), do: "100"

  defp maybe_compress(data, :none), do: data

  defp maybe_compress(data, :zlib) do
    :zlib.compress(data)
  end

  defp chunk_data(data, chunk_size) do
    chunk_data_recursive(data, chunk_size, [])
  end

  defp chunk_data_recursive(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp chunk_data_recursive(data, chunk_size, acc) do
    case data do
      <<chunk::binary-size(^chunk_size), rest::binary>> ->
        chunk_data_recursive(rest, chunk_size, [chunk | acc])

      remainder ->
        Enum.reverse([remainder | acc])
    end
  end

  defp extract_kitty_data(data) when is_binary(data) do
    case :binary.split(data, @kitty_start) do
      [_, rest] ->
        case :binary.split(rest, @kitty_end) do
          [kitty_content | _] -> {:ok, kitty_content}
          _ -> {:error, :no_kitty_terminator}
        end

      _ ->
        {:error, :no_kitty_start}
    end
  end

  defp apply_parsed_state(image, parsed_state) do
    %{
      image
      | width: parsed_state.width || image.width,
        height: parsed_state.height || image.height,
        format: parsed_state.format,
        compression: parsed_state.compression,
        image_id: parsed_state.image_id || image.image_id,
        placement_id: parsed_state.placement_id || image.placement_id,
        position: {parsed_state.x_offset, parsed_state.y_offset},
        cell_position: maybe_cell_position(parsed_state),
        z_index: parsed_state.z_index,
        pixel_buffer: parsed_state.pixel_buffer
    }
  end

  defp maybe_cell_position(%{cell_x: nil, cell_y: nil}), do: nil
  defp maybe_cell_position(%{cell_x: x, cell_y: y}), do: {x || 0, y || 0}

  defp detect_kitty_support do
    term = System.get_env("TERM", "")
    term_program = System.get_env("TERM_PROGRAM", "")

    cond do
      # Kitty terminal
      String.contains?(term, "kitty") or term_program == "kitty" ->
        :supported

      # WezTerm has Kitty graphics support
      term_program == "WezTerm" ->
        :supported

      # Ghostty has Kitty graphics support
      term_program == "ghostty" ->
        :supported

      # iTerm2 has partial Kitty graphics support
      term_program == "iTerm.app" ->
        :partial_support

      # Unknown terminals
      true ->
        :unknown
    end
  end

  defp generate_image_id do
    :erlang.unique_integer([:positive, :monotonic])
  end

  defp truncate_for_log(data) when byte_size(data) > 100 do
    <<prefix::binary-size(100), _rest::binary>> = data
    prefix <> "..."
  end

  defp truncate_for_log(data), do: data
end
