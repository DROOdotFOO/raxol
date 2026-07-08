defmodule Raxol.Terminal.ANSI.PngDecoder do
  @moduledoc """
  Pure Elixir PNG decoder using `:zlib`.

  Supports 8-bit RGB (color type 2) and RGBA (color type 6) PNGs.
  Returns pixel data as a flat list of `{r, g, b}` tuples in row-major order.
  """

  import Bitwise

  @png_magic <<137, 80, 78, 71, 13, 10, 26, 10>>

  @type pixel :: {byte(), byte(), byte()}
  @type decoded :: %{
          width: pos_integer(),
          height: pos_integer(),
          pixels: [pixel()]
        }

  @spec decode(binary()) :: {:ok, decoded()} | {:error, term()}
  def decode(<<@png_magic, chunks::binary>>) do
    with {:ok, ihdr, idat_chunks} <- parse_chunks(chunks),
         {:ok, header} <- parse_ihdr(ihdr),
         {:ok, raw} <- decompress(idat_chunks),
         {:ok, pixels} <- unfilter(raw, header) do
      {:ok, %{width: header.width, height: header.height, pixels: pixels}}
    end
  end

  def decode(_), do: {:error, :invalid_png_magic}

  # -- Chunk parsing --

  defp parse_chunks(data), do: parse_chunks(data, nil, [])

  defp parse_chunks(<<>>, _ihdr, _idats), do: {:error, :unexpected_end}

  defp parse_chunks(
         <<length::32, "IHDR", chunk_data::binary-size(length), _crc::32, rest::binary>>,
         nil,
         idats
       ) do
    parse_chunks(rest, chunk_data, idats)
  end

  defp parse_chunks(
         <<length::32, "IDAT", chunk_data::binary-size(length), _crc::32, rest::binary>>,
         ihdr,
         idats
       ) do
    parse_chunks(rest, ihdr, [chunk_data | idats])
  end

  defp parse_chunks(<<_length::32, "IEND", _rest::binary>>, nil, _idats) do
    {:error, :missing_ihdr}
  end

  defp parse_chunks(<<_length::32, "IEND", _rest::binary>>, ihdr, []) do
    {:error, {:missing_idat, byte_size(ihdr)}}
  end

  defp parse_chunks(<<_length::32, "IEND", _rest::binary>>, ihdr, idats) do
    {:ok, ihdr, Enum.reverse(idats)}
  end

  defp parse_chunks(
         <<length::32, _type::binary-size(4), _data::binary-size(length), _crc::32,
           rest::binary>>,
         ihdr,
         idats
       ) do
    parse_chunks(rest, ihdr, idats)
  end

  defp parse_chunks(_, _, _), do: {:error, :malformed_chunks}

  # -- IHDR parsing --

  defp parse_ihdr(<<width::32, height::32, 8, color_type, 0, 0, _interlace>>)
       when color_type in [2, 6] do
    bpp = if color_type == 2, do: 3, else: 4

    {:ok, %{width: width, height: height, color_type: color_type, bpp: bpp}}
  end

  defp parse_ihdr(<<_w::32, _h::32, bit_depth, color_type, _rest::binary>>) do
    {:error, {:unsupported_format, bit_depth: bit_depth, color_type: color_type}}
  end

  defp parse_ihdr(_), do: {:error, :invalid_ihdr}

  # -- Decompression --

  defp decompress(idat_chunks) do
    compressed = IO.iodata_to_binary(idat_chunks)

    try do
      {:ok, :zlib.uncompress(compressed)}
    rescue
      ErlangError -> {:error, :zlib_decompression_failed}
    end
  end

  # -- Un-filtering --

  defp unfilter(raw, %{width: w, height: h, bpp: bpp, color_type: ct}) do
    stride = w * bpp
    prev_row = :binary.copy(<<0>>, stride)

    result =
      Enum.reduce_while(0..(h - 1), {raw, prev_row, []}, fn _y, acc ->
        unfilter_scanline(acc, stride, bpp)
      end)

    collect_pixels(result, ct)
  end

  defp unfilter_scanline({data, prev, rows_acc}, stride, bpp) do
    case data do
      <<filter_type, scanline::binary-size(^stride), rest::binary>> ->
        case unfilter_row(filter_type, scanline, prev, bpp) do
          {:ok, row} -> {:cont, {rest, row, [row | rows_acc]}}
          {:error, _} = err -> {:halt, err}
        end

      _ ->
        {:halt, {:error, :truncated_image_data}}
    end
  end

  defp collect_pixels({:error, _} = err, _ct), do: err

  defp collect_pixels({_rest, _prev, rows}, ct) do
    pixels =
      rows
      |> Enum.reverse()
      |> Enum.flat_map(&row_to_pixels(&1, ct))

    {:ok, pixels}
  end

  defp unfilter_row(0, scanline, _prev, _bpp), do: {:ok, scanline}

  defp unfilter_row(filter_type, scanline, prev, bpp)
       when filter_type in [1, 2, 3, 4] do
    {:ok, unfilter_bytes(filter_type, scanline, prev, bpp)}
  end

  defp unfilter_row(filter_type, _scanline, _prev, _bpp) do
    {:error, {:unknown_filter_type, filter_type}}
  end

  # Accumulates filtered bytes into an iolist (prepend), then flattens once.
  # This avoids O(n^2) binary concatenation on the hot path.
  defp unfilter_bytes(filter, scan, prev, bpp) do
    size = byte_size(scan)
    acc = unfilter_bytes_loop(filter, scan, prev, bpp, 0, size, [])
    IO.iodata_to_binary(acc)
  end

  defp unfilter_bytes_loop(_filter, _scan, _prev, _bpp, i, size, acc)
       when i >= size do
    Enum.reverse(acc)
  end

  defp unfilter_bytes_loop(filter, scan, prev, bpp, i, size, acc) do
    x = :binary.at(scan, i)
    b = :binary.at(prev, i)

    # For filters needing byte `a`, look it up from the already-decoded output.
    # acc is reversed, so the byte at position (i - bpp) is at index (bpp - 1).
    a = if i >= bpp, do: Enum.at(acc, bpp - 1), else: 0

    raw =
      case filter do
        1 ->
          x + a

        2 ->
          x + b

        3 ->
          x + div(a + b, 2)

        4 ->
          c = if i >= bpp, do: :binary.at(prev, i - bpp), else: 0
          x + paeth_predictor(a, b, c)
      end

    val = band(raw, 0xFF)
    unfilter_bytes_loop(filter, scan, prev, bpp, i + 1, size, [val | acc])
  end

  defp paeth_predictor(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  # -- Pixel extraction --

  defp row_to_pixels(row_binary, 2) do
    for <<r, g, b <- row_binary>>, do: {r, g, b}
  end

  defp row_to_pixels(row_binary, 6) do
    for <<r, g, b, a <- row_binary>> do
      alpha = a / 255.0

      {round(r * alpha + 255 * (1 - alpha)), round(g * alpha + 255 * (1 - alpha)),
       round(b * alpha + 255 * (1 - alpha))}
    end
  end
end
