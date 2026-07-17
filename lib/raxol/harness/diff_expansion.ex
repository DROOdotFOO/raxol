defmodule Raxol.Harness.DiffExpansion do
  @moduledoc """
  Pure scrollable window over a full-screen diff render: the state behind
  the harness surface's "expand the focused diff block" feature.

  This module owns none of the terminal bytes -- it renders a `:diff`
  content map into a plain list of sanitized, width-truncated, styled
  lines exactly once, then exposes a clamped scroll offset and a
  header-plus-slice render over that list. `Raxol.Harness.Surface` is the
  only caller that turns this into terminal bytes (via `InlineAuthority`);
  this module never touches an `IO.device()`, a process, or ANSI beyond
  the SGR it wraps its own lines in.

  ## Rendering: one line per `LineDiff` op, not the Component view tree

  This renders DIRECTLY from `Raxol.UI.Components.Harness.LineDiff.diff/2`
  -- one styled line per `{:equal | :delete | :insert, line}` op --
  rather than through `DiffViewer.render/2` piped into
  `Raxol.Harness.Surface.ViewText.lines/3` (the seam every other harness
  Component's rendered body uses, and this module's own first
  implementation used too). That pipeline was tried and rejected, for a
  concrete, measured reason: `DiffViewer.render/2` composes each visual
  row from SEVERAL side-by-side leaf nodes (a gutter bar, a line number,
  a content span, alignment padding) meant to be laid out horizontally by
  the normal `Preparer -> LayoutEngine -> UIRenderer` pipeline.
  `ViewText.lines/3` has no notion that those nodes share one physical
  row -- it flattens every leaf into its OWN line, the same as it does
  for the genuinely one-text-child-per-line bodies every other harness
  Component renders (`MessageBlock`, `ReasoningBlock`, `ToolCallBlock`).
  Measured against a real 20-line diff at 40 columns, that pipeline
  produced ~170 flattened lines for what should have been ~21 rows --
  breaking the row math `scroll/2`'s clamp and the surface's
  `view_rows` claim both depend on. Worse, `ViewText.style_line/2` has no
  `:background` handling at all (it only ever wraps `:bold`/`:dim`/`:fg`),
  so even where the flatten produced a usable line, the diff's own
  add/del row washes -- the merged visual language's whole point -- were
  silently dropped. Rendering one line directly per op, styled here, is
  what actually satisfies both "one row per diff line" and "the diff's
  own styling is preserved."

  ## What this module actually is

  A plain map (`t()`), not a process or a Component:

    * `content` -- the `:diff` content map this expansion was built from
      (`%{path, old, new, language}`), kept so `resize_view/3` can
      re-render at a new geometry without the caller re-supplying it.
      `:language` is accepted (part of the shared `:diff` content schema)
      and currently unused here -- see "Scope" below.
    * `lines` -- the full render: one already-sanitized, width-truncated,
      styled binary per `LineDiff.diff/2` op, in document order. There is
      no folding of long unchanged runs -- a full-screen review surface
      exists precisely to show everything (`DiffViewer`'s own folding is
      a property of ITS renderer, never reached here).
    * `total` -- `length(lines)`, which is exactly `length(LineDiff.diff(old, new))`.
    * `offset` -- the first `lines` index visible in the current window,
      clamped by `scroll/2` to `0..max(0, total - view_rows)`.
    * `view_rows` / `width` -- the current viewport geometry.

  ## Per-row rendering (sanitize, then truncate, then pad, then style)

  Each op's raw line content goes through, IN ORDER:

    1. **Sanitize** -- `Raxol.Harness.Surface.ViewText.sanitize_line/1`,
       the SAME trust-boundary byte-strip every harness Component's
       content passes through (ESC/C0 stripped except `\\t`, `\\t`
       excepted, multi-byte UTF-8 safe). This is content from an
       untrusted source (an agent-produced diff) -- sanitizing FIRST
       means styling (step 4) only ever wraps already-safe bytes.
    2. **Truncate** -- `ViewText.truncate/2` to `width - 2` display
       columns (2 reserved for the 1-column gutter glyph plus 1 column
       of gutter chrome), CJK-safe (`Raxol.UI.TextMeasure`, never
       `String.length`), ellipsis-truncated when it would overflow.
    3. **Pad** (changed rows only) -- an `:insert`/`:delete` row's
       content is right-padded with spaces to fill the full `width - 2`
       budget, so the row's background wash paints the WHOLE row, not
       just the columns under the text. `:equal` rows are never padded
       (no wash to spread, and padding them would waste width truncating
       real content earlier for no visual benefit).
    4. **Style** -- `:insert` rows get the `▌` gutter bar plus the
       merged palette's `add_base`/`add_row_bg` (`DiffViewer.diff_palette/0`
       -- the single source of these hexes, shared with the grid
       renderer, never a forked copy); `:delete` rows get `del_base`/
       `del_row_bg`. Both wrap the WHOLE composed row (gutter + gap +
       content) in one 24-bit SGR run (`\\e[38;2;r;g;b;48;2;r;g;bm`,
       fg then bg) and a single `\\e[0m` reset at the end -- one run, not
       a mid-row reset, since `\\e[0m` clears background too and a
       second reset partway through the row would cut the wash off
       early. `:equal` rows get a plain space gutter and carry no SGR at
       all -- unstyled content, exactly like every other unchanged
       line in this codebase's diff conventions.

  ## Scope: this is the row-level tier of the diff visual language

  `DiffViewer`'s moduledoc describes several composed tiers: a row wash,
  a brighter intra-line word-diff emphasis tier on top of it, a gutter
  tint, and syntax-highlighted tokens. This line renderer carries only
  the ROW tier -- gutter bar plus full-row wash, read from the exact same
  `DiffViewer.diff_palette/0` hexes. Word-level emphasis (which parts of
  a changed line actually differ) and syntax highlighting are
  `DiffViewer`'s own GRID-rendered tiers (built from several styled
  spans per row, the very composition this module deliberately does not
  reach for -- see "Rendering" above) and are out of scope for a
  single-binary-per-row line renderer. `language` in the content map is
  accepted, unused.

  ## The header

  `render_lines/1` is one header line (the file path under review, the
  scroll position, and the dismiss/scroll hints) followed by exactly the
  visible slice of `lines`. The path is there because full-screen review
  hides the transcript block that named it -- "which file am I
  reviewing" is supervision context the expanded view must carry itself.
  The path is the ELASTIC element: sanitized (producer data) and
  truncated to whatever display-width budget the fixed position/hint
  suffix leaves, so a pathological path can never truncate away the
  scroll position or the dismiss hint. The composed header is then run
  through `Raxol.Harness.Surface.ViewText.lines/3` itself -- the same
  width-truncation budget every content line already obeys, so a narrow
  terminal truncates the header exactly like it would any other row,
  never overflowing it.

  ## Why this maximizes the footer instead of visiting the alternate screen

  The obvious "full-screen" mechanism would be a bracketed alt-screen
  visit (`\e[?1049h` ... `\e[?1049l`) around the expanded diff, exactly
  like a suspended external editor. That was considered and rejected, for
  reasons worth naming honestly rather than assuming away:

    * The inline driver profile's headline invariant is LC-P-NOALT: no
      `\e[?1049h` byte anywhere on this rendering path (see
      `Raxol.Terminal.InlineDriver` and its `Sequences` moduledoc). Even
      the editor-suspend bracket -- the one place this codebase DOES hand
      the terminal to another process -- deliberately releases the
      DECSTBM region instead of visiting the alternate screen. An
      alt-screen diff expansion would be a different terminal contract
      than every other surface this harness renders through, not a
      variant of the same one.
    * No alt-screen capability detection exists anywhere in this
      codebase, and `\e[?1049h` support is not reliably probeable from
      inside a running session -- there is no honest fallback path for a
      terminal that silently ignores or mishandles the sequence.
    * The seal oracle's mechanical byte-walk (the strongest verification
      tool this lane has for "history was never touched") classifies
      `?1049`/`?47` mode switches as unverifiable control tokens -- an
      alt-screen bracket would blind exactly the tool that has to prove
      the sealed-history invariant holds, at the one moment (a
      full-viewport takeover) where that proof matters most.
    * An honest alt-screen visit needs editor-suspend-grade compensation
      machinery: a crash mid-visit stranding the terminal in the alt
      buffer is a real failure mode that has to be planned for. Growing
      the footer instead means a crash mid-expansion just leaves a bigger
      pinned footer -- the existing resize/teardown paths already recover
      that, with no new compensation code.

  The mechanism this module renders FOR is instead footer-region
  maximization: `Raxol.Harness.Surface.expand_focused_diff/1` grows the
  DECSTBM footer (via the same `InlineAuthority.set_footer_rows/2` the
  overlay picker already uses) to the largest claim that still leaves
  history its 2-row minimum, and this module supplies the scrollable
  content that fills it.

  Honest cost of that choice, stated plainly: "full-screen" is
  approximate (history never shrinks below 2 rows, so a sliver of
  scrollback stays visible above the expansion), growing over occupied
  history rows scrolls them into the terminal's native scrollback earlier
  than ordinary streaming would have (the content is unchanged -- the
  seal oracle's scrollback-plus-on-screen-history concatenation is
  invariant under that earlier scroll -- but it happens sooner), and
  dismissing the expansion does not restore whatever scroll position the
  operator had before expanding.
  """

  alias Raxol.Harness.Surface.ViewText
  alias Raxol.UI.Components.Harness.BodyProvider
  alias Raxol.UI.Components.Harness.DiffViewer
  alias Raxol.UI.Components.Harness.LineDiff
  alias Raxol.UI.TextMeasure

  @type t :: %{
          content: map(),
          lines: [String.t()],
          total: non_neg_integer(),
          offset: non_neg_integer(),
          view_rows: pos_integer(),
          width: pos_integer()
        }

  # Reserved for the gutter glyph plus one column of gutter chrome (the
  # gap before content) -- see the moduledoc's "Per-row rendering".
  @gutter_width 2

  @doc """
  Builds a new expansion from a `:diff` content map (`%{path, old, new,
  language}`).

  ## Options

    * `:width` (required) -- display-width budget, `>= 1`.
    * `:view_rows` (required) -- visible content rows (excluding the
      header), `>= 1`.

  Refuses with `{:error, :degenerate_view}` when either geometry value is
  missing or `< 1` -- checked BEFORE content validation, since a
  degenerate viewport can never render anything regardless of content.
  Refuses with `{:error, {:invalid_content, reason}}` when `content` is
  missing a required `:diff` key (`Raxol.UI.Components.Harness.BodyProvider.validate/2`,
  the same schema check `BlockBody` uses for every other kind).
  """
  @spec new(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(content, opts) do
    width = Keyword.get(opts, :width)
    view_rows = Keyword.get(opts, :view_rows)

    case validate_geometry(width, view_rows) do
      :ok -> build(content, width, view_rows)
      error -> error
    end
  end

  defp validate_geometry(width, view_rows)
       when is_integer(width) and width >= 1 and is_integer(view_rows) and
              view_rows >= 1,
       do: :ok

  defp validate_geometry(_width, _view_rows), do: {:error, :degenerate_view}

  defp build(content, width, view_rows) do
    case BodyProvider.validate(:diff, content) do
      :ok ->
        lines = render_diff_lines(content, width)

        {:ok,
         %{
           content: content,
           lines: lines,
           total: length(lines),
           offset: 0,
           view_rows: view_rows,
           width: width
         }}

      {:error, reason} ->
        {:error, {:invalid_content, reason}}
    end
  end

  # One rendered line per `LineDiff` op -- never folded, never split
  # across multiple lines (see the moduledoc's "Rendering" section for
  # why the DiffViewer/ViewText view-tree pipeline is deliberately NOT
  # used here).
  defp render_diff_lines(content, width) do
    old = Map.fetch!(content, :old)
    new = Map.fetch!(content, :new)
    palette = DiffViewer.diff_palette()

    old
    |> LineDiff.diff(new)
    |> Enum.map(&render_row(&1, width, palette))
  end

  defp render_row({kind, raw_line}, width, palette) do
    content_width = max(width - @gutter_width, 0)

    plain =
      raw_line
      |> ViewText.sanitize_line()
      |> ViewText.truncate(content_width)

    build_row(kind, plain, content_width, palette)
  end

  # `:equal` rows: plain gutter space + content, no padding (nothing to
  # wash), no SGR at all.
  defp build_row(:equal, plain, _content_width, _palette) do
    " " <> " " <> plain
  end

  # `:insert`/`:delete`: gutter bar + content padded to fill the FULL
  # content budget (the wash must span the whole row, not stop under the
  # text -- see the moduledoc), then wrapped in one fg+bg SGR run.
  defp build_row(:insert, plain, content_width, palette) do
    style_row(pad(plain, content_width), palette.add_base, palette.add_row_bg)
  end

  defp build_row(:delete, plain, content_width, palette) do
    style_row(pad(plain, content_width), palette.del_base, palette.del_row_bg)
  end

  defp pad(text, width) do
    deficit = width - TextMeasure.display_width(text)
    if deficit > 0, do: text <> String.duplicate(" ", deficit), else: text
  end

  # ONE combined SGR run around the whole row (gutter + gap + content),
  # ONE trailing reset -- never a reset partway through, which would
  # clear the background wash early (`\e[0m` resets fg AND bg).
  defp style_row(padded_content, fg_hex, bg_hex) do
    "\e[" <>
      sgr_rgb(38, fg_hex) <>
      ";" <>
      sgr_rgb(48, bg_hex) <> "m" <> "▌" <> " " <> padded_content <> "\e[0m"
  end

  defp sgr_rgb(mode, "#" <> hex) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex

    "#{mode};2;#{String.to_integer(r, 16)};#{String.to_integer(g, 16)};#{String.to_integer(b, 16)}"
  end

  @doc """
  Scrolls by `delta` rows (negative scrolls up), clamped to
  `0..max(0, total - view_rows)`.
  """
  @spec scroll(t(), integer()) :: t()
  def scroll(t, delta) do
    %{t | offset: clamp_offset(t.offset + delta, t.total, t.view_rows)}
  end

  defp clamp_offset(offset, total, view_rows) do
    offset
    |> max(0)
    |> min(max(total - view_rows, 0))
  end

  @doc """
  Renders the current window: one header line (the file path under
  review + scroll position + dismiss hint) followed by exactly
  `Enum.slice(t.lines, t.offset, t.view_rows)`.

  The path is in the header because full-screen review HIDES the
  transcript block that named it -- "which file am I reviewing" is
  supervision context the expanded view must carry itself. The path is
  the ELASTIC element: it is sanitized (producer data -- the same trust
  boundary every content line goes through) and truncated to whatever
  display-width budget the fixed position/hint suffix leaves, so a
  pathological path can never truncate away the scroll position or the
  dismiss hint.
  """
  @spec render_lines(t()) :: [String.t()]
  def render_lines(t) do
    [header_line(t) | Enum.slice(t.lines, t.offset, t.view_rows)]
  end

  defp header_line(t) do
    first = t.offset + 1
    last = min(t.offset + t.view_rows, t.total)

    suffix = " · #{first}–#{last}/#{t.total} · j/k · esc"
    prefix = "» "

    path_budget =
      t.width - TextMeasure.display_width(prefix <> suffix)

    path =
      t.content
      |> Map.get(:path, "")
      |> ViewText.sanitize_line()
      |> ViewText.truncate(path_budget)

    text = prefix <> path <> suffix

    case ViewText.lines(%{type: :text, content: text}, t.width, :styled) do
      [line | _rest] -> line
      [] -> ""
    end
  end

  @doc """
  Re-renders the SAME `content` at a new `width`/`view_rows` (a resize),
  clamping the current offset to the new geometry's window. Refuses
  exactly like `new/2` when the requested geometry is degenerate,
  leaving `t` untouched.
  """
  @spec resize_view(t(), pos_integer(), pos_integer()) ::
          {:ok, t()} | {:error, :degenerate_view}
  def resize_view(t, width, view_rows)
      when is_integer(width) and width >= 1 and is_integer(view_rows) and
             view_rows >= 1 do
    lines = render_diff_lines(t.content, width)
    total = length(lines)

    {:ok,
     %{
       t
       | lines: lines,
         total: total,
         offset: clamp_offset(t.offset, total, view_rows),
         view_rows: view_rows,
         width: width
     }}
  end

  def resize_view(_t, _width, _view_rows), do: {:error, :degenerate_view}
end
