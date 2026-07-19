defmodule Raxol.Harness.HarnessApp.View do
  @moduledoc """
  The pure TEA view for `Raxol.Harness.HarnessApp` — Surface's
  `paint_viewport/1` / `footer_frame/1` / cursor calc reborn as an element
  tree (spec §2 mapping table line 106; §5 laws 3/6/7). It emits elements,
  never SGR rows: the Preparer → LayoutEngine → UIRenderer → ScreenBuffer
  pipeline turns them into bytes.

  ## Composition (surface.ex `paint_viewport/1`)

  ```
  column
    ├─ TranscriptView   — the windowed visible slice of seal_records (law 7)
    └─ FooterStack      — status / lane / submitting / preview / composer /
                          notice groups, fit to a row budget (law 3)
  ```

  Root `:cursor` = the composer edit point lowered to absolute buffer
  coordinates (law 6), or absent when an overlay owns the keys. An open
  overlay wraps the whole tree in an `AbsoluteLayer` — the overlay is a
  centered, backdrop-dimming layout child painted OVER the footer/transcript
  (U3's gap-closer: full-viewport overlays HOST, never refuse).
  """

  alias Raxol.Harness.HarnessApp.Model
  alias Raxol.UI.Components.AbsoluteLayer

  alias Raxol.UI.Components.Harness.{
    BlockBody,
    ChoicePrompt,
    CommandAutocomplete,
    Composer,
    FooterStack,
    MemoryPanel,
    Notice,
    Picker,
    RulesPanel,
    StatusStrip,
    TranscriptView,
    WorktracksPanel
  }

  # The fit-law drop order (surface.ex:5069; §5 law 3). Most-droppable
  # FIRST, each trimmed from its tail. `:lane`, `:submitting`, `:notice`
  # are absent → never shed (the honest-report channels).
  @drop_order [:composer_sep, :preview, :divider, :composer, :overlay, :status]

  @doc "Renders the model to a View-DSL element tree (with a root `:cursor`)."
  @spec render(Model.t()) :: map()
  def render(model) do
    cw = Model.content_width(model)
    inset = Model.frame_inset(model)

    groups = footer_groups(model, cw)
    budget_cap = max(model.rows - 1 - inset, 1)
    natural = FooterStack.total_height(groups)
    budget = natural |> min(budget_cap) |> max(1)
    transcript_h = max(model.rows - budget - inset, 0)

    base =
      frame(
        %{
          type: :column,
          id: "harness-app",
          style: %{},
          gap: 0,
          children: [
            transcript_element(model, cw, transcript_h),
            footer_element(groups, budget, cw)
          ]
        },
        inset
      )

    case overlay_surface(model, cw) do
      nil ->
        base
        |> with_slash_popup(model, cw, groups, budget, transcript_h, inset)
        |> put_cursor(
          cursor_decl(model, groups, budget, cw, transcript_h, inset)
        )

      {w, h, surface} ->
        AbsoluteLayer.absolute_layer(base, [
          AbsoluteLayer.dialog_overlay(w, h, surface)
        ])
    end
  end

  # ── the slash autocomplete popup ─────────────────────────────────────────
  #
  # A POPUP, not a dialog (V's contract): rendered on top of the existing
  # layer via a plain positioned overlay — explicit background, NO global
  # backdrop, and the cursor stays parked in the composer (focus never
  # leaves the input; the popup's selection is a separate register).
  # Anchored so its bottom edge sits directly above the composer row.
  defp with_slash_popup(base, model, cw, groups, budget, transcript_h, inset) do
    # A stale slash draft can sit in the (hidden) composer while the
    # ChoicePrompt owns the footer — the popup must not float over it.
    if Model.slash_active?(model) and not Model.choice_active?(model) do
      {:ok, popup} =
        CommandAutocomplete.init(
          id: "harness-slash-popup",
          query: Model.slash_query(model),
          width: min(cw, 48)
        )

      popup = %{popup | selected: model.slash_selected}

      case CommandAutocomplete.height(popup) do
        0 ->
          base

        height ->
          composer_offset =
            FooterStack.group_offset(groups, @drop_order, budget, :composer) ||
              0

          composer_row = transcript_h + composer_offset
          y = max(composer_row - height, 0)

          AbsoluteLayer.absolute_layer(base, [
            AbsoluteLayer.overlay(
              inset,
              y,
              CommandAutocomplete.render(popup, %{})
            )
          ])
      end
    else
      base
    end
  end

  # The full-viewport frame inset PAINTED (V's margin ruling, surface.ex
  # `inset_prefix/2` reborn as layout): a borderless box pads the whole
  # surface one cell left, so markers leave column 0 and the cursor park's
  # `+ inset` shift points at real glyph positions. A no-op wrapper is
  # skipped entirely when the geometry can't afford the inset.
  defp frame(tree, 0), do: tree

  defp frame(tree, inset) do
    %{
      type: :box,
      id: "harness-frame",
      style: %{},
      border: :none,
      padding: {0, 0, 0, inset},
      children: [tree]
    }
  end

  # ── transcript ────────────────────────────────────────────────────────

  # The record list comes from ONE source (`Model.body_records/1`: sealed
  # history with the click-fold lens + the live frontier approval at the
  # bottom) so render and `hit_test/3` can never disagree about what sits
  # on a row. The live approval is the "special tool render": its FULL
  # Pierre diff rides INLINE here (never the 2-line footer stub), and
  # `preview_lines/2` suppresses it in the footer.
  defp transcript_element(model, cw, transcript_h) do
    {:ok, state} = transcript_state(model, cw, transcript_h)
    TranscriptView.render(state, %{available_width: cw})
  end

  defp transcript_state(model, cw, transcript_h) do
    TranscriptView.init(
      id: "harness-transcript",
      records: Model.body_records(model),
      height: transcript_h,
      anchor: model.scroll_anchor,
      width: cw,
      source_events: model.projection.source_events,
      greeting?: model.greeting? and model.transcript_records == [],
      sigil: model.sigil,
      reply_sigil: model.reply_sigil,
      # This view hosts the footer ChoicePrompt for a live approval
      # (`choice_lines/2`), so the block body must not repeat the
      # option list — the prompt owns the answer affordance.
      selector_hosted?: true
    )
  end

  @doc """
  Resolves a click at 1-based terminal `{x, y}` (the SGR mouse report's
  own coordinates) against THIS view's geometry — the same groups/budget/
  window `render/1` lays out, recomputed from the model so the answer
  can never drift from the paint:

    * a transcript row over a block record → `{:block, block}`
    * a footer row inside the live-tail preview group → `:tail`
    * anything else → `:none`

  Pure geometry only — `Raxol.Harness.HarnessApp.Model.click/2` owns the
  state fold.
  """
  @spec hit_test(Model.t(), pos_integer(), pos_integer()) ::
          {:block, term()} | :tail | :none
  def hit_test(model, _x, y) when is_integer(y) and y >= 1 do
    cw = Model.content_width(model)
    inset = Model.frame_inset(model)

    groups = footer_groups(model, cw)
    budget_cap = max(model.rows - 1 - inset, 1)
    natural = FooterStack.total_height(groups)
    budget = natural |> min(budget_cap) |> max(1)
    transcript_h = max(model.rows - budget - inset, 0)

    row = y - 1

    cond do
      model.overlay != nil ->
        :none

      row < transcript_h ->
        {:ok, state} = transcript_state(model, cw, transcript_h)

        case state |> TranscriptView.row_records(cw) |> Enum.at(row) do
          {:record, {:block, block, _prominence}} -> {:block, block}
          {:record, {:live_thinking, _text, _expanded?}} -> :tail
          _pad_or_marker -> :none
        end

      true ->
        preview_offset =
          FooterStack.group_offset(groups, @drop_order, budget, :preview)

        preview_rows = groups |> Keyword.get(:preview, []) |> length()
        footer_row = row - transcript_h

        if is_integer(preview_offset) and preview_rows > 0 and
             footer_row >= preview_offset and
             footer_row < preview_offset + preview_rows,
           do: :tail,
           else: :none
    end
  end

  def hit_test(_model, _x, _y), do: :none

  # ── footer (FooterStack + its groups) ───────────────────────────────────

  defp footer_element(groups, budget, cw) do
    {:ok, fs} =
      FooterStack.init(
        id: "harness-footer",
        groups: groups,
        drop_order: @drop_order,
        budget: budget
      )

    FooterStack.render(fs, %{available_width: cw})
  end

  # Display order (surface.ex footer_frame normal clause). Overlays are now
  # layout children, so the `:overlay` footer group is always empty; the
  # `:divider` channel is dormant until the focus-event unit lands; the
  # `:selector` slot is reserved (the live approval's answer surface is
  # the ChoicePrompt hosted in the `:composer` group).
  defp footer_groups(model, cw) do
    [
      status: status_lines(model, cw),
      lane: Notice.lines(model.lane_notice, cw),
      submitting: submitting_lines(model, cw),
      overlay: [],
      divider: [],
      preview: preview_lines(model, cw),
      composer_sep: composer_sep_lines(model),
      selector: [],
      # While a live approval holds the frontier the footer input IS the
      # ChoicePrompt (V's selector-and-prompt: allow/deny rows + the
      # free-text third way) — it replaces the composer wholesale; the
      # ordinary prompt returns when the question seals.
      composer: composer_group_lines(model, cw),
      notice: Notice.lines(model.stub_notice, cw)
    ]
  end

  defp composer_group_lines(model, cw) do
    if Model.choice_active?(model),
      do: choice_lines(model, cw),
      else: composer_lines(model, cw)
  end

  # The ChoicePrompt rendered to footer line elements: its own render is
  # a column of one-physical-row nodes, exactly the line-list shape
  # FooterStack measures and fits.
  defp choice_lines(model, cw) do
    ChoicePrompt.render(model.choice, %{available_width: cw})
    |> Map.get(:children, [])
  end

  # While a live approval holds the frontier, the strip's `awaiting
  # approval <elapsed>` line is redundant (V's ruling): the inline block
  # shows the question and the footer selector shows the answer keys. The
  # strip keeps the floor ONLY for an alert (a stall is never silenced).
  defp status_lines(model, cw) do
    status = Map.put(model.status, :spinner_frame, model.spinner_frame)

    if Model.live_approval_block(model) != nil and
         not StatusStrip.alerting?(status) do
      []
    else
      StatusStrip.lines(status, cw, model.spinner_frame)
    end
  end

  defp submitting_lines(%{pending_submit: %{text: text}}, _cw),
    do: [dim_text("↑ sending: " <> String.slice(text, 0, 40))]

  defp submitting_lines(_model, _cw), do: []

  # The footer preview channel (ported from the retired Surface engine's
  # `pending_preview_lines/1`). Precedence mirrors that engine's: the
  # trailing completed-but-unsealed block while one pends, else the live
  # tail of a still-accumulating item. Suppressed under an open overlay
  # (spec §5 law 3 / the suppressed-preview law).
  defp preview_lines(%{overlay: overlay}, _cw) when overlay != nil, do: []

  defp preview_lines(model, cw) do
    # A live approval renders INLINE in the body now (transcript tail, full
    # diff -- see `live_body_records/1`), so it must NOT also appear in the
    # footer preview. When one is live it IS the pending block (it holds the
    # frontier at `painted_count`), so drop to the streaming tail here: the
    # footer preview keeps only a still-accumulating reasoning/answer item,
    # never the approval.
    if Model.live_approval_block(model) do
      live_tail_lines(model, cw)
    else
      case pending_block(model) do
        nil -> live_tail_lines(model, cw)
        {block, index} -> pending_block_lines(model, block, index, cw)
      end
    end
  end

  # The pending block is the first projection block at/after the committed
  # cursor (surface.ex pending_block/1: keyed on `painted_count`, the
  # post-walk cursor -- never on the pre-commit scan, which diverges from
  # it exactly on a refused seal write).
  defp pending_block(model) do
    case Enum.slice(model.projection.blocks, model.painted_count..-1//1) do
      [] -> nil
      [block | _rest] -> {block, model.painted_count}
    end
  end

  # The pending block renders with its current fold override applied (a
  # fold toggle is visible in the preview BEFORE seal -- the old surface's
  # own acceptance), capped at two rows like the shelved `Enum.take(2)`.
  defp pending_block_lines(model, block, index, cw) do
    rendered =
      block
      |> Model.apply_fold_override(index, model.fold_overrides)
      |> BlockBody.render(%{
        width: cw,
        turn_has_tools?: turn_has_tools?(block, model),
        # The footer live tail is the ONE place a resultless tool renders
        # `running…` (seal-on-result-only) -- but only while a result may
        # still arrive. After the reveal finishes, the preview shows the
        # final `⊘ no result` form, matching what will seal.
        pending?: not Model.reveal_finished?(model)
      })

    rendered
    |> row_children()
    |> take_rows(2)
  end

  # The live tail: only the first entry renders (surface.ex
  # live_tail_preview_lines/1). Reasoning streams as the ShadowStream peek
  # window -- the same component the shelved surface wired, re-hosted the
  # U1 way: the element tree goes into the real pipeline (no ViewText
  # flattening), so the per-char prominence fade actually paints. It seals
  # to the folded ⁖ block when the reasoning item completes.
  defp live_tail_lines(%{projection: %{tail: tail}}, _cw)
       when map_size(tail) == 0,
       do: []

  defp live_tail_lines(model, _cw) do
    case model.projection.tail |> Map.values() |> List.first() do
      nil ->
        []

      %{item_type: :reasoning, chunks: _chunks} ->
        # The ACTIVE thought renders in the BODY as its ∵-cornered
        # Indication record (V's ruling — `Model.live_frontier_records/1`);
        # a footer copy would double-render it.
        []

      %{chunks: chunks} ->
        # Answer text keeps the plain `» ` streaming preview.
        [dim_text("» " <> Enum.join(chunks, ""))]
    end
  end

  # A block render root is a :column whose children are its visible rows
  # (compact header first, then body rows) -- take them as the group
  # lines. A non-column root (never produced today) counts as one line.
  defp row_children(%{children: children}) when is_list(children), do: children
  defp row_children(other), do: [other]

  # Row-honest cap: accumulate children while their MEASURED heights (the
  # TranscriptView estimator) fit the cap, always keeping the first -- a
  # nested body column counts its real height, so the FooterStack budget
  # never under-charges a tall preview.
  defp take_rows(children, cap) do
    {kept, _used} =
      Enum.reduce_while(children, {[], 0}, fn child, {acc, used} ->
        height = TranscriptView.element_height(child)

        cond do
          acc == [] -> {:cont, {[child], height}}
          used + height > cap -> {:halt, {acc, used}}
          true -> {:cont, {[child | acc], used + height}}
        end
      end)

    Enum.reverse(kept)
  end

  # Ported verbatim from surface.ex turn_has_tools?/3 + block_turn_id/2 +
  # event_item_type/1: whether the block's own turn carried tool activity
  # (the compact tool header renders its receipt only when it did).
  defp turn_has_tools?(block, model) do
    events = model.projection.source_events

    case block_turn_id(block, events) do
      nil ->
        true

      turn_id ->
        Enum.any?(events, fn event ->
          Map.get(event, :turn_id) == turn_id and
            event_item_type(event) in ["tool_use", "tool_result"]
        end)
    end
  end

  defp block_turn_id(block, events) do
    refs = MapSet.new(block.event_refs || [])

    Enum.find_value(events, fn event ->
      if MapSet.member?(refs, Map.get(event, :id)),
        do: Map.get(event, :turn_id)
    end)
  end

  defp event_item_type(event) do
    case Map.get(event, :payload) do
      %{} = payload ->
        Map.get(payload, "item_type") || Map.get(payload, :item_type)

      _other ->
        nil
    end
  end

  # One blank row above the composer (surface.ex composer_sep,
  # full-viewport) — suppressed while the greeting idles at the transcript
  # bottom, so the greeting sits exactly ONE line above the chevron prompt
  # (V's placement ruling), not two.
  defp composer_sep_lines(%{greeting?: true, transcript_records: []}), do: []
  defp composer_sep_lines(_model), do: [%{type: :text, content: ""}]

  # The composer rows, chevron applied (surface.ex `chevron_lines/2` ported
  # to elements). Row indexing mirrors `Composer.edit_point/2`'s banner
  # accounting: a queued-steer banner (when present) is row 0, the draft's
  # first input row follows and carries the bold `❯ `; hang continuations
  # take two aligning spaces so the draft column stays fixed. The cursor
  # park shifts by `Model.sigil_cols/0` to match (`cursor_decl/6`).
  defp composer_lines(model, cw) do
    sigil_row = if model.composer.queued_steer, do: 1, else: 0

    model.composer
    |> Composer.visual_lines(cw)
    |> Enum.with_index()
    |> Enum.map(fn
      {line, ^sigil_row} -> sigil_row_element(model.sigil, line)
      {line, index} when index < sigil_row -> %{type: :text, content: line}
      {line, _index} -> %{type: :text, content: "  " <> line}
    end)
  end

  # One physical footer row: the bold chevron cell pair + the draft text.
  # A `:row` keeps the sigil's bold confined to the sigil (the H-K anchor
  # of an idle frame) without SGR-styling the whole draft.
  defp sigil_row_element(sigil, line) do
    %{
      type: :row,
      style: %{},
      gap: 0,
      children: [
        %{type: :text, content: sigil <> " ", style: %{bold: true}},
        %{type: :text, content: line}
      ]
    }
  end

  defp dim_text(content),
    do: %{type: :text, content: content, attrs: %{style: [:dim]}}

  # ── cursor (law 6) ──────────────────────────────────────────────────────

  # Lower the composer edit point to an absolute {row, col, visible?} —
  # only ever called on the no-overlay branch (an open overlay owns the
  # keys and wraps the tree instead). Nil when the composer was shed by the
  # fit or the geometry is sub-margin.
  defp cursor_decl(model, groups, budget, cw, transcript_h, inset) do
    with true <- cw > 0,
         offset when is_integer(offset) <-
           FooterStack.group_offset(groups, @drop_order, budget, :composer),
         {row_in_group, col0} when is_integer(row_in_group) <-
           group_edit_point(model, cw, inset) do
      abs_row = transcript_h + offset + row_in_group
      {abs_row, col0 |> max(0) |> min(model.width - 1), true}
    else
      _ -> nil
    end
  end

  # The edit point of whatever the :composer group hosts. ChoicePrompt's
  # own edit_point/2 already accounts for the chevron cells and returns
  # nil while an option row holds focus (the caret must never point at
  # state the keys don't reach); the plain composer shifts past its
  # chevron prefix here -- mirrors surface.ex `composer_cursor/3`.
  defp group_edit_point(model, cw, inset) do
    if Model.choice_active?(model) do
      case ChoicePrompt.edit_point(model.choice, cw) do
        nil -> nil
        {row, col} -> {row, col - 1 + inset}
      end
    else
      {row, col} = Composer.edit_point(model.composer, cw)
      {row, col - 1 + Model.sigil_cols() + inset}
    end
  end

  defp put_cursor(view, nil), do: view
  defp put_cursor(view, cursor), do: Map.put(view, :cursor, cursor)

  # ── overlays (hosted as AbsoluteLayer children — U3 gap-closer) ──────────

  defp overlay_surface(%{overlay: nil}, _cw), do: nil

  defp overlay_surface(%{overlay: {:picker, state}} = model, _cw) do
    {w, h} = overlay_box(model)

    surface =
      framed(
        "Command Palette",
        Picker.render(state, %{available_width: w - 4}),
        w,
        h
      )

    {w, h, surface}
  end

  defp overlay_surface(%{overlay: {:panel, kind}} = model, _cw) do
    {w, h} = overlay_box(model)
    {w, h, panel_render(kind, model)}
  end

  defp overlay_surface(%{overlay: {:expansion, exp}} = model, _cw) do
    {w, h} = overlay_box(model)
    {w, h, framed("Diff", expansion_body(model, exp, w), w, h)}
  end

  defp panel_render(:memory, model) do
    items = [
      %{key: "revealed", value: model.revealed},
      %{key: "blocks", value: length(model.projection.blocks)},
      %{key: "turn", value: model.current_turn_id}
    ]

    {:ok, state} = MemoryPanel.init(id: "overlay-memory", items: items)
    MemoryPanel.render(state, %{})
  end

  defp panel_render(:rules, _model) do
    {:ok, state} = RulesPanel.init(id: "overlay-rules", rules: [])
    RulesPanel.render(state, %{})
  end

  defp panel_render(:worktracks, _model) do
    {:ok, state} = WorktracksPanel.init(id: "overlay-worktracks", lanes: [])
    WorktracksPanel.render(state, %{})
  end

  defp panel_render(_other, _model),
    do: framed("Panel", %{type: :text, content: "(no panel)"}, 24, 6)

  # The expanded diff block, windowed by the model-held scroll offset.
  defp expansion_body(model, exp, w) do
    case Enum.at(model.projection.blocks, exp.block_index) do
      nil ->
        %{type: :text, content: "(diff unavailable)"}

      block ->
        expanded = %{block | fold: :expanded}

        Raxol.UI.Components.Harness.BlockBody.render(expanded, %{
          width: max(w - 4, 1),
          prominence: 1.0,
          turn_has_tools?: true,
          scroll_top: exp.scroll_top
        })
    end
  end

  # A bordered, sized dialog surface with a bold title over its content
  # (HarnessOverlayDemo's `framed/4`).
  defp framed(title, content, w, h) do
    Raxol.View.Components.box(
      id: "overlay-frame",
      style: %{border: :single, width: w, height: h},
      children: [
        %{
          type: :column,
          gap: 0,
          children: [
            %{type: :text, content: title, attrs: %{style: [:bold]}},
            content
          ]
        }
      ]
    )
  end

  defp overlay_box(%{width: width, rows: rows}) do
    w = width |> Kernel.-(8) |> min(56) |> max(24)
    h = rows |> Kernel.-(6) |> min(14) |> max(4)
    {w, h}
  end
end
