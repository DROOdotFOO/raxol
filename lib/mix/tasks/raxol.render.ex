defmodule Mix.Tasks.Raxol.Render do
  @shortdoc "Render a Raxol TEA app to a video or image (MP4/WebM/GIF/PNG)"
  @moduledoc """
  Render a TEA module (or `.exs` file path) to a video file or a single image.

      $ mix raxol.render examples/getting_started/counter.exs --output demo.gif
      $ mix raxol.render examples/getting_started/counter.exs --output frame.png

  The output extension selects the format: `.mp4`/`.webm`/`.gif` produce a clip;
  `.png` captures a single frame.

  ## Options

    * `--output FILE`      output path (required); extension selects the format
    * `--duration MS`      clip length in ms (default: 2000; ignored for `.png`)
    * `--fps N`            frames per second (default: 10; ignored for `.png`)
    * `--theme NAME`       terminal theme (default: default)
    * `--size COLSxROWS`   grid size (default: 120x40)
    * `--rasterizer NAME`  `chromic` (default, warm Chrome pool) or `chrome` (per-frame)
    * `--settle MS`        wait before the first capture (default: 80)
  """

  use Mix.Task

  # Matches Raxol.LiveView.TerminalBridge's supported themes.
  @themes ~w(default nord dracula solarized_dark solarized_light monokai
             synthwave84 gruvbox_dark one_dark tokyo_night catppuccin)

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _} =
      OptionParser.parse(argv,
        strict: [
          output: :string,
          duration: :integer,
          fps: :integer,
          theme: :string,
          size: :string,
          rasterizer: :string,
          settle: :integer
        ]
      )

    target =
      List.first(rest) ||
        Mix.raise("usage: mix raxol.render PATH [--output FILE]")

    output = Keyword.get(opts, :output) || Mix.raise("--output is required")

    Mix.Task.run("app.start")

    case dispatch(Path.extname(output), target, output, build_opts(opts)) do
      {:ok, path} -> Mix.shell().info("Rendered #{path}")
      {:error, reason} -> Mix.raise("render failed: #{inspect(reason)}")
    end
  end

  defp dispatch(".png", target, output, opts),
    do: Raxol.Recording.Video.capture_frame_to_file(target, output, opts)

  defp dispatch(_ext, target, output, opts),
    do: Raxol.Recording.Video.capture_clip(target, [{:output, output} | opts])

  defp build_opts(opts) do
    [
      theme: theme_atom(Keyword.get(opts, :theme, "default")),
      rasterizer: rasterizer(Keyword.get(opts, :rasterizer, "chromic")),
      duration_ms: Keyword.get(opts, :duration, 2_000),
      fps: Keyword.get(opts, :fps, 10),
      settle_ms: Keyword.get(opts, :settle, 80)
    ]
    |> put_size(Keyword.get(opts, :size))
  end

  defp put_size(opts, nil), do: opts

  defp put_size(opts, size) do
    case String.split(size, "x") do
      [w, h] ->
        Keyword.merge(opts,
          width: String.to_integer(w),
          height: String.to_integer(h)
        )

      _ ->
        Mix.raise("--size must be COLSxROWS, e.g. 120x40")
    end
  end

  defp rasterizer("chrome"), do: Raxol.Recording.Video.Rasterizer.HeadlessChrome
  defp rasterizer("chromic"), do: Raxol.Recording.Video.Rasterizer.ChromicPDF

  defp rasterizer(other),
    do: Mix.raise("unknown --rasterizer #{inspect(other)} (chromic|chrome)")

  defp theme_atom(name) when name in @themes, do: String.to_atom(name)

  defp theme_atom(name),
    do:
      Mix.raise(
        "unknown --theme #{inspect(name)} (one of: #{Enum.join(@themes, ", ")})"
      )
end
