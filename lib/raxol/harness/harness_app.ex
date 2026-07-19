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
      owns the tty, the alt-screen bracket, and the clock. **This wiring is
      the U6 follow-up** — the framework seams it needs (Engine
      suspend/resume, `lifecycle_stop`, the Dispatcher verbatim-consumer)
      are not yet built (spec §9 risks 2/7; agent finding). `update/2` is
      already live-ready: it returns directives addressed to `model.pump`.

    * **Fixture** — `Raxol.Harness.HarnessApp.FixtureDriver` (used by
      `Raxol.Playground.Demos.HarnessAssembledDemo`) seeds the model from a
      recorded session, paces `{:reveal}` / `{:tick}` over the held events,
      and drives keys headlessly. The deterministic, testable half — shipped
      here in full. `model.pump` is `nil`, so lane-crossing commands fold an
      honest stub notice instead of a live directive.

  ## Time-travel comes free

  `Raxol.start_link(HarnessApp, time_travel: true)` records every
  `update/2` cycle — `update/2` is a pure fold of `(message, model)`, so the
  snapshot is complete. No extra machinery.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.Harness.HarnessApp.{Model, View}

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
  def update(%Event{type: :resize, data: %{width: w, height: h}}, model)
      when is_integer(w) and is_integer(h),
      do: {Model.resize(model, w, h), []}

  # -- mouse (click-to-fold; V's ruling) --
  #
  # Resolved HERE, not in the Model: hit-testing needs the view's own
  # geometry (footer fit, transcript window), and this module is the one
  # place that legitimately holds both halves. `View.hit_test/3` is pure
  # geometry; `Model.click/2` is the pure fold. A left PRESS acts;
  # releases/moves/other buttons fold away silently.
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

  defp handle_mouse(
         %Event{
           type: :mouse,
           data: %{action: :press, button: :left, x: x, y: y}
         },
         model
       )
       when is_integer(x) and is_integer(y) do
    {Model.click(model, View.hit_test(model, x, y)), []}
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
