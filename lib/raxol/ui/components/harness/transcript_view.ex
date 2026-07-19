defmodule Raxol.UI.Components.Harness.TranscriptView do
  @moduledoc """
  The windowed transcript region for the TEA harness (unit U4, spec §4
  "Transcript region", §5 law 7). Renders ONLY the visible slice of the
  sealed `seal_record` list into the element tree — the F0-perf lever: a
  1,000-block session puts at most `height` rows of blocks into the tree,
  not all 1,000 (the spike's finding that `Viewport` slices by item COUNT
  and never consults `item_height/2` is why this windows row-aware here
  instead of leaning on `Viewport`).

  ## Windowing (row-aware, record-granular)

  Records are supplied oldest-first. The window is bottom-anchored by
  `:anchor` (`:tail` keeps the newest record at the bottom — follow;
  a 1-based record index pins that record at the bottom — preserve, law
  7). Whole records are taken from the bottom upward, measuring each
  rendered element's height, until the next record would overflow `:height`
  rows; the top is then padded with blank rows so sealed content hugs the
  footer (V's chat-entry ruling). Only the taken records are ever rendered
  through `Raxol.UI.Components.Harness.BlockBody` — the frozen block bodies
  above the window are never built.

  ## Controlled (spec §2)

  Sealed records are logically immutable (law 1): this component holds no
  fold/scroll state of its own and emits nothing — the TEA model owns all
  of it, and `handle_event/3` is inert. Folds/jumps/scrolls mutate the
  model, which re-supplies `records`/`anchor` on the next render.
  """

  use Raxol.UI.Components.Base.Component

  alias Raxol.UI.Components.Harness.{Block, BlockBody, Indication}
  alias Raxol.UI.Harness.Prominence

  @impl true
  def init(props) do
    props = Map.new(props)

    {:ok,
     %{
       id: Map.get(props, :id, "harness-transcript"),
       records: Map.get(props, :records, []),
       height: Map.get(props, :height, 0),
       anchor: Map.get(props, :anchor, :tail),
       width: Map.get(props, :width, 0),
       source_events: Map.get(props, :source_events, []),
       greeting?: Map.get(props, :greeting?, false),
       # The mirrored dialogue pair (V's margin ruling): `sigil` echoes the
       # user, `reply_sigil` fronts expanded assistant messages. The host
       # passes the capability-degraded pair from the model so the sealed
       # chevrons can never drift from the live composer's.
       sigil: Map.get(props, :sigil, "❯"),
       reply_sigil: Map.get(props, :reply_sigil, "❮"),
       # True when the hosting view renders its own footer answer selector
       # for a live approval — threaded into BlockBody so the block body
       # drops its in-body option list (the selector owns the affordance).
       selector_hosted?: Map.get(props, :selector_hosted?, false)
     }}
  end

  @impl true
  def render(state, context) do
    width = context[:available_width] || state.width
    height = state.height

    children =
      cond do
        height <= 0 ->
          []

        state.records == [] ->
          greeting_rows(state, width, height)

        true ->
          windowed_rows(state, width, height)
      end

    %{
      type: :column,
      id: state.id,
      attrs: %{kind: :transcript, component_module: __MODULE__},
      style: %{},
      gap: 0,
      children: children
    }
  end

  # Sealed history is never re-driven by this component (law 1); folds and
  # scrolls travel through the TEA model, not local state.
  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @doc """
  The row → record map for hit-testing (click-to-fold): exactly `height`
  entries, top-first, each `:pad` or `{:record, record}` — the SAME
  window `render/2` paints (same `take_upward/5` walk, same measured
  heights, same top padding), so a clicked row resolves to the record
  actually under the pointer, never a drifted second computation. A
  record spanning N rows contributes N consecutive entries.
  """
  @spec row_records(map(), pos_integer()) ::
          [:pad | {:record, term()}]
  def row_records(state, width) do
    height = state.height

    cond do
      height <= 0 ->
        []

      state.records == [] ->
        List.duplicate(:pad, height)

      true ->
        ordered = state.records
        total = length(ordered)
        bottom = bottom_index(state.anchor, total)

        {rows, used} =
          Enum.reduce_while(bottom..0//-1, {[], 0}, fn index, {acc, used} ->
            record = Enum.at(ordered, index)
            element = record_element(record, width, state)
            h = element |> clip_tail_if_first(acc, height) |> element_height()

            cond do
              acc == [] ->
                {:cont,
                 {List.duplicate({:record, record}, min(h, height)),
                  min(h, height)}}

              used + h > height ->
                {:halt, {acc, used}}

              true ->
                {:cont, {List.duplicate({:record, record}, h) ++ acc, used + h}}
            end
          end)

        List.duplicate(:pad, max(height - used, 0)) ++ rows
    end
  end

  defp clip_tail_if_first(element, [], max_rows),
    do: clip_tail(element, max_rows)

  defp clip_tail_if_first(element, _acc, _max_rows), do: element

  # ── windowing ─────────────────────────────────────────────────────────

  # Records arrive oldest-first. Bottom-anchor by `anchor`, take whole
  # records upward until the next would overflow `height`, pad the top so
  # content hugs the bottom. Returns exactly `height` rows.
  defp windowed_rows(state, width, height) do
    ordered = state.records
    total = length(ordered)
    bottom = bottom_index(state.anchor, total)

    {visible, used} =
      take_upward(ordered, bottom, width, height, state)

    pad = max(height - used, 0)
    List.duplicate(blank(), pad) ++ visible
  end

  defp bottom_index(:tail, total), do: total - 1

  defp bottom_index(n, total) when is_integer(n),
    do: n |> Kernel.-(1) |> max(0) |> min(total - 1)

  # Walk from `bottom` downward in index (upward on screen), rendering and
  # measuring each record, accumulating until the next record would push
  # the total past `height`. Always includes the bottom record (even if it
  # alone exceeds height — the box clips it). Returns {elements_top_first, rows}.
  defp take_upward(records, bottom, width, height, state) do
    Enum.reduce_while(bottom..0//-1, {[], 0}, fn index, {acc, used} ->
      element = record_element(Enum.at(records, index), width, state)
      h = element_height(element)

      cond do
        acc == [] -> {:cont, {[clip_tail(element, height)], min(h, height)}}
        used + h > height -> {:halt, {acc, used}}
        true -> {:cont, {[element | acc], used + h}}
      end
    end)
  end

  # The bottom record always shows — but the TEA column does NOT clip, so
  # a record taller than the whole window (a live approval mid-diff) must
  # be trimmed here or it pushes the footer off-screen. Trim from the TOP,
  # keeping the tail rows: on a live approval that tail is the answer
  # prompt — the actionable end. Containers trim their child list; a
  # non-container taller than the window is left as-is (nothing row-wise
  # to trim).
  # A `:row` is horizontal — its height is its tallest child, so clip each
  # child down instead of dropping siblings (which would drop the sigil
  # cell off a chevroned message, not save any rows).
  defp clip_tail(%{type: :row, children: children} = el, max_rows)
       when is_list(children) do
    if element_height(el) <= max_rows,
      do: el,
      else: %{el | children: Enum.map(children, &clip_tail(&1, max_rows))}
  end

  defp clip_tail(%{children: children} = el, max_rows)
       when is_list(children) do
    if element_height(el) <= max_rows do
      el
    else
      {kept, _used} =
        children
        |> Enum.reverse()
        |> Enum.reduce_while({[], 0}, fn kid, {acc, used} ->
          h = element_height(kid)

          if used + h > max_rows,
            do: {:halt, {acc, used}},
            else: {:cont, {[kid | acc], used + h}}
        end)

      %{el | children: kept}
    end
  end

  defp clip_tail(el, _max_rows), do: el

  # ── record → element ──────────────────────────────────────────────────

  @sigil_cols 2
  @live_peek_lines 3

  # THE LAW (V's general rule): every record element leaving this
  # function is an `Indication`, an `IndentationException`, or a
  # composite whose top-level children each are — `normalize_record/1`
  # auto-wraps anything else in `Indication.plain/2` (the safe 2-indent
  # default), so a non-compliant producer gets a VISIBLE nudge, never a
  # silent col-0 violation.
  defp record_element(record, width, state) do
    record |> raw_record_element(width, state) |> normalize_record()
  end

  defp raw_record_element({:block, block, prominence}, width, state) do
    dialogue? = dialogue_block?(block)
    body_width = if dialogue?, do: max(width - @sigil_cols, 1), else: width

    rendered =
      BlockBody.render(block, %{
        width: body_width,
        prominence: prominence,
        turn_has_tools?: turn_has_tools?(block, state.source_events),
        id: stable_block_id(block),
        selector_hosted?: state.selector_hosted?
      })

    if dialogue?,
      do: Indication.speaker(rendered, speaker_sigil(block, state)),
      else: rendered
  end

  # A marker is machinery: its `»` (when it carries one) IS the icon —
  # gutter, not string prefix.
  defp raw_record_element({:marker, "» " <> text}, _width, _state) do
    Indication.container(
      %{type: :text, content: text, attrs: %{style: [:dim]}},
      gutter: {:top, "»"},
      gutter_style: %{dim: true}
    )
  end

  defp raw_record_element({:marker, text}, _width, _state),
    do: Indication.plain(%{type: :text, content: text, attrs: %{style: [:dim]}})

  defp raw_record_element({:echo, text}, _width, state),
    do:
      Indication.speaker(%{type: :text, content: text, attrs: %{}}, state.sigil)

  # The ACTIVE thought (V's ruling: live thinking speaks Indication too):
  # a ∵-cornered container — down-dots mark the open start, NO closer
  # until the thought seals — peeking the newest #{@live_peek_lines}
  # lines, or everything when the click toggle expanded it.
  defp raw_record_element({:live_thinking, text, expanded?}, _width, _state) do
    lines = text |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

    shown =
      if expanded?, do: lines, else: Enum.take(lines, -@live_peek_lines)

    # The quiet cognition register (V's ruling: a streaming thought is
    # LOW-prominent): :dim alone reads near-white on many terminals, so
    # the rows carry the same fade ramp sealed machinery uses.
    quiet = %{dim: true, fg: Prominence.resolve("#B4B4B4", 0.5)}

    rows =
      [%{type: :text, content: "thinking", style: quiet}] ++
        Enum.map(shown, fn line ->
          %{type: :text, content: line, style: quiet}
        end)

    Indication.container(
      %{type: :column, gap: 0, style: %{}, children: rows},
      gutter: {:corners, "∵", nil},
      gutter_style: quiet
    )
  end

  defp normalize_record(%{type: :indication} = node), do: node
  defp normalize_record(%{type: :indentation_exception} = node), do: node

  # composite roots whose children each satisfy the law pass through
  # (the stamped approval; a bare column of law nodes)
  defp normalize_record(%{type: type, children: children} = node)
       when type in [:column, :approval_prompt] and is_list(children) do
    if Enum.all?(children, &law_child?/1),
      do: node,
      else: Indication.plain(node)
  end

  defp normalize_record(node), do: Indication.plain(node)

  defp law_child?(%{type: :indication}), do: true
  defp law_child?(%{type: :indentation_exception}), do: true
  defp law_child?(_node), do: false

  defp speaker_sigil(block, state) do
    case Block.role(block) do
      :user -> state.sigil
      :assistant -> state.reply_sigil
    end
  end

  # Only an EXPANDED message speaks with a sigil (surface.ex
  # `dialogue_block?/1` ported): a folded one renders as a `▸ ❯/❮ summary`
  # header via `Block.render/2`'s own role-aware glyph, and fronting THAT
  # with a second chevron would stutter.
  defp dialogue_block?(%{kind: :message, fold: :expanded}), do: true
  defp dialogue_block?(_block), do: false

  defp blank, do: %{type: :text, content: ""}

  # The greeting idles at the transcript BOTTOM (V's placement ruling: one
  # line above the chevron prompt — the host suppresses the composer
  # separator while it shows), at low prominence: it is a costume line,
  # not content — dim + the same fade ramp sealed machinery uses.
  @greeting_prominence 0.5

  defp greeting_rows(%{greeting?: true}, _width, height) do
    faded =
      Raxol.UI.Harness.Prominence.resolve("#B4B4B4", @greeting_prominence)

    List.duplicate(blank(), max(height - 1, 0)) ++
      [
        %{
          type: :text,
          content: "welcome back, operator",
          attrs: %{style: [:dim], fg: faded}
        }
      ]
  end

  defp greeting_rows(_state, _width, height),
    do: List.duplicate(blank(), height)

  # A stable identity for TreeWalker stamping / MCP derivation: the block's
  # journal offsets (its identity key), never a fresh unique integer.
  defp stable_block_id(%{event_refs: refs}) when refs != [],
    do: "block-" <> (refs |> Enum.map(&to_string/1) |> Enum.join("-"))

  defp stable_block_id(_block), do: "block-unknown"

  # A turn carries tools if any event on the block's turn is a tool_use /
  # tool_result (surface.ex:2733, ported).
  defp turn_has_tools?(block, source_events) do
    case block_turn_id(block, source_events) do
      nil ->
        true

      turn_id ->
        Enum.any?(source_events, fn event ->
          Map.get(event, :turn_id) == turn_id and
            event_item_type(event) in ["tool_use", "tool_result"]
        end)
    end
  end

  defp block_turn_id(%{event_refs: [ref | _]}, source_events) do
    case Enum.find(source_events, &(Map.get(&1, :id) == ref)) do
      nil -> nil
      event -> Map.get(event, :turn_id)
    end
  end

  defp block_turn_id(_block, _events), do: nil

  defp event_item_type(event) do
    case Map.get(event, :payload) do
      %{} = payload ->
        Map.get(payload, "item_type", Map.get(payload, :item_type))

      _ ->
        nil
    end
  end

  # ── element height estimate (rows) ──────────────────────────────────────

  @doc """
  Estimates the rendered row count of a View-DSL element — used to window
  the transcript row-aware. A column sums its children (plus gaps), a row
  is the tallest child, a box adds its border, and a text node is one row
  per embedded newline. Close enough to anchor the window; the exact paint
  is the LayoutEngine's.
  """
  @spec element_height(term()) :: non_neg_integer()
  def element_height(%{type: :column} = el) do
    children = children_of(el)
    gap = style_gap(el)
    sum = children |> Enum.map(&element_height/1) |> Enum.sum()
    sum + gap * max(length(children) - 1, 0)
  end

  def element_height(%{type: :row} = el) do
    case el |> children_of() |> Enum.map(&element_height/1) do
      [] -> 0
      heights -> Enum.max(heights)
    end
  end

  def element_height(%{type: :box} = el) do
    inner = children_of(el) |> Enum.map(&element_height/1) |> Enum.sum()
    border = if border?(el), do: 2, else: 0
    padding = padding_rows(el)
    fixed_height(el) || inner + border + padding
  end

  # An `:indication` container is its CONTENT's height — the gutter
  # renders alongside, never adding rows (the engine's own layout law
  # for the node). Missing this clause re-opens the footer-push defect:
  # an expanded thought counted as 1 row shoves the composer off-screen.
  def element_height(%{type: :indication, content: content})
      when is_binary(content),
      do: 1 + count_newlines(content)

  def element_height(%{type: :indication, content: content}),
    do: element_height(content)

  def element_height(%{type: :indentation_exception, content: content}),
    do: element_height(content)

  def element_height(%{type: :text, content: content}) when is_binary(content),
    do: 1 + count_newlines(content)

  def element_height(%{type: :text}), do: 1

  def element_height(list) when is_list(list),
    do: list |> Enum.map(&element_height/1) |> Enum.sum()

  def element_height(nil), do: 0

  # Any other container stacks like a column (`:approval_prompt` — the
  # stamped approval root — lands here). Estimating these as 1 row is the
  # footer-push defect: an 8-row approval counted as 1 overflows the
  # window and shoves the composer off-screen.
  def element_height(%{children: children} = el) when is_list(children) do
    gap = style_gap(el)
    sum = children |> Enum.map(&element_height/1) |> Enum.sum()
    sum + gap * max(length(children) - 1, 0)
  end

  def element_height(_other), do: 1

  defp children_of(el), do: Map.get(el, :children, []) |> List.wrap()

  defp style_gap(el),
    do: el |> Map.get(:style, %{}) |> Map.get(:gap, Map.get(el, :gap, 0)) || 0

  defp border?(el) do
    border = el |> Map.get(:style, %{}) |> Map.get(:border)
    border not in [nil, false]
  end

  defp padding_rows(el) do
    case el |> Map.get(:style, %{}) |> Map.get(:padding) do
      p when is_integer(p) -> p * 2
      _ -> 0
    end
  end

  defp fixed_height(el), do: el |> Map.get(:style, %{}) |> Map.get(:height)

  defp count_newlines(content),
    do: content |> String.graphemes() |> Enum.count(&(&1 == "\n"))
end
