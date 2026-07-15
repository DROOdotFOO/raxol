defmodule Raxol.UI.Components.Harness.DiffViewer do
  @moduledoc """
  Pre-apply file diff viewer.

  Renders the line-based diff between a file's current content (`old`) and
  a proposed edit (`new`) BEFORE the edit is applied. This is the
  "pre-apply confirmation over post-hoc undo" surface described in
  `docs/proposals/in-flight/harness-spec-frontend.md`: framing always
  reads as "this WILL change" -- a "Proposed change" header and a "Not yet
  applied" caption, never past tense.

  Added lines render green with a `+` marker, removed lines render red
  with a `-` marker, unchanged context lines render dim, and every line
  carries its old/new line number in a dim gutter. Syntax highlighting is
  out of scope -- diff coloring and line numbers only.

  Line differencing is computed by `Raxol.UI.Components.Harness.LineDiff`
  (a plain LCS line diff).

  ## Props

    * `:path` - file path shown in the header (default `""`).
    * `:old` - original file content (default `""`).
    * `:new` - proposed file content (default `""`).
    * `:mode` - `:auto` (default), `:unified`, or `:split`. In `:auto`,
      split is chosen when both rendered panes fit side by side in the
      available width, otherwise unified. Width comes from the `:width`
      prop, else from the render context (`:available_width`, `:width`,
      or `dimensions.width`); with no width information auto falls back
      to unified (the safe narrow default).
    * `:width` - available width in terminal columns, used only by
      `:auto` (default `nil`).
    * `:id`, `:style`, `:theme` - standard component props.

  ## Example

      {:ok, state} =
        DiffViewer.init(path: "lib/orders/total.ex", old: old_text, new: new_text)

      DiffViewer.render(state, %{})
  """
  use Raxol.UI.Components.Base.Component

  alias Raxol.UI.Components.Harness.LineDiff
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  @type mode :: :unified | :split | :auto

  @type t :: %{
          id: String.t() | atom(),
          path: String.t(),
          old: String.t(),
          new: String.t(),
          mode: mode(),
          width: pos_integer() | nil,
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
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  defp normalize_mode(:split), do: :split
  defp normalize_mode(:unified), do: :unified
  defp normalize_mode(_other), do: :auto

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
        :split -> render_split(ops, gutter_width)
        :unified -> render_unified(ops, gutter_width)
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

  # A split pane renders: gutter, gap(1), marker+space(2), the line, inside
  # a :single-border box with padding 1 (border 2 + padding 2 = 4 chrome).
  # Two panes sit in a row with gap 2.
  @pane_chrome 7
  @pane_gap 2

  defp split_fits?(ops, gutter_width, width) do
    {old_max, new_max} = max_line_widths(ops)

    pane_width = fn line_width -> gutter_width + @pane_chrome + line_width end

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

  # -- Unified mode: one column, +/- markers inline --

  defp render_unified(ops, gutter_width) do
    ops
    |> annotate()
    |> Enum.map(&unified_line(&1, gutter_width))
  end

  defp annotate(ops) do
    {rows, _old_no, _new_no} = Enum.reduce(ops, {[], 1, 1}, &annotate_op/2)
    Enum.reverse(rows)
  end

  defp annotate_op({:equal, _line} = op, {acc, old_no, new_no}) do
    {[{op, old_no, new_no} | acc], old_no + 1, new_no + 1}
  end

  defp annotate_op({:delete, _line} = op, {acc, old_no, new_no}) do
    {[{op, old_no, nil} | acc], old_no + 1, new_no}
  end

  defp annotate_op({:insert, _line} = op, {acc, old_no, new_no}) do
    {[{op, nil, new_no} | acc], old_no, new_no + 1}
  end

  defp unified_line({{:equal, line}, old_no, new_no}, gutter_width) do
    gutter = format_gutter(old_no, new_no, gutter_width)
    diff_row(gutter, " ", line, %{fg: :dim})
  end

  defp unified_line({{:delete, line}, old_no, _new_no}, gutter_width) do
    gutter = format_gutter(old_no, nil, gutter_width)
    diff_row(gutter, "-", line, %{fg: :red})
  end

  defp unified_line({{:insert, line}, _old_no, new_no}, gutter_width) do
    gutter = format_gutter(nil, new_no, gutter_width)
    diff_row(gutter, "+", line, %{fg: :green})
  end

  defp format_gutter(old_no, new_no, width) do
    pad(old_no, width) <> " " <> pad(new_no, width)
  end

  # -- Split mode: old | new side by side, blank filler for unmatched lines --

  defp render_split(ops, gutter_width) do
    pairs = ops |> pair_rows() |> annotate_pairs()

    old_side =
      Components.column(
        gap: 0,
        children: [
          Components.text(content: "OLD", style: %{bold: true, fg: :red})
          | Enum.map(pairs, &split_old_line(&1, gutter_width))
        ]
      )

    new_side =
      Components.column(
        gap: 0,
        children: [
          Components.text(content: "NEW", style: %{bold: true, fg: :green})
          | Enum.map(pairs, &split_new_line(&1, gutter_width))
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

  # Groups consecutive :equal ops as 1:1 pairs; consecutive :delete/:insert
  # runs (a changed hunk) pair up index-wise so both sides render on the
  # same row, padding the shorter side with `nil` (blank filler).
  defp pair_rows(ops) do
    ops
    |> Enum.chunk_by(fn
      {:equal, _line} -> :equal
      _change -> :change
    end)
    |> Enum.flat_map(&expand_run/1)
  end

  defp expand_run([{:equal, _line} | _] = equal_run) do
    Enum.map(equal_run, fn {:equal, line} -> {:equal, line, line} end)
  end

  defp expand_run(change_run) do
    deletes = for {:delete, line} <- change_run, do: line
    inserts = for {:insert, line} <- change_run, do: line
    count = max(length(deletes), length(inserts))

    Enum.map(0..(count - 1), fn idx ->
      {:change, Enum.at(deletes, idx), Enum.at(inserts, idx)}
    end)
  end

  defp annotate_pairs(pairs) do
    {rows, _old_no, _new_no} = Enum.reduce(pairs, {[], 1, 1}, &annotate_pair/2)
    Enum.reverse(rows)
  end

  defp annotate_pair({:equal, old_line, new_line}, {acc, old_no, new_no}) do
    row = {:equal, old_no, old_line, new_no, new_line}
    {[row | acc], old_no + 1, new_no + 1}
  end

  defp annotate_pair({:change, nil, new_line}, {acc, old_no, new_no}) do
    row = {:change, nil, nil, new_no, new_line}
    {[row | acc], old_no, new_no + 1}
  end

  defp annotate_pair({:change, old_line, nil}, {acc, old_no, new_no}) do
    row = {:change, old_no, old_line, nil, nil}
    {[row | acc], old_no + 1, new_no}
  end

  defp annotate_pair({:change, old_line, new_line}, {acc, old_no, new_no}) do
    row = {:change, old_no, old_line, new_no, new_line}
    {[row | acc], old_no + 1, new_no + 1}
  end

  defp split_old_line({:equal, old_no, line, _new_no, _new_line}, width) do
    diff_row(pad(old_no, width), " ", line, %{fg: :dim})
  end

  defp split_old_line({:change, nil, nil, _new_no, _new_line}, width) do
    diff_row(pad(nil, width), " ", "", %{})
  end

  defp split_old_line({:change, old_no, line, _new_no, _new_line}, width) do
    diff_row(pad(old_no, width), "-", line, %{fg: :red})
  end

  defp split_new_line({:equal, _old_no, _old_line, new_no, line}, width) do
    diff_row(pad(new_no, width), " ", line, %{fg: :dim})
  end

  defp split_new_line({:change, _old_no, _old_line, nil, nil}, width) do
    diff_row(pad(nil, width), " ", "", %{})
  end

  defp split_new_line({:change, _old_no, _old_line, new_no, line}, width) do
    diff_row(pad(new_no, width), "+", line, %{fg: :green})
  end

  # -- Shared row/gutter helpers --

  defp diff_row(gutter, marker, content, content_style) do
    Components.row(
      gap: 1,
      children: [
        Components.text(content: gutter, style: %{fg: :dim}),
        Components.text(
          content: marker <> " " <> content,
          style: content_style
        )
      ]
    )
  end

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
