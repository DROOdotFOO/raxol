# Generates the recorded frames raxol.io serves statically:
#
#   web/priv/hero_frames/<example>/frame_N.html
#                                       -- the landing hero's terminal pane,
#                                          one directory per switchable
#                                          example, each rendered through
#                                          Raxol.Headless as its own interval
#                                          subscription advances it
#   web/priv/demo_previews/<slug>.html  -- one rendered frame per playground
#                                          catalog demo, for the gallery cards
#
# Run from the repo root:
#
#   mix run scripts/gen_landing_frames.exs
#
# Frames are committed; rerun when the Counter source or a demo's first
# render changes. A demo that fails to start headless is skipped with a
# warning (its gallery card just renders without a preview).

alias Raxol.LiveView.TerminalBridge

# The module the hero displays. web/'s landing hero (@hero_source in
# landing_components.ex) shows this exact source; keep the two byte-identical
# (the whole point of recording is that the pane and the frames are the same
# program).
defmodule Pulse do
  use Raxol.Core.Runtime.Application

  def init(_), do: %{t: 0}
  def update(:tick, m), do: {%{m | t: m.t + 1}, []}
  def update(_, m), do: {m, []}
  def subscribe(_), do: [subscribe_interval(90, :tick)]

  def view(m) do
    line_chart(series: series(m.t), width: 46, height: 12)
  end

  defp series(t) do
    [
      %{name: "sine", data: wave(t, &:math.sin/1), color: :cyan},
      %{name: "cos", data: wave(t, &:math.cos/1), color: :magenta}
    ]
  end

  defp wave(t, f),
    do: for(i <- 0..29, do: round(50 + 35 * f.((t + i) * 0.2)))
end

defmodule Halo do
  use Raxol.Core.Runtime.Application

  @ramp ["·", ":", "-", "=", "+", "*", "#", "%"]
  @faces ["≡··≡", "≡''≡", "≡oo≡", "≡^^≡"]
  @a 374_761_393
  @b 668_265_263

  def init(_), do: %{t: 0}
  def update(:tick, m), do: {%{m | t: m.t + 1}, []}
  def update(_, m), do: {m, []}
  def subscribe(_), do: [subscribe_interval(110, :tick)]

  def view(m) do
    column do
      for y <- 0..12, do: text(strip(m.t, y), fg: :cyan)
    end
  end

  defp strip(t, y),
    do: for(x <- 0..45, into: "", do: cell(t, x, y))

  defp cell(t, x, 6) when x in 21..24,
    do: String.at(Enum.at(@faces, rem(div(t, 6), 4)), x - 21)

  defp cell(_t, x, y) when abs(y - 6) <= 1 and x in 18..27,
    do: " "

  defp cell(t, x, y) do
    edge = min(1.0, abs(x - 23) / 23 + abs(y - 6) / 6)
    n = rem(abs((x + div(t, 2)) * @a + (y - div(t, 3)) * @b), 9973)
    v = n / 9973 * edge
    if v < 0.2, do: " ", else: Enum.at(@ramp, trunc(v * 7))
  end
end

defmodule GenLandingFrames do
  @hero_dir Path.expand("../web/priv/hero_frames", __DIR__)
  @preview_dir Path.expand("../web/priv/demo_previews", __DIR__)

  @preview_size {60, 14}
  @hero_frames 6
  @hero_settle_ms 400
  @hero_tick_ms 280
  @preview_settle_ms 1600

  def run do
    ensure_headless()
    File.mkdir_p!(@hero_dir)
    File.mkdir_p!(@preview_dir)
    hero()
    previews()
  end

  defp ensure_headless do
    case Raxol.Headless.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  # Each example advances on its own interval subscription rather than on
  # input, so the recorder waits between captures instead of sending keys. The
  # wait is a few ticks long: consecutive frames must differ visibly, or the
  # hero plays what looks like a still image.
  @examples [
    {"pulse", Pulse, {58, 17}},
    {"halo", Halo, {48, 14}}
  ]

  defp hero do
    for {name, module, {w, h}} <- @examples do
      dir = Path.join(@hero_dir, name)
      File.mkdir_p!(dir)

      {:ok, id} =
        Raxol.Headless.start(module, id: :"hero_#{name}", width: w, height: h)

      for n <- 0..(@hero_frames - 1) do
        Process.sleep(if n == 0, do: @hero_settle_ms, else: @hero_tick_ms)

        {:ok, buffer} = Raxol.Headless.get_buffer(id)
        html = TerminalBridge.buffer_to_html(buffer, aria_mode: :application)
        path = Path.join(dir, "frame_#{n}.html")
        File.write!(path, html)
        IO.puts("hero  #{path}")
      end

      Raxol.Headless.stop(id)
    end
  end

  defp previews do
    {w, h} = @preview_size

    for comp <- Raxol.Playground.Catalog.list_components() do
      slug = slug(comp.name)
      id = String.to_atom("preview_#{slug}")

      case safe_start(comp.module, id, w, h) do
        {:ok, id} ->
          # Give subscription-driven demos (charts, dashboards) a tick or
          # two so the preview is not an empty axis.
          Process.sleep(@preview_settle_ms)

          case Raxol.Headless.get_buffer(id) do
            {:ok, buffer} ->
              html =
                TerminalBridge.buffer_to_html(buffer, aria_mode: :application)

              path = Path.join(@preview_dir, "#{slug}.html")
              File.write!(path, html)
              IO.puts("card  #{path}")

            {:error, reason} ->
              IO.puts("SKIP  #{comp.name}: get_buffer #{inspect(reason)}")
          end

          Raxol.Headless.stop(id)

        {:error, reason} ->
          IO.puts("SKIP  #{comp.name}: #{inspect(reason)}")
      end
    end
  end

  defp safe_start(module, id, w, h) do
    case Raxol.Headless.start(module, id: id, width: w, height: h) do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end

GenLandingFrames.run()
