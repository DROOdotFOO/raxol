# =============================================================================
# SPIKE (throwaway) — F0-perf: per-event full-tree render cost under TEA
#
# Spec: docs/proposals/in-flight/harness-tea-migration.md — §6 Phase 0
# "F0-perf spike", §9 risk 3. This harness GATES Phase 3 (U4). It is a
# measurement rig, not production code and not part of any test suite.
#
# Run:
#   RAXOL_SKIP_TERMINAL_INIT=true mix run bench/spikes/f0_tea_perf_spike.exs
#
# What it measures — the REAL pipeline stages, called exactly as
# Raxol.Core.Runtime.Rendering.Engine calls them (engine.ex do_render_frame):
#
#   view/1 construction  -> element tree built through the REAL harness block
#                           Components (BodyProvider.mount -> MessageBlock /
#                           ReasoningBlock / ToolCallBlock(+Result) /
#                           DiffViewer / ApprovalPrompt), i.e. the exact
#                           modules Phase 1 re-hosts
#   Preparer             -> Raxol.UI.Layout.Preparer.prepare_incremental/2
#                           (cold = vs nil, warm = vs previous prepared tree)
#   LayoutEngine         -> Raxol.UI.Layout.Engine.apply_layout/3 at 200x60
#   UIRenderer           -> Raxol.UI.Renderer.render_to_cells/2 (default theme)
#   buffer fill          -> Backends.apply_cells_to_buffer/2 (fresh
#                           ScreenBuffer per frame, the production shape)
#   frame diff/emit      -> Backends.build_terminal_frame/4 (row-level grid
#                           diff, one CUP vocabulary; keyframe vs delta)
#
# Honest approximation notes (the harness app does not exist yet):
#   * The transcript model is 1_000 blocks of mixed kinds sized from the
#     fixture sessions' content classes (prose messages incl. markdown
#     lists/fences, reasoning, tool_call+result, diffs, sparse approvals,
#     opaque markers). Content is deterministic (seeded :rand).
#   * Block elements come from the real Base.Component render fns via
#     BodyProvider.mount/3 — the same view maps ViewText flattens today and
#     the pipeline will host after Phase 1. Blank-row rhythm approximated by
#     an explicit separator text row per block (seal-time separators).
#   * The footer stack (divider/preview/composer_sep/composer/strip/notice)
#     is approximated as styled text rows — fit-law logic is view-time model
#     math (spec §5 law 3) and does not change pipeline stage cost classes.
#   * "Windowed" = the transcript region holds only the tail slice of blocks
#     covering the visible rows, which is what Viewport does at RENDER time
#     (viewport.ex render/2 Enum.slice — windowing happens BEFORE
#     Preparer/Layout; layout-side overflow only clips cells after they are
#     produced, see engine.ex clip stamping + ui_renderer.ex
#     clip_cells_to_bounds).
#   * Excluded: Dispatcher sync casts, plugin transforms (absent in the
#     :harness profile per F0-env), tty IO.write, DEC-2026 bracket bytes.
# =============================================================================

# Debug logging is hot on this path (Buffer.Writer logs per written char);
# leaving it on would measure Logger I/O, not the pipeline.
Logger.configure(level: :error)

