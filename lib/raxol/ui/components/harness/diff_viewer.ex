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
      dim "N unchanged lines" row; `context: :all` disables folding.
    * Split mode is borderless and label-less -- the red/green gutters
      carry the old/new identity -- and the unpaired side of a change
      block stays blank to keep the panes vertically aligned.

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

  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.Components.Harness.LineDiff
  alias Raxol.UI.Components.Harness.WordDiff
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.SyntaxHighlighter
  alias Raxol.UI.TextMeasure
  alias Raxol.UI.Theming.Salience
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
      id: Ids.default_id(props, "diff-viewer"),
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
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_diff_viewer)

    ops = LineDiff.diff(state.old, state.new)
    {added, removed} = count_changes(ops)
    gutter_width = gutter_width_for(ops)

    avail_width = state.width || context_width(context)

    body =
      case resolve_mode(state, context, ops, gutter_width) do
        :split ->
          render_split(
            build_render_context(state, ops, gutter_width, avail_width)
          )

        :unified ->
          render_unified(
            build_render_context(state, ops, gutter_width, avail_width)
          )
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

  # A split pane renders borderless: gutter (bar glyph + numbers), then a
  # 1-column row gap before the line content -- that gap is the only
  # chrome left now that the pane's border box and OLD/NEW header are
  # gone. The `+`/`-` text marker lives in the 1-column gutter bar,
  # counted separately as `@bar_width` so it composes cleanly with
  # `gutter_width_for/1`. Two panes sit in a row with gap 2.
  @pane_chrome 1
  @bar_width 1
  @pane_gap 2

  # Auto-fit is percentile-based, not max-based: one 200-char outlier
  # line shouldn't veto side-by-side for the whole file. Split is chosen
  # when the 95th-percentile line of each side fits its half-width pane;
  # the outliers beyond that get ellipsis-truncated at render (see
  # `truncate_pieces/2`), keeping the 50/50 grid intact.
  @fit_percentile 0.95

  defp split_fits?(ops, gutter_width, width) do
    {old_typical, new_typical} = side_percentile_widths(ops, @fit_percentile)

    pane_width = fn line_width ->
      gutter_width + @bar_width + @pane_chrome + line_width
    end

    pane_width.(old_typical) + @pane_gap + pane_width.(new_typical) <= width
  end

  # Per-side display widths at the given percentile (floor 1 so an empty
  # side still occupies a cell). Equal lines count toward both sides.
  defp side_percentile_widths(ops, percentile) do
    {old_widths, new_widths} =
      Enum.reduce(ops, {[], []}, fn
        {:delete, line}, {olds, news} ->
          {[TextMeasure.display_width(line) | olds], news}

        {:insert, line}, {olds, news} ->
          {olds, [TextMeasure.display_width(line) | news]}

        {:equal, line}, {olds, news} ->
          width = TextMeasure.display_width(line)
          {[width | olds], [width | news]}
      end)

    {percentile_of(old_widths, percentile),
     percentile_of(new_widths, percentile)}
  end

  defp percentile_of([], _percentile), do: 1

  defp percentile_of(widths, percentile) do
    sorted = Enum.sort(widths)
    index = max(ceil(percentile * length(sorted)) - 1, 0)
    max(Enum.at(sorted, index), 1)
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
          content: "Not yet applied: review before confirming",
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
  # The tiers now live in `Raxol.UI.Theming.Palette.diff_palette/0`, with the
  # rationale for flattening the translucency documented there.
  #
  # The TODO this replaces asked to "consolidate with the project-wide
  # palette inventory at docs/proposals/in-flight/palette-inventory.md once
  # it exists". No such file exists at that path or at the
  # docs/proposals/palette-inventory.md path `Palette` itself cites, so the
  # TODO's precondition could never have been met.
  @diff_palette Raxol.UI.Theming.Palette.diff_palette()

  defp add_base, do: @diff_palette.add_base
  defp add_row_bg, do: @diff_palette.add_row_bg
  defp add_emphasis_bg, do: @diff_palette.add_emphasis_bg
  defp add_gutter_bg, do: @diff_palette.add_gutter_bg
  defp del_base, do: @diff_palette.del_base
  defp del_row_bg, do: @diff_palette.del_row_bg
  defp del_emphasis_bg, do: @diff_palette.del_emphasis_bg
  defp del_gutter_bg, do: @diff_palette.del_gutter_bg

  @doc """
  The single source of the merged diff visual language's hex tiers (row
  wash, intra-line emphasis, gutter tint -- see the comment above
  `@diff_palette`): `add_base`/`add_row_bg`/`add_emphasis_bg`/`add_gutter_bg`
  and their `del_*` counterparts, each an `"#RRGGBB"` string. This
  Component's own grid rendering (`render/2`) always reads it through the
  private per-tier accessors above; `diff_palette/0` exposes the SAME map
  publicly so a second renderer of this diff visual language never forks
  its own copy of these hexes. `Raxol.Harness.DiffExpansion`'s per-row
  line renderer (the full-screen diff expansion's row-level tier of this
  same visual language -- gutter bar plus row wash, no word-level
  emphasis or syntax highlighting) is the first such caller.
  """
  @spec diff_palette() :: %{
          add_base: String.t(),
          add_row_bg: String.t(),
          add_emphasis_bg: String.t(),
          add_gutter_bg: String.t(),
          del_base: String.t(),
          del_row_bg: String.t(),
          del_emphasis_bg: String.t(),
          del_gutter_bg: String.t()
        }
  def diff_palette, do: @diff_palette

  # -- Perceptual transforms (H-K solver, Raxol.UI.Theming.Salience) --
  #
  # Ground lightness is the reference near-black; pairing this with the
  # OSC 11-queried terminal ground is a natural follow-up (the Salience
  # API already takes it as an input).

  # Chroma factor for the row wash under the UNCHANGED parts of a
  # partially-changed line: visibly calmer than the full wash, same
  # apparent lightness, so "this part of the changed line didn't change"
  # reads at a glance.
  @unchanged_part_chroma 0.35

  # Prominence by distance (in lines) from the nearest change: the edited
  # line's immediate neighbour keeps 80%, then 60%, and everything
  # further rests at the 40% floor (folding hides the deep tail anyway).
  defp prominence(0), do: 1.0
  defp prominence(1), do: 0.8
  defp prominence(2), do: 0.6
  defp prominence(3), do: 0.4
  # 40% is the floor: fading further reads as "broken terminal", not calm.
  defp prominence(_distance), do: 0.4

  # Reduce a hex color's chroma while holding its H-K apparent lightness
  # constant, so the calmer color reads equally bright.
  defp dechroma(hex, factor) do
    {l, c, h} = Salience.hex_to_oklch(hex)
    apparent = Salience.apparent_lightness(l, c, h)
    reduced_c = c * factor
    solved_l = Salience.solve_lightness(apparent, reduced_c, h)
    Salience.oklch_to_hex(solved_l, reduced_c, h)
  end

  # Fade a foreground toward the ground by interpolating APPARENT
  # lightness (not nominal L) and scaling chroma with prominence -- the
  # H-K compensation keeps the fade perceptually even across hues.
  defp fade_toward_ground(hex, prominence) when prominence >= 1.0, do: hex

  defp fade_toward_ground(hex, prominence) do
    ground = Salience.reference_ground()
    {l, c, h} = Salience.hex_to_oklch(hex)
    apparent = Salience.apparent_lightness(l, c, h)
    faded_apparent = ground + (apparent - ground) * prominence
    faded_c = c * prominence
    solved_l = Salience.solve_lightness(faded_apparent, faded_c, h)
    Salience.oklch_to_hex(solved_l, faded_c, h)
  end

  defp dechroma_row_bg(:delete),
    do: dechroma(del_row_bg(), @unchanged_part_chroma)

  defp dechroma_row_bg(:insert),
    do: dechroma(add_row_bg(), @unchanged_part_chroma)

  defp dechroma_row_bg(:equal), do: nil

  # Neutral base for chrome text (line numbers, fold rows): the Salience
  # baseline-tier neutral, faded per element by prominence.
  @chrome_base_fg "#B4B4B4"

  # Line-number prominence rides 20pp under its row's content prominence
  # (never below the 40% floor); rows with a wash present (changed rows)
  # hold the numbers at 80% so they anchor against the tinted background.
  defp gutter_prominence(:changed, _content_prominence), do: 0.8

  defp gutter_prominence(:context, content_prominence),
    do: max(content_prominence - 0.2, 0.4)

  defp chrome_fg(prominence),
    do: fade_toward_ground(@chrome_base_fg, prominence)

  # -- Render context: precomputed per-render inputs shared by both modes --

  defp build_render_context(state, ops, gutter_width, avail_width) do
    ops_with_ranges = annotate_word_ranges(ops)

    %{
      ops_with_ranges: Enum.zip(ops_with_ranges, change_distances(ops)),
      gutter_width: gutter_width,
      old_lines: highlight(state.old, state.language, state.syntax_theme),
      new_lines: highlight(state.new, state.language, state.syntax_theme),
      pane_budget: pane_budget(avail_width, gutter_width),
      unified_budget: unified_budget(avail_width, gutter_width),
      avail_width: avail_width,
      context: state.context
    }
  end

  # Per-op distance (in rows) to the nearest changed op -- the input to
  # the prominence fade. Two linear sweeps.
  defp change_distances(ops) do
    infinity = length(ops) + 1

    forward =
      ops
      |> Enum.scan(infinity, fn
        {:equal, _line}, prev -> prev + 1
        {_changed, _line}, _prev -> 0
      end)

    ops
    |> Enum.zip(forward)
    |> Enum.reverse()
    |> Enum.scan(infinity, fn
      {{:equal, _line}, fwd}, prev -> min(fwd, prev + 1)
      {{_changed, _line}, _fwd}, _prev -> 0
    end)
    |> Enum.reverse()
  end

  # Content columns for a unified row: full width minus the gutter block
  # (bar + old-number + space + new-number) and the leader space.
  defp unified_budget(nil, _gutter_width), do: nil

  defp unified_budget(avail_width, gutter_width) do
    max(avail_width - (2 * gutter_width + 1) - @bar_width - 1, 4)
  end

  # Full rendered row width (gutter block + leader + content budget), for
  # centering the fold row. nil when the available width is unknown.
  defp unified_row_width(%{unified_budget: nil}), do: nil

  defp unified_row_width(ctx),
    do: @bar_width + 2 * ctx.gutter_width + 1 + 1 + ctx.unified_budget

  defp split_row_width(%{pane_budget: nil}), do: nil

  defp split_row_width(ctx),
    do: @bar_width + ctx.gutter_width + 1 + ctx.pane_budget

  # Content columns available inside one split pane, or nil when the
  # available width is unknown (then nothing truncates and flex does its
  # best). Floor 4 so pathological narrow widths still show something.
  defp pane_budget(nil, _gutter_width), do: nil

  defp pane_budget(avail_width, gutter_width) do
    half = div(avail_width - @pane_gap, 2)
    max(half - gutter_width - @bar_width - @pane_chrome, 4)
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

  defp fold_label(count) do
    plural = if count == 1, do: "", else: "s"
    " ⋯ #{count} unchanged line#{plural} ⋯ "
  end

  # -- Unified mode: one column, gutter bar + numbers, spans inline --

  defp render_unified(ctx) do
    plans = unified_plans(ctx.ops_with_ranges, ctx.unified_budget)

    ctx.ops_with_ranges
    |> Enum.zip(plans)
    |> annotate()
    |> fold_rows(ctx.context, &unified_classify/1)
    |> Enum.flat_map(&unified_line(&1, ctx))
  end

  defp unified_classify(row),
    do: if(elem(row, 0) == :equal, do: :context, else: :change)

  # -- Long-line render plans (unified mode only) --------------------------
  #
  # Removed content is low-value: an over-budget UNPAIRED delete keeps one
  # row and mid-ellipses (head + "…" + last 5 chars). Added content is
  # what's being reviewed: an over-budget insert SOFT-WRAPS in full. A
  # PAIRED over-budget delete borrows its insert's allocation — it wraps
  # into exactly as many rows as the paired insert took, tail-ellipsed if
  # it still overflows. Split mode keeps plain truncation (wrapping would
  # break pane row alignment).
  defp unified_plans(ops_with_meta, nil),
    do: Enum.map(ops_with_meta, fn _op -> :plain end)

  defp unified_plans(ops_with_meta, budget) do
    ops_with_meta
    |> Enum.chunk_by(fn {{{kind, _line}, _ranges}, _dist} ->
      if kind == :equal, do: :equal, else: :change
    end)
    |> Enum.flat_map(&run_plans(&1, budget))
  end

  defp run_plans([{{{:equal, _}, _}, _} | _] = equal_run, _budget),
    do: Enum.map(equal_run, fn _op -> :plain end)

  defp run_plans(change_run, budget) do
    over? = fn line -> TextMeasure.display_width(line) > budget end

    inserts =
      for {{{:insert, line}, _ranges}, _dist} <- change_run, do: line

    insert_rows =
      Enum.map(inserts, fn line ->
        if over?.(line), do: wrap_row_count(line, budget), else: 1
      end)

    {plans_rev, _del_idx} =
      Enum.reduce(change_run, {[], 0}, fn
        {{{:insert, line}, _r}, _d}, {acc, del_idx} ->
          plan = if over?.(line), do: :wrap, else: :plain
          {[plan | acc], del_idx}

        {{{:delete, line}, _r}, _d}, {acc, del_idx} ->
          plan =
            cond do
              not over?.(line) ->
                :plain

              del_idx < length(insert_rows) ->
                {:wrap_limit, Enum.at(insert_rows, del_idx)}

              true ->
                :mid_ellipsis
            end

          {[plan | acc], del_idx + 1}
      end)

    Enum.reverse(plans_rev)
  end

  # Greedy display-width fill — must stay in lockstep with wrap_pieces/2
  # so a paired delete's row allowance matches the insert's actual rows.
  defp wrap_row_count(line, budget) do
    line
    |> String.graphemes()
    |> Enum.reduce({1, 0}, fn grapheme, {rows, used} ->
      w = TextMeasure.display_width(grapheme)
      if used + w > budget, do: {rows + 1, w}, else: {rows, used + w}
    end)
    |> elem(0)
  end

  defp annotate(ops_with_plans) do
    {rows, _old_no, _new_no} =
      Enum.reduce(ops_with_plans, {[], 1, 1}, &annotate_op/2)

    Enum.reverse(rows)
  end

  defp annotate_op(
         {{{{:equal, line}, ranges}, dist}, _plan},
         {acc, old_no, new_no}
       ) do
    row = {:equal, line, ranges, old_no, new_no, dist}
    {[row | acc], old_no + 1, new_no + 1}
  end

  defp annotate_op(
         {{{{:delete, line}, ranges}, _dist}, plan},
         {acc, old_no, new_no}
       ) do
    row = {:delete, line, ranges, old_no, nil, plan}
    {[row | acc], old_no + 1, new_no}
  end

  defp annotate_op(
         {{{{:insert, line}, ranges}, _dist}, plan},
         {acc, old_no, new_no}
       ) do
    row = {:insert, line, ranges, nil, new_no, plan}
    {[row | acc], old_no, new_no + 1}
  end

  defp unified_line({:fold, count}, ctx) do
    [fold_row(count, unified_row_width(ctx))]
  end

  defp unified_line({:equal, line, _ranges, old_no, new_no, dist}, ctx) do
    gutter =
      unified_gutter(
        " ",
        old_no,
        new_no,
        ctx.gutter_width,
        nil,
        nil,
        gutter_prominence(:context, prominence(dist))
      )

    content =
      content_spans(:equal, line, [], old_no, ctx,
        budget: ctx.unified_budget,
        prominence: prominence(dist)
      )

    [Components.row(gap: 0, children: [gutter, content])]
  end

  defp unified_line({:delete, line, ranges, old_no, _new_no, plan}, ctx) do
    changed_rows(
      :delete,
      line,
      ranges,
      old_no,
      plan,
      ctx,
      fn no ->
        unified_gutter(
          "▌",
          no,
          nil,
          ctx.gutter_width,
          del_base(),
          del_gutter_bg(),
          gutter_prominence(:changed, 1.0)
        )
      end
    )
  end

  defp unified_line({:insert, line, ranges, _old_no, new_no, plan}, ctx) do
    changed_rows(
      :insert,
      line,
      ranges,
      new_no,
      plan,
      ctx,
      fn no ->
        unified_gutter(
          "▌",
          nil,
          no,
          ctx.gutter_width,
          add_base(),
          add_gutter_bg(),
          gutter_prominence(:changed, 1.0)
        )
      end
    )
  end

  # Emits one-or-more rows for a changed line according to its plan. The
  # first row carries the numbered gutter; wrap continuation rows keep the
  # colored bar but blank numbers.
  defp changed_rows(kind, line, ranges, line_no, plan, ctx, gutter_fn) do
    case plan do
      :plain ->
        content =
          content_spans(kind, line, ranges, line_no, ctx,
            budget: ctx.unified_budget
          )

        [Components.row(gap: 0, children: [gutter_fn.(line_no), content])]

      :mid_ellipsis ->
        content =
          mid_ellipsis_spans(
            kind,
            line,
            ranges,
            line_no,
            ctx,
            ctx.unified_budget
          )

        [Components.row(gap: 0, children: [gutter_fn.(line_no), content])]

      :wrap ->
        wrapped_rows(kind, line, ranges, line_no, ctx, nil, gutter_fn)

      {:wrap_limit, allowed} ->
        wrapped_rows(kind, line, ranges, line_no, ctx, allowed, gutter_fn)
    end
  end

  defp wrapped_rows(kind, line, ranges, line_no, ctx, allowed, gutter_fn) do
    budget = ctx.unified_budget
    pieces = line_pieces(kind, line, ranges, line_no, ctx)

    # A paired over-budget DELETE squeezes its CHANGED clusters (the
    # content being removed — low-value) to fit the insert's allocation,
    # keeping the unchanged frame around them fully visible. Inserts are
    # never squeezed.
    pieces =
      if kind == :delete and allowed != nil and ranges != [] do
        squeeze_changed_pieces(pieces, allowed * budget)
      else
        pieces
      end

    piece_rows = wrap_pieces(pieces, budget)

    piece_rows =
      case allowed do
        nil -> piece_rows
        n when length(piece_rows) <= n -> piece_rows
        n -> limit_rows(piece_rows, n, budget)
      end

    piece_rows
    |> Enum.with_index()
    |> Enum.map(fn {row_pieces, index} ->
      gutter =
        if index == 0,
          do: gutter_fn.(line_no),
          else: gutter_fn.(nil)

      content = pieces_row(kind, ranges, row_pieces, budget, 1.0)
      Components.row(gap: 0, children: [gutter, content])
    end)
  end

  # Greedy display-width wrap of span pieces into rows of `budget` columns.
  # Kept in lockstep with wrap_row_count/2.
  defp wrap_pieces(pieces, budget) do
    {rows_rev, current_rev, _used} =
      Enum.reduce(pieces, {[], [], 0}, fn piece, acc ->
        wrap_piece(piece, acc, budget)
      end)

    rows_rev =
      if current_rev == [], do: rows_rev, else: [current_rev | rows_rev]

    rows_rev
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> case do
      [] -> [[]]
      rows -> rows
    end
  end

  defp wrap_piece(piece, {rows_rev, current_rev, used}, budget) do
    width = TextMeasure.display_width(piece.text)

    if used + width <= budget do
      {rows_rev, [piece | current_rev], used + width}
    else
      room = budget - used
      {head_text, rest_text} = split_text_at_width(piece.text, room)

      current_rev =
        if head_text == "",
          do: current_rev,
          else: [%{piece | text: head_text} | current_rev]

      rest = %{piece | text: rest_text}

      wrap_piece(rest, {[current_rev | rows_rev], [], 0}, budget)
    end
  end

  defp split_text_at_width(text, width) when width <= 0, do: {"", text}

  defp split_text_at_width(text, width) do
    head = slice_to_width(text, width)
    {head, String.slice(text, String.length(head)..-1//1) || ""}
  end

  # Keep the first `n` rows; the last kept row is re-truncated to make
  # room for the trailing "…" marker.
  defp limit_rows(piece_rows, n, budget) do
    kept = Enum.take(piece_rows, n)
    {head_rows, [last_row]} = Enum.split(kept, n - 1)

    {trimmed_rev, _} =
      take_within(last_row, budget - 1, [])

    ellipsis = %{text: "…", fg: nil, styles: [], changed: false}
    head_rows ++ [Enum.reverse([ellipsis | trimmed_rev])]
  end

  # Mid-string ellipsis for an over-budget UNPAIRED delete: head, "…",
  # then the line's last 5 characters — enough to see what it was, no
  # more ("we do not care about the full contents of what's removed").
  defp mid_ellipsis_spans(kind, line, ranges, line_no, ctx, budget) do
    tail_text = String.slice(line, -5, 5)
    tail_width = TextMeasure.display_width(tail_text)

    pieces = line_pieces(kind, line, ranges, line_no, ctx)

    {head_rev, _} = take_within(pieces, budget - 1 - tail_width, [])

    ellipsis = %{text: "…", fg: nil, styles: [], changed: false}
    tail = %{text: tail_text, fg: nil, styles: [], changed: false}

    row_pieces = Enum.reverse(head_rev) ++ [ellipsis, tail]
    pieces_row(kind, ranges, row_pieces, budget, 1.0)
  end

  # Gutter = two spans: the bar keeps its full-strength identity color;
  # the line numbers are chrome, faded to their own prominence.
  defp unified_gutter(bar, old_no, new_no, width, bar_fg, bg, number_prom) do
    numbers = pad(old_no, width) <> " " <> pad(new_no, width)
    gutter_spans(bar, numbers, bar_fg, bg, number_prom)
  end

  defp gutter_spans(bar, numbers, bar_fg, bg, number_prom) do
    Components.row(
      gap: 0,
      children: [
        Components.text(content: bar, style: gutter_style(bar_fg, bg)),
        Components.text(
          content: numbers,
          style: gutter_style(chrome_fg(number_prom), bg)
        )
      ]
    )
  end

  defp gutter_style(nil, nil), do: %{}
  defp gutter_style(fg, nil), do: %{fg: fg}
  defp gutter_style(nil, bg), do: %{bg: bg}
  defp gutter_style(fg, bg), do: %{fg: fg, bg: bg}

  # -- Split mode: old | new side by side, blank filler for unmatched lines --

  # Borderless, label-less panes (less is more): the red/green gutters
  # already say which side is which, so no OLD/NEW headers and no border
  # boxes. Each pane takes half the available width.
  defp render_split(ctx) do
    pairs =
      ctx.ops_with_ranges
      |> pair_rows()
      |> annotate_pairs()
      |> fold_rows(ctx.context, &split_classify/1)

    # flex: 1 shares the row's free space equally — a true 50/50 split.
    # ({:pct, n} only resolves against a definite container dimension,
    # which this row usually doesn't have.) Outlier-long lines are
    # ellipsis-truncated to the pane budget so they can't push a pane
    # past its half (the flex min-content floor never engages).
    old_side =
      Components.column(
        gap: 0,
        style: %{flex: 1},
        children: Enum.map(pairs, &split_old_line(&1, ctx))
      )

    new_side =
      Components.column(
        gap: 0,
        style: %{flex: 1},
        children: Enum.map(pairs, &split_new_line(&1, ctx))
      )

    [
      Components.row(
        gap: 2,
        # flex children only share space the row actually HAS: inside the
        # content-sized root column an unsized row collapses to content
        # width and the panes pile up left. Give the row the known
        # available width; :fill is the best-effort fallback when the
        # width is unknown (explicit :split with no width prop).
        style: %{width: ctx.avail_width || :fill},
        children: [old_side, new_side]
      )
    ]
  end

  defp split_classify(row),
    do: if(elem(row, 0) == :equal, do: :context, else: :change)

  # Groups consecutive :equal ops as 1:1 pairs; consecutive :delete/:insert
  # runs (a changed hunk) pair up index-wise so both sides render on the
  # same row, padding the shorter side with `nil` (blank filler). Carries
  # each side's word-diff ranges through alongside its line.
  defp pair_rows(ops_with_meta) do
    ops_with_meta
    |> Enum.chunk_by(fn {{{kind, _line}, _ranges}, _dist} ->
      if kind == :equal, do: :equal, else: :change
    end)
    |> Enum.flat_map(&expand_run/1)
  end

  defp expand_run([{{{:equal, _line}, _ranges}, _dist} | _] = equal_run) do
    Enum.map(equal_run, fn {{{:equal, line}, _ranges}, dist} ->
      {:equal, line, line, [], [], dist}
    end)
  end

  defp expand_run(change_run) do
    deletes =
      for {{{:delete, line}, ranges}, _dist} <- change_run, do: {line, ranges}

    inserts =
      for {{{:insert, line}, ranges}, _dist} <- change_run, do: {line, ranges}

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

  defp annotate_pair(
         {:equal, old_line, new_line, _, _, dist},
         {acc, old_no, new_no}
       ) do
    row = {:equal, old_no, old_line, new_no, new_line, [], [], dist}
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
    fold_row(count, split_row_width(ctx))
  end

  defp split_old_line(
         {:equal, old_no, line, _new_no, _new_line, _, _, dist},
         ctx
       ) do
    gutter =
      split_gutter(
        " ",
        old_no,
        ctx.gutter_width,
        nil,
        nil,
        gutter_prominence(:context, prominence(dist))
      )

    content =
      content_spans(:equal, line, [], old_no, ctx,
        budget: ctx.pane_budget,
        prominence: prominence(dist)
      )

    Components.row(gap: 0, children: [gutter, content])
  end

  defp split_old_line({:change, nil, nil, _new_no, _new_line, _, _}, ctx) do
    gutter = split_gutter(" ", nil, ctx.gutter_width, nil, nil, 0.4)
    Components.row(gap: 0, children: [gutter, filler_row()])
  end

  defp split_old_line(
         {:change, old_no, line, _new_no, _new_line, del_ranges, _},
         ctx
       ) do
    gutter =
      split_gutter(
        "▌",
        old_no,
        ctx.gutter_width,
        del_base(),
        del_gutter_bg(),
        gutter_prominence(:changed, 1.0)
      )

    content =
      content_spans(:delete, line, del_ranges, old_no, ctx,
        budget: ctx.pane_budget
      )

    Components.row(gap: 0, children: [gutter, content])
  end

  defp split_new_line({:fold, count}, ctx) do
    fold_row(count, split_row_width(ctx))
  end

  defp split_new_line(
         {:equal, _old_no, _old_line, new_no, line, _, _, dist},
         ctx
       ) do
    gutter =
      split_gutter(
        " ",
        new_no,
        ctx.gutter_width,
        nil,
        nil,
        gutter_prominence(:context, prominence(dist))
      )

    content =
      content_spans(:equal, line, [], new_no, ctx,
        budget: ctx.pane_budget,
        prominence: prominence(dist)
      )

    Components.row(gap: 0, children: [gutter, content])
  end

  defp split_new_line({:change, _old_no, _old_line, nil, nil, _, _}, ctx) do
    gutter = split_gutter(" ", nil, ctx.gutter_width, nil, nil, 0.4)
    Components.row(gap: 0, children: [gutter, filler_row()])
  end

  defp split_new_line(
         {:change, _old_no, _old_line, new_no, line, _, ins_ranges},
         ctx
       ) do
    gutter =
      split_gutter(
        "▌",
        new_no,
        ctx.gutter_width,
        add_base(),
        add_gutter_bg(),
        gutter_prominence(:changed, 1.0)
      )

    content =
      content_spans(:insert, line, ins_ranges, new_no, ctx,
        budget: ctx.pane_budget
      )

    Components.row(gap: 0, children: [gutter, content])
  end

  defp split_gutter(bar, no, width, bar_fg, bg, number_prom) do
    gutter_spans(bar, pad(no, width), bar_fg, bg, number_prom)
  end

  # An absent line renders as plain blank space -- the row exists only to
  # keep the two panes vertically aligned.
  defp filler_row do
    Components.row(
      gap: 0,
      children: [Components.text(content: "", style: %{})]
    )
  end

  # -- Fold row (shared shape for unified + both split panes) --
  #
  # Center-positioned across the full row width when it's known: dashes
  # rule the whole line at 20% prominence, the "N unchanged lines" label
  # sits centered at 40%.

  defp fold_row(count, row_width) do
    label = fold_label(count)
    label_width = TextMeasure.display_width(label)

    {left, right} =
      case row_width do
        nil ->
          {5, 5}

        total when total > label_width + 2 ->
          side = total - label_width
          {div(side, 2), side - div(side, 2)}

        _too_narrow ->
          {1, 1}
      end

    Components.row(
      gap: 0,
      children: [
        Components.text(
          content: String.duplicate("─", left),
          style: %{fg: chrome_fg(0.2)}
        ),
        Components.text(content: label, style: %{fg: chrome_fg(0.4)}),
        Components.text(
          content: String.duplicate("─", right),
          style: %{fg: chrome_fg(0.2)}
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

  defp content_spans(kind, line, ranges, line_no, ctx, opts) do
    budget = Keyword.get(opts, :budget)
    prominence = Keyword.get(opts, :prominence, 1.0)

    pieces =
      kind
      |> line_pieces(line, ranges, line_no, ctx)
      |> truncate_pieces(budget)

    pieces_row(kind, ranges, pieces, budget, prominence)
  end

  defp line_pieces(kind, line, ranges, line_no, ctx) do
    kind
    |> line_tokens(line, line_no, ctx)
    |> split_tokens_by_ranges(ranges)
    |> Enum.reject(fn piece -> piece.text == "" end)
  end

  defp pieces_row(kind, ranges, pieces, budget, prominence) do
    row_bg = row_bg_for(kind)
    emphasis_bg = emphasis_bg_for(kind)
    fallback_fg = fallback_fg_for(kind)

    # Partially-changed line: the UNCHANGED pieces sit on a chroma-reduced
    # wash (same apparent lightness) so "this part didn't change" reads at
    # a glance; the changed pieces keep the bright emphasis tier. A fully
    # added/removed line (no ranges) keeps the full wash end to end.
    plain_bg = if ranges == [], do: row_bg, else: dechroma_row_bg(kind)

    used_width =
      Enum.reduce(pieces, 0, fn piece, acc ->
        acc + TextMeasure.display_width(piece.text)
      end)

    spans =
      Enum.map(pieces, fn piece ->
        bg = if piece.changed, do: emphasis_bg, else: plain_bg
        fg = span_fg(piece.fg, fallback_fg, prominence)

        Components.text(
          content: piece.text,
          style: span_style(fg, bg, piece.styles)
        )
      end)

    # Leader covers the former gutter-content gap cell; trailing pad
    # stretches the wash to the full row budget -- together the line
    # background spans the whole width, not just the text.
    leader = Components.text(content: " ", style: span_style(nil, plain_bg, []))
    trailer = trailing_pad(budget, used_width, plain_bg)

    Components.row(gap: 0, children: [leader | spans] ++ trailer)
  end

  # Fade only real (hex) token colors; atom fallbacks like :dim have no
  # colorimetric identity to fade.
  defp span_fg(nil, fallback_fg, _prominence), do: fallback_fg

  defp span_fg(fg, _fallback_fg, prominence) when is_binary(fg),
    do: fade_toward_ground(fg, prominence)

  defp span_fg(fg, _fallback_fg, _prominence), do: fg

  defp trailing_pad(nil, _used, _bg), do: []
  defp trailing_pad(_budget, _used, nil), do: []

  defp trailing_pad(budget, used, bg) when budget > used do
    [
      Components.text(
        content: String.duplicate(" ", budget - used),
        style: span_style(nil, bg, [])
      )
    ]
  end

  defp trailing_pad(_budget, _used, _bg), do: []

  # Ellipsis-truncates a line's span pieces to a display-width budget
  # (grapheme-accurate via TextMeasure — CJK/emoji count double). The
  # outliers past the auto-fit percentile land here; everything else
  # passes through untouched. nil budget = no truncation.
  defp truncate_pieces(pieces, nil), do: pieces

  defp truncate_pieces(pieces, budget) do
    total =
      Enum.reduce(pieces, 0, fn piece, acc ->
        acc + TextMeasure.display_width(piece.text)
      end)

    if total <= budget do
      pieces
    else
      {kept_rev, _used} = take_within(pieces, budget - 1, [])

      ellipsis = %{text: "…", fg: nil, styles: [], changed: false}
      Enum.reverse([ellipsis | kept_rev])
    end
  end

  # -- Changed-cluster squeeze (paired over-budget deletes) ----------------
  #
  # Mid-ellipses each run of CHANGED pieces to a proportional share of the
  # space left after the unchanged frame is fully accounted for. The
  # ellipsis stays `changed: true` so it renders on the emphasis tier --
  # the squeeze reads as part of the removed cluster.

  @cluster_min_width 7
  @cluster_tail_keep 4

  defp squeeze_changed_pieces(pieces, capacity) do
    {unchanged_w, changed_w} =
      Enum.reduce(pieces, {0, 0}, fn piece, {u, c} ->
        w = TextMeasure.display_width(piece.text)
        if piece.changed, do: {u, c + w}, else: {u + w, c}
      end)

    cond do
      unchanged_w + changed_w <= capacity ->
        pieces

      # The unchanged frame alone overflows: squeezing clusters can't
      # save the row; leave it to wrap + limit_rows.
      unchanged_w >= capacity ->
        pieces

      true ->
        budget_for_changed = capacity - unchanged_w

        pieces
        |> cluster_by_changed()
        |> Enum.flat_map(fn
          {:unchanged, run} ->
            run

          {:changed, run} ->
            run_w =
              Enum.reduce(run, 0, fn piece, acc ->
                acc + TextMeasure.display_width(piece.text)
              end)

            allot =
              max(
                div(budget_for_changed * run_w, max(changed_w, 1)),
                @cluster_min_width
              )

            squeeze_cluster(run, run_w, allot)
        end)
    end
  end

  defp cluster_by_changed(pieces) do
    pieces
    |> Enum.chunk_by(& &1.changed)
    |> Enum.map(fn [first | _] = run ->
      {if(first.changed, do: :changed, else: :unchanged), run}
    end)
  end

  defp squeeze_cluster(run, run_w, allot) when run_w <= allot, do: run

  defp squeeze_cluster(run, _run_w, allot) do
    head_width = max(allot - 1 - @cluster_tail_keep, 1)
    {head_rev, _} = take_within(run, head_width, [])
    tail = tail_within(run, @cluster_tail_keep)

    ellipsis = %{text: "…", fg: nil, styles: [], changed: true}
    Enum.reverse(head_rev) ++ [ellipsis | tail]
  end

  # Last `want` display columns of a piece run, preserving piece styling.
  defp tail_within(pieces, want) do
    pieces
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn piece, {acc, used} ->
      width = TextMeasure.display_width(piece.text)

      cond do
        used >= want ->
          {:halt, {acc, used}}

        used + width <= want ->
          {:cont, {[piece | acc], used + width}}

        true ->
          kept = slice_from_end(piece.text, want - used)
          {:halt, {[%{piece | text: kept} | acc], want}}
      end
    end)
    |> elem(0)
  end

  defp slice_from_end(text, width) do
    text
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, used} ->
      grapheme_width = TextMeasure.display_width(grapheme)

      if used + grapheme_width <= width do
        {:cont, {[grapheme | acc], used + grapheme_width}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
    |> Enum.join()
  end

  defp take_within([], _left, acc), do: {acc, 0}

  defp take_within([piece | rest], left, acc) do
    width = TextMeasure.display_width(piece.text)

    cond do
      width <= left ->
        take_within(rest, left - width, [piece | acc])

      left <= 0 ->
        {acc, 0}

      true ->
        {[%{piece | text: slice_to_width(piece.text, left)} | acc], 0}
    end
  end

  defp slice_to_width(text, width) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, used} ->
      grapheme_width = TextMeasure.display_width(grapheme)

      if used + grapheme_width <= width do
        {:cont, {[grapheme | acc], used + grapheme_width}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
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
