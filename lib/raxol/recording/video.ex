defmodule Raxol.Recording.Video do
  @moduledoc """
  Video render target: turn a Raxol screen buffer into a rasterized frame.

  This is the foundation of the LiveView -> video pipeline. A `Raxol.Core.Buffer`
  is rendered to a self-contained, themed HTML document via
  `Raxol.LiveView.TerminalBridge` and then rasterized to a PNG by a pluggable
  `Raxol.Recording.Video.Rasterizer` backend. Stitching frames into MP4/WebM/GIF
  (FFmpeg) and driving a virtual animation clock are later phases.
  """

  alias Raxol.LiveView.TerminalBridge
  alias Raxol.Recording.Video.Rasterizer

  @default_rasterizer Rasterizer.HeadlessChrome

  # Approximate cell metrics for a 16px monospace cell. Used only to size the
  # capture viewport; refined later from real font metrics.
  @cell_w_px 10
  @cell_h_px 20
  @pad_px 8

  @doc """
  Wrap a buffer's HTML in a standalone, self-contained document.

  Colors are emitted inline (`use_inline_styles: true`) so the frame needs no
  external stylesheet; the wrapper supplies font, background, and layout.
  """
  @spec frame_html(map(), keyword()) :: String.t()
  def frame_html(buffer, opts \\ []) do
    theme = Keyword.get(opts, :theme, :default)
    background = Keyword.get(opts, :background, "#16161e")

    font =
      Keyword.get(
        opts,
        :font_family,
        "ui-monospace, 'SF Mono', Menlo, Consolas, 'DejaVu Sans Mono', monospace"
      )

    body = TerminalBridge.buffer_to_html(buffer, theme: theme, use_inline_styles: true)

    """
    <!doctype html>
    <html><head><meta charset="utf-8"><style>
    html, body { margin: 0; padding: 0; background: #{background}; }
    .raxol-terminal {
      font-family: #{font};
      font-size: 16px;
      line-height: 1.25;
      white-space: pre;
      display: inline-block;
      padding: #{@pad_px}px;
      color: #e0e0e0;
    }
    </style></head><body>#{body}</body></html>
    """
  end

  @doc """
  Render a single buffer to PNG bytes via the configured rasterizer.

  ## Options

    * `:theme` - `Raxol.LiveView.TerminalBridge` theme (default: `:default`)
    * `:rasterizer` - backend module (default: `HeadlessChrome`)
    * `:background` - page background CSS color
    * `:font_family` - CSS font stack
  """
  @spec render_frame(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render_frame(buffer, opts \\ []) do
    rasterizer = Keyword.get(opts, :rasterizer, @default_rasterizer)
    {cols, rows} = buffer_dims(buffer)
    width = cols * @cell_w_px + 2 * @pad_px
    height = rows * @cell_h_px + 2 * @pad_px
    html = frame_html(buffer, opts)
    rasterizer.rasterize(html, {width, height}, opts)
  end

  @doc """
  Render a buffer straight to a PNG file on disk.
  """
  @spec render_frame_to_file(map(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def render_frame_to_file(buffer, path, opts \\ []) do
    with {:ok, png} <- render_frame(buffer, opts),
         :ok <- File.write(path, png) do
      {:ok, path}
    end
  end

  @doc """
  Boot a TEA module (or `.exs` path) headlessly, capture its current frame,
  and render it to PNG bytes. Starts and stops a one-off headless session.

  ## Options

    * `:width` / `:height` - session dimensions (forwarded to `Raxol.Headless`)
    * `:settle_ms` - wait before capture so the first frame renders (default: 50)
    * plus all `render_frame/2` options (`:theme`, `:rasterizer`, ...)
  """
  @spec capture_frame(module() | Path.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def capture_frame(module_or_path, opts \\ []) do
    ensure_headless_started()
    start_opts = Keyword.take(opts, [:id, :width, :height])

    with {:ok, id} <- Raxol.Headless.start(module_or_path, start_opts) do
      try do
        Process.sleep(Keyword.get(opts, :settle_ms, 50))

        case Raxol.Headless.get_buffer(id) do
          {:ok, buffer} -> render_frame(buffer, opts)
          error -> error
        end
      after
        Raxol.Headless.stop(id)
      end
    end
  end

  @doc "Like `capture_frame/2`, but writes the PNG to `path`."
  @spec capture_frame_to_file(module() | Path.t(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def capture_frame_to_file(module_or_path, path, opts \\ []) do
    with {:ok, png} <- capture_frame(module_or_path, opts),
         :ok <- File.write(path, png) do
      {:ok, path}
    end
  end

  @doc """
  Boot a TEA module headlessly, step it over time while injecting scripted
  key events, capture each frame, and encode the result to a video file.

  Frames change only when events fire, so this needs no animation clock for
  event-driven apps. The output extension selects the format (`.mp4`/`.webm`/`.gif`).

  ## Options

    * `:fps` - frames per second (default: 10)
    * `:duration_ms` - clip length (default: 2000)
    * `:output` - output path (default: `"raxol_clip.gif"`)
    * `:events` - `[{ms, {:key, key}}]` or `[{ms, {:key, key, key_opts}}]`
    * `:width` / `:height` - session dimensions
    * `:event_settle_ms` - wait after firing events so the update lands (default: 40)
    * plus all `render_frame/2` options (`:theme`, `:rasterizer`, ...)
  """
  @spec capture_clip(module() | Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def capture_clip(module_or_path, opts \\ []) do
    fps = Keyword.get(opts, :fps, 10)
    duration_ms = Keyword.get(opts, :duration_ms, 2_000)
    output = Keyword.get(opts, :output, "raxol_clip.gif")
    events = normalize_events(Keyword.get(opts, :events, []))
    settle = Keyword.get(opts, :event_settle_ms, 40)

    ensure_headless_started()
    start_opts = Keyword.take(opts, [:id, :width, :height])

    # Drive a deterministic virtual clock so animations are frame-accurate
    # regardless of how long rasterization actually takes.
    Raxol.Animation.Clock.freeze(0)

    try do
      with {:ok, id} <- Raxol.Headless.start(module_or_path, start_opts) do
        dir =
          Path.join(
            System.tmp_dir!(),
            "raxol_clip_#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(dir)

        try do
          Process.sleep(Keyword.get(opts, :settle_ms, 80))
          frames = max(1, round(duration_ms / 1000 * fps))
          dt = max(1, div(1000, fps))

          with :ok <- render_frames(id, dir, frames, dt, events, settle, opts) do
            Raxol.Recording.Video.Encoder.encode(dir, fps, output, opts)
          end
        after
          Raxol.Headless.stop(id)
          File.rm_rf(dir)
        end
      end
    after
      Raxol.Animation.Clock.unfreeze()
    end
  end

  defp render_frames(id, dir, frames, dt, events, settle, opts) do
    Enum.reduce_while(0..(frames - 1), :ok, fn n, _acc ->
      Raxol.Animation.Clock.freeze(n * dt)
      inject_due_events(id, events, n * dt, dt, settle)

      case capture_frame_png(id, n, dir, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp capture_frame_png(id, n, dir, opts) do
    name = "frame_#{String.pad_leading(Integer.to_string(n), 5, "0")}.png"

    with {:ok, buffer} <- Raxol.Headless.get_buffer(id),
         {:ok, png} <- render_frame(buffer, opts) do
      File.write(Path.join(dir, name), png)
    end
  end

  defp inject_due_events(id, events, window_start, dt, settle) do
    due =
      Enum.filter(events, fn {ms, _ev} ->
        ms >= window_start and ms < window_start + dt
      end)

    Enum.each(due, fn {_ms, {:key, key, key_opts}} ->
      Raxol.Headless.send_key(id, key, key_opts)
    end)

    if due != [], do: Process.sleep(settle)
  end

  defp normalize_events(events) do
    Enum.map(events, fn
      {ms, {:key, key}} -> {ms, {:key, key, []}}
      {ms, {:key, key, key_opts}} -> {ms, {:key, key, key_opts}}
    end)
  end

  defp ensure_headless_started do
    case Process.whereis(Raxol.Headless) do
      nil -> start_headless()
      _pid -> :ok
    end
  end

  defp start_headless do
    case Raxol.Headless.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  end

  defp buffer_dims(%{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: {w, h}

  defp buffer_dims(%{cells: [first_row | _] = rows}) when is_list(first_row),
    do: {length(first_row), length(rows)}

  defp buffer_dims(_), do: {80, 24}
end
