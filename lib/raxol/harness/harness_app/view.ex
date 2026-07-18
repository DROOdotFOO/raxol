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

    base = %{
      type: :column,
      id: "harness-app",
      style: %{},
      gap: 0,
      children: [
        transcript_element(model, cw, transcript_h),
        footer_element(groups, budget, cw)
      ]
    }

    case overlay_surface(model, cw) do
      nil ->
        put_cursor(
          base,
          cursor_decl(model, groups, budget, cw, transcript_h, inset)
        )

      {w, h, surface} ->
        AbsoluteLayer.absolute_layer(base, [
          AbsoluteLayer.dialog_overlay(w, h, surface)
        ])
    end
  end

  # ── transcript ────────────────────────────────────────────────────────

  defp transcript_element(model, cw, transcript_h) do
    {:ok, state} =
      TranscriptView.init(
        id: "harness-transcript",
        # held newest-first; the view renders oldest-first
        records: Enum.reverse(model.transcript_records),
        height: transcript_h,
        anchor: model.scroll_anchor,
        width: cw,
        source_events: model.projection.source_events,
        greeting?: model.greeting? and model.transcript_records == []
      )

    TranscriptView.render(state, %{available_width: cw})
  end

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
  # `:divider` channel is dormant until the focus-event unit lands.
  defp footer_groups(model, cw) do
    [
      status: status_lines(model, cw),
      lane: Notice.lines(model.lane_notice, cw),
      submitting: submitting_lines(model, cw),
      overlay: [],
      divider: [],
      preview: preview_lines(model, cw),
      composer_sep: composer_sep_lines(model),
      composer: composer_lines(model, cw),
      notice: Notice.lines(model.stub_notice, cw)
    ]
  end

  defp status_lines(model, cw) do
    status = Map.put(model.status, :spinner_frame, model.spinner_frame)
    StatusStrip.lines(status, cw, model.spinner_frame)
  end

  defp submitting_lines(%{pending_submit: %{text: text}}, _cw),
    do: [dim_text("↑ sending: " <> String.slice(text, 0, 40))]

  defp submitting_lines(_model, _cw), do: []

  # The live-tail preview, suppressed under an open overlay (spec §5 law 3 /
  # the suppressed-preview law).
  defp preview_lines(%{overlay: overlay}, _cw) when overlay != nil, do: []

  defp preview_lines(%{projection: %{tail: tail}}, _cw) when map_size(tail) > 0,
    do: [dim_text("❮ …streaming…")]

  defp preview_lines(_model, _cw), do: []

  # One blank row above the composer (surface.ex composer_sep, full-viewport).
  defp composer_sep_lines(_model), do: [%{type: :text, content: ""}]

  defp composer_lines(model, cw) do
    model.composer
    |> Composer.visual_lines(cw)
    |> Enum.map(&%{type: :text, content: &1})
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
           FooterStack.group_offset(groups, @drop_order, budget, :composer) do
      {row_in_composer, col} = Composer.edit_point(model.composer, cw)
      abs_row = transcript_h + offset + row_in_composer
      col0 = col - 1 + inset

      {abs_row, col0 |> max(0) |> min(model.width - 1), true}
    else
      _ -> nil
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
