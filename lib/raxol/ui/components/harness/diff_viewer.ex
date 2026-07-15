defmodule Raxol.UI.Components.Harness.DiffViewer do
  @moduledoc """
  Pre-apply file diff viewer.

  Renders the line-based diff between a file's current content (`old`) and
  a proposed edit (`new`) BEFORE the edit is applied. This is the
  "pre-apply confirmation over post-hoc undo" surface described in
  `docs/proposals/in-flight/harness-spec-frontend.md`: framing always
  reads as "this WILL change" -- a "Proposed change" header and a "Not yet
  applied" caption, never past tense.

  ## Visual language

  Ports the Pierre (`@pierre/diffs`) visual language --
  `docs/proposals/in-flight/pierre-diffs-analysis.md` -- flattened for a
  terminal cell grid (one bg + one fg per cell, no alpha compositing):

    * **Diff paints background only; syntax tokens own foreground and are
      never overridden.** Added rows get a dark-green bg wash, removed
      rows dark-red, with a brighter "emphasis" bg tier on the
      word-level-changed sub-ranges of a paired change row -- syntax
      colors show through both tiers unchanged.
    * A `▌` gutter bar (green/red) replaces the classic `+`/`-` text
      marker, per Pierre's `bars` indicator style.
    * Long unchanged runs (> `2 * context + 1` lines) fold into a single
      dim "N unchanged lines" pill row; `context: :all` disables folding.
    * Split mode fills the unpaired side of a change block with a dim
      `╱` hatch instead of blank space.

  Line differencing is computed by `Raxol.UI.Components.Harness.LineDiff`
  (a plain LCS line diff). Intra-line word ranges come from
  `Raxol.UI.Components.Harness.WordDiff` (positional deletion/addition
  pairing within a changed hunk, word-level LCS, `word-alt` span
  merging). Syntax tokens come from `Raxol.UI.SyntaxHighlighter`
  (Makeup-based; `language: nil` skips highlighting entirely).

  ## Props

    * `:path` - file path shown in the header (default `""`).
    * `:old` - original file content (default `""`).
    * `:new` - proposed file content (default `""`).
    * `:mode` - `:auto` (default), `:unified`, or `:split`. In `:auto`,
      split is chosen when both rendered panes fit side by side in the
      available width, otherwise unified. Width comes from the `:width`
      prop, else from the render context (`:available_width, `:width`,
      or `dimensions.width`); with no width information auto falls back
      to unified (the safe narrow default).
    * `:width` - available width in terminal columns, used only by
      `:auto` (default `nil`).
    * `:language` - source language for syntax highlighting (e.g.
      `"elixir"`), passed to `Raxol.UI.SyntaxHighlighter.highlight_lines/3`.
      `nil` (default) disables highlighting -- lines render as plain
      diff-tinted text.
    * `:syntax_theme` - Makeup style atom (e.g. `:one_dark`, `:dracula`)
      or a `%Makeup.Styles.HTML.Style{}`, passed through to the
      highlighter (default `:one_dark`). Distinct from the `:theme` prop
      below, which is the Raxol UI theme override map, not a code theme.
    * `:context` - number of unchanged lines kept visible at each edge of
      a folded hunk, or `:all` to disable folding entirely (default `3`).
    * `:id`, `:style`, `:theme` - standard component props.

  ## Example

      {:ok, state} =
        DiffViewer.init(
          path: "lib/orders/total.ex",
          old: old_text,
          new: new_text,
          language: "elixir"
        )

      DiffViewer.render(state, %{})
  """
  use Raxol.UI.Components.Base.Component

  alias Raxol.UI.Components.Harness.LineDiff
  alias Raxol.UI.Components.Harness.WordDiff
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.SyntaxHighlighter
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  @type mode :: :unified | :split | :auto
  @type fold_context :: non_neg_integer() | :all

  @type t :: %{
          id: String.t() | atom(),
          path: String.t(),
          old: String.t(),
          new: String.t(),
          mode: mode(),
          width: pos_integer() | nil,
          language: String.t() | nil,
          syntax_theme: atom() | struct(),
          context: fold_context(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "diff-viewer-#{:erlang.unique_integer([:positive])}"
        ),
      path: Keyword.get(props, :path, ""),
      old: Keyword.get(props, :old, ""),
      new: Keyword.get(props, :new, ""),
      mode: normalize_mode(Keyword.get(props, :mode, :auto)),
      width: Keyword.get(props, :width),
      language: Keyword.get(props, :language),
      syntax_theme: Keyword.get(props, :syntax_theme, :one_dark),
      context: normalize_context(Keyword.get(props, :context, 3)),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  defp normalize_mode(:split), do: :split
  defp normalize_mode(:unified), do: :unified
  defp normalize_mode(_other), do: :auto

  defp normalize_context(:all), do: :all
  defp normalize_context(n) when is_integer(n) and n >= 0, do: n
  defp normalize_context(_other), do: 3

  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_diff_viewer)

    ops = LineDiff.diff(state.old, state.new)
    {added, removed} = count_changes(ops)
    gutter_width = gutter_width_for(ops)

    body =
      case resolve_mode(state, context, ops, gutter_width) do
        :split ->
          render_split(build_render_context(state, ops, gutter_width))

        :unified ->
          render_unified(build_render_context(state, ops, gutter_width))
      end

    %{
      type: :column,
      style: base_style,
      gap: 0,
      children: [header(state, added, removed), Components.divider() | body]
    }
  end

  @doc """
  The mode `render/2` will actually use for this state and context.

  Resolves `:auto` against the available width: `:split` when both panes
  fit side by side, `:unified` otherwise (including when no width is
  known). Explicit `:unified`/`:split` pass through unchanged. Exposed so
  demos and callers can display or act on the auto decision.
  """
  @spec effective_mode(t(), map()) :: :unified | :split
  def effective_mode(state, context) do
    ops = LineDiff.diff(state.old, state.new)
    resolve_mode(state, context, ops, gutter_width_for(ops))
  end

  defp resolve_mode(%{mode: :auto} = state, context, ops, gutter_width) do
    width = state.width || context_width(context)

    if is_integer(width) and split_fits?(ops, gutter_width, width) do
      :split
    else
      :unified
    end
  end

  defp resolve_mode(%{mode: mode}, _context, _ops, _gutter_width), do: mode

  defp context_width(%{available_width: w}) when is_integer(w) and w > 0,
    do: w

  defp context_width(%{width: w}) when is_integer(w) and w > 0, do: w

  defp context_width(%{dimensions: %{width: w}})
       when is_integer(w) and w > 0,
       do: w

  defp context_width(_context), do: nil

  # A split pane renders: gutter (bar glyph + numbers), gap(1), the line,
  # inside a :single-border box with padding 1 (border 2 + padding 2 = 4
  # chrome, + 1 row gap between gutter and content = 5). The `+`/`-` text
  # marker that used to sit in the content is gone -- it's the 1-column
  # gutter bar now, counted separately as `@bar_width` so it composes
  # cleanly with `gutter_width_for/1`. Two panes sit in a row with gap 2.
  @pane_chrome 5
  @bar_width 1
  @pane_gap 2

  defp split_fits?(ops, gutter_width, width) do
    {old_max, new_max} = max_line_widths(ops)

    pane_width = fn line_width ->
      gutter_width + @bar_width + @pane_chrome + line_width
    end

    pane_width.(old_max) + @pane_gap + pane_width.(new_max) <= width
  end

  # Widest line per side, floored at the "OLD"/"NEW" pane header width.
  defp max_line_widths(ops) do
    header_width = TextMeasure.display_width("OLD")

    Enum.reduce(ops, {header_width, header_width}, fn
      {:delete, line}, {old_max, new_max} ->
        {max(old_max, TextMeasure.display_width(line)), new_max}

      {:insert, line}, {old_max, new_max} ->
        {old_max, max(new_max, TextMeasure.display_width(line))}

      {:equal, line}, {old_max, new_max} ->
        width = TextMeasure.display_width(line)
        {max(old_max, width), max(new_max, width)}
    end)
  end

  # -- Header: framing reads "will change", never "changed" --

  defp header(state, added, removed) do
    Components.column(
      gap: 0,
      children: [
        Components.row(
          gap: 1,
          children: [
            Components.text(content: "Proposed change", style: %{bold: true}),
            Components.text(
              content: state.path,
              style: %{bold: true, fg: :cyan}
            ),
            Components.text(content: "+#{added}", style: %{fg: :green}),
            Components.text(content: "-#{removed}", style: %{fg: :red})
          ]
        ),
        Components.text(
          content: "Not yet applied — review before confirming",
          style: %{fg: :dim}
        )
      ]
    )
  end

  defp count_changes(ops) do
    Enum.reduce(ops, {0, 0}, fn
      {:insert, _line}, {added, removed} -> {added + 1, removed}
      {:delete, _line}, {added, removed} -> {added, removed + 1}
      {:equal, _line}, acc -> acc
    end)
  end

  # -- Diff palette ---------------------------------------------------------
  # Pre-flattened opaque bg/fg tiers approximating Pierre's layered
  # translucent backgrounds (pierre-diffs-analysis.md §2.2-2.3) against a
  # dark terminal background: a row wash, a brighter intra-line-emphasis
  # tier on top of it, and a weaker gutter tint. Terminal cells give one
  # bg + one fg per cell, so the translucency is flattened to these
  # discrete tiers rather than composited. TODO: consolidate with the
  # project-wide palette inventory at
  # docs/proposals/in-flight/palette-inventory.md once it exists.
  @diff_palette %{
    add_base: "#5ECC71",
    add_row_bg: "#12261B",
    add_emphasis_bg: "#1D4428",
    add_gutter_bg: "#0F1D16",
    del_base: "#FF6762",
    del_row_bg: "#291418",
    del_emphasis_bg: "#552527",
    del_gutter_bg: "#200F12",
    separator_bg: "#1A1D21"
  }

  defp add_base, do: @diff_palette.add_base
  defp add_row_bg, do: @diff_palette.add_row_bg
  defp add_emphasis_bg, do: @diff_palette.add_emphasis_bg
  defp add_gutter_bg, do: @diff_palette.add_gutter_bg
  defp del_base, do: @diff_palette.del_base
  defp del_row_bg, do: @diff_palette.del_row_bg
  defp del_emphasis_bg, do: @diff_palette.del_emphasis_bg
  defp del_gutter_bg, do: @diff_palette.del_gutter_bg
  defp separator_bg, do: @diff_palette.separator_bg

  # -- Render context: precomputed per-render inputs shared by both modes --

  defp build_render_context(state, ops, gutter_width) do
    {old_line_width, new_line_width} = max_line_widths(ops)

    %{
      ops_with_ranges: annotate_word_ranges(ops),
      gutter_width: gutter_width,
      old_lines: highlight(state.old, state.language, state.syntax_theme),
      new_lines: highlight(state.new, state.language, state.syntax_theme),
      old_line_width: old_line_width,
      new_line_width: new_line_width,
      context: state.context
    }
  end

  defp highlight(text, language, theme) do
    text
    |> SyntaxHighlighter.highlight_lines(language, theme)
    |> List.to_tuple()
  end

  defp tokens_at(lines_tuple, no, _fallback_line)
       when is_integer(no) and no >= 1 and no <= tuple_size(lines_tuple) do
    elem(lines_tuple, no - 1)
  end

  defp tokens_at(_lines_tuple, _no, fallback_line),
    do: [%{text: fallback_line, fg: nil, styles: []}]

  # -- Intra-line word ranges, computed once per change block ---------------
  #
  # Pairs the i-th deletion of a changed hunk with its i-th addition
  # (positional, per pierre-diffs-analysis.md §1.3) and runs WordDiff over
  # each pair. Returns `[{op, ranges}]` aligned 1:1 with `ops`, where
  # `ranges` is `[]` for :equal ops and for any :delete/:insert beyond the
  # paired count.

  defp annotate_word_ranges(ops) do
    ops
    |> Enum.chunk_by(fn {kind, _line} ->
      if kind == :equal, do: :equal, else: :change
    end)
    |> Enum.flat_map(&word_ranges_for_run/1)
  end

  defp word_ranges_for_run([{:equal, _line} | _] = run) do
    Enum.map(run, fn op -> {op, []} end)
  end

  defp word_ranges_for_run(run) do
    deletes = for {:delete, line} <- run, do: line
    inserts = for {:insert, line} <- run, do: line
    pair_count = min(length(deletes), length(inserts))

    delete_entries =
      deletes
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        {{:delete, line}, delete_ranges(idx, pair_count, line, inserts)}
      end)

    insert_entries =
      inserts
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        {{:insert, line}, insert_ranges(idx, pair_count, deletes, line)}
      end)

    delete_entries ++ insert_entries
  end

  defp delete_ranges(idx, pair_count, _line, _inserts) when idx >= pair_count,
    do: []

  defp delete_ranges(idx, _pair_count, line, inserts) do
    {ranges, _new_ranges} = WordDiff.word_ranges(line, Enum.at(inserts, idx))
    ranges
  end

  defp insert_ranges(idx, pair_count, _deletes, _line) when idx >= pair_count,
    do: []

  defp insert_ranges(idx, _pair_count, deletes, line) do
    {_old_ranges, ranges} = WordDiff.word_ranges(Enum.at(deletes, idx), line)
    ranges
  end

  # -- Hunk folding -----------------------------------------------------------
  #
  # Collapses a run of consecutive unchanged (context) rows longer than
  # `2 * context + 1` down to `context` head rows, a single `{:fold,
  # count}` marker, and `context` tail rows. Runs on the already-annotated
  # (line-numbered) row lists for unified/split, so line numbers on the
  # surviving rows are untouched -- folding only removes rows, it never
  # renumbers. `context: :all` disables folding.

  defp fold_rows(rows, :all, _classify), do: rows

  defp fold_rows(rows, context, classify) when is_integer(context) do
    rows
    |> Enum.chunk_by(classify)
    |> Enum.flat_map(&fold_chunk(&1, context, classify))
  end

  defp fold_chunk(chunk, context, classify) do
    if classify.(hd(chunk)) == :context and length(chunk) > 2 * context + 1 do
      {head, rest} = Enum.split(chunk, context)
      {_hidden, tail} = Enum.split(rest, length(rest) - context)
      hidden_count = length(chunk) - 2 * context
      head ++ [{:fold, hidden_count}] ++ tail
    else
      chunk
    end
  end

  defp fold_text(count) do
    plural = if count == 1, do: "", else: "s"
    "───── ⋯ #{count} unchanged line#{plural} ⋯ ─────"
  end

  # -- Unified mode: one column, gutter bar + numbers, spans inline --

  defp render_unified(ctx) do
    ctx.ops_with_ranges
    |> annotate()
    |> fold_rows(ctx.context, &unified_classify/1)
    |> Enum.map(&unified_line(&1, ctx))
  end

  defp unified_classify(row),
    do: if(elem(row, 0) == :equal, do: :context, else: :change)

  defp annotate(ops_with_ranges) do
    {rows, _old_no, _new_no} =
      Enum.reduce(ops_with_ranges, {[], 1, 1}, &annotate_op/2)

    Enum.reverse(rows)
  end

  defp annotate_op({{:equal, line}, ranges}, {acc, old_no, new_no}) do
    row = {:equal, line, ranges, old_no, new_no}
    {[row | acc], old_no + 1, new_no + 1}
  end

  defp annotate_op({{:delete, line}, ranges}, {acc, old_no, new_no}) do
    row = {:delete, line, ranges, old_no, nil}
    {[row | acc], old_no + 1, new_no}
  end

  defp annotate_op({{:insert, line}, ranges}, {acc, old_no, new_no}) do
    row = {:insert, line, ranges, nil, new_no}
    {[row | acc], old_no, new_no + 1}
  end

  defp unified_line({:fold, count}, ctx) do
    fold_row(2 * ctx.gutter_width + 2, count)
  end

  defp unified_line({:equal, line, _ranges, old_no, new_no}, ctx) do
    gutter = unified_gutter(" ", old_no, new_no, ctx.gutter_width, :dim, nil)
    content = content_spans(:equal, line, [], old_no, ctx)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp unified_line({:delete, line, ranges, old_no, _new_no}, ctx) do
    gutter =
      unified_gutter(
        "▌",
        old_no,
        nil,
        ctx.gutter_width,
        del_base(),
        del_gutter_bg()
      )

    content = content_spans(:delete, line, ranges, old_no, ctx)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp unified_line({:insert, line, ranges, _old_no, new_no}, ctx) do
    gutter =
      unified_gutter(
        "▌",
        nil,
        new_no,
        ctx.gutter_width,
        add_base(),
        add_gutter_bg()
      )

    content = content_spans(:insert, line, ranges, new_no, ctx)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp unified_gutter(bar, old_no, new_no, width, fg, bg) do
    text = bar <> pad(old_no, width) <> " " <> pad(new_no, width)
    Components.text(content: text, style: gutter_style(fg, bg))
  end

  defp gutter_style(fg, nil), do: %{fg: fg}
  defp gutter_style(fg, bg), do: %{fg: fg, bg: bg}

  # -- Split mode: old | new side by side, hatch filler for unmatched lines --

  defp render_split(ctx) do
    pairs =
      ctx.ops_with_ranges
      |> pair_rows()
      |> annotate_pairs()
      |> fold_rows(ctx.context, &split_classify/1)

    old_side =
      Components.column(
        gap: 0,
        children: [
          Components.text(content: "OLD", style: %{bold: true, fg: :red})
          | Enum.map(pairs, &split_old_line(&1, ctx))
        ]
      )

    new_side =
      Components.column(
        gap: 0,
        children: [
          Components.text(content: "NEW", style: %{bold: true, fg: :green})
          | Enum.map(pairs, &split_new_line(&1, ctx))
        ]
      )

    [
      Components.row(
        gap: 2,
        children: [
          Components.box(
            style: %{border: :single, padding: 1},
            children: [old_side]
          ),
          Components.box(
            style: %{border: :single, padding: 1},
            children: [new_side]
          )
        ]
      )
    ]
  end

  defp split_classify(row),
    do: if(elem(row, 0) == :equal, do: :context, else: :change)

  # Groups consecutive :equal ops as 1:1 pairs; consecutive :delete/:insert
  # runs (a changed hunk) pair up index-wise so both sides render on the
  # same row, padding the shorter side with `nil` (hatch filler). Carries
  # each side's word-diff ranges through alongside its line.
  defp pair_rows(ops_with_ranges) do
    ops_with_ranges
    |> Enum.chunk_by(fn {{kind, _line}, _ranges} ->
      if kind == :equal, do: :equal, else: :change
    end)
    |> Enum.flat_map(&expand_run/1)
  end

  defp expand_run([{{:equal, _line}, _ranges} | _] = equal_run) do
    Enum.map(equal_run, fn {{:equal, line}, _ranges} ->
      {:equal, line, line, [], []}
    end)
  end

  defp expand_run(change_run) do
    deletes = for {{:delete, line}, ranges} <- change_run, do: {line, ranges}
    inserts = for {{:insert, line}, ranges} <- change_run, do: {line, ranges}
    count = max(length(deletes), length(inserts))

    Enum.map(0..(count - 1), fn idx ->
      {del_line, del_ranges} = Enum.at(deletes, idx, {nil, []})
      {ins_line, ins_ranges} = Enum.at(inserts, idx, {nil, []})
      {:change, del_line, ins_line, del_ranges, ins_ranges}
    end)
  end

  defp annotate_pairs(pairs) do
    {rows, _old_no, _new_no} = Enum.reduce(pairs, {[], 1, 1}, &annotate_pair/2)
    Enum.reverse(rows)
  end

  defp annotate_pair({:equal, old_line, new_line, _, _}, {acc, old_no, new_no}) do
    row = {:equal, old_no, old_line, new_no, new_line, [], []}
    {[row | acc], old_no + 1, new_no + 1}
  end

  defp annotate_pair(
         {:change, nil, new_line, _del_ranges, ins_ranges},
         {acc, old_no, new_no}
       ) do
    row = {:change, nil, nil, new_no, new_line, [], ins_ranges}
    {[row | acc], old_no, new_no + 1}
  end

  defp annotate_pair(
         {:change, old_line, nil, del_ranges, _ins_ranges},
         {acc, old_no, new_no}
       ) do
    row = {:change, old_no, old_line, nil, nil, del_ranges, []}
    {[row | acc], old_no + 1, new_no}
  end

  defp annotate_pair(
         {:change, old_line, new_line, del_ranges, ins_ranges},
         {acc, old_no, new_no}
       ) do
    row = {:change, old_no, old_line, new_no, new_line, del_ranges, ins_ranges}
    {[row | acc], old_no + 1, new_no + 1}
  end

  defp split_old_line({:fold, count}, ctx) do
    fold_row(ctx.gutter_width + 1, count)
  end

  defp split_old_line({:equal, old_no, line, _new_no, _new_line, _, _}, ctx) do
    gutter = split_gutter(" ", old_no, ctx.gutter_width, :dim, nil)
    content = content_spans(:equal, line, [], old_no, ctx)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp split_old_line({:change, nil, nil, _new_no, _new_line, _, _}, ctx) do
    gutter = split_gutter(" ", nil, ctx.gutter_width, :dim, nil)
    content = hatch_row(ctx.old_line_width)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp split_old_line(
         {:change, old_no, line, _new_no, _new_line, del_ranges, _},
         ctx
       ) do
    gutter =
      split_gutter("▌", old_no, ctx.gutter_width, del_base(), del_gutter_bg())

    content = content_spans(:delete, line, del_ranges, old_no, ctx)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp split_new_line({:fold, count}, ctx) do
    fold_row(ctx.gutter_width + 1, count)
  end

  defp split_new_line({:equal, _old_no, _old_line, new_no, line, _, _}, ctx) do
    gutter = split_gutter(" ", new_no, ctx.gutter_width, :dim, nil)
    content = content_spans(:equal, line, [], new_no, ctx)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp split_new_line({:change, _old_no, _old_line, nil, nil, _, _}, ctx) do
    gutter = split_gutter(" ", nil, ctx.gutter_width, :dim, nil)
    content = hatch_row(ctx.new_line_width)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp split_new_line(
         {:change, _old_no, _old_line, new_no, line, _, ins_ranges},
         ctx
       ) do
    gutter =
      split_gutter("▌", new_no, ctx.gutter_width, add_base(), add_gutter_bg())

    content = content_spans(:insert, line, ins_ranges, new_no, ctx)
    Components.row(gap: 1, children: [gutter, content])
  end

  defp split_gutter(bar, no, width, fg, bg) do
    text = bar <> pad(no, width)
    Components.text(content: text, style: gutter_style(fg, bg))
  end

  defp hatch_row(width) do
    text = String.duplicate("╱", max(width, 1))

    Components.row(
      gap: 0,
      children: [Components.text(content: text, style: %{fg: :dim})]
    )
  end

  # -- Fold pill row (shared shape for unified + both split panes) --

  defp fold_row(gutter_span_width, count) do
    Components.row(
      gap: 1,
      children: [
        Components.text(
          content: String.duplicate(" ", gutter_span_width),
          style: %{}
        ),
        Components.text(
          content: fold_text(count),
          style: %{fg: :dim, bg: separator_bg()}
        )
      ]
    )
  end

  # -- Content spans: syntax tokens cut at word-diff range boundaries --
  #
  # Layering rule (pierre-diffs-analysis.md §2.4, THE aesthetic): diff
  # paints background only, syntax tokens own foreground and are never
  # overridden. Each rendered span carries the token's own fg/styles
  # (from SyntaxHighlighter, or a plain fallback fg if unhighlighted) and
  # a bg picked from the diff palette -- the row wash normally, the
  # brighter emphasis tier over any word-diff-changed range.

  defp content_spans(kind, line, ranges, line_no, ctx) do
    tokens = line_tokens(kind, line, line_no, ctx)
    row_bg = row_bg_for(kind)
    emphasis_bg = emphasis_bg_for(kind)
    fallback_fg = fallback_fg_for(kind)

    spans =
      tokens
      |> split_tokens_by_ranges(ranges)
      |> Enum.reject(fn piece -> piece.text == "" end)
      |> Enum.map(fn piece ->
        bg = if piece.changed, do: emphasis_bg, else: row_bg
        fg = piece.fg || fallback_fg

        Components.text(
          content: piece.text,
          style: span_style(fg, bg, piece.styles)
        )
      end)

    spans =
      if spans == [] do
        [
          Components.text(
            content: "",
            style: span_style(fallback_fg, row_bg, [])
          )
        ]
      else
        spans
      end

    Components.row(gap: 0, children: spans)
  end

  defp line_tokens(:delete, line, old_no, ctx),
    do: tokens_at(ctx.old_lines, old_no, line)

  defp line_tokens(:equal, line, old_no, ctx),
    do: tokens_at(ctx.old_lines, old_no, line)

  defp line_tokens(:insert, line, new_no, ctx),
    do: tokens_at(ctx.new_lines, new_no, line)

  defp row_bg_for(:equal), do: nil
  defp row_bg_for(:delete), do: del_row_bg()
  defp row_bg_for(:insert), do: add_row_bg()

  defp emphasis_bg_for(:equal), do: nil
  defp emphasis_bg_for(:delete), do: del_emphasis_bg()
  defp emphasis_bg_for(:insert), do: add_emphasis_bg()

  defp fallback_fg_for(:equal), do: :dim
  defp fallback_fg_for(:delete), do: del_base()
  defp fallback_fg_for(:insert), do: add_base()

  defp span_style(fg, bg, styles) do
    %{}
    |> maybe_put_color(:fg, fg)
    |> maybe_put_color(:bg, bg)
    |> maybe_put_flag(:bold, :bold in styles)
    |> maybe_put_flag(:italic, :italic in styles)
    |> maybe_put_flag(:underline, :underline in styles)
  end

  defp maybe_put_color(map, _key, nil), do: map
  defp maybe_put_color(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_flag(map, _key, false), do: map
  defp maybe_put_flag(map, key, true), do: Map.put(map, key, true)

  # Cuts a line's syntax tokens at intra-line word-diff range boundaries
  # (mirrors Shiki's decoration-based token splitting, per
  # pierre-diffs-analysis.md §1.3: "the token is cloned into
  # before/inside/after pieces"). `ranges` are grapheme offsets into the
  # concatenation of all token texts (see `WordDiff`).
  defp split_tokens_by_ranges(tokens, ranges) do
    sorted_ranges =
      ranges
      |> Enum.map(fn {start, len} -> {start, start + len} end)
      |> Enum.sort()

    {pieces, _offset} =
      Enum.reduce(tokens, {[], 0}, fn token, {acc, offset} ->
        token_len = String.length(token.text)
        token_end = offset + token_len
        cut = cut_token(token, offset, token_end, sorted_ranges)
        {[cut | acc], token_end}
      end)

    pieces |> Enum.reverse() |> List.flatten()
  end

  defp cut_token(token, start, stop, ranges) do
    overlaps =
      ranges
      |> Enum.filter(fn {r_start, r_end} ->
        r_start < stop and r_end > start
      end)
      |> Enum.map(fn {r_start, r_end} ->
        {max(r_start, start), min(r_end, stop)}
      end)

    start
    |> build_segments(stop, overlaps)
    |> Enum.map(fn {seg_start, seg_end, changed?} ->
      local_start = seg_start - start
      local_len = seg_end - seg_start

      %{
        text: String.slice(token.text, local_start, local_len),
        fg: token.fg,
        styles: token.styles,
        changed: changed?
      }
    end)
  end

  defp build_segments(start, stop, []), do: [{start, stop, false}]

  defp build_segments(start, stop, overlaps) do
    {segments, cursor} =
      Enum.reduce(overlaps, {[], start}, fn {o_start, o_end}, {acc, cursor} ->
        acc =
          if o_start > cursor, do: [{cursor, o_start, false} | acc], else: acc

        {[{o_start, o_end, true} | acc], o_end}
      end)

    segments =
      if cursor < stop, do: [{cursor, stop, false} | segments], else: segments

    Enum.reverse(segments)
  end

  # -- Shared gutter/pad helpers --

  defp gutter_width_for(ops) do
    old_total = Enum.count(ops, fn op -> elem(op, 0) != :insert end)
    new_total = Enum.count(ops, fn op -> elem(op, 0) != :delete end)

    [old_total, new_total, 1]
    |> Enum.max()
    |> Integer.to_string()
    |> TextMeasure.display_width()
  end

  defp pad(nil, width), do: String.duplicate(" ", width)
  defp pad(no, width), do: String.pad_leading(Integer.to_string(no), width)
end
