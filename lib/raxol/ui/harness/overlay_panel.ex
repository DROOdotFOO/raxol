defmodule Raxol.UI.Harness.OverlayPanel do
  @moduledoc """
  Pure, read-only footer-region content panel: a fixed-height scrollable
  block of pre-formatted lines, driven entirely by
  `Raxol.UI.Harness.InputEvent`-normalized events. No process, no I/O --
  state is a plain map, and every function here is `(t(), ...) -> t() |
  result`, exactly `Raxol.UI.Harness.OverlayPicker`'s style.

  ## `OverlayPicker` vs. this module

  `OverlayPicker` is filterable and *selects* -- a query row, ranked
  matches, `{:picked, item}` on Enter. This module is its read-only
  sibling: no query row, no selection, no `{:picked, _}` outcome ever.
  It exists for content a footer panel needs to *show*, not choose from --
  the worktracks/memory/plan read-models `Raxol.Harness.PanelProjection`
  folds. Same host contract (fixed claimed height, exact-row-count
  rendering, `InputEvent`-normalized `handle_key/2`), different shape of
  interaction: scroll instead of filter-and-pick.

  ## Fixed claimed height -- no per-keystroke footer re-pin

  `height/1` is `1 + max_visible`, fixed at construction from `:max_visible`
  alone -- it never tracks `length(lines)` the way a naive "shrink to fit"
  panel would. This mirrors `OverlayPicker`'s own fixed-height rationale
  exactly: the footer viewport this panel is hosted inside grows its
  DECSTBM split ONCE, at open, to fit the claimed height. If height instead
  tracked content length, a `put_lines/2` call mid-interaction (a footer
  repaint pulling a fresh `PanelProjection.render_lines/2` result) could
  change the claimed row count and force a mid-interaction re-pin -- a
  visible flicker. A panel that claims its full potential height up front,
  then pads unused rows with blank lines, costs a few empty footer rows in
  exchange for zero re-pinning churn.

  ## State shape

      %{
        kind: :worktracks | :memory | :plan,
        title: String.t(),
        lines: [String.t()],
        offset: non_neg_integer(),
        max_visible: pos_integer()
      }

  ## Rendering: text leaves only, exactly `height/1` of them

  `render/1` returns a `%{type: :column, children: [...]}` view map whose
  children are ALWAYS exactly `height(t)` `%{type: :text}` leaves: one
  title row, then `max_visible` content rows (padded with blank leaves when
  there are fewer lines than that). This is the same row-accounting
  contract `OverlayPicker` establishes for its host's footer row budget --
  load-bearing here for the identical reason: a caller (the harness
  surface's footer composer) sizes the scroll-region split from `height/1`
  alone and must never have to guess the actual child count. The title row
  shows a `"title (first-last/total)"` range indicator only when content
  overflows `max_visible`; otherwise it is the plain title. No width
  truncation happens here -- `Raxol.Harness.Surface.ViewText` is the one
  trust boundary that owns display-width truncation and control-byte
  sanitization, so this module hands it full, untruncated line content
  (already clamped upstream by `Raxol.Harness.PanelProjection`'s own
  hostile-content discipline).
  """

  alias Raxol.UI.Harness.InputEvent

  @type t :: %{
          kind: atom(),
          title: String.t(),
          lines: [String.t()],
          offset: non_neg_integer(),
          max_visible: pos_integer()
        }

  @default_max_visible 8

  @doc """
  The default `:max_visible` content-row cap `new/1` uses. Exposed so hosts
  clamp against THIS value rather than re-encoding the literal -- one
  source of truth, mirroring `OverlayPicker.default_max_visible/0`.
  """
  @spec default_max_visible() :: pos_integer()
  def default_max_visible, do: @default_max_visible

  @doc """
  Builds a fresh panel.

  ## Options

    * `:kind` (required) -- `:worktracks`, `:memory`, or `:plan`; used only
      to derive the default title.
    * `:title` (default derived from `:kind` -- "Worktracks"/"Memory"/"Plan")
    * `:max_visible` (default `#{@default_max_visible}`) -- the cap on
      content rows (excluding the title row) `height/1` claims.
    * `:lines` (default `[]`) -- initial content, typically
      `Raxol.Harness.PanelProjection.render_lines/2`'s output.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    kind = Keyword.fetch!(opts, :kind)

    %{
      kind: kind,
      title: Keyword.get(opts, :title, default_title(kind)),
      lines: Keyword.get(opts, :lines, []),
      offset: 0,
      max_visible: Keyword.get(opts, :max_visible, @default_max_visible)
    }
  end

  defp default_title(:worktracks), do: "Worktracks"
  defp default_title(:memory), do: "Memory"
  defp default_title(:plan), do: "Plan"
  defp default_title(other), do: to_string(other)

  @doc """
  The rows this panel claims -- fixed at construction from `:max_visible`
  alone, never the live `length(lines)` (see moduledoc, "no per-keystroke
  footer re-pin").
  """
  @spec height(t()) :: pos_integer()
  def height(%{max_visible: max_visible}), do: 1 + max_visible

  @doc """
  Replaces the panel's content (e.g. a fresh
  `PanelProjection.render_lines/2` result on repaint), clamping a
  now-stale `offset` into the new content's valid scroll range.
  """
  @spec put_lines(t(), [String.t()]) :: t()
  def put_lines(t, lines) do
    %{
      t
      | lines: lines,
        offset: min(t.offset, max_offset(t.max_visible, length(lines)))
    }
  end

  @doc """
  Handles one normalized `InputEvent.t()`. Returns `{:continue, t()}` for
  everything except `:escape`, which returns `:dismissed` (defensive -- in
  the assembled harness surface, the Keymap's `:overlay` guard captures ESC
  before it ever reaches this function, exactly as documented on
  `OverlayPicker.handle_key/2`). Read-only: printable characters, Enter,
  and paste are all inert no-ops. NEVER returns `{:picked, _}`.
  """
  @spec handle_key(t(), InputEvent.t()) :: {:continue, t()} | :dismissed
  def handle_key(t, norm) do
    case InputEvent.key(norm) do
      :up -> {:continue, scroll(t, -1)}
      :down -> {:continue, scroll(t, 1)}
      :page_up -> {:continue, scroll(t, -t.max_visible)}
      :page_down -> {:continue, scroll(t, t.max_visible)}
      :escape -> :dismissed
      _other -> {:continue, t}
    end
  end

  defp scroll(t, delta) do
    max_offset = max_offset(t.max_visible, length(t.lines))
    new_offset = (t.offset + delta) |> max(0) |> min(max_offset)
    %{t | offset: new_offset}
  end

  defp max_offset(max_visible, line_count), do: max(line_count - max_visible, 0)

  @doc """
  Renders the fixed-height view map (see moduledoc, "Rendering"): one title
  row followed by exactly `max_visible` content-row leaves.
  """
  @spec render(t()) :: map()
  def render(t) do
    content =
      t.lines
      |> Enum.slice(t.offset, t.max_visible)
      |> pad(t.max_visible)

    title_row = %{type: :text, content: title_content(t), style: %{bold: true}}

    content_rows =
      Enum.map(content, fn line -> %{type: :text, content: line, style: %{}} end)

    %{type: :column, children: [title_row | content_rows]}
  end

  defp pad(lines, count) do
    kept = Enum.take(lines, count)
    kept ++ List.duplicate("", max(count - length(kept), 0))
  end

  defp title_content(%{
         title: title,
         lines: lines,
         offset: offset,
         max_visible: max_visible
       }) do
    total = length(lines)

    if total > max_visible do
      first = offset + 1
      last = min(offset + max_visible, total)
      "#{title} (#{first}-#{last}/#{total})"
    else
      title
    end
  end
end