defmodule F0Perf.Content do
  @moduledoc false
  # Deterministic fixture content shaped like the harness session fixtures.

  @words ~w(the render pipeline seal frontier stream cadence budget viewport
            anchor diff journal fold projection lane steer composer notice
            grid style batch cursor park frame inset overlay picker panel
            transcript block reveal turn item delta durable ephemeral)

  def seed, do: :rand.seed(:exsss, {1121, 2233, 3345})

  def sentence(n), do: Enum.map_join(1..n, " ", fn _ -> Enum.random(@words) end)

  def paragraph, do: sentence(8 + :rand.uniform(22))

  def markdown_message do
    parts =
      Enum.map(1..(1 + :rand.uniform(2)), fn _ ->
        case :rand.uniform(10) do
          n when n <= 6 ->
            decorate(paragraph())

          n when n <= 8 ->
            Enum.map_join(1..(2 + :rand.uniform(2)), "\n", fn _ ->
              "- " <> sentence(4 + :rand.uniform(6))
            end)

          _ ->
            code =
              Enum.map_join(1..(3 + :rand.uniform(3)), "\n", fn _ ->
                "  " <> sentence(3 + :rand.uniform(4))
              end)

            "```elixir\n" <> code <> "\n```"
        end
      end)

    Enum.join(parts, "\n\n")
  end

  defp decorate(text) do
    case :rand.uniform(4) do
      1 -> String.replace(text, " render ", " **render** ", global: false)
      2 -> String.replace(text, " pipeline ", " `pipeline` ", global: false)
      _ -> text
    end
  end

  def reasoning_text, do: Enum.map_join(1..(1 + :rand.uniform(1)), "\n\n", fn _ -> paragraph() end)

  def tool_output(lines), do: Enum.map_join(1..lines, "\n", fn i -> "#{i}  " <> sentence(4 + :rand.uniform(6)) end)

  def diff_pair(lines) do
    old = Enum.map(1..lines, fn i -> "line #{i} " <> sentence(3 + :rand.uniform(3)) end)

    new =
      Enum.map(old, fn line ->
        if :rand.uniform(4) == 1, do: line <> " (edited)", else: line
      end)

    {Enum.join(old, "\n"), Enum.join(new ++ ["line new " <> sentence(4)], "\n")}
  end

  @doc "One block record: {kind, body, outcome, seal, est_rows}"
  def block(idx) do
    case :rand.uniform(100) do
      n when n <= 34 ->
        text = markdown_message()
        {:message, %{text: text, role: :assistant}, %{}, :sealed, est_rows(text)}

      n when n <= 45 ->
        text = "❯-echo " <> sentence(6 + :rand.uniform(10))
        {:message, %{text: text, role: :user}, %{}, :sealed, est_rows(text)}

      n when n <= 60 ->
        text = reasoning_text()
        {:reasoning, %{text: text}, %{}, :sealed, est_rows(text)}

      n when n <= 85 ->
        with_result = :rand.uniform(10) <= 6
        out_lines = 2 + :rand.uniform(10)

        body = %{
          name: Enum.random(~w(shell read_file edit_file search)),
          args: %{command: "cmd-#{idx} " <> sentence(3)}
        }

        body = if with_result, do: Map.put(body, :result, tool_output(out_lines)), else: body
        exit_code = if :rand.uniform(10) == 1, do: 1, else: 0
        rows = if with_result, do: 2 + out_lines, else: 2
        {:tool_call, body, %{exit_code: exit_code}, :sealed, rows}

      n when n <= 95 ->
        lines = 6 + :rand.uniform(14)
        {old, new} = diff_pair(lines)
        {:diff, %{path: "lib/raxol/file_#{idx}.ex", old: old, new: new}, %{}, :sealed, lines + 4}

      n when n <= 96 ->
        {:approval, %{action: "run " <> sentence(3), blast_radius: %{}, options: [:allow, :deny]}, %{}, :sealed, 8}

      _ ->
        {:opaque, %{text: "· event marker #{idx} (opaque)"}, %{}, :sealed, 1}
    end
  end

  defp est_rows(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line -> max(1, div(String.length(line), 190) + 1) end)
    |> Enum.sum()
  end
end

defmodule F0Perf.Frame do
  @moduledoc false
  # Builds the harness-shaped frame out of the REAL block Components.

  alias Raxol.UI.Components.Harness.BodyProvider

  @width 200
  @height 60
  @content_width 196
  @footer_rows 7
  @transcript_rows @height - @footer_rows

  def dims, do: %{width: @width, height: @height}
  def transcript_rows, do: @transcript_rows

  @doc "Element for one block via the real component render path."
  def block_element({:opaque, %{text: text}, _outcome, _seal, _rows}) do
    %{type: :text, content: text, style: %{fg: :bright_black}}
  end

  def block_element({kind, body, outcome, seal, _rows}) do
    {:ok, view} =
      BodyProvider.mount(kind, body,
        context: %{width: @content_width},
        seal: seal,
        outcome: outcome
      )

    view
  end

  @doc "Blocks -> transcript children with blank-row separators (rhythm law)."
  def transcript_children(block_elements) do
    Enum.flat_map(block_elements, fn el -> [%{type: :text, content: ""}, el] end)
  end

  def footer(draft) do
    [
      %{type: :text, content: String.duplicate("─", @width - 2), style: %{fg: :bright_black}},
      %{type: :text, content: "preview: " <> String.slice(draft, 0, 80), style: %{fg: :bright_black}},
      %{type: :text, content: ""},
      %{type: :text, content: "❯ " <> draft, style: %{style: [:bold]}},
      %{type: :text, content: String.duplicate(" ", 40)},
      %{type: :text, content: " model claude-sonnet-5 · ctx 42% · lane live · main ", style: %{bg: {40, 44, 52}, fg: :white}},
      %{type: :text, content: " notice: spike fixture session ", style: %{fg: :yellow}}
    ]
  end

  @doc """
  Full frame: transcript box (clipped, fixed height) + footer stack.
  `block_elements` — prebuilt element per block (view-construction cost is
  measured separately so stages can be attributed).
  """
  def frame(block_elements, draft) do
    %{
      type: :column,
      gap: 0,
      style: %{},
      children: [
        %{
          type: :box,
          id: "transcript",
          style: %{width: @width, height: @transcript_rows, overflow: :hidden},
          children: [
            %{type: :column, gap: 0, style: %{}, children: transcript_children(block_elements)}
          ]
        }
        | footer(draft)
      ]
    }
  end

  @doc """
  Tail slice of blocks fitting within the transcript rows (what Viewport's
  render-time windowing produces in follow mode). Fits <= rows so the live
  tail's bottom edge stays visible (follow mode shows the bottom; a real
  TranscriptView would part-clip the top block instead — cost-equivalent).
  """
  def window(blocks) do
    {win, _rows} =
      blocks
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn {_k, _b, _o, _s, rows} = block, {acc, sum} ->
        if sum + rows + 1 > @transcript_rows do
          {:halt, {acc, sum}}
        else
          {:cont, {[block | acc], sum + rows + 1}}
        end
      end)

    win
  end
