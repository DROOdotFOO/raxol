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
  alias Raxol.UI.Components.Harness.AxolFace

  @ramp ["·", ":", "-", "=", "+", "*", "#", "%"]
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
    do: String.at(AxolFace.glyph(:thinking, div(t, 6)), x - 32)

  defp cell(_t, x, y) when abs(y - 6) <= 1 and x in 29..38, do: " "

  defp cell(t, x, y) do
    n = rem(abs((x + div(t, 2)) * @a + (y - div(t, 3)) * @b), 9973)
    v = n / 9973 * min(1.0, abs(x - 34) / 34 + abs(y - 6) / 6)
    if v < 0.2, do: " ", else: Enum.at(@ramp, trunc(v * 7))
  end
end

defmodule Harness do
  use Raxol.Core.Runtime.Application
  alias Raxol.UI.Components.Harness.ToolCallBlock, as: T
  @calls [
    {"read", "spend_gate.ex"},
    {"edit", "spend_gate.ex:42"},
    {"shell", "mix test"}
  ]
  @ladder [0, 0, 1, 1, 1, 1, 1, 2, 2, 3]
  def init(_), do: %{t: 0}
  def update(:tick, m), do: {%{m | t: m.t + 1}, []}
  def update(_, m), do: {m, []}
  def subscribe(_), do: [subscribe_interval(200, :tick)]
  def view(m) do
    at = Enum.at(@ladder, rem(m.t, length(@ladder)))
    column style: %{gap: 1} do
      [
        text("virtuals acp  bugfix  40.00 USDC", fg: :cyan),
        column(do: Enum.with_index(@calls, &call(&1, &2, at, m.t)))
      ]
    end
  end
  defp call({n, a}, i, x, t) do
    {:ok, s} = T.init(name: n, args: a, status: st(i, x), frame: t)
    T.render(s, %{})
  end
  defp st(i, x) when i < x, do: :done
  defp st(i, i), do: :running
  defp st(_, _), do: :pending
end

defmodule Settle do
  use Raxol.Core.Runtime.Application
  alias Raxol.Payments.{Assets, Router}
  @route Router.select(cross_chain: true)
  @tokens Assets.evm_tokens() |> Map.keys() |> Enum.sort()
  @stables Enum.reject(@tokens, &(&1 == "WETH"))
  @steps [
    {"quote", "Base -> Arbitrum One"},
    {"sign", "EIP-712 intent"},
    {"settle", "0x7f3a9c.. stealth"}
  ]
  def init(_), do: %{t: 0}
  def update(:tick, m), do: {%{m | t: m.t + 1}, []}
  def update(_, m), do: {m, []}
  def subscribe(_), do: [subscribe_interval(200, :tick)]
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

  defp step({n, note}, i, at) when i < at,
    do: text("ok  #{String.pad_trailing(n, 8)}#{note}", fg: :cyan)
  defp step({n, _note}, _i, _at), do: text("    #{n}")
end

