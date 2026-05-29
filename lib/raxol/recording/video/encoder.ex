defmodule Raxol.Recording.Video.Encoder do
  @moduledoc """
  Encodes a directory of PNG frames into a video file via FFmpeg.

  Frames must be named `frame_%05d.png`. The output extension selects the
  codec: `.mp4` (H.264), `.webm` (VP9), or `.gif` (single-pass palette).
  """

  @doc "Whether ffmpeg is on the PATH."
  @spec available?() :: boolean()
  def available?, do: not is_nil(System.find_executable("ffmpeg"))

  @doc "Encode `frames_dir`/frame_%05d.png at `fps` into `output`."
  @spec encode(Path.t(), pos_integer(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def encode(frames_dir, fps, output, opts \\ []) do
    case System.find_executable("ffmpeg") do
      nil -> {:error, :ffmpeg_not_found}
      ffmpeg -> do_encode(ffmpeg, frames_dir, fps, output, opts)
    end
  end

  defp do_encode(ffmpeg, dir, fps, output, _opts) do
    pattern = Path.join(dir, "frame_%05d.png")
    args = ffmpeg_args(Path.extname(output), pattern, fps, output)

    case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
      {_out, 0} -> {:ok, output}
      {out, code} -> {:error, {:ffmpeg_exit, code, String.slice(out, 0, 800)}}
    end
  end

  @even "scale=trunc(iw/2)*2:trunc(ih/2)*2"

  defp ffmpeg_args(".gif", pattern, fps, output) do
    filter =
      "fps=#{fps},scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos," <>
        "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"

    ["-y", "-framerate", "#{fps}", "-i", pattern, "-vf", filter, output]
  end

  defp ffmpeg_args(".webm", pattern, fps, output) do
    ["-y", "-framerate", "#{fps}", "-i", pattern,
     "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-vf", @even, output]
  end

  defp ffmpeg_args(ext, pattern, fps, output) when ext in [".mp4", ".m4v", ""] do
    ["-y", "-framerate", "#{fps}", "-i", pattern,
     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", @even, output]
  end

  defp ffmpeg_args(_ext, pattern, fps, output) do
    ffmpeg_args(".mp4", pattern, fps, output)
  end
end