end

defmodule F0Perf.Stats do
  @moduledoc false

  def series(n, fun) do
    Enum.map(1..n, fn _ ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fun)
      us
    end)
  end

  def pct(list, p) do
    sorted = Enum.sort(list)
    Enum.at(sorted, round(p * (length(sorted) - 1)))
  end

  def fmt_us(us) when us >= 1000, do: :io_lib.format("~.2f ms", [us / 1000]) |> to_string()
  def fmt_us(us), do: "#{us} us"

  def row(name, list) do
    :io_lib.format("~-46s n=~2b  p50 ~12s  p95 ~12s  max ~12s", [
      name,
      length(list),
      fmt_us(pct(list, 0.5)),
      fmt_us(pct(list, 0.95)),
      fmt_us(Enum.max(list))
    ])
    |> IO.puts()

    {name, pct(list, 0.5), pct(list, 0.95)}
  end
end

defmodule F0Perf do
  @moduledoc false

  alias F0Perf.{Content, Frame, Stats}
  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Layout.Preparer
  alias Raxol.UI.Renderer, as: UIRenderer

  @blocks 1_000
  @warm_iters 15
  @cold_iters 5

  def run do
    Content.seed()

    theme =
      try do
        Raxol.UI.Theming.Theme.get(Raxol.UI.Theming.Theme.default_theme_id())
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    IO.puts("F0-perf spike — 1k-block transcript at 200x60, theme=#{inspect(theme && Map.get(theme, :id))}")

    # --- model: 1k blocks; the last block is a live streaming message -------
    sealed = Enum.map(1..(@blocks - 1), &Content.block/1)
    tail_text = Content.markdown_message()
    live_tail = {:message, %{text: tail_text, role: :assistant}, %{}, :live, 6}
    model_a = sealed ++ [live_tail]

    # event 1: one new sealed block appended (previous tail seals)
    appended = Content.block(@blocks + 1)
    model_b = model_a ++ [appended]

    # event 2: streaming tail grows by one short line
    grown_tail = {:message, %{text: tail_text <> "\nplus one more streamed line of prose", role: :assistant}, %{}, :live, 7}
    model_c = sealed ++ [grown_tail]

    # --- element caches (sealed-block memoization simulation) ---------------
    elements_a = Enum.map(model_a, &Frame.block_element/1)
    elements_b = Enum.map(model_b, &Frame.block_element/1)
    elements_c = Enum.map(model_c, &Frame.block_element/1)

    win_a = Frame.window(model_a)
    win_b = Frame.window(model_b)
    win_c = Frame.window(model_c)

    # true memo cache for the windowed append event: every win_b block except
    # the appended one is sealed and cache-hits; only `appended` is mounted
    # per event. Precomputed ONCE, outside the timed closures.
    win_b_cached_head = win_b |> Enum.drop(-1) |> Enum.map(&Frame.block_element/1)
    IO.puts("window sizes: a=#{length(win_a)} b=#{length(win_b)} c=#{length(win_c)} blocks (of #{@blocks})")

    draft = "draft reply being typed into the composer"

    build_full = fn model -> Frame.frame(Enum.map(model, &Frame.block_element/1), draft) end
    build_win = fn model -> Frame.frame(Enum.map(Frame.window(model), &Frame.block_element/1), draft) end

    # memoized view: sealed block elements come from cache; only the changed
    # block is re-mounted; footer + frame assembly rebuilt per event.
    build_full_memo = fn cached, changed ->
      Frame.frame(cached ++ [Frame.block_element(changed)], draft)
    end

    va_full = Frame.frame(elements_a, draft)
    vb_full = Frame.frame(elements_b, draft)
    vc_full = Frame.frame(elements_c, draft)
    va_win = Frame.frame(Enum.map(win_a, &Frame.block_element/1), draft)
    vb_win = Frame.frame(Enum.map(win_b, &Frame.block_element/1), draft)
    vc_win = Frame.frame(Enum.map(win_c, &Frame.block_element/1), draft)

    prep_a_full = Preparer.prepare_incremental(va_full, nil)
    prep_b_full = Preparer.prepare_incremental(vb_full, prep_a_full)
    prep_a_win = Preparer.prepare_incremental(va_win, nil)
    prep_b_win = Preparer.prepare_incremental(vb_win, prep_a_win)
    prep_c_win = Preparer.prepare_incremental(vc_win, prep_a_win)

    dims = Frame.dims()
    pos_b_full = LayoutEngine.apply_layout(vb_full, dims, prep_b_full)
    pos_a_win = LayoutEngine.apply_layout(va_win, dims, prep_a_win)
    pos_b_win = LayoutEngine.apply_layout(vb_win, dims, prep_b_win)
    pos_c_win = LayoutEngine.apply_layout(vc_win, dims, prep_c_win)

    cells_b_full = UIRenderer.render_to_cells(pos_b_full, theme)
    cells_a_win = UIRenderer.render_to_cells(pos_a_win, theme)
    cells_b_win = UIRenderer.render_to_cells(pos_b_win, theme)
    cells_c_win = UIRenderer.render_to_cells(pos_c_win, theme)

    bstate = %{width: dims.width, height: dims.height}
    buf_a = Backends.apply_cells_to_buffer(cells_a_win, bstate)
    buf_b = Backends.apply_cells_to_buffer(cells_b_win, bstate)
    buf_c = Backends.apply_cells_to_buffer(cells_c_win, bstate)

    sanity!(cells_a_win, buf_a)

    changed_append = count_changed_rows(buf_a, buf_b)
    changed_tail = count_changed_rows(buf_a, buf_c)

    IO.puts(
      "sizes: full positioned=#{length(pos_b_full)} cells=#{length(cells_b_full)} | " <>
        "win positioned=#{length(pos_b_win)} cells=#{length(cells_b_win)}"
    )

    IO.puts("changed rows: append(scroll)=#{changed_append}/60 tail-growth=#{changed_tail}/60")
    IO.puts(String.duplicate("=", 100))

    # --- stage timings ------------------------------------------------------
    IO.puts("\n-- view construction (element tree build; real component render fns) --")
    Stats.row("view FULL rebuild (1k blocks)", Stats.series(@warm_iters, fn -> build_full.(model_b) end))
    Stats.row("view FULL memo (cache + 1 mount)", Stats.series(@warm_iters, fn -> build_full_memo.(elements_a, appended) end))
    Stats.row("view WIN rebuild (visible slice)", Stats.series(@warm_iters, fn -> build_win.(model_b) end))
    Stats.row("view WIN memo (cache + 1 mount)", Stats.series(@warm_iters, fn -> Frame.frame(win_b_cached_head ++ [Frame.block_element(appended)], draft) end))

    IO.puts("\n-- Preparer (prepare_incremental) --")
    Stats.row("prepare FULL cold (vs nil)", Stats.series(@cold_iters, fn -> Preparer.prepare_incremental(vb_full, nil) end))
    Stats.row("prepare FULL warm append", Stats.series(@warm_iters, fn -> Preparer.prepare_incremental(vb_full, prep_a_full) end))
    Stats.row("prepare FULL warm tail-growth", Stats.series(@warm_iters, fn -> Preparer.prepare_incremental(vc_full, prep_a_full) end))
    Stats.row("prepare WIN cold (vs nil)", Stats.series(@cold_iters, fn -> Preparer.prepare_incremental(vb_win, nil) end))
    Stats.row("prepare WIN warm append", Stats.series(@warm_iters, fn -> Preparer.prepare_incremental(vb_win, prep_a_win) end))
    Stats.row("prepare WIN warm tail-growth", Stats.series(@warm_iters, fn -> Preparer.prepare_incremental(vc_win, prep_a_win) end))

    IO.puts("\n-- LayoutEngine (apply_layout, 200x60) --")
    Stats.row("layout FULL", Stats.series(@cold_iters, fn -> LayoutEngine.apply_layout(vb_full, dims, prep_b_full) end))
    Stats.row("layout WIN", Stats.series(@warm_iters, fn -> LayoutEngine.apply_layout(vb_win, dims, prep_b_win) end))

    IO.puts("\n-- UIRenderer (render_to_cells) --")
    Stats.row("cells FULL", Stats.series(@cold_iters, fn -> UIRenderer.render_to_cells(pos_b_full, theme) end))
    Stats.row("cells WIN", Stats.series(@warm_iters, fn -> UIRenderer.render_to_cells(pos_b_win, theme) end))

    IO.puts("\n-- ScreenBuffer fill + frame emit (row diff) --")
    Stats.row("buffer fill (12k cells)", Stats.series(@warm_iters, fn -> Backends.apply_cells_to_buffer(cells_b_win, bstate) end))
    Stats.row("frame emit keyframe (60 rows)", Stats.series(@warm_iters, fn -> frame_emit(buf_a, buf_b, true) end))
    Stats.row("frame emit append/scroll delta", Stats.series(@warm_iters, fn -> frame_emit(buf_a, buf_b, false) end))
    Stats.row("frame emit tail-growth delta", Stats.series(@warm_iters, fn -> frame_emit(buf_a, buf_c, false) end))

    IO.puts("\n-- end-to-end per event (view -> ... -> frame string) --")

    e2e = fn model, prev_prep, prev_buf, builder ->
      view = builder.(model)
      prep = Preparer.prepare_incremental(view, prev_prep)
      pos = LayoutEngine.apply_layout(view, dims, prep)
      cells = UIRenderer.render_to_cells(pos, theme)
      buf = Backends.apply_cells_to_buffer(cells, bstate)
      frame_emit(prev_buf, buf, prev_buf == nil)
    end

    Stats.row("e2e FULL cold first frame", Stats.series(@cold_iters, fn -> e2e.(model_a, nil, nil, build_full) end))
    Stats.row("e2e FULL warm append (rebuild)", Stats.series(@cold_iters, fn -> e2e.(model_b, prep_a_full, buf_a, build_full) end))
    Stats.row("e2e FULL warm append (memo view)", Stats.series(@cold_iters, fn -> e2e.(model_b, prep_a_full, buf_a, fn _ -> build_full_memo.(elements_a, appended) end) end))
    Stats.row("e2e WIN cold first frame", Stats.series(@warm_iters, fn -> e2e.(model_a, nil, nil, build_win) end))
    Stats.row("e2e WIN warm append (rebuild)", Stats.series(@warm_iters, fn -> e2e.(model_b, prep_a_win, buf_a, build_win) end))
    Stats.row("e2e WIN warm tail-growth (rebuild)", Stats.series(@warm_iters, fn -> e2e.(model_c, prep_a_win, buf_a, build_win) end))

    win_memo_builder = fn _ ->
      Frame.frame(win_b_cached_head ++ [Frame.block_element(appended)], draft)
    end

    Stats.row("e2e WIN warm append (memo view)", Stats.series(@warm_iters, fn -> e2e.(model_b, prep_a_win, buf_a, win_memo_builder) end))

    IO.puts("\ndone.")
  end

  defp frame_emit(prev, next, force) do
    renderer = Raxol.Terminal.Renderer.new(next, %{}, %{}, true)
    prev_or_next = prev || next
    Backends.build_terminal_frame(prev_or_next, next, renderer, %{force_repaint: force})
  end

  defp count_changed_rows(a, b) do
    Enum.count(0..(b.height - 1), fn y -> Enum.at(a.cells, y) != Enum.at(b.cells, y) end)
  end

  defp sanity!(cells, buf) do
    if length(cells) < 500, do: raise("sanity: suspiciously few cells (#{length(cells)}) — tree not rendering")

    row_texts =
      for y <- 0..(buf.height - 1) do
        buf.cells |> Enum.at(y) |> Enum.map_join("", fn c -> c.char || " " end)
      end

    unless Enum.any?(row_texts, &String.contains?(&1, "❯ draft")) do
      raise "sanity: composer row not found in buffer — frame shape broken"
    end
  end
end

F0Perf.run()
