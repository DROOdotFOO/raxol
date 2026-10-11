# Mogrify is an optional dep; guarded at runtime
defmodule Raxol.Terminal.Image do
  @compile {:no_warn_undefined, Mogrify}
  @moduledoc """
  Unified facade for terminal inline image display.

  Auto-detects the best available graphics protocol (Kitty, iTerm2, Sixel)
  and encodes image data as a terminal escape sequence.

  ## Usage

      # Display from file path
      {:ok, escape_seq} = Image.display("logo.png", width: 20, height: 10)
      IO.write(escape_seq)

      # Display raw PNG bytes
      {:ok, escape_seq} = Image.display(png_binary, format: :png)

      # Force a specific protocol
      {:ok, escape_seq} = Image.display("photo.jpg", protocol: :iterm2)

      # Check support
      Image.supported?()        #=> true
      Image.detect_protocol()   #=> :kitty
  """

  alias Raxol.Terminal.ANSI.KittyGraphics
  alias Raxol.Terminal.ImageCache

  @type protocol :: :kitty | :iterm2 | :sixel | :unsupported

  @type display_opts :: [
          width: pos_integer(),
          height: pos_integer(),
          protocol: protocol(),
          format: :png | :jpeg | :gif,
          preserve_aspect: boolean(),
          z_index: integer()
        ]

  @doc """
  Detects the best available image protocol for the current terminal.

  Priority: Kitty > iTerm2 > Sixel > :unsupported.
  """
  @spec detect_protocol() :: protocol()
  def detect_protocol do
    term = System.get_env("TERM", "")
    term_program = System.get_env("TERM_PROGRAM", "")

    cond do
      kitty_supported?(term, term_program) -> :kitty
      iterm2_supported?(term_program) -> :iterm2
      sixel_supported?(term) -> :sixel
      true -> :unsupported
    end
  end

  @doc """
  Returns true if any image protocol is supported.
  """
  @spec supported?() :: boolean()
  def supported?, do: detect_protocol() != :unsupported

  @doc """
  Encodes an image for display in the terminal.

  The source can be a file path (string) or raw image bytes (binary).
  Returns the escape sequence to write to the terminal.

  ## Options

    * `:width` - Width in terminal cells
    * `:height` - Height in terminal cells
    * `:protocol` - Override auto-detected protocol
    * `:format` - Image format hint (:png, :jpeg, :gif)
    * `:preserve_aspect` - Preserve aspect ratio (default: true)
    * `:z_index` - Z-index layer for Kitty protocol (default: 0)
  """
  @spec display(binary(), display_opts()) :: {:ok, binary()} | {:error, term()}
  def display(source, opts \\ []) do
    case Keyword.get(opts, :protocol) || detect_protocol() do
      protocol when protocol in [:kitty, :iterm2, :sixel] ->
        cached_encode(source, protocol, opts)

      # Decided before any work: the resize shells out to ImageMagick, and a
      # terminal (or headless/agent session) that cannot show the result paid
      # for it on every first render. On Windows CI that spawn took over 5 s
      # inside the rendering engine, past `Raxol.Headless`'s call timeout.
      :unsupported ->
        {:error, :unsupported_protocol}

      protocol ->
        {:error, {:unknown_protocol, protocol}}
    end
  end

  defp cached_encode(source, protocol, opts) do
    cache_opts = %{
      protocol: protocol,
      width: opts[:width],
      height: opts[:height]
    }

    ImageCache.fetch(source, cache_opts, fn ->
      with {:ok, data} <- load_image(source),
           {:ok, resized} <- maybe_resize(data, opts) do
        encode(resized, protocol, opts)
      end
    end)
  end

  # -- Protocol detection --

  defp kitty_supported?(term, term_program) do
    String.contains?(term, "kitty") or
      term_program in ["kitty", "WezTerm", "ghostty"]
  end

  defp iterm2_supported?(term_program) do
    term_program == "iTerm.app"
  end

  defp sixel_supported?(term) do
    term in ["xterm-sixel", "mintty"] or String.contains?(term, "sixel")
  end

  # -- Image loading --

  defp load_image(source) when is_binary(source) do
    case File.read(source) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:ok, source}
      {:error, :eisdir} -> {:error, :eisdir}
      {:error, _reason} -> {:ok, source}
    end
  end

  # -- Resize --

  defp maybe_resize(data, opts) do
    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)

    if width || height do
      resize_with_mogrify(data, width, height)
    else
      {:ok, data}
    end
  end

  defp resize_with_mogrify(data, width, height) do
    if Code.ensure_loaded?(Mogrify) do
      try do
        tmp_dir = System.tmp_dir!()
        id = :erlang.unique_integer([:positive])
        input_path = Path.join(tmp_dir, "raxol_img_#{id}_in")
        output_path = Path.join(tmp_dir, "raxol_img_#{id}_out.png")

        File.write!(input_path, data)

        geometry =
          case {width, height} do
            {w, nil} -> "#{w * 8}x"
            {nil, h} -> "x#{h * 16}"
            {w, h} -> "#{w * 8}x#{h * 16}"
          end

        _ =
          Mogrify.open(input_path)
          |> Mogrify.resize(geometry)
          |> Mogrify.format("png")
          |> Mogrify.save(path: output_path)

        result = File.read(output_path)
        _ = File.rm(input_path)
        _ = File.rm(output_path)
        result
      rescue
        e -> {:error, {:resize_failed, Exception.message(e)}}
      end
    else
      {:ok, data}
    end
  end

  # -- Protocol encoding --

  defp encode(data, :kitty, opts) do
    z_index = Keyword.get(opts, :z_index, 0)

    image =
      KittyGraphics.new(1, 1)
      |> KittyGraphics.set_data(data)
      |> KittyGraphics.set_format(:png)
      |> KittyGraphics.transmit_image(%{})
      |> KittyGraphics.place_image(%{z: z_index})

    case KittyGraphics.encode(image) do
      <<>> -> {:error, :empty_image}
      sequence -> {:ok, sequence}
    end
  end

  defp encode(data, :iterm2, opts) do
    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)
    preserve = Keyword.get(opts, :preserve_aspect, true)

    w_param = if width, do: "#{width}", else: "auto"
    h_param = if height, do: "#{height}", else: "auto"
    aspect_flag = if preserve, do: "1", else: "0"
    b64 = Base.encode64(data)
    size = byte_size(data)

    sequence =
      "\e]1337;File=inline=1;width=#{w_param};height=#{h_param};" <>
        "preserveAspectRatio=#{aspect_flag};size=#{size};" <>
        "name=image;base64,#{b64}\a"

    {:ok, sequence}
  end

  defp encode(data, :sixel, _opts) do
    alias Raxol.Terminal.ANSI.{SixelGraphics, SixelRenderer}

    with {:ok, img} <-
           SixelGraphics.from_image_data(data, :png, %{max_colors: 64}) do
      SixelRenderer.render_image(%{
        pixel_buffer: img.pixel_buffer,
        palette: img.palette,
        attributes: %{width: img.width, height: img.height}
      })
    end
  end
end
