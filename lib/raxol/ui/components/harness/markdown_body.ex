defmodule Raxol.UI.Components.Harness.MarkdownBody.Checkpoint do
  @moduledoc """
  Carries the frozen (already-parsed) prefix across successive calls to
  `Raxol.UI.Components.Harness.MarkdownBody.render_streaming_incremental/3`.

  All fields are private implementation state -- callers should treat this
  as an opaque token: create one via `MarkdownBody.new_checkpoint/0`, thread
  it through successive `render_streaming_incremental/3` calls, and never
  construct or inspect the fields directly.

  - `frozen_byte_offset` -- raw byte offset into the caller's accumulated
    text, always sitting just past a committed `"\\n"` (never inside a
    line still being typed).
  - `frozen_elements` -- the already-rendered elements for the frozen
    prefix; a genuine prefix of every subsequent view's `:children`.
  - `raw_prefix` -- the exact raw bytes frozen so far, used to detect a
    non-extending (stale/misused) `text` argument on the next call.
  - `sanitized_prefix` -- `to_text/1` of `raw_prefix` (ends with `"\\n"`
    whenever non-empty).
  - `width` -- the width the frozen elements were rendered at; a change
    invalidates the checkpoint (frozen elements are width-dependent).
  """

  defstruct frozen_byte_offset: 0,
            frozen_elements: [],
            raw_prefix: "",
            sanitized_prefix: "",
            width: nil

  @type t :: %__MODULE__{
          frozen_byte_offset: non_neg_integer(),
          frozen_elements: [map()],
          raw_prefix: binary(),
          sanitized_prefix: binary(),
          width: pos_integer() | nil
        }
end

