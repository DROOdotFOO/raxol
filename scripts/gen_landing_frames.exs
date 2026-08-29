# Generates the recorded frames raxol.io serves statically:
#
#   web/priv/hero_frames/frame_N.html   -- the landing hero's terminal pane,
#                                          the Counter module driven by real
#                                          keypresses through Raxol.Headless
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

# The module the hero displays. web/'s landing hero (@hero_counter_source in
# landing_components.ex) shows this exact source; keep the two byte-identical
# (the whole point of recording is that the pane and the frames are the same
# program).
defmodule Counter do
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_), do: %{count: 0}

  @impl true
  def update(:inc, m),
    do: {%{m | count: m.count + 1}, []}

  def update(%{data: %{char: "+"}}, m),
    do: update(:inc, m)

  def update(_, m), do: {m, []}

  @impl true
  def view(m) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Count: #{m.count}", style: [:bold]),
        button("+", on_click: :inc)
      ]
    end
  end
end

defmodule GenLandingFrames do
  @hero_dir Path.expand("../web/priv/hero_frames", __DIR__)
  @preview_dir Path.expand("../web/priv/demo_previews", __DIR__)

  @hero_size {44, 12}
  @preview_size {60, 14}
  @hero_frames 4
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

  defp hero do
    {w, h} = @hero_size

    {:ok, id} =
      Raxol.Headless.start(Counter, id: :hero_rec, width: w, height: h)

    for n <- 0..(@hero_frames - 1) do
      if n > 0 do
        :ok = Raxol.Headless.send_key(id, "+")
        Process.sleep(80)
      end

      {:ok, buffer} = Raxol.Headless.get_buffer(id)
      html = TerminalBridge.buffer_to_html(buffer, aria_mode: :application)
      path = Path.join(@hero_dir, "frame_#{n}.html")
      File.write!(path, html)
      IO.puts("hero  #{path}")
    end

    Raxol.Headless.stop(id)
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
