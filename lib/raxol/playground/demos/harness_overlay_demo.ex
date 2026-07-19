defmodule Raxol.Playground.Demos.HarnessOverlayDemo do
  @moduledoc """
  Playground demo: the harness OVERLAYS re-hosted as LayoutEngine children
  (harness TEA migration, unit U3 -- spec §4 overlays row, §6 Phase 2, §7).

  ## What this closes: the full-viewport overlay gap

  On the retired map-machine (`Raxol.Harness.Surface`), summoning an
  overlay grew the inline DECSTBM footer via
  `InlineAuthority.set_footer_rows/2`. The alternate-screen authority has
  no such mechanism, so `open_overlay/3`, `open_panel/3`, and
  `expand_focused_diff/1` all REFUSED in `:full_viewport`
  (`surface.ex:3805/3936/4401`, each `{:error, :no_footer}`).

  Under the TEA pipeline there is no footer to grow: an overlay is just a
  layout child. This demo hosts the picker, the read-only projection
  panels, and the scrollable diff-expansion as
  `AbsoluteLayer.dialog_overlay/3` children painted OVER the transcript --
  the exact `Modal`/`HarnessApprovalDemo` idiom -- with zero footer-grow,
  zero `set_footer_rows`. The `view/1` result is an `:absolute_layer`
  whose overlay is a centered, backdrop-dimming `dialog: true` child; the
  LayoutEngine positions it. That is the gap closing: the full-viewport
  render path hosts overlays that the footer-grow substrate could only
  refuse.

  ## The laws it preserves (spec §5, and `surface.ex`'s overlay moduledoc)

    * **One overlay at a time** -- a summon key is inert while any overlay
      is open (`update/2`'s open/closed split); the picker, panels, and
      expansion are mutually exclusive, exactly as the map-machine's
      `open_*` refusal ladder enforces.
    * **ESC / dismiss vocabulary** -- ESC always dismisses the open
      overlay (never the "turn"); the expansion also honors `q`, the
      panels are dismiss-only, and the picker's own `handle_event/3` emits
      its wired `:cancel` on ESC.
    * **Suppressed preview while an overlay is open** -- the live preview
      line is not rendered under any open overlay (`preview_view/1`),
      mirroring `surface.ex`'s "suppressed under an open overlay exactly
      like the pending preview" law; the `dialog: true` backdrop dim is
      the visual half, this omission is the structural half.
    * **Honest degenerate refusal** -- when the viewport genuinely cannot
      host even a minimal overlay (`can_host?/1`), the summon refuses with
      a visible one-line notice and leaves the model untouched -- the
      surviving floor of the map-machine's `insufficient_footer_capacity`
      rung. Drive it with `Headless.send_resize/3`.

  ## Controlled hosting (spec §2 doctrine)

  The model owns ALL overlay state: `model.overlay` is a tagged value
  (`{:picker, picker_state}` | `{:panel, kind}` | `{:expansion, %{content,
  scroll_top}}`). The picker is driven the controlled way -- every key is
  forwarded to `Picker.handle_event/3`, the returned state is kept in the
  model (the Bubbler would discard it on the view path), and the emitted
  `{:component_event, …}` messages are what mutate the model. MCP: the
  picker's stamped root derives `overlay-picker.select` /
  `overlay-picker.dismiss` tools whose synthetic keys travel the identical
  routing a physical keystroke does.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.AbsoluteLayer
  alias Raxol.UI.Components.Harness.DiffViewer
  alias Raxol.UI.Components.Harness.MemoryPanel
  alias Raxol.UI.Components.Harness.Picker
  alias Raxol.UI.Components.Harness.RulesPanel
  alias Raxol.UI.Components.Harness.WorktracksPanel

  # Below these a "minimal overlay" (border + title + prompt + one row)
  # cannot be hosted -- the honest-refusal floor.
  @min_overlay_rows 6
  @min_overlay_width 24

  @default_width 80
  @default_rows 24

  @commands [
    "Approve the pending tool call",
    "Reject the pending tool call",
    "Steer the current turn",
    "Interrupt the running turn",
    "Open the command palette",
    "Compact the transcript",
    "Toggle reasoning visibility",
    "Jump to the last diff",
    "Copy the last assistant message",
    "Quit the session"
  ]

  @diff_content %{
    path: "lib/orders/total.ex",
    language: "elixir",
    old: """
    def calculate(items) do
      IO.inspect(items, label: "items")

      items
      |> Enum.map(& &1.price)
      |> Enum.sum()
    end
    """,
    new: """
    def calculate(items) do
      items
      |> Enum.reject(&is_nil(&1.price))
      |> Enum.map(& &1.price)
      |> Enum.filter(&(&1 >= 0))
      |> Enum.sum()
    end
    """
  }

  @memory [
    %{key: "session_id", value: "sess_8f21c"},
    %{key: "active_gate", value: "probe_c1_gate"},
    %{key: "turns_completed", value: 12}
  ]

  @rules [
    %{
      when: "approval_requested is pending",
      then: "block further tool_use until approval_decision arrives",
      hard: true
    },
    %{
      when: "turn_completed carries usage",
      then: "refresh the status line's cost readout",
      hard: false
    }
  ]

  @lanes [
    %{
      name: "todo",
      items: [%{title: "Wire overlays as layout children", status: "todo"}]
    },
    %{name: "doing", items: [%{title: "Re-host the picker", status: "doing"}]},
    %{name: "done", items: [%{title: "Delete footer-grow", status: "done"}]}
  ]

  @impl true
  def init(_context) do
    %{
      overlay: nil,
      width: @default_width,
      rows: @default_rows,
      available_width: @default_width,
      notice: nil
    }
  end

  # Resize is forwarded to update/2 like any message (dispatcher.ex): track
  # the live geometry so `can_host?/1` and overlay sizing are honest, and
  # so a `Headless.send_resize/3` to a cramped size exercises the refusal.
  @impl true
  def update(%Event{type: :resize, data: %{width: w, height: h}}, model) do
    {%{model | width: w, rows: h, available_width: w}, []}
  end

  # An overlay is open: every message is consulted for the open overlay's
  # own key vocabulary instead of the summon keys (the map-machine's
  # route_passthrough analog).
  def update(message, %{overlay: overlay} = model) when overlay != nil do
    {update_open(message, model), []}
  end

  # No overlay: summon keys. One-overlay-at-a-time falls out of this split
  # -- a summon can only fire from the closed branch.
  def update(message, model) do
    {update_closed(message, model), []}
  end

  @impl true
  def subscribe(_model), do: []

  # -- summon (closed) -----------------------------------------------------

  defp update_closed(message, model) do
    case message do
      key_match("p") -> open_picker(model)
      key_match("1") -> open_panel(model, :memory)
      key_match("2") -> open_panel(model, :rules)
      key_match("3") -> open_panel(model, :worktracks)
      key_match("e") -> open_expansion(model)
      _ -> model
    end
  end

  defp open_picker(model) do
    if can_host?(model) do
      {_w, h} = overlay_box(model)

      {:ok, state} =
        Picker.init(
          id: "overlay-picker",
          items: @commands,
          key_fn: & &1,
          placeholder: "type to filter commands",
          visible_height: max(h - 4, 1)
        )

      %{model | overlay: {:picker, state}, notice: nil}
    else
      refuse(model)
    end
  end

  defp open_panel(model, kind) do
    if can_host?(model),
      do: %{model | overlay: {:panel, kind}, notice: nil},
      else: refuse(model)
  end

  defp open_expansion(model) do
    if can_host?(model),
      do: %{
        model
        | overlay: {:expansion, %{content: @diff_content, scroll_top: 0}},
          notice: nil
      },
      else: refuse(model)
  end

  # Genuine degenerate geometry: refuse honestly (visible notice, model
  # otherwise untouched -- overlay stays nil). The full-viewport path drops
  # the substrate refusals, NOT this one (spec: "Preserve the refusal
  # ladder for genuine degenerate geometry").
  defp refuse(model) do
    %{
      model
      | notice:
          "» cannot host overlay: viewport too small (#{model.width}×#{model.rows})"
    }
  end

  defp can_host?(%{rows: rows, width: width}),
    do: rows >= @min_overlay_rows and width >= @min_overlay_width

  # -- routing (open) ------------------------------------------------------

  defp update_open(message, %{overlay: {:picker, state}} = model) do
    case message do
      %Event{type: :key} = event -> route_picker(model, state, event)
      _ -> model
    end
  end

  defp update_open(message, %{overlay: {:panel, _kind}} = model) do
    case message do
      key_match(:escape) -> dismiss(model)
      _ -> model
    end
  end

  defp update_open(message, %{overlay: {:expansion, exp}} = model) do
    case message do
      key_match(:escape) -> dismiss(model)
      key_match("q") -> dismiss(model)
      key_match("j") -> scroll_expansion(model, exp, 1)
      key_match(:down) -> scroll_expansion(model, exp, 1)
      key_match("k") -> scroll_expansion(model, exp, -1)
      key_match(:up) -> scroll_expansion(model, exp, -1)
      _ -> model
    end
  end

  # The picker is the single authority on which keys filter/move/select:
  # forward the raw event, KEEP the returned state in the model (controlled
  # -- the Bubbler discards it on the view path), and fold the emitted
  # component events (select -> pick+close, cancel -> close).
  defp route_picker(model, state, event) do
    {new_state, messages} = Picker.handle_event(event, state, %{})
    model = %{model | overlay: {:picker, new_state}}
    Enum.reduce(messages, model, &apply_picker_message/2)
  end

  defp apply_picker_message({:component_event, _id, {:select, item}}, model),
    do: %{dismiss(model) | notice: "» picked: #{item}"}

  defp apply_picker_message({:component_event, _id, :cancel}, model),
    do: dismiss(model)

  defp apply_picker_message(_other, model), do: model

  defp dismiss(model), do: %{model | overlay: nil, notice: nil}

  defp scroll_expansion(model, exp, delta) do
    rows = expansion_rows(exp.content, model)
    visible = expansion_visible_rows(model)
    max_top = max(length(rows) - visible, 0)
    new_top = (exp.scroll_top + delta) |> max(0) |> min(max_top)
    %{model | overlay: {:expansion, %{exp | scroll_top: new_top}}}
  end

  # -- view ----------------------------------------------------------------

  @impl true
  def view(model) do
    base = base_view(model)

    case overlay_surface(model) do
      nil ->
        base

      {w, h, surface} ->
        # THE gap closing: the overlay is a LayoutEngine child (a
        # dialog over the transcript), never a grown footer.
        AbsoluteLayer.absolute_layer(base, [
          AbsoluteLayer.dialog_overlay(w, h, surface)
        ])
    end
  end

  defp base_view(model) do
    column style: %{gap: 1} do
      [
        text("Harness Overlay Demo (full-viewport)", style: [:bold]),
        divider()
      ] ++
        transcript_view() ++
        preview_view(model) ++
        [notice_view(model), hint_view(model)]
    end
  end

  # A small fixture transcript sitting behind the overlays: two turns plus
  # a folded diff block (the block `e` expands).
  defp transcript_view do
    {:ok, diff} =
      DiffViewer.init(
        id: "transcript-diff",
        path: @diff_content.path,
        old: @diff_content.old,
        new: @diff_content.new,
        language: @diff_content.language,
        folded: true
      )

    [
      text("❯ Refactor calculate/1 to drop the debug inspect."),
      text("❮ Here is the proposed edit:", style: [:dim]),
      DiffViewer.render(diff, %{})
    ]
  end

  # The suppressed-preview law: the live preview renders ONLY when no
  # overlay is open.
  defp preview_view(%{overlay: nil}),
    do: [
      text("❮ …assistant is composing a reply…",
        id: "live_preview",
        style: [:dim]
      )
    ]

  defp preview_view(_model), do: []

  defp notice_view(%{notice: nil}), do: text("", id: "notice")

  defp notice_view(%{notice: notice}),
    do: text(notice, id: "notice", style: [:dim])

  defp hint_view(%{overlay: nil}),
    do:
      text("[p] picker · [1] memory [2] rules [3] worktracks · [e] expand diff",
        id: "hint",
        style: [:dim]
      )

  defp hint_view(%{overlay: {:picker, _}}),
    do:
      text("type to filter · [↑↓] move · [enter] select · [esc] dismiss",
        id: "hint",
        style: [:dim]
      )

  defp hint_view(%{overlay: {:panel, _}}),
    do: text("[esc] dismiss", id: "hint", style: [:dim])

  defp hint_view(%{overlay: {:expansion, _}}),
    do: text("[j/k] scroll · [esc]/[q] dismiss", id: "hint", style: [:dim])

  # -- overlay surfaces ----------------------------------------------------

  defp overlay_surface(%{overlay: nil}), do: nil

  defp overlay_surface(%{overlay: {:picker, state}} = model) do
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

  defp overlay_surface(%{overlay: {:panel, kind}} = model) do
    {w, h} = overlay_box(model)
    # The panel components render their OWN bordered box + title, so they
    # are used directly as the dialog surface (no double frame).
    {w, h, panel_render(kind)}
  end

  defp overlay_surface(%{overlay: {:expansion, exp}} = model) do
    {w, h} = expansion_box(model)

    {w, h,
     framed(
       "Diff · #{exp.content.path}",
       expansion_body(model, exp, w, h),
       w,
       h
     )}
  end

  defp panel_render(:memory) do
    {:ok, state} = MemoryPanel.init(id: "overlay-memory", items: @memory)
    MemoryPanel.render(state, %{})
  end

  defp panel_render(:rules) do
    {:ok, state} = RulesPanel.init(id: "overlay-rules", rules: @rules)
    RulesPanel.render(state, %{})
  end

  defp panel_render(:worktracks) do
    {:ok, state} = WorktracksPanel.init(id: "overlay-worktracks", lanes: @lanes)
    WorktracksPanel.render(state, %{})
  end

  defp expansion_body(model, exp, _w, h) do
    rows = expansion_rows(exp.content, model)
    visible = expansion_visible_rows_for(h)
    total = length(rows)
    first = if total == 0, do: 0, else: exp.scroll_top + 1
    last = min(exp.scroll_top + visible, total)

    header =
      text(
        "» #{exp.content.path} · #{first}–#{last}/#{total} lines · j/k · esc",
        id: "expansion-header",
        style: [:dim]
      )

    windowed = Enum.slice(rows, exp.scroll_top, visible)

    column style: %{gap: 0} do
      [header | windowed]
    end
  end

  # The full diff rendered as flat unified rows (one view node per physical
  # line), windowed by the model-held scroll offset. `context: :all` -- a
  # full-screen review shows everything.
  defp expansion_rows(content, model) do
    {w, _h} = expansion_box(model)

    DiffViewer.diff_rows(
      path: content.path,
      old: content.old,
      new: content.new,
      language: content.language,
      context: :all,
      width: max(w - 2, 1)
    )
  end

  defp expansion_visible_rows(model) do
    {_w, h} = expansion_box(model)
    expansion_visible_rows_for(h)
  end

  # Box height minus the border (2) and the header line (1).
  defp expansion_visible_rows_for(h), do: max(h - 3, 1)

  # -- geometry ------------------------------------------------------------

  defp overlay_box(%{width: width, rows: rows}) do
    w = width |> Kernel.-(8) |> min(56) |> max(@min_overlay_width)
    h = rows |> Kernel.-(6) |> min(14) |> max(4)
    {w, h}
  end

  defp expansion_box(%{width: width, rows: rows}) do
    w = max(width - 4, @min_overlay_width)
    h = max(rows - 4, 4)
    {w, h}
  end

  # A bordered, sized dialog surface with a bold title over its content.
  defp framed(title, content, w, h) do
    Raxol.View.Components.box(
      id: "overlay-frame",
      style: %{border: :single, width: w, height: h},
      children: [
        column style: %{gap: 0} do
          [text(title, style: [:bold]), content]
        end
      ]
    )
  end
end
