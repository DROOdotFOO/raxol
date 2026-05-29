defmodule Raxol.Recording.Video.Rasterizer.HeadlessChrome do
  @moduledoc """
  Rasterizer backend that shells out to an installed headless Chrome/Chromium.

  Writes the frame HTML to a temp file and invokes Chrome with `--screenshot`.
  No Hex dependency: it uses whatever Chrome binary is on the machine. For
  multi-frame renders a persistent-session backend (CDP `setDocumentContent` +
  `captureScreenshot`) is faster; this backend favours zero setup.
  """

  @behaviour Raxol.Recording.Video.Rasterizer

  @candidates [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome-stable",
    "google-chrome",
    "chromium",
    "chromium-browser"
  ]

  @impl true
  def available?, do: not is_nil(chrome_binary())

  @impl true
  def rasterize(html, {w, h}, opts) do
    case chrome_binary() do
      nil -> {:error, :chrome_not_found}
      bin -> do_rasterize(bin, html, {w, h}, opts)
    end
  end

  defp do_rasterize(bin, html, {w, h}, opts) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_video_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    html_path = Path.join(dir, "frame.html")
    png_path = Path.join(dir, "frame.png")
    File.write!(html_path, html)

    args = [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      "--force-device-scale-factor=#{Keyword.get(opts, :scale, 1)}",
      "--default-background-color=00000000",
      "--screenshot=#{png_path}",
      "--window-size=#{w},#{h}",
      "file://#{html_path}"
    ]

    try do
      case System.cmd(bin, args, stderr_to_stdout: true) do
        {_out, 0} -> read_png(png_path)
        {out, code} -> {:error, {:chrome_exit, code, String.slice(out, 0, 500)}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp read_png(path) do
    case File.read(path) do
      {:ok, <<137, 80, 78, 71, _::binary>> = png} -> {:ok, png}
      {:ok, _} -> {:error, :not_a_png}
      {:error, reason} -> {:error, {:read_png, reason}}
    end
  end

  defp chrome_binary do
    Enum.find_value(@candidates, fn candidate ->
      if String.contains?(candidate, "/") do
        if File.exists?(candidate), do: candidate
      else
        System.find_executable(candidate)
      end
    end)
  end
end
