defmodule Raxol.Harness.UnreadDivider do
  @moduledoc """
  The pure unread-divider policy: when the harness surface's operator
  looks away (`blur/2`) and completed blocks keep arriving, on return
  (`focus/2`, or the keystroke fallback `input_activity/2`) exactly one
  "N new since you looked" span is recorded, for the caller to render as
  a full-width rule (`line/2`) in the repaintable footer LIVE region --
  never in sealed history. Every guarantee documented below corresponds
  to a named test in `test/harness/unread_divider_test.exs` (the policy
  suite) or `test/harness/unread_divider_surface_test.exs` (the
  `Raxol.Harness.Surface` integration).

  ## Offsets, not clocks

  Every decision here is a pure function of caller-injected offsets --
  `Raxol.Harness.Surface` feeds `length(model.projection.blocks)` at the
  moment of each call. There is no wall clock, no timestamp, no gap
  threshold anywhere in this module: stricter than `Raxol.Harness.StatusStrip`'s
  own injected-`now` convention, because this policy needs no notion of
  time at all, only "how many blocks have committed since a marked
  point."

  ## The attention machine

  A fresh policy (`new/0`) starts `:attending` with no boundary and no
  span. `blur/2` records the boundary (everything committed before it
  was seen); `focus/2` (or `input_activity/2` while away) opens AT MOST
  one span, `%{from: boundary, count: offset - boundary}`, when the
  caller-supplied offset is strictly past the boundary -- otherwise it
  silently returns to `:attending` with no span (nothing arrived while
  away, or a decreased offset; see "Defensive boundaries and
  reconciliation" below).

  ## One divider per unattended span (merge-on-reblur)

  Repeated `blur/2` calls while already away are no-ops: the EARLIEST
  boundary is kept, never overwritten by a later one. A re-blur while a
  span is still active (the operator glanced back, then looked away
  again before scrolling past the divider) MERGES instead of retiring:
  the new boundary becomes the still-active span's `:from`, not the
  offset of this second blur -- because retiring an unvisited boundary
  in favor of a later one would silently un-mark content the operator
  never actually read. The span itself is discarded at that point (not
  carried forward); the next `focus/2` rebuilds a fresh span from the
  preserved boundary.

  ## Count frozen at return

  Once a span exists, it does not grow. Blocks arriving while the
  operator is demonstrably attending again -- including through
  `input_activity/2`, which is deliberately inert on an existing span --
  are not "new since you looked"; the count is exactly what had
  committed at the moment of return, forever, until `viewed/2` retires
  it.

  ## Clears on scroll-past only

  `viewed/2`, given a block index, retires the active span (and its
  underlying boundary) the moment that index reaches or passes the
  span's `:from`. Keystrokes never clear it: `input_activity/2` is
  presence evidence ("someone is at the keyboard"), not reading evidence
  ("someone has scrolled past this content"), and conflating the two
  would silently hide unread content the moment the operator merely
  types.

  ## Defensive boundaries and reconciliation

  The offsets this module receives are block COUNTS the caller samples
  from a projection that can, in principle, be rebuilt smaller (session
  replay, reattach, truncation). Two independent defenses, honestly
  scoped:

    * **The focus-time guard** (`focus/2`'s `offset <= boundary` clause)
      rejects exactly ONE shape: a single decreased sample at
      focus-time. It cannot see a shrink-then-regrow that lands back
      above the boundary while away -- such a span's count silently
      UNDER-reports (the blocks between the shrink floor and the new
      offset are different content this module has no way to
      distinguish). That is a documented limit, not a covered case.
    * **`reconcile/2`** clamps recorded state against the live offset:
      an active span whose boundary meets or exceeds the offset is
      retired (its marked content no longer exists -- and `viewed/2`'s
      navigation gate would otherwise be permanently unreachable, a
      stuck divider); a span extending past the offset has its count
      clamped; an away boundary above the offset is pulled down.
      `Raxol.Harness.Surface` threads this on every `advance/2` (the
      only place its projection is rebuilt), and `divider/2` applies the
      same clamp read-only at render time, so a stale span can never
      PAINT past reality even before the state itself is reconciled.
      Post-reconcile, an active span always satisfies `from < offset`,
      which restores `viewed/2`'s reachability (the highest navigable
      index, `offset - 1`, can always reach the gate). Reconciliation
      only ever clamps -- growth never inflates a frozen count.

  ## Rendering is width-exact up to a clamp, never `String.length`

  `line/2` sizes its output via `Raxol.UI.TextMeasure.display_width/1`,
  matching every other harness chrome unit's discipline (`StatusStrip`,
  `Raxol.Harness.Surface.ViewText`). The width is clamped to
  `@max_rule_width` (1024) display columns first:
  the caller's width flows from raw terminal geometry (a resize event),
  and an unclamped `String.duplicate/2` would hand a spoofed or absurd
  resize an O(width) allocation on every footer repaint. A width too
  small to hold even the bare label degrades to that bare label
  unpadded, for the caller's `ViewText` truncation seam to finish the
  job -- this module never truncates its own label.

  ## Live-region only (the in-history divider is a deferred upgrade)

  This module has no opinion on WHERE its output is painted -- that is
  `Raxol.Harness.Surface`'s job (see that module's "The unread divider"
  moduledoc section), which renders `line/2`'s output exclusively inside
  the repaintable footer viewport. An in-history divider (a marker
  embedded in sealed, scrolled-off content) would require a
  reflow-capable substrate this harness does not have -- `InlineAuthority`
  only ever seals once, never repaints history -- so it is out of scope
  for v1, not an oversight.

  ## The mode-1004 seam -- INERT at runtime until that unit lands

  `Raxol.Harness.Surface.blur/1` / `Surface.focus/1` are the explicit
  attention API a later focus-event unit (a real terminal-focus-in/out
  signal, mode 1004 in xterm's escape sequence vocabulary) wires
  directly. Be clear about what exists TODAY: `blur/1` has zero
  production callers -- `Raxol.Terminal.AdvancedFeatures.parse_focus_event/1`
  can already parse `\\e[I`/`\\e[O`, but nothing calls it, and
  `Raxol.Terminal.InlineDriver` neither enables mode 1004 nor routes
  focus bytes anywhere. `input_activity/2` (fed on every keystroke) can
  only CLOSE an away state, never open one, so in the running harness
  the machine never leaves `:attending` and the divider never renders.
  This module is exercised end-to-end by its test suites, which drive
  `blur/1` directly; the feature goes live only when the focus-event
  unit wires the driver through -- a deliberate scope cut, not an
  oversight.
  """

  alias Raxol.UI.TextMeasure

  @type attention :: :attending | :away
  @type span :: %{from: non_neg_integer(), count: pos_integer()}
  @type t :: %__MODULE__{
          attention: attention(),
          boundary: non_neg_integer() | nil,
          span: span() | nil
        }

  defstruct attention: :attending, boundary: nil, span: nil

  @label_suffix " new since you looked"

  @doc "A fresh policy: attending, no boundary, no divider."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records the attention boundary. A no-op while already `:away` (keeps
  the earliest boundary -- see the moduledoc's "one divider per
  unattended span"). While a span is active, MERGES: the boundary
  becomes the span's own `:from` (the oldest block the operator never
  actually visited), and the span is discarded (the next `focus/2`
  rebuilds it from the preserved boundary).
  """
  @spec blur(t(), non_neg_integer()) :: t()
  def blur(%__MODULE__{attention: :away} = state, _offset), do: state

  def blur(
        %__MODULE__{attention: :attending, span: %{from: from}} = state,
        _offset
      ) do
    %{state | attention: :away, boundary: from, span: nil}
  end

  def blur(%__MODULE__{attention: :attending} = state, offset) do
    %{state | attention: :away, boundary: offset}
  end

  @doc """
  Returns attention. A no-op while already `:attending` (including when
  no prior `blur/2` ever ran). While `:away`, opens a span of everything
  committed since the boundary when `offset` is strictly past it;
  otherwise (nothing new, or a defensive non-monotone `offset` -- see
  the moduledoc) clears the away state with no span, never a
  zero/negative count.
  """
  @spec focus(t(), non_neg_integer()) :: t()
  def focus(%__MODULE__{attention: :attending} = state, _offset), do: state

  def focus(%__MODULE__{attention: :away, boundary: boundary} = state, offset)
      when offset > boundary do
    %{
      state
      | attention: :attending,
        span: %{from: boundary, count: offset - boundary}
    }
  end

  def focus(%__MODULE__{attention: :away} = state, _offset) do
    %{state | attention: :attending, span: nil, boundary: nil}
  end

  @doc """
  The keystroke fallback (see the moduledoc's "mode-1004 seam"). Acts as
  `focus/2` while `:away`. While already `:attending`, this is ALWAYS a
  no-op -- even with an active span -- because typing is presence
  evidence, not reading evidence (see "clears on scroll-past only").
  """
  @spec input_activity(t(), non_neg_integer()) :: t()
  def input_activity(%__MODULE__{attention: :away} = state, offset),
    do: focus(state, offset)

  def input_activity(%__MODULE__{attention: :attending} = state, _offset),
    do: state

  @doc """
  Scroll-past clear: retires the active span (and its boundary) once
  `block_index` reaches or passes the span's `:from`. A no-op with no
  active span, or when `block_index` is still strictly before it.
  """
  @spec viewed(t(), non_neg_integer()) :: t()
  def viewed(%__MODULE__{span: %{from: from}} = state, block_index)
      when is_integer(block_index) and block_index >= from do
    %{state | span: nil, boundary: nil, attention: :attending}
  end

  def viewed(state, _block_index), do: state

  @doc """
  Clamps recorded state against the live `offset` (see the moduledoc's
  "Defensive boundaries and reconciliation"): retires a span whose
  `:from` meets or exceeds `offset` (its marked content no longer
  exists, and `viewed/2` could never reach it), clamps a span's count to
  the extant blocks past the boundary, and pulls an away boundary down
  to `offset`. Clamp-only: growth never changes anything.
  """
  @spec reconcile(t(), non_neg_integer()) :: t()
  def reconcile(%__MODULE__{span: %{from: from}} = state, offset)
      when offset <= from do
    %{state | span: nil, boundary: nil, attention: :attending}
  end

  def reconcile(%__MODULE__{span: %{from: from, count: count}} = state, offset)
      when offset < from + count do
    %{state | span: %{from: from, count: offset - from}}
  end

  def reconcile(
        %__MODULE__{attention: :away, boundary: boundary} = state,
        offset
      )
      when is_integer(boundary) and boundary > offset do
    %{state | boundary: offset}
  end

  def reconcile(state, _offset), do: state

  @doc "The active span, or `nil` when none is open."
  @spec divider(t()) :: span() | nil
  def divider(%__MODULE__{span: span}), do: span

  @doc """
  The reconciled read: the active span as `reconcile/2` at `offset`
  would leave it, without mutating anything -- the render-time guarantee
  that a stale span never PAINTS past the live block count, even before
  the state itself has been reconciled.
  """
  @spec divider(t(), non_neg_integer()) :: span() | nil
  def divider(state, offset), do: state |> reconcile(offset) |> divider()

  @doc """
  Renders `span` as a full-width `─` rule sized to `width` display
  columns (clamped to `@max_rule_width` -- see the moduledoc's
  "Rendering" section) via `Raxol.UI.TextMeasure.display_width/1` (never
  `String.length` -- see the moduledoc). The label is exactly
  `" \#{count} new since you looked "` (leading and trailing space),
  filled with the box-drawing rule on both sides so the widest widths
  produce `~r/^─+ \\d+ new since you looked ─+$/u`. A width too small to
  fit at least one rule glyph on each side of the padded label falls
  back to the bare (unspaced) label, rule-filled to hit the width
  exactly when it still fits, or entirely unpadded when `width` can't
  even hold that -- left for the caller's `ViewText` truncation seam to
  finish (this module never truncates its own label).
  """
  # The rule-width clamp (see the moduledoc's "Rendering" section): wide
  # enough for any real terminal, small enough that a spoofed resize
  # cannot force an unbounded `String.duplicate/2` on the repaint hot
  # path. `StatusStrip` shares the unclamped-width pattern (its padding
  # is also O(width)) -- a repo-wide clamp at the resize boundary is
  # backlog, not this module's scope; this constant caps the divider's
  # own contribution.
  @max_rule_width 1024

  @spec line(span(), non_neg_integer()) :: String.t()
  def line(%{count: count}, width) when is_integer(width) do
    width = min(width, @max_rule_width)
    bare = "#{count}#{@label_suffix}"
    bare_width = TextMeasure.display_width(bare)
    padded = " " <> bare <> " "
    padded_width = bare_width + 2

    cond do
      width >= padded_width + 2 -> pad_with_rule(padded, width - padded_width)
      width >= bare_width -> pad_with_rule(bare, width - bare_width)
      true -> bare
    end
  end

  defp pad_with_rule(content, extra) do
    left = div(extra, 2)
    right = extra - left
    String.duplicate("─", left) <> content <> String.duplicate("─", right)
  end
end