defmodule Raxol.UI.Components.Harness.MarkdownBody do
  @moduledoc """
  Renders a message/reasoning block's Markdown content for the harness
  transcript.

  Extends `Raxol.UI.Components.MarkdownRenderer` (does not change its
  existing behavior -- see that module's own additive GFM table support)
  with a streaming-aware render policy: while a message is still being
  typed/streamed, its trailing text may contain an incomplete construct,
  and this module renders a provisional, closed-up view of that tail
  without ever touching the real (still-growing) source buffer.

  ## Two modes

  - `:sealed` -- the block's `item_completed` content is final; render it
    through a plain full parse (`Raxol.UI.Components.MarkdownRenderer`, no
    transformation).
  - `:streaming` -- the block is still live; the accumulated tail text may
    contain an incomplete construct (an unclosed fence, an unpaired
    `**`/`_`/`` ` ``, a half-written link). `provisional_close/1` computes
    a RENDER-ONLY closed copy of the text -- the caller's source buffer is
    never touched, this module takes a string by value and returns a view,
    nothing more. Discarded on the next delta / at seal: the sealed render
    is always a full parse of the true final content, never a leftover of
    a provisional close.

  ## Provisional-close constructs handled

  A single left-to-right scan of the "prose" portion of the text (fenced
  code content is excluded -- markdown markers inside a code span/block
  are literal, never auto-closed as emphasis) tracks a stack of open
  constructs and appends whatever is still open, in LIFO order, at the
  very end of the text:

  - fenced code block (an odd count of ```` ``` ````/`~~~` fence lines --
    closed by appending a fence line of the SAME marker type that opened
    it; a fence only closes on a matching marker, so a stray `~~~` line
    inside a ```` ``` ```` block never prematurely ends it, and vice
    versa; nothing else is scanned once the buffer ends inside an
    unterminated fence)
  - inline code span (a single `` ` ``)
  - bold (`**` / `__`)
  - italic (`*` / `_`)
  - link text (`[` without a matching `]`) and link URL (`](url` without a
    matching `)`)

  The renderer this module hands off to uses a flat (non-recursive)
  regex grammar -- it can represent at most ONE active emphasis/code/link
  run at a time, never genuine parent-child nesting of different marker
  kinds. So when the truncation point falls inside real nesting (e.g. a
  bold span containing an unfinished italic run), only the OUTERMOST
  still-open construct is closed; any INNER opener that never got a
  chance to close before the cut has its own marker characters stripped
  from the render-only copy -- the real text it introduced is preserved,
  now attributed to the surviving outer construct. Emitting a closer for
  every open frame (LIFO, unconditionally) would produce a marker
  sequence -- like `***`, `___`, or `` `* `` -- the flat grammar can't
  parse back out, which is exactly the raw-marker leak this guards
  against. This is the same "strip a dangling opener rather than leak
  it" idea the module already applies to a content-free opener, just
  widened to cover an un-nestable one too.

  A half-written **table row** needs no closer here.
  `Raxol.UI.Components.MarkdownRenderer`'s table detector fires only once
  a header line and a separator-shaped line (`|---|...`) both exist as
  complete lines in the buffer, so a lone in-progress header renders as
  plain text (harmless literal `|` characters, not a broken frame). Two
  benign streaming shapes follow from that: a partial separator on the
  still-streaming last line (e.g. `|--`, which the lenient detector
  accepts) renders a *premature but well-formed* frame -- header +
  separator, no body rows yet; and a still-in-progress last body row
  renders with a short/ragged final cell. Neither is a broken frame, and
  a narrow width never collapses a column to zero (columns clamp to a
  minimum and the row overflows/wraps like any long line -- see
  `MarkdownRenderer`'s table renderer).

  ## Known limitation

  Backslash-escaped markers (e.g. `\\*`) are not treated as CommonMark
  escapes -- the backslash is scanned as ordinary text and the following
  marker character still toggles/opens its construct normally. Full
  escape handling would need to thread an "escaped" flag through the
  scan; left as a documented gap rather than expanded scope here.

  ## Stable-prefix streaming (incremental render)

  `render_streaming_incremental/3` is the O(live tail) alternative to
  re-parsing the FULL accumulated text on every delta: it accepts the
  full accumulated text, a `width`, and a `Checkpoint` carried from the
  previous call, and returns `{view, checkpoint}` where `view` is EXACTLY
  what `render(text, %{mode: :streaming, width: width})` would return --
  element-for-element, at every prefix. The full re-parse remains the
  correctness oracle; the checkpoint only changes how much work gets
  redone, never what the result is. `new_checkpoint/0` builds the initial
  (empty) checkpoint; `nil` is also accepted as fresh.

  ### The checkpoint rule

  A candidate boundary sits just past a committed `"\\n"` (the still-
  growing last line is never frozen). A boundary is safe only when ALL of
  these hold, each protecting a specific construct's immutability:

  - **fence** -- both the renderer's raw-prefix ```` ``` ````/`~~~`
    matching-marker fence machine AND provisional-close's trimmed-prefix
    fence machine must be closed. A fence parser is forward-only: once a
    matching-marker line closes it, no later byte can reopen it, so a
    closed fence's extent is permanently fixed -- but an OPEN fence's
    extent is not yet known, so nothing inside or at its still-open
    boundary may freeze.
  - **table** -- the line immediately before the boundary must contain no
    `"|"`. A committed `"|"`-line can still become a table HEADER once
    the next line arrives (the header+separator lookahead is 2 lines),
    and a still-absorbing table re-derives column widths over ALL rows,
    so a later row can rewrite an earlier row's rendered text. Excluding
    every pipe-containing line from being the boundary's last line rules
    out both hazards at once.
  - **inline** -- the provisional-close scan stack must be empty. An
    unclosed `` **`` / `*` / `` ` `` / `[` on a committed line receives
    erasures/closers from LATER lines (`resolve_inline_close/1` looks at
    the tail of the whole prose run), so a boundary with live inline
    state is not stable.
  - **single-line constructs** (headings, hr, blockquote, list items,
    plain paragraphs) are immutable the moment their `"\\n"` arrives --
    this grammar nests only via fences and tables, both covered above.
  - **UTF-8** -- the frozen raw segment must be valid UTF-8 on its own
    (bounded by the longest valid UTF-8 prefix of the live tail). Whole-
    buffer Latin-1 recovery (`recover_utf8/1`) is not tail-composable, so
    a boundary past a genuinely-invalid byte would freeze the wrong
    (recovered) bytes. `"\\r"` needs no special handling: sanitize
    preserves both `"\\r"` and `"\\n"`, so a CRLF split lands like any
    other chunk boundary.

  ### Cap interaction

  The 256KB cap (`@render_byte_cap`) applies to the TOTAL sanitized text
  (frozen prefix + live tail), matching the full re-parse's own cap
  check. Above it, the view is the same plain-text fallback the full
  re-parse would produce, and the checkpoint RESETS to fresh -- the next
  call re-derives everything from scratch rather than growing an
  unbounded frozen-elements list past the cap.

  ### Misuse guard

  `text` must be an append-only extension of the previous call's `text`
  at the same `width`; `render_streaming_incremental/3` verifies this by
  byte-comparing the accumulated text's prefix against the checkpoint's
  own frozen raw bytes. A width change or a non-extending `text` (stale
  checkpoint reused against unrelated content) resets to a fresh
  checkpoint and a full parse -- the output is always oracle-correct,
  never corrupted by a misused checkpoint.

  ### Garbage degradation

  A genuinely-invalid byte permanently blocks the checkpoint from
  advancing past it (the UTF-8 rule above), so a message containing
  arbitrary garbage degrades to the pre-optimization behavior: a full
  re-parse of the accumulated text on every delta, still capped at
  `@render_byte_cap` bytes like any other streaming render.

  ### Follow-up seam

  `render/2` and `render_streaming/2` are unchanged -- nothing here
  alters sealed or full-streaming rendering. Wiring a caller (e.g.
  `BodyProvider`) to actually carry a `Checkpoint` across deltas, instead
  of calling `render_streaming/2` fresh each time, is the follow-up seam
  this module leaves open.
  """

  alias __MODULE__.Checkpoint
  alias Raxol.UI.Components.MarkdownRenderer
  alias Raxol.View.Components

  @type mode :: :sealed | :streaming

  @doc """
  The single vocabulary bridge from a block's seal state (`:live |
  :sealed`, see `Raxol.UI.Components.Harness.Block`) to this module's
  render mode: `:live -> :streaming`, `:sealed -> :sealed`. Every call
  site that glues block seal to Markdown rendering (`BodyProvider`'s
  `:message` props, `Block.render/2`'s `context[:markdown]` path) MUST
  use this rather than re-deriving the mapping -- two names for the same
  binary state is already one too many.
  """
  @spec mode_for_seal(Raxol.UI.Components.Harness.Block.seal_state()) :: mode()
  def mode_for_seal(:live), do: :streaming
  def mode_for_seal(:sealed), do: :sealed

  # Above this byte size, both the provisional-close scan and the
  # downstream render/parse skip their normal work and fall back to a
  # cheap identity/plain-text path. Pure insurance: the scan is
  # single-pass O(n) so it stays fast well past this, but a
  # multi-hundred-KB single streamed message is degenerate -- the
  # incomplete-construct-flash risk (for the scan) and the repeated-
  # full-reparse cost (for the render, paid again on every delta) are
  # both negligible against the ceiling this trades them for. Never
  # reached by normal deltas.
  @render_byte_cap 256 * 1024

  @doc """
  Renders `markdown_text` per `context[:mode]` (`:sealed` default) and
  `context[:width]` (defaults to `Raxol.Core.Defaults.terminal_width/0`).
  Never raises -- arbitrary/garbage/invalid-UTF-8 input always yields
  some safe view.
  """
  @spec render(term(), map()) :: map()
  def render(markdown_text, context \\ %{}) do
    width = Map.get(context, :width, Raxol.Core.Defaults.terminal_width())

    case Map.get(context, :mode, :sealed) do
      :streaming -> render_streaming(markdown_text, width)
      _sealed -> render_sealed(markdown_text, width)
    end
  rescue
    _ -> fallback_view(to_text(markdown_text))
  end

  @doc """
  Full parse -- the seal-time render. `markdown_text` is trusted to be
  the item's final, complete content (`item_completed.content`, never a
  concatenation of deltas).
  """
  @spec render_sealed(term(), pos_integer()) :: map()
  def render_sealed(markdown_text, width) do
    markdown_text |> to_text() |> render_via(width)
  end

  @doc """
  Streaming render: `provisional_close/1` on a copy of `markdown_text`,
  then a full parse of THAT -- never the original. The caller's buffer is
  untouched; this function takes a value and returns a value.
  """
  @spec render_streaming(term(), pos_integer()) :: map()
  def render_streaming(markdown_text, width) do
    markdown_text |> to_text() |> provisional_close() |> render_via(width)
  end

  @doc """
  A fresh, empty `Checkpoint` -- the starting point for a new streamed
  message. Also see the `nil` shorthand accepted by
  `render_streaming_incremental/3`.
  """
  @spec new_checkpoint() :: Checkpoint.t()
  def new_checkpoint, do: %Checkpoint{}

  @doc """
  Incremental streaming render: `text` is the FULL accumulated text
  (append-only across deltas -- never just the newest chunk), `width` is
  the render width, and `checkpoint` is the `Checkpoint` returned by the
  previous call (or `nil`/`new_checkpoint/0` for the first call).

  Returns `{view, checkpoint}`. `view` is always exactly what
  `render(text, %{mode: :streaming, width: width})` would return; the
  checkpoint only changes how much of `text` gets re-parsed, never the
  result. Never raises. See the moduledoc's "Stable-prefix streaming"
  section for the full checkpoint rule.
  """
  @spec render_streaming_incremental(
          term(),
          pos_integer(),
          Checkpoint.t() | nil
        ) ::
          {map(), Checkpoint.t()}
  def render_streaming_incremental(text, width, checkpoint) do
    do_render_streaming_incremental(text, width, checkpoint)
  rescue
    _ -> {render(text, %{mode: :streaming, width: width}), new_checkpoint()}
  end

  defp do_render_streaming_incremental(text, width, _checkpoint)
       when not is_binary(text) do
    {render(text, %{mode: :streaming, width: width}), new_checkpoint()}
  end

  defp do_render_streaming_incremental(text, width, checkpoint) do
    if Code.ensure_loaded?(EarmarkParser) do
      {render(text, %{mode: :streaming, width: width}), new_checkpoint()}
    else
      cp = validate_checkpoint(checkpoint, width, text)
      incremental_render(text, width, cp)
    end
  end

  defp validate_checkpoint(nil, _width, _text), do: new_checkpoint()

  defp validate_checkpoint(%Checkpoint{} = cp, width, text) do
    cond do
      cp.width != width ->
        new_checkpoint()

      byte_size(text) < cp.frozen_byte_offset ->
        new_checkpoint()

      binary_part(text, 0, cp.frozen_byte_offset) != cp.raw_prefix ->
        new_checkpoint()

      true ->
        cp
    end
  end

  defp validate_checkpoint(_other, _width, _text), do: new_checkpoint()

  defp incremental_render(text, width, cp) do
    raw_tail =
      binary_part(
        text,
        cp.frozen_byte_offset,
        byte_size(text) - cp.frozen_byte_offset
      )

    sanitized_tail = to_text(raw_tail)
    s_total_size = byte_size(cp.sanitized_prefix) + byte_size(sanitized_tail)

    if s_total_size > @render_byte_cap do
      closed_total = cp.sanitized_prefix <> sanitized_tail
      {fallback_view(closed_total), new_checkpoint()}
    else
      closed_tail = do_provisional_close(sanitized_tail)

      if byte_size(cp.sanitized_prefix) + byte_size(closed_tail) >
           @render_byte_cap do
        {fallback_view(cp.sanitized_prefix <> closed_tail), new_checkpoint()}
      else
        tail_elements = MarkdownRenderer.render_with_builtin(closed_tail, width)

        view = %{
          type: :column,
          children: cp.frozen_elements ++ tail_elements,
          style: %{},
          gap: 0
        }

        new_cp = advance_checkpoint(cp, text, raw_tail, sanitized_tail, width)
        {view, new_cp}
      end
    end
  end

  defp advance_checkpoint(cp, text, raw_tail, sanitized_tail, width) do
    lines = String.split(sanitized_tail, "\n")
    complete_line_count = length(lines) - 1

    case find_safe_boundary(lines, complete_line_count, raw_tail) do
      nil ->
        cp

      {raw_delta, san_delta} ->
        segment_sanitized = binary_part(sanitized_tail, 0, san_delta)
        seg_parse_text = binary_part(segment_sanitized, 0, san_delta - 1)

        seg_elements =
          MarkdownRenderer.render_with_builtin(seg_parse_text, width)

        %Checkpoint{
          frozen_byte_offset: cp.frozen_byte_offset + raw_delta,
          frozen_elements: cp.frozen_elements ++ seg_elements,
          raw_prefix: binary_part(text, 0, cp.frozen_byte_offset + raw_delta),
          sanitized_prefix: cp.sanitized_prefix <> segment_sanitized,
          width: width
        }
    end
  end

  # Finds the LAST safe boundary among `sanitized_tail`'s complete lines
  # (the first `complete_line_count` entries of `lines` -- the final,
  # still-partial line is never a candidate). Threads four pieces of
  # state left-to-right, all starting clean per the invariant that the
  # frozen prefix always ends balanced: the renderer's raw-prefix fence
  # machine, provisional-close's trimmed-prefix fence machine, and the
  # inline scan stack (updated only on lines the trimmed machine tags
  # `:prose`). Returns `{raw_delta, san_delta}` for the winning candidate
  # or `nil` if none survive.
  defp find_safe_boundary(_lines, 0, _raw_tail), do: nil

  defp find_safe_boundary(lines, complete_line_count, raw_tail) do
    {valid_prefix, _rest} = longest_valid_utf8_prefix(raw_tail)
    max_raw_delta = byte_size(valid_prefix)

    raw_newline_positions =
      raw_tail
      |> :binary.matches("\n")
      |> Enum.map(fn {pos, _len} -> pos end)

    # Zip pairs the i-th complete sanitized line with the i-th raw "\n"
    # position -- a 1:1 correspondence (sanitize never touches "\n", and
    # UTF-8 recovery neither drops nor invents a 0x0A byte), and O(1) per
    # line where an indexed lookup would be O(i).
    {_final_state, best, _san_offset} =
      lines
      |> Enum.take(complete_line_count)
      |> Enum.zip(raw_newline_positions)
      |> Enum.reduce({{false, false, []}, nil, 0}, fn {line, raw_pos},
                                                      {state, best, san_offset} ->
        {new_state, safe?} = step_scan_state(state, line)
        san_offset = san_offset + byte_size(line) + 1
        raw_delta = raw_pos + 1

        best =
          if safe? and raw_delta <= max_raw_delta,
            do: {raw_delta, san_offset},
            else: best

        {new_state, best, san_offset}
      end)

    best
  end

  defp step_scan_state({m1, m2, stack}, line) do
    {new_m1, tag1} = fence_step(m1, fence_marker_of(line))
    {new_m2, _tag2} = fence_step(m2, raw_fence_marker_of(line))

    new_stack =
      if tag1 == :prose do
        scan_markers(String.graphemes(line), 0, stack)
      else
        stack
      end

    safe? =
      new_m1 == false and new_m2 == false and new_stack == [] and
        not String.contains?(line, "|")

    {{new_m1, new_m2, new_stack}, safe?}
  end

  # The renderer's own fence detector (`parse_blocks`/`take_until_fence`)
  # matches the RAW line, no leading-whitespace trim -- unlike
  # `fence_marker_of/1` (provisional-close's trimmed version). Kept
  # separate because the two parsers can (and, per the directed hazard
  # tests, do) disagree on indented fence markers.
  defp raw_fence_marker_of(line) do
    cond do
      String.starts_with?(line, "```") -> "```"
      String.starts_with?(line, "~~~") -> "~~~"
      true -> nil
    end
  end

  # Above this byte size, rendering skips the parse entirely and falls
  # back to a single plain-text view. It guards the EXPENSIVE side of the
  # pipeline (a full re-parse of the whole buffer, paid on every
  # streaming delta) the same way `@render_byte_cap`'s check in
  # `provisional_close/1` guards the cheap scan -- without this, a
  # multi-hundred-KB message would re-run a full parse on every single
  # delta even though the provisional-close scan itself was skipped.
  defp render_via(text, width) do
    if byte_size(text) > @render_byte_cap do
      fallback_view(text)
    else
      {:ok, state} = MarkdownRenderer.init(%{markdown_text: text, width: width})
      MarkdownRenderer.render(state, %{})
    end
  rescue
    _ -> fallback_view(text)
  end

  defp fallback_view(text) do
    %{
      type: :column,
      gap: 0,
      style: %{},
      children: [Components.text(content: text)]
    }
  end

  defp to_text(text) when is_binary(text) do
    text |> ensure_valid_utf8() |> sanitize_controls()
  end

  defp to_text(other), do: other |> inspect() |> sanitize_controls()

  defp ensure_valid_utf8(text) do
    if String.valid?(text), do: text, else: recover_utf8(text)
  end

  # A streamed delta can arrive mid multi-byte grapheme (an "e" + a
  # combining accent, a CJK character, an emoji codepoint -- all split
  # across a chunk boundary), so `text` may be invalid UTF-8 purely
  # because its TAIL is an incomplete codepoint that will complete once
  # the next delta arrives. Naively reinterpreting the WHOLE buffer as
  # Latin-1 in that case mojibakes every already-committed, already-valid
  # character too (a leading "cafe" + valid multi-byte accent becomes
  # "cafe" + two garbage Latin-1 glyphs, and that garbled render can flash
  # onto the transcript for a frame before the next delta fixes it -- a
  # regression, not just cosmetic noise). Instead: keep the longest valid
  # UTF-8 prefix untouched, and only fall back to a lossy re-encoding for
  # the trailing bytes -- and only when those bytes could NEVER become
  # valid no matter what follows (i.e. they are not merely truncated).
  defp recover_utf8(binary) do
    {valid_prefix, rest} = longest_valid_utf8_prefix(binary)

    cond do
      rest == "" -> valid_prefix
      plausibly_truncated_utf8?(rest) -> valid_prefix
      true -> valid_prefix <> latin1_fallback(rest)
    end
  end

  defp longest_valid_utf8_prefix(binary),
    do: longest_valid_utf8_prefix(binary, [])

  defp longest_valid_utf8_prefix(<<codepoint::utf8, rest::binary>>, acc),
    do: longest_valid_utf8_prefix(rest, [<<codepoint::utf8>> | acc])

  defp longest_valid_utf8_prefix(rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  # A leftover 1-3 byte tail is "plausibly truncated" (as opposed to
  # genuinely malformed) iff padding it out with SOME small number of
  # UTF-8 continuation bytes (`0x80..0xBF`, and `0xBF` is a valid
  # continuation byte for every multi-byte lead) makes it valid -- i.e.
  # it really was the start of a longer codepoint, just cut short.
  defp plausibly_truncated_utf8?(tail) when byte_size(tail) in 1..3 do
    Enum.any?(1..3, fn n -> String.valid?(tail <> :binary.copy(<<0xBF>>, n)) end)
  end

  defp plausibly_truncated_utf8?(_tail), do: false

  # Genuinely-invalid bytes (arbitrary garbage, e.g. `StreamData.binary()`
  # in the fuzz suite) still need a total, never-raising fallback --
  # reinterpreted as Latin-1 (total over all 256 byte values), falling
  # back to `inspect/1` only if even that somehow fails.
  defp latin1_fallback(binary) do
    case :unicode.characters_to_binary(binary, :latin1) do
      converted when is_binary(converted) -> converted
      _ -> inspect(binary)
    end
  end

  # Untrusted (e.g. LLM-generated) markdown must never carry a raw C0/C1
  # control byte, DEL, or -- critically -- an ESC (`\e`) out of this
  # module: an embedded ESC/OSC sequence would reach the terminal
  # renderer as if it were a real control sequence (cursor move, screen
  # clear, a fake window-title write), which is exactly the "never embed
  # raw ANSI in text()" rule this codebase enforces at the View-DSL
  # boundary. `\n` and `\t` are the only control characters that are
  # ever meaningful here, so both are kept; everything else in C0
  # (`0x00-0x1F` minus those two), DEL (`0x7F`), and C1 (`0x80-0x9F`) is
  # removed.
  @control_chars_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{0080}-\x{009F}]/u

  defp sanitize_controls(text),
    do: String.replace(text, @control_chars_pattern, "")

  # --- provisional close (render-only closing of incomplete constructs) ----

  @doc """
  Render-only provisional close of incomplete Markdown constructs in
  `text`. Pure: returns a NEW string, never mutates or reads any external
  state. Safe on arbitrary input (garbage, invalid UTF-8, empty string) --
  never raises. Runs in a single pass, time linear in `byte_size(text)`
  (above `#{@render_byte_cap}` bytes the scan is skipped and `text` is
  returned unchanged -- a degradation ceiling, not the bound).
  """
  @spec provisional_close(String.t()) :: String.t()
  def provisional_close(text) when is_binary(text) do
    text = to_text(text)

    if byte_size(text) > @render_byte_cap do
      text
    else
      do_provisional_close(text)
    end
  rescue
    _ -> to_text(text)
  end

  defp do_provisional_close(text) do
    # A still-in-progress last line consisting of ONLY 1-2 backticks (not
    # yet the 3 that make a real fence -- see `fence_marker_of/1`),
    # possibly followed by a partial language tag, is ambiguous: it might
    # become a ``` fence on the next delta, or it might not. Either way
    # it must never be scanned as inline code -- "``" alone is a code
    # span whose captured content would be empty, which the renderer's
    # regex can't match (requires >= 1 char), so it would leak as
    # literal backticks. Stripping it from the render-only copy is the
    # same tail-strip the inline scan below applies to a content-free
    # opener.
    text = strip_ambiguous_fence_opener(text)
    lines = String.split(text, "\n")
    {fence_marker, tagged_lines} = fence_scan(lines)

    if fence_marker do
      text <> "\n" <> fence_marker
    else
      prose_lines = for {:prose, line} <- tagged_lines, do: line
      prose_text = Enum.join(prose_lines, "\n")
      {erasures, closer} = resolve_inline_close(prose_text)
      corrected_prose_text = apply_erasures(prose_text, erasures) <> closer
      reassemble(tagged_lines, corrected_prose_text)
    end
  end

  @fence_opener_ambiguous ~r/^`{1,2}\w*$/

  defp strip_ambiguous_fence_opener(text) do
    if String.ends_with?(text, "\n") do
      text
    else
      last_line = text |> String.split("\n") |> List.last()

      if last_line != "" and Regex.match?(@fence_opener_ambiguous, last_line) do
        drop_last_graphemes(text, String.length(last_line))
      else
        text
      end
    end
  end

  # Toggles fence state per fence-marker line, tagging every line (in
  # original order) as `{:fence, line}` or `{:prose, line}` so
  # `reassemble/2` can splice a corrected prose rendering back into its
  # original position without disturbing fenced content. A fence only
  # closes on a line that opens with the SAME marker (```` ``` ```` vs
  # `~~~`) it was opened with -- a stray line of the OTHER marker type
  # while a fence is open is just fence content, not a closer. Returns
  # the marker string that is still open (or `false` if every fence
  # closed) as the first element.
  defp fence_scan(lines) do
    {fence_marker, tagged_rev} =
      Enum.reduce(lines, {false, []}, fn line, {fence_marker, acc} ->
        {new_marker, tag} = fence_step(fence_marker, fence_marker_of(line))
        {new_marker, [{tag, line} | acc]}
      end)

    {fence_marker, Enum.reverse(tagged_rev)}
  end

  # One line's contribution to the fence state machine: `fence_marker` is
  # the currently-open marker (or `false`), `line_marker` is what THIS
  # line looks like as a fence opener/closer (or `nil` for an ordinary
  # line). Returns `{new_fence_marker, tag}` where `tag` is `:fence` for
  # an opener, closer, or already-inside-a-fence line, `:prose` otherwise.
  defp fence_step(false, nil), do: {false, :prose}
  defp fence_step(false, line_marker), do: {line_marker, :fence}
  defp fence_step(marker, marker), do: {false, :fence}
  defp fence_step(marker, _line_marker), do: {marker, :fence}

  defp fence_marker_of(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "```") -> "```"
      String.starts_with?(trimmed, "~~~") -> "~~~"
      true -> nil
    end
  end

  # Splices `corrected_prose_text` (the inline-closed rendering of just
  # the prose lines, joined by "\n") back into `tagged_lines`' original
  # line order, leaving every `:fence` line byte-identical to the
  # source. Safe because inline closing/erasure never adds or removes a
  # "\n": `String.split(corrected_prose_text, "\n")` always yields
  # exactly as many lines as there were `:prose` entries.
  defp reassemble(tagged_lines, corrected_prose_text) do
    corrected_prose_lines = String.split(corrected_prose_text, "\n")

    {lines, _remaining} =
      Enum.map_reduce(tagged_lines, corrected_prose_lines, fn
        {:fence, line}, remaining -> {line, remaining}
        {:prose, _line}, [next | remaining] -> {next, remaining}
        {:prose, _line}, [] -> {"", []}
      end)

    Enum.join(lines, "\n")
  end

  # Determines how the LIVE TAIL of `prose_text` (the portion after the
  # last durable line boundary) should be provisionally closed, in a
  # SINGLE left-to-right pass -- O(byte_size(prose_text)):
  #
  #   1. one scan (`scan_markers/3`) builds the open-construct stack,
  #      each frame `{kind, opener_index}`, O(1) per grapheme;
  #   2. one tail-walk (`unwind/3`) resolves it into a set of graphemes
  #      to erase plus (at most) one trailing closer.
  #
  # Why erasure is needed at all: naively appending a closer for a
  # construct with NO content yet (its opener is the last thing typed,
  # e.g. "Summary of the **") produces a degenerate empty span ("****")
  # the underlying renderer's regex won't match (it requires >= 1
  # non-marker char between delimiters), which would leak the raw marker
  # right back out. And the renderer's flat grammar can represent only
  # ONE active emphasis/code/link run at a time -- so if the cut lands
  # inside real nesting (two or more DIFFERENT kinds open at once, e.g. a
  # bold span containing an unfinished italic run), only the outermost
  # one can be closed; any inner opener that never closed is erased
  # instead (its real content is kept, just no longer styled as its own
  # separate construct). Both cases are handled by the same mechanism:
  # `unwind/3` erases an opener's own token rather than closing it,
  # either because there was nothing after it (content-free) or because
  # something else still encloses it.
  #
  # Returns `{erasures, closer}` where `erasures` is a list of
  # `{grapheme_index, grapheme_count}` ranges (each identifying a set of
  # opener graphemes to drop from `prose_text`) and `closer` is the
  # (possibly empty) string to append after erasure.
  defp resolve_inline_close(prose_text) do
    graphemes = String.graphemes(prose_text)
    stack = scan_markers(graphemes, 0, [])
    unwind(stack, length(graphemes), [])
  end

  defp unwind([], _pos, erasures), do: {erasures, ""}

  defp unwind([{kind, idx} | tail], pos, erasures) do
    len = opener_len(kind)

    cond do
      idx + len == pos ->
        # opener flush against the tail -> content-free -> erase it and
        # move the tail back over its token, then re-examine what's
        # below (a chain of nested empty openers collapses fully here,
        # no re-scan needed).
        unwind(tail, idx, [{idx, len} | erasures])

      tail == [] ->
        # the outermost surviving frame, with genuine content after it --
        # the one construct the flat grammar can still close.
        {erasures, closer_for(kind)}

      true ->
        # genuine content follows, but something else still (differently)
        # encloses this frame -- true nesting truncated mid-stream. The
        # flat grammar can only keep one run open at a time, so this
        # inner marker can't be honored as styling; erase just its own
        # opener token (the real content after it is preserved,
        # attributed to whatever encloses it) and let the enclosing
        # frame resolve against the true tail.
        unwind(tail, pos, [{idx, len} | erasures])
    end
  end

  # Grapheme length of a construct's OPENING token (what `unwind/3` erases
  # for a content-free or un-nestable frame). `:link_url`'s opener is the
  # lone `(` -- the `]` belongs to the link text and must survive -- hence 1.
  defp opener_len(:bold_star), do: 2
  defp opener_len(:bold_under), do: 2
  defp opener_len(:code), do: 1
  defp opener_len(:italic_star), do: 1
  defp opener_len(:italic_under), do: 1
  defp opener_len(:link_text), do: 1
  defp opener_len(:link_url), do: 1

  defp drop_last_graphemes(text, 0), do: text

  defp drop_last_graphemes(text, n) do
    text |> String.graphemes() |> Enum.drop(-n) |> Enum.join()
  end

  # Removes every grapheme covered by `erasures` (a list of
  # `{start_index, count}` ranges over `text`'s own grapheme list) --
  # used to drop a stripped opener's token from wherever it sits in
  # `text`, not just its tail.
  defp apply_erasures(text, []), do: text

  defp apply_erasures(text, erasures) do
    erased_indices =
      for {idx, len} <- erasures,
          i <- idx..(idx + len - 1),
          into: MapSet.new(),
          do: i

    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reject(fn {_grapheme, i} -> MapSet.member?(erased_indices, i) end)
    |> Enum.map_join(&elem(&1, 0))
  end

  # Single left-to-right pass building a stack of `{kind, opener_index}`
  # open constructs (top first; `opener_index` = the grapheme position of
  # the construct's opening token). O(1) per grapheme -- push/pop plus an
  # index bump, never any work proportional to stack depth. Whether a
  # frame is ultimately content-free, or is un-nestable next to a
  # different already-open kind, is NOT tracked here; `unwind/3` derives
  # both, once, at the tail.
  #
  # Precedence: whenever the stack is topped by `:code`, every grapheme is
  # literal except the matching closing backtick (CommonMark: nothing is
  # parsed inside an inline code span). Otherwise `**`/`__` (two-grapheme
  # lookahead) are checked before single `*`/`_` so bold is preferred over
  # italic on a run of stars/underscores, matching common nesting.
  defp scan_markers([], _idx, stack), do: stack

  # inside a code span: every grapheme literal until the matching backtick
  defp scan_markers([grapheme | rest], idx, [{:code, _} | tail] = stack) do
    if grapheme == "`",
      do: scan_markers(rest, idx + 1, tail),
      else: scan_markers(rest, idx + 1, stack)
  end

  defp scan_markers(["*", "*" | rest], idx, stack),
    do: toggle(:bold_star, rest, idx, 2, stack)

  defp scan_markers(["_", "_" | rest], idx, stack),
    do: toggle(:bold_under, rest, idx, 2, stack)

  # `](` closes the (now-complete) link text and opens the URL. The URL's
  # opener is the lone `(` at `idx + 1`: stripping a content-free URL then
  # removes only `(`, leaving the `]` that terminates the link text.
  defp scan_markers(["]", "(" | rest], idx, stack),
    do: enter_link_url(rest, idx, stack)

  defp scan_markers(["`" | rest], idx, stack),
    do: toggle(:code, rest, idx, 1, stack)

  defp scan_markers(["*" | rest], idx, stack),
    do: toggle(:italic_star, rest, idx, 1, stack)

  defp scan_markers(["_" | rest], idx, stack),
    do: toggle(:italic_under, rest, idx, 1, stack)

  defp scan_markers(["[" | rest], idx, stack),
    do: scan_markers(rest, idx + 1, [{:link_text, idx} | stack])

  defp scan_markers(["]" | rest], idx, stack),
    do: close_marker(:link_text, rest, idx, 1, stack)

  defp scan_markers([")" | rest], idx, stack),
    do: close_marker(:link_url, rest, idx, 1, stack)

  defp scan_markers([_grapheme | rest], idx, stack),
    do: scan_markers(rest, idx + 1, stack)

  defp toggle(kind, rest, idx, len, stack) do
    case stack do
      [{^kind, _} | tail] -> scan_markers(rest, idx + len, tail)
      _ -> scan_markers(rest, idx + len, [{kind, idx} | stack])
    end
  end

  defp enter_link_url(rest, idx, stack) do
    case stack do
      [{:link_text, _} | tail] ->
        scan_markers(rest, idx + 2, [{:link_url, idx + 1} | tail])

      _ ->
        scan_markers(rest, idx + 2, stack)
    end
  end

  defp close_marker(kind, rest, idx, len, stack) do
    case stack do
      [{^kind, _} | tail] -> scan_markers(rest, idx + len, tail)
      _ -> scan_markers(rest, idx + len, stack)
    end
  end

  defp closer_for(:code), do: "`"
  defp closer_for(:bold_star), do: "**"
  defp closer_for(:bold_under), do: "__"
  defp closer_for(:italic_star), do: "*"
  defp closer_for(:italic_under), do: "_"
  defp closer_for(:link_text), do: "]"
  defp closer_for(:link_url), do: ")"
end
