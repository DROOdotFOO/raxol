defmodule Raxol.Harness.HarnessApp do
  @moduledoc """
  The TEA harness application — the keystone of the harness → TEA migration
  (`docs/proposals/in-flight/harness-tea-migration.md` §1, §6 Phase 3, §9.8).
  A plain `Raxol.Core.Runtime.Application` (init/update/view, the playground
  demo shape) over the ported `Raxol.Harness.HarnessApp.Model`, fed the
  frozen `Raxol.Harness.PumpContract` message vocabulary and returning
  `Raxol.Harness.Directive.Lane` / `.Editor` commands back to its pump.

  ```
  SessionPump ──PumpContract msgs──▶ Dispatcher ▶ update/2 (pure) ──Directives──▶ pump
                                                       │
                                        view/1 ▶ Preparer ▶ LayoutEngine ▶ ScreenBuffer ▶ tty
  ```

  ## Two ways to drive it

    * **Live** — `Raxol.Harness.SessionPump` boots a
      `Lifecycle(environment: :harness)` with this app as its `consumer`,
      feeds `{:batch, …}` / `{:key, …}` / `{:tick, …}` etc., and executes
      the returned directives against the real `SessionLane`. The pump
      owns the tty, the alt-screen bracket, and the clock. This wiring is
      the production path (`mix raxol.harness`, assembled by
      `Raxol.Harness.Live`); `update/2` returns directives addressed to
      `model.pump`.

    * **Fixture** — a caller (e.g.
      `Raxol.Playground.Demos.HarnessAssembledDemo` or a test) seeds the
      model from a recorded session via `Model.build(events: …)` and paces
      it with `reveal_all/1` / `{:tick, …}`. The deterministic, testable
      half — shipped here in full. `model.pump` is `nil`, so lane-crossing
      commands fold an honest stub notice instead of a live directive.

  ## Time-travel comes free

  `Raxol.start_link(HarnessApp, time_travel: true)` records every
  `update/2` cycle — `update/2` is a pure fold of `(message, model)`, so the
  snapshot is complete. No extra machinery.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.Harness.HarnessApp.{Model, View}

  require Logger

  # ── init ────────────────────────────────────────────────────────────────

  @impl true
  def init(context) do
    options = normalize_options(context)

    Model.build(
      width: Map.get(context, :width) || Keyword.get(options, :width, 80),
      rows: Map.get(context, :height) || Keyword.get(options, :rows, 24),
      events: Keyword.get(options, :events, []),
      pump: Keyword.get(options, :pump),
      fold_defaults: Keyword.get(options, :fold_defaults, %{}),
      greeting?: Keyword.get(options, :greeting?, false),
      stream_open: Keyword.get(options, :stream_open, false),
      sigil: Keyword.get(options, :sigil, "❯"),
      reply_sigil: Keyword.get(options, :reply_sigil, "❮"),
      editor_session: Keyword.get(options, :editor_session),
      editor_opts: Keyword.get(options, :editor_opts, []),
      sessions_dir: Keyword.get(options, :sessions_dir)
    )
  end

  defp normalize_options(context) do
    case Map.get(context, :options) do
      kw when is_list(kw) -> kw
      %{} = m -> Map.to_list(m)
      _ -> []
    end
  end

  # ── update (the PumpContract fold, spec §2) ──────────────────────────────

  @impl true
  # -- reveal / batch / tick (the stream clocks) --
  def update({:reveal}, model), do: {Model.advance(model), []}
  def update({:batch, items}, model), do: {Model.fold_batch(model, items), []}

  def update({:tick, now}, model) when is_integer(now),
    do: {Model.tick(model, now), []}

  # -- resize rides the real Event (the system-event path, PumpContract §3) --
  # Clear any armed press: the {x,y} it recorded points at a PRE-resize
  # layout, so a release landing on the same cell after the reflow would
  # hit-test against different geometry and toggle the wrong block. A resize
  # mid-drag cancels the click.
  def update(%Event{type: :resize, data: %{width: w, height: h}}, model)
      when is_integer(w) and is_integer(h),
      do: {%{Model.resize(model, w, h) | mouse_press: nil}, []}

  # -- mouse (click-to-fold; V's ruling) --
  #
  # Resolved HERE, not in the Model: hit-testing needs the view's own
  # geometry (footer fit, transcript window), and this module is the one
  # place that legitimately holds both halves. `View.hit_test/3` is pure
  # geometry; `Model.click/2` is the pure fold. A left PRESS arms the site;
  # the matching left RELEASE on the same cell acts. Moves fold away
  # silently; a release outside the completion allowlist (`[:left,
  # :release]`) also folds — the arm is left-only, so completing on a
  # right/middle release would toggle a block the user never left-clicked —
  # but that drop is LOGGED at debug (see `handle_mouse/2`), so a click that
  # silently dies under an unmodeled button token leaves a breadcrumb.
  # The LIVE shape: the pump normalizes every input event
  # (`PumpContract.key/1` → `InputEvent.normalize/1`), and a mouse Event
  # classifies `%{kind: :other, raw: %Event{type: :mouse}}` — the struct
  # rides in `:raw`. The bare-struct clauses below serve the fixture/
  # headless drivers, which deliver the Event unwrapped.
  def update({:key, %{kind: :other, raw: %Event{type: :mouse} = event}}, model),
    do: handle_mouse(event, model)

  def update({:key, %Event{type: :mouse} = event}, model),
    do: handle_mouse(event, model)

  def update(%Event{type: :mouse} = event, model),
    do: handle_mouse(event, model)

  # -- input (the one path that returns directives) --
  def update({:key, event}, model), do: Model.handle_key(model, event)

  def update(%Event{type: :key} = event, model),
    do: Model.handle_key(model, event)

  # -- lane / feed facts --
  def update({:session_down, reason}, model),
    do: {Model.session_down(model, reason), []}

  def update({:feed_down, source, reason}, model),
    do: {Model.feed_down(model, source, reason), []}

  # -- fire-and-forget dispatch results --
  def update({:submit_result, result}, model),
    do: {Model.submit_result(model, result), []}

  def update({:steer_result, result}, model),
    do: {Model.steer_result(model, result), []}

  def update({:interrupt_result, result}, model),
    do: {Model.interrupt_result(model, result), []}

  def update({:approval_answer_result, result}, model),
    do: {Model.approval_answer_result(model, result), []}

  def update({:editor_result, outcome}, model),
    do: {Model.editor_result(model, outcome), []}

  # -- stall / observer / embedder facts --
  def update({:stall_verdict, verdict}, model),
    do: {Model.stall_verdict(model, verdict), []}

  def update({:isig_reasserted}, model), do: {Model.isig_reasserted(model), []}

  def update({:lane_notice, text}, model),
    do: {Model.put_lane_notice(model, text), []}

  def update({:debug_highlight, group}, model),
    do: {Model.put_debug_highlight(model, group), []}

  def update({:seal_lines, lines}, model),
    do: {Model.seal_lines(model, lines), []}

  # -- anything else is ignored (never crash the fold on an unknown term) --
  def update(_message, model), do: {model, []}

  # A click ACTS on RELEASE, and only when the release lands on the SAME
  # cell the press did (V's selection ruling): press-drag-release is a
  # selection attempt, not a click — it must never toggle the block under
  # the pointer. The press only arms the site; all state change waits for
  # the matching release.
  #
  # The press RESOLVES its target NOW, against the press-time geometry, and
  # arms `{cell, target}`. The release acts on THAT stored target — it does
  # NOT re-hit-test the cell. So any transcript reflow between press and
  # release (a `:seal_lines` fold, streamed reasoning lines, a scroll) that
  # slides a different block under the same cell can no longer toggle the
  # WRONG block: the target was pinned at press. (Resize additionally nils
  # the arm above, cancelling the click outright — a viewport change is a
  # bigger disruption than a transcript reflow.)
  defp handle_mouse(
         %Event{
           type: :mouse,
           data: %{action: :press, button: :left, x: x, y: y}
         },
         model
       )
       when is_integer(x) and is_integer(y) do
    {%{model | mouse_press: {{x, y}, View.hit_test(model, x, y)}}, []}
  end

  # SGR (mode 1006) preserves the button on release, so a left release
  # reports `button: :left`; `:release` is the legacy button-agnostic
  # marker (both complete the click). A right/middle/wheel release does
  # not match here and folds away via the catch-all.
  defp handle_mouse(
         %Event{
           type: :mouse,
           data: %{action: :release, button: button, x: x, y: y}
         },
         model
       )
       when button in [:left, :release] and is_integer(x) and is_integer(y) do
    armed = model.mouse_press
    model = %{model | mouse_press: nil}

    case armed do
      {{^x, ^y}, target} -> {Model.click(model, target), []}
      _drag_or_unarmed -> {model, []}
    end
  end

  # A release that is a release but did NOT satisfy the completion clause
  # above — its button is missing, or outside the [:left, :release]
  # allowlist (right/middle/wheel button-up, or an unmodeled token from a
  # mouse mode we don't handle). We fold it (no toggle), but log at debug
  # so the drop is observable: if a real left-click ever arrives under an
  # unexpected button token, this breadcrumb explains the otherwise-silent
  # dead click instead of it vanishing into the generic catch-all.
  defp handle_mouse(
         %Event{type: :mouse, data: %{action: :release} = data},
         model
       ) do
    Logger.debug(fn ->
      "harness: dropped unrecognized mouse release " <>
        "button=#{inspect(Map.get(data, :button))}"
    end)

    {model, []}
  end

  defp handle_mouse(_event, model), do: {model, []}

  # ── view ─────────────────────────────────────────────────────────────────

  @impl true
  def view(model), do: View.render(model)

  # ── subscribe (law 2: event-clocked) ─────────────────────────────────────

  # No self-subscription: the live pump owns the stall/elapsed ticker (it
  # feeds `{:tick, now}`), and the fixture driver paces `{:reveal}`/`{:tick}`
  # itself. The Engine paints only on `:render_frame` after an update, so
  # motion is strictly event-clocked (law 2).
  @impl true
  def subscribe(_model), do: []
end
