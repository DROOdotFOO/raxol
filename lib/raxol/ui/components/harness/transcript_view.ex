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

  alias Raxol.UI.Components.Harness.{Block, BlockBody}

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
       reply_sigil: Map.get(props, :reply_sigil, "❮")
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
        acc == [] -> {:cont, {[element], h}}
        used + h > height -> {:halt, {acc, used}}
        true -> {:cont, {[element | acc], used + h}}
      end
    end)
  end

  # ── record → element ──────────────────────────────────────────────────

  @sigil_cols 2

  defp record_element({:block, block, prominence}, width, state) do
    dialogue? = dialogue_block?(block)
    body_width = if dialogue?, do: max(width - @sigil_cols, 1), else: width

    rendered =
      BlockBody.render(block, %{
        width: body_width,
        prominence: prominence,
        turn_has_tools?: turn_has_tools?(block, state.source_events),
        id: stable_block_id(block)
      })

    if dialogue?, do: sigil_front(rendered, block, state), else: rendered
  end

  defp record_element({:marker, text}, _width, _state),
    do: %{type: :text, content: text, attrs: %{style: [:dim]}}

  defp record_element({:echo, text}, _width, state),
    do: %{type: :text, content: echo_line(text, state), attrs: %{}}

  defp echo_line(text, state), do: state.sigil <> " " <> text

  # Only an EXPANDED message speaks with a sigil (surface.ex
  # `dialogue_block?/1` ported): a folded one renders as a `▸ ❯/❮ summary`
  # header via `Block.render/2`'s own role-aware glyph, and fronting THAT
  # with a second chevron would stutter.
  defp dialogue_block?(%{kind: :message, fold: :expanded}), do: true
  defp dialogue_block?(_block), do: false

  # The speaker chevron fronts the block as a `:row`: the bold 2-cell sigil
  # column, then the body -- every body row lands at the content indent, so
  # continuation lines hang-align exactly like the composer's (V's margin
  # ruling; surface.ex `echo_lines/4` reborn as layout).
  defp sigil_front(rendered, block, state) do
    sigil =
      case Block.role(block) do
        :user -> state.sigil
        :assistant -> state.reply_sigil
      end

    %{
      type: :row,
      style: %{},
      gap: 0,
      children: [
        %{type: :text, content: sigil <> " ", style: %{bold: true}},
        rendered
      ]
    }
  end

  defp blank, do: %{type: :text, content: ""}

  defp greeting_rows(%{greeting?: true}, _width, height) do
    top = div(max(height - 1, 0), 2)

    List.duplicate(blank(), top) ++
      [
        %{
          type: :text,
          content: "welcome back, operator",
          attrs: %{style: [:dim]}
        }
      ] ++
      List.duplicate(blank(), max(height - top - 1, 0))
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

  def element_height(%{type: :text, content: content}) when is_binary(content),
    do: 1 + count_newlines(content)

  def element_height(%{type: :text}), do: 1

  def element_height(list) when is_list(list),
    do: list |> Enum.map(&element_height/1) |> Enum.sum()

  def element_height(nil), do: 0
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
