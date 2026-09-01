# Generates the recorded frames raxol.io serves statically:
#
#   web/priv/hero_frames/<example>/frame_NN.html
#                                       -- the landing hero's terminal pane,
#                                          one directory per switchable
#                                          example, each rendered through
#                                          Raxol.Headless as its own interval
#                                          subscription advances it
#   web/priv/hero_frames/<example>/ansi_NN.ansi
#                                       -- the same buffers as the bytes the
#                                          SSH surface writes, one per frame,
#                                          so that pane animates in lockstep
#   web/priv/hero_frames/<example>/interval_ms
#                                       -- the tick the frames were sampled at,
#                                          which is what the page plays back at
#   web/priv/hero_frames/<example>/surface.mcp.json
#                                       -- the frame-zero render as the widget
#                                          tree the MCP surface serves
#   web/priv/demo_previews/<slug>.html  -- one rendered frame per playground
#                                          catalog demo, for the gallery cards
#
# Run from web/, not the repo root:
#
#   cd web && mix run ../scripts/gen_landing_frames.exs
#
# The paths above resolve from __DIR__, so the working directory only decides
# which project's deps are loadable. It has to be web/: `settle` renders the
# real fee schedule and the real USDC deployment table, and raxol_payments is
# a dep of web/ rather than of root raxol (root would fail to compile it).
#
# Frames are committed; rerun when a hero example or a demo's first render
# changes. A demo that fails to start headless is skipped with a warning (its
# gallery card just renders without a preview).

alias Raxol.LiveView.TerminalBridge

# The modules the hero displays. web/'s landing hero (@pulse_source,
# @halo_source, @harness_source and @settle_source in landing_components.ex)
# shows these exact sources; keep each pair byte-identical (the whole point of
# recording is that the pane and the frames are the same program).
defmodule Pulse do
  use Raxol.Core.Runtime.Application

  def init(_), do: %{t: 0}
  def update(:tick, m), do: {%{m | t: m.t + 1}, []}
  def update(_, m), do: {m, []}
  def subscribe(_), do: [subscribe_interval(90, :tick)]

  def view(m) do
    line_chart(series: series(m.t), width: 60, height: 12)
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
    column(do: for(y <- 0..12, do: text(scan(m.t, y), fg: :cyan)))
  end

  defp scan(t, y), do: for(x <- 0..67, into: "", do: cell(t, x, y))

  defp cell(t, x, 6) when x in 32..35,
    do: String.at(Enum.at(@faces, rem(div(t, 6), 4)), x - 32)

  defp cell(_t, x, y) when abs(y - 6) <= 1 and x in 29..38, do: " "

  defp cell(t, x, y) do
    n = rem(abs((x + div(t, 2)) * @a + (y - div(t, 3)) * @b), 9973)
    v = n / 9973 * min(1.0, abs(x - 34) / 34 + abs(y - 6) / 6)
    if v < 0.2, do: " ", else: Enum.at(@ramp, trunc(v * 7))
  end
end

defmodule Harness do
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.ToolCallBlock, as: Tool

  @calls [
    {"read", "router.ex", :done},
    {"edit", "router.ex:42", :running},
    {"shell", "mix test", :pending}
  ]

  def init(_), do: %{t: 0}
  def update(:tick, m), do: {%{m | t: m.t + 1}, []}
  def update(_, m), do: {m, []}
  def subscribe(_), do: [subscribe_interval(120, :tick)]

  def view(m) do
    column style: %{gap: 1} do
      [
        text("raxol code", style: [:bold]),
        column(do: Enum.map(@calls, &call(&1, m.t)))
      ]
    end
  end

  defp call({n, a, s}, t) do
    {:ok, st} = Tool.init(name: n, args: a, status: s, frame: t)
    Tool.render(st, %{})
  end
end

