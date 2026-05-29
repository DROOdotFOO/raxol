defmodule Raxol.Recording.Video.Rasterizer.ChromicPDF do
  @moduledoc """
  Rasterizer backend backed by ChromicPDF's warm headless-Chrome session pool.

  Unlike `Raxol.Recording.Video.Rasterizer.HeadlessChrome`, which launches a
  fresh Chrome process per frame, this keeps Chrome resident and reuses it
  across frames via CDP, which is dramatically faster for multi-frame clips.

  Requires the optional `:chromic_pdf` dependency. `full_page: true` captures
  the rendered content box, so every frame of a fixed terminal grid comes out
  at consistent pixel dimensions without manual viewport math.
  """

  @behaviour Raxol.Recording.Video.Rasterizer

  # chromic_pdf is optional; consumers who don't use the video target won't have it.
  @compile {:no_warn_undefined, ChromicPDF}

  @impl true
  def available?, do: Code.ensure_loaded?(ChromicPDF)

  @impl true
  def rasterize(html, _size_px, opts) do
    if Code.ensure_loaded?(ChromicPDF) do
      with :ok <- ensure_started(),
           {:ok, base64} <- capture(html, opts) do
        decode(base64)
      end
    else
      {:error, :chromic_pdf_not_available}
    end
  end

  defp capture(html, opts) do
    capture_opts = [
      {:capture_screenshot, %{format: "png"}},
      {:full_page, Keyword.get(opts, :full_page, true)}
    ]

    ChromicPDF.capture_screenshot({:html, html}, capture_opts)
  end

  defp decode(base64) do
    case Base.decode64(base64) do
      {:ok, png} -> {:ok, png}
      :error -> {:error, :invalid_base64}
    end
  end

  defp ensure_started do
    case ChromicPDF.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  end
end