defmodule GenLandingFrames do
  @hero_dir Path.expand("../web/priv/hero_frames", __DIR__)
  @preview_dir Path.expand("../web/priv/demo_previews", __DIR__)

  @preview_size {60, 14}
  @hero_poll_ms 10
  @hero_frame_timeout_ms 1500

  # Sampling is pinned to demo state, never to a wall clock.
  #
  # Both settles used to be `Process.sleep/1` -- 400ms for the hero, 1600ms per
  # card -- which records whichever tick happened to land inside that window.
  # Rerunning the script then rewrote animated artifacts with a different frame
  # and produced a diff that had nothing to do with any source change, so the
  # artifacts could not be checked for drift: a real staleness was
  # indistinguishable from scheduler noise.
  #
  # The hero pins frame zero to the demo's own tick (see `baseline!/2`), then
  # chains later frames off the engine's own render order.
  
  #
  # The tick frame zero is taken at. Not zero: the first couple of renders of a
  # chart are a half-drawn axis, and the hero should open on a real picture.
  @hero_start_tick 4

  # The catalog previews have no tick counter to pin to -- they are arbitrary
  # demos -- so they advance a fixed number of distinct frames instead. Static
  # demos stop on the first step and keep their initial render.
  @preview_settle_frames 8

  # Per STEP, not per demo. The slowest demo tick in the catalog is 500ms, so
  # 700ms is a generous "it did not move"; the first step to hit it stops the
  # advance, so a static card costs one timeout rather than eight.
  @preview_step_timeout_ms 700

  # What cannot be reproduced, named rather than quietly tolerated, so that
  # "the artifacts drifted" stays a real signal for everything else. Two
  # consecutive runs of this script differ in exactly these and nothing else:
  #
  #   beam_dashboard        renders the LIVE VM -- process and atom counts,
  #                         memory, uptime. Reproducing it would mean not
  #                         showing the thing it exists to show.
  #   heatmap               fills its grid from `:rand.uniform/0` in `init/1`.
  #                         The demo runs in its own process, so seeding from
  #                         here does nothing, and seeding it properly means
  #                         changing the demo to suit the recorder.
  #   harness/surface.mcp   `Harness.Ids.generate/1` builds element ids from
  #                         `:erlang.unique_integer/1`, which is VM-global, so
  #                         the committed tree carries ids ("tool-call-3657")
  #                         that no agent will ever see again. Worth fixing at
  #                         the component rather than papering over here.
  #
  # `--check` skips exactly this list.
  @nondeterministic ~w(beam_dashboard heatmap)

  def run do
    ensure_headless()
    File.mkdir_p!(@hero_dir)
    File.mkdir_p!(@preview_dir)
    hero()
    previews()
  end

  @doc """
  Re-record into a scratch directory and diff against what is committed.

  This is the reason the settles are counted rather than slept: a generator
  whose output moves on its own can never answer "are these artifacts stale?",
  because every run reports drift. Now a difference means a source change that
  was not re-recorded, which is a real thing to fail a build on.

  The demos in `@nondeterministic` are skipped by name and reported, so the
  exemption is visible in the output rather than buried here.
  """
  def check do
    ensure_headless()
    scratch = Path.join(System.tmp_dir!(), "raxol_frames_check")
    File.rm_rf!(scratch)
    File.mkdir_p!(scratch)

    previews(scratch)

    {drifted, skipped} =
      Path.wildcard(Path.join(scratch, "*.html"))
      |> Enum.reduce({[], []}, fn fresh, {drift, skip} ->
        slug = Path.basename(fresh, ".html")
        committed = Path.join(@preview_dir, "#{slug}.html")

        cond do
          slug in @nondeterministic -> {drift, [slug | skip]}
          not File.exists?(committed) -> {[slug <> " (missing)" | drift], skip}
          File.read!(fresh) == File.read!(committed) -> {drift, skip}
          true -> {[slug | drift], skip}
        end
      end)

    File.rm_rf!(scratch)

    if skipped != [],
      do: IO.puts("skipped (renders live VM state): #{Enum.join(skipped, ", ")}")

    case drifted do
      [] ->
        IO.puts("previews up to date")
        :ok

      names ->
        IO.puts("STALE, re-record with `mix run ../scripts/gen_landing_frames.exs`:")
        Enum.each(names, &IO.puts("  #{&1}"))
        System.halt(1)
    end
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
  #          `@ladder` is the dwell, one entry per frame, so the ten frames it
  #          holds are the loop. The dwell is uneven on purpose: `edit` sits
  #          for five of them because it is the call a reader wants to watch,
  #          and one call per tick went by too fast to follow. All-done gets a
  #          single frame -- it is the one state with no spinner, so a second
  #          frame of it would be identical to the first.
  #   settle three steps of one transfer plus the empty state they start
  #          from: four states, one per tick, so four frames closes the loop
  #          and no two repeat. A step every OTHER tick reads better but
  #          records each frame twice, and identical frames are what
  #          "recorded identical frames" refuses.
  @examples [
    {"pulse", Pulse, {62, 13}, 90, 63},
    {"halo", Halo, {70, 14}, 110, 48},
    {"harness", Harness, {36, 5}, 200, 10},
    {"settle", Settle, {56, 7}, 200, 4}
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

      # Frame zero waits for the demo's own tick rather than for a wall clock,
      # then every later frame chains off the previous DISTINCT render. The
      # chain is what makes the sequence reproducible: it follows the engine's
      # render order instead of asking the dispatcher what tick it is on, and
      # those two disagree -- `get_buffer` renders the engine's model, which
      # trails the dispatcher's by up to a tick, so pinning each frame to a
      # dispatcher tick paired tick N's number with tick N-1's picture and the
      # back half of the pulse recording churned.
      Enum.reduce(0..(frame_count - 1), nil, fn n, previous ->
        buffer =
          if n == 0,
            do: baseline!(id, @hero_start_tick),
            else: next_distinct!(id, previous, name)

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

  # Frame zero: wait for the demo to reach its own tick `t`, then take the
  # engine's next render. The wait pins the phase (a `Process.sleep(400)` here
  # was the original churn: it recorded whichever tick the scheduler reached),
  # and taking the following distinct render lets the engine catch up to the
  # model before the sequence starts.
  defp baseline!(id, t) do
    deadline = System.monotonic_time(:millisecond) + @hero_frame_timeout_ms
    wait_for_tick!(id, t, deadline)
    buffer = buffer!(id)
    next_distinct!(id, buffer, "baseline")
  end

  defp wait_for_tick!(id, t, deadline) do
    {:ok, model} = Raxol.Headless.get_model(id)

    cond do
      model.t >= t ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(@hero_poll_ms)
        wait_for_tick!(id, t, deadline)

      true ->
        raise "demo never reached tick #{t}"
    end
  end

  # Waits for the render to actually change rather than sleeping a guessed
  # multiple of the tick. Sleeping exactly one tick races the scheduler and
  # records the same buffer twice; sleeping several skips motion the page then
  # has to play back slowly.
  defp next_distinct!(id, previous, name) do
    deadline = System.monotonic_time(:millisecond) + @hero_frame_timeout_ms

    case poll_changed(id, previous, deadline) do
      {:ok, buffer} ->
        buffer

      :static ->
        raise "#{name} stopped changing within #{@hero_frame_timeout_ms}ms; " <>
                "the hero would play a still image"
    end
  end

  # Step forward exactly `n` DISTINCT frames, or stop early if the demo is
  # static. Used for the catalog previews, which are arbitrary demos with no
  # tick counter to pin to. Most of them are static and stop on the first step;
  # the ones that animate land on the nth change, which is stable for anything
  # driven by its own state.
  #
  # Unlike `wait_for_tick!/3` this does not raise on a demo that stops moving:
  # a card that never animates is a correct recording, not a failure.
  # Halts on the first step that times out. Most of the catalog is static, and
  # continuing to wait out the full timeout seven more times for a demo that
  # has already proved it does not move turned a 41-card pass into eight
  # minutes of sleeping.
  defp advance!(id, n) do
    Enum.reduce_while(1..n, buffer!(id), fn _step, previous ->
      deadline = System.monotonic_time(:millisecond) + @preview_step_timeout_ms

      case poll_changed(id, previous, deadline) do
        {:ok, buffer} -> {:cont, buffer}
        :static -> {:halt, previous}
      end
    end)
  end

  defp poll_changed(id, previous, deadline) do
    Process.sleep(@hero_poll_ms)
    buffer = buffer!(id)

    cond do
      buffer != previous -> {:ok, buffer}
      System.monotonic_time(:millisecond) < deadline -> poll_changed(id, previous, deadline)
      true -> :static
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
  # Folded from `init/1` rather than read off the running session. The MCP
  # artifact is the one thing here that does NOT come from a buffer, so it was
  # reading the dispatcher's model -- which is a moving target, and churned on
  # every run even while the frames beside it were stable. These modules are
  # pure, so the model at tick `t` is a fold and nothing has to be sampled.
  defp mcp(module, _id) do
    model =
      Enum.reduce(1..@hero_start_tick, module.init(nil), fn _tick, m ->
        {m, _cmds} = module.update(:tick, m)
        m
      end)

    model
    |> module.view()
    |> Raxol.MCP.StructuredScreenshot.from_view_tree()
    |> Raxol.MCP.StructuredScreenshot.to_json()
  end

  defp previews(dir \\ @preview_dir) do
    {w, h} = @preview_size

    for comp <- Raxol.Playground.Catalog.list_components() do
      slug = slug(comp.name)
      id = String.to_atom("preview_#{slug}")

      case safe_start(comp.module, id, w, h) do
        {:ok, id} ->
          # Counted, not slept: subscription-driven demos (charts, dashboards)
          # still get several ticks so the preview is not an empty axis, but
          # WHICH tick is now a property of the script rather than of how busy
          # the machine was. Static demos time out on the first step and keep
          # their initial frame.
          advance!(id, @preview_settle_frames)

          case Raxol.Headless.get_buffer(id) do
            {:ok, buffer} ->
              html =
                TerminalBridge.buffer_to_html(buffer, aria_mode: :application)

              path = Path.join(dir, "#{slug}.html")
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

# `--check` re-records to a scratch dir and diffs; anything else records.
case System.argv() do
  ["--check"] -> GenLandingFrames.check()
  _ -> GenLandingFrames.run()
end