defmodule Settle do
  use Raxol.Core.Runtime.Application

  alias Raxol.Payments.{Assets, Router}
  @route Router.select(cross_chain: true)
  @stables Assets.evm_tokens() |> Map.keys() |> Enum.sort() |> List.delete("WETH")
  @steps [
    {"quote", "Base -> Arbitrum One"},
    {"sign", "EIP-712 intent"},
    {"settle", "0x7f3a9c.. stealth"}
  ]

  def init(_), do: %{t: 0}
  def update(:tick, m), do: {%{m | t: m.t + 1}, []}
  def update(_, m), do: {m, []}
  def subscribe(_), do: [subscribe_interval(400, :tick)]

  def view(m) do
    at = rem(m.t, length(@steps) + 1)

    column style: %{gap: 1} do
      [
        text("USDC 25.00  via #{@route}", style: [:bold]),
        column(do: Enum.with_index(@steps, &step(&1, &2, at))),
        text("stables  " <> Enum.join(@stables, "  "))
      ]
    end
  end

  defp step({name, note}, i, at) when i < at,
    do: text("ok  #{String.pad_trailing(name, 8)}#{note}", fg: :cyan)

  defp step({name, _note}, _i, _at), do: text("    #{name}")
end

defmodule GenLandingFrames do
  @hero_dir Path.expand("../web/priv/hero_frames", __DIR__)
  @preview_dir Path.expand("../web/priv/demo_previews", __DIR__)

  @preview_size {60, 14}
  @hero_settle_ms 400
  @hero_poll_ms 10
  @hero_frame_timeout_ms 1500
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

  # `{name, module, {w, h}, tick_ms, frames}`.
  #
  # The tick is the module's own `subscribe_interval`, and it is what the page
  # plays the recording back at -- written beside the frames so the player does
  # not carry a constant that has to be kept in step with this list by hand.
  #
  # The frame count is chosen so the loop closes where the ANIMATION closes,
  # which is the only thing that stops a recording snapping back in the middle
  # of a motion. Six frames at 850ms was a slideshow; twenty-four was smooth
  # but cut a sine wave off at 76% of its cycle, so it visibly reset.
  #
  #   pulse  wave(t) has period 2*pi/0.2 = 31.416 ticks. 63 frames is two
  #          periods to within 0.17 of a tick -- 5.7s, and the seam lands
  #          inside the rounding.
  #   halo   the face cycles every 24 ticks (four glyphs, six ticks each), so
  #          48 is two full cycles. Its drift field is seeded on absolute t and
  #          never repeats, so nothing divides it; the face is what an eye
  #          tracks, and the field reads as noise either way.
  #   harness
  #          the only thing moving is the spinner on the one running tool, and
  #          `ToolCallBlock` draws it from `Spinner`'s ten-frame table, so ten
  #          frames is exactly one revolution. The statuses are fixed: a turn
  #          that also advanced them would need the status ladder as state, and
  #          the source pane holds thirty lines.
  #   settle three steps of one transfer, one arriving per tick, plus the
  #          empty state they start from: four frames closes the loop exactly.
  #          400ms because a settlement that lands in under a second reads as
  #          a progress bar rather than as three distinct things happening.
  @examples [
    {"pulse", Pulse, {62, 13}, 90, 63},
    {"halo", Halo, {70, 14}, 110, 48},
    {"harness", Harness, {24, 5}, 120, 10},
    {"settle", Settle, {56, 7}, 400, 4}
  ]

  defp hero do
    for {name, module, {w, h}, tick_ms, frame_count} <- @examples do
      dir = Path.join(@hero_dir, name)
      File.mkdir_p!(dir)

      # A shorter run must not leave a longer one's frames behind: the player
      # counts the files it finds, not the number recorded here.
      for stale <- Path.wildcard(Path.join(dir, "frame_*.html")),
          do: File.rm!(stale)

      for stale <- Path.wildcard(Path.join(dir, "ansi_*.ansi")),
          do: File.rm!(stale)

      File.rm(Path.join(dir, "surface.ansi"))

      {:ok, id} =
        Raxol.Headless.start(module, id: :"hero_#{name}", width: w, height: h)

      Process.sleep(@hero_settle_ms)

      Enum.reduce(0..(frame_count - 1), nil, fn n, previous ->
        buffer =
          if n == 0, do: buffer!(id), else: next_distinct!(id, previous, name)

        # Zero-padded: `RecordedFrames` sorts these lexically, so frame_10
        # would otherwise play before frame_2.
        seq = String.pad_leading(to_string(n), 2, "0")

        html = TerminalBridge.buffer_to_html(buffer, aria_mode: :application)
        File.write!(Path.join(dir, "frame_#{seq}.html"), html)

        # The SSH pane paints this same buffer, so it gets the same number of
        # frames and plays in lockstep. It used to be one still projected from
        # frame zero, which read as a broken terminal beside a moving one.
        File.write!(Path.join(dir, "ansi_#{seq}.ansi"), ansi(buffer))

        if n == 0, do: surfaces(dir, module, id)
        buffer
      end)

      IO.puts("hero  #{dir} (#{frame_count} frames @ #{tick_ms}ms)")

      File.write!(Path.join(dir, "interval_ms"), to_string(tick_ms))

      Raxol.Headless.stop(id)
    end
  end

  defp buffer!(id) do
    {:ok, buffer} = Raxol.Headless.get_buffer(id)
    buffer
  end

  # Waits for the frame to actually change rather than sleeping a guessed
  # multiple of the tick. Sleeping exactly one tick races the scheduler and
  # records the same buffer twice; sleeping several skips motion the page then
  # has to play back slowly. Polling gives the tightest sampling that is still
  # guaranteed to advance, which is what the "no identical frames" test in
  # `landing_components_test.exs` asserts from the other side.
  defp next_distinct!(id, previous, name) do
    deadline = System.monotonic_time(:millisecond) + @hero_frame_timeout_ms
    poll_until_changed!(id, previous, deadline, name)
  end

  defp poll_until_changed!(id, previous, deadline, name) do
    Process.sleep(@hero_poll_ms)
    buffer = buffer!(id)

    cond do
      buffer != previous ->
        buffer

      System.monotonic_time(:millisecond) < deadline ->
        poll_until_changed!(id, previous, deadline, name)

      true ->
        raise "#{name} stopped changing within #{@hero_frame_timeout_ms}ms; " <>
                "the hero would play a still image"
    end
  end

  # The hero's non-terminal panes, all projected from the frame-zero buffer the
  # loop just wrote, so the four tabs are four encodings of one frame rather
  # than four separate recordings. The browser pane needs no artifact:
  # frame_0.html is already the LiveView encoding.
  # The ANSI projection moved into the frame loop, since that pane animates
  # now. What is left is the one artifact that does not: an agent's view of the
  # tree, which is a structure rather than a picture and says the same thing in
  # every frame.
  defp surfaces(dir, module, id) do
    mcp_path = Path.join(dir, "surface.mcp.json")
    File.write!(mcp_path, mcp(module, id))
    IO.puts("hero  #{mcp_path}")
  end

  # What the SSH surface writes down the channel. `style_batching: true`
  # matches `Raxol.Core.Runtime.Rendering.Backends`, so these are the bytes a
  # real session emits.
  defp ansi(buffer) do
    buffer
    |> Raxol.Terminal.Renderer.new(%{}, %{}, true)
    |> Raxol.Terminal.Renderer.render()
  end

  # What the MCP surface serves: the structured content behind
  # `raxol_screenshot`, taken from the view tree, which is that tool's input.
  defp mcp(module, id) do
    {:ok, model} = Raxol.Headless.get_model(id)

    model
    |> module.view()
    |> Raxol.MCP.StructuredScreenshot.from_view_tree()
    |> Raxol.MCP.StructuredScreenshot.to_json()
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
