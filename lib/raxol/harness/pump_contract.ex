defmodule Raxol.Harness.PumpContract do
  @moduledoc """
  THE FROZEN SessionPump ↔ HarnessApp contract (unit A0 of the TEA
  migration, `docs/proposals/in-flight/harness-tea-migration.md` §3, §8
  "A0", §9 risk 1). This module IS the contract: the typed vocabulary of
  every normalized message the pump feeds the Dispatcher (and therefore
  `HarnessApp.update/2`), plus the laws that bind both sides. The pump
  reshape (`Raxol.Harness.LiveSessionDriver` → `SessionPump`, A-side) and
  the TEA app (`HarnessApp`, U-side) build CONCURRENTLY against these
  shapes; neither may change a shape here without the other lane's
  agreement — that is what "frozen" means.

  The directive half of the contract (commands OUT of `update/2`) lives in
  `Raxol.Harness.Directive.Lane` and `Raxol.Harness.Directive.Editor`;
  `Raxol.Harness.Directive` is the constructor facade.

  **Status: SEAM — frozen ahead of its consumers.** Neither
  `SessionPump` nor `HarnessApp` exists yet; these constructors and
  types are inert until the A-side (pump reshape) and U-side
  (`HarnessApp.update/2`) units land against them. That is the point:
  the shapes freeze FIRST so both sides build concurrently (spec §8,
  "A0 … frozen on paper at Phase-0 time").

  ## 1. Roles

  The pump is to the harness what `Raxol.Terminal.Driver` is to a normal
  app — the IO boundary feeding normalized messages in — plus the
  lane-protocol client executing directives back out. It is the SOLE
  feeder of the Dispatcher and the SOLE tty writer/owner (stdin via
  `Raxol.Terminal.InlineDriver`, alt-screen bracket, editor bracket,
  teardown). `HarnessApp` is a plain `Raxol.Core.Runtime.Application`:
  `update/2` folds these messages into the model and returns directives;
  it never touches a byte, a process, or a timer.

  ## 2. The ordering guarantee (restated from the spec, binding)

  > **Input enters the Dispatcher ahead of any batch that was pending
  > with it at the pump seam.**

  The pump establishes order in its OWN mailbox with the input-first
  selective receive (`receive {:inline_input, _} after 0` — the owner
  half of `Raxol.Harness.StreamCadence`'s section-2 contract, exactly as
  `LiveSessionDriver.loop/1` does today), and only then forwards. Because
  the Dispatcher is a plain FIFO GenServer, it PRESERVES the pump's
  chosen order end-to-end.

  Ordering classes (see `ordering_class/1`):

    * `:input_first` — `{:key, _}` only. A keystroke pending at the pump
      is forwarded ahead of any `{:batch, _}` pending with it.
    * `:fifo` — everything else, forwarded in pump-arrival order.

  **Honest residual** (spec §3/§9 risk 1): one FIFO segment remains
  INSIDE the Dispatcher — a keystroke forwarded behind an
  already-forwarded batch waits one `update/2` fold plus one coalesced
  paint. Bounded by cadence (≤ 32 deltas / 16 ms) and the row-diff
  paint. The falsifier is the input-latency-under-flood property in
  `test/harness/pump_contract_test.exs` ("ordering property (falsifier
  stub)") — a STUB until the pump reshape lands and must be made real by
  it. If that test fails under flood, the escape hatch is the spec's
  fallback: the pump applies batches itself and feeds pre-folded deltas.

  ## 3. Delivery

  Every message in this vocabulary reaches `update/2` VERBATIM — the
  tuple constructed here is the term `update/2` pattern-matches on. No
  `{:command_result, _}` wrapping (that channel stays reserved for
  framework directives like `Schedule`/`Spawn`), no envelope. The
  transport seam the pump uses to obtain verbatim delivery (today the
  Dispatcher's raw-dispatch path; possibly a dedicated ingress later) is
  the pump reshape's own concern and is deliberately NOT frozen.

  **The one exception is resize**: `resize/2` builds a real
  `%Raxol.Core.Events.Event{type: :resize}` and the pump dispatches it
  through the Dispatcher's system-event path
  (`dispatcher.ex` `handle_resize_event/2`), because the Rendering
  Engine's size sync rides that path — a bare tuple would repaint at a
  stale size. `update/2` therefore matches the `%Event{}` itself, which
  the Dispatcher already forwards to apps today.

  ## 4. Message inventory

  | Message | Class | Producer | `update/2` fold (summary) |
  |---|---|---|---|
  | `{:batch, items}` | fifo | live pump ← StreamCadence | append events + advance reveal frontier; fold turn brackets, interrupt acks, approval events from the items; seal loss markers |
  | `{:reveal}` | fifo | fixture pump only | advance the reveal frontier over already-held events (fixture pacing); the live pump never sends it |
  | `{:key, input_event}` | **input_first** | pump ← `InlineDriver` `{:inline_input, %Event{}}`, normalized via `Raxol.UI.Harness.InputEvent.normalize/1` | Keymap route: composer edit, overlay nav, quit protocol (^C arm/disarm, `q`-on-empty), commands → directives |
  | `%Event{type: :resize}` | fifo | pump (SIGWINCH / post-editor re-probe) via the system-event path | fold new geometry into the model; pipeline repaints |
  | `{:tick, now}` | fifo | pump's ticker (`now` = pump-clock monotonic ms); fixture pump scripts it | elapsed/status ageing (today's `Surface.tick/2` fold). Wall time is DATA here — `update/2` never reads a clock |
  | `{:session_down, reason}` | fifo | pump (monitor on the lane session) | close stream (held blocks seal), honest footer statement, `session_over?` belief; NEVER teardown (§8) |
  | `{:feed_down, source, reason}` | fifo | pump (`:subscribe` failure, forwarder EXIT, cadence EXIT) | `:forwarder`/`:cadence`: close stream + "no further events will render"; `:subscribe`: attach-failure notice (nothing was open) |
  | `{:submit_result, result}` | fifo | pump, exactly one per executed submit directive | `:ok`: nothing (acceptance is EVENT-observed via `turn_started` in a later batch); error: restore draft (`submit_refused`) + honest notice |
  | `{:steer_result, result}` | fifo | pump, exactly one TERMINAL result per accepted steer directive | clear `steer_in_flight?` belief; render the accepted / duplicate / stale-turn / no-live-turn / error / timeout / crashed notice (a CAS failure is NEVER silent) |
  | `{:interrupt_result, result}` | fifo | pump, one per executed interrupt directive | `:ok`: "interrupt sent — awaiting confirmation" (advisory); error: dispatch-failure notice. The REAL acks arrive as batch events (§6) |
  | `{:approval_answer_result, result}` | fifo | pump, one per executed approval-answer directive | `:ok`: "approval answer sent"; error: dispatch-failure notice. The decision receipt folds from the `approval_decided` batch event |
  | `{:stall_verdict, verdict}` | fifo | pump (StallDetector mechanics: observations scanned from forwarded items + the ticker) | model owns the RENDER decision: suppress while `needs_input` (operator-paced ≠ stalled), clear on `:ok` class, else show |
  | `{:editor_result, outcome}` | fifo | pump, exactly one per executed editor directive (§7) | `:ok`: replace composer draft; `:kept`: kept-notice; `:error`: abort notice; non-empty `degraded` MUST surface a footer warning |
  | `{:isig_reasserted}` | fifo | pump ← `InlineDriver` `{:inline_isig_reasserted}` | honest footer notice: the tty's `-isig` was re-asserted after an external flip |
  | `{:lane_notice, text_or_nil}` | fifo | embedder (DevTools bridge) via pump | set/clear the persistent footer lane notice |
  | `{:debug_highlight, group_or_nil}` | fifo | embedder (DevTools bridge) via pump | display-only footer-group highlight; unknown group clears (fail-safe) |
  | `{:seal_lines, lines}` | fifo | embedder (boot POST) via pump | seal each line into history via the marker path; non-binaries seal as `inspect/1` (never dropped) |

  ## 5. Batch items and the loud-loss law

  `{:batch, items}` carries `Raxol.Harness.StreamCadence` output verbatim:

    * `{:event, map}` — an `Raxol.Harness.EventBoundary.normalize/1`-shaped
      event (the nine-field fixture wire shape; the boundary already ran
      in the forwarder, so `update/2` never sees a raw lane event);
    * `{:cadence_dropped, n}` — in-band loss report, sitting exactly at
      the loss position;
    * `{:malformed_event}` — an event the boundary rejected.

  The cadence contract (its moduledoc §3) RESERVES the right to grow new
  element types and requires consumers to handle them LOUDLY. That law is
  part of THIS contract: `update/2` must seal an honest
  "unrecognized stream element" marker for any item
  `batch_item_kind/1` classifies `:unknown` — never silently drop it,
  and the pump must never filter items it does not recognize.
  `message?/1` exists for tests, NOT as a runtime filter — filtering
  with it would violate this law.

  ## 6. The lane-fact split (what is a message vs what is a batch event)

  Facts that arrive OUT-OF-BAND at the pump (monitors, EXITs, call
  replies, Task results, timers) are normalized into the dedicated
  messages above. Facts the SESSION emits on its own event stream —
  `turn_started`, `turn_completed`, `turn_canceled`,
  `interrupt_signaled`, `interrupt_kill_failed`, `approval_decided`,
  item events — stay INSIDE `{:batch, items}` and are folded from there.
  There is deliberately NO second channel for them: the interrupt
  dispatch outcome is `{:interrupt_result, _}`, but the authoritative
  "which turn died" statement folds from the `turn_canceled` EVENT
  (rendered from the event's own `turn_id`, never from the model's
  belief) — exactly today's driver semantics.

  ### The steer split (spec §3, binding)

  BELIEF lives in the model: `current_turn_id` (kept alive across
  inter-round `final: false` completions — the submit busy-gate),
  `steer_in_flight?` (the single-in-flight refusal renders from it,
  BEFORE any directive is returned), `pending_submit`, `quit_armed?`.
  MECHANICS live in the pump: the `Task.async` steer dispatch, the
  timeout timer + `Task.shutdown` kill, monitor bookkeeping, and the
  `client_msg_id` mint (an idempotency key is mechanics, not belief —
  `update/2` stays deterministic for fixture replay). The pump sends
  EXACTLY ONE terminal `{:steer_result, _}` per accepted steer
  directive: the lane reply, or `{:error, {:timeout, ms}}` after the
  kill, or `{:error, {:crashed, reason}}` from the Task monitor. If a
  steer directive reaches the pump while one is already in flight (a
  model-belief bug — the model should have refused), the pump answers
  the NEW one with `{:steer_result, {:error, :steer_in_flight}}` and
  leaves the in-flight steer undisturbed. The falsifier home for the
  exactly-one/timeout/crash guarantees is the ported driver contract
  suite (spec §6: "driver contract tests → pump, same scripted fake
  lane" — today's `live_session_driver_test.exs` steer sections).

  ## 7. Alt-screen and editor-bracket ownership (pump-owned bytes)

  The pump owns the alternate screen: it emits enter (`\\e[?1049h` + the
  capability-appropriate prelude) BEFORE the first frame the Engine
  paints, and emits leave (`\\e[?1049l`) as the session's LAST byte,
  after `InlineDriver` teardown — `ViewportAuthority`'s teardown-ordering
  law transfers to the pump verbatim (spec §3). The Engine paints frames;
  it never owns the screen bracket.

  The editor bracket (`Raxol.Harness.Directive.Editor`): the pump is the
  sole tty writer, so the bracket runs synchronously INSIDE the pump —

    1. gate Engine painting via the named seam: a synchronous
       `GenServer.call(engine, :suspend_painting)` /
       `GenServer.call(engine, :resume_painting)` pair on
       `Raxol.Core.Runtime.Rendering.Engine`. **This seam is a stub
       today** — the Engine has no such calls yet; the pump reshape
       lands it (spec §9 risk 7). Suspend gates `:render_frame`
       handling; resume sets `force_repaint` so the first frame after
       the bracket is a full keyframe. The call being synchronous is
       load-bearing: the pump must KNOW painting stopped before handing
       the tty to `$EDITOR`;
    2. run `Raxol.Harness.EditorSession.run/3`-shaped mechanics
       (suspend, spawn, resume — the pump owns `editor_session` /
       `editor_opts`, which leave the model entirely);
    3. re-probe geometry; if it changed, follow with a `resize/2`
       dispatch (the outcome's `width`/`rows` are informational for the
       model; the ENGINE learns size only via the resize path);
    4. send exactly one `{:editor_result, outcome}` —
       `{:ok, %{text: edited, width: w, rows: h, degraded: [...]}}`,
       `{:kept, reason, %{width: w, rows: h, degraded: [...]}}`, or
       `{:error, reason}` (see `Raxol.Harness.EditorSession`). Messages
       arriving mid-bracket simply queue in the pump's mailbox (cadence
       keeps coalescing upstream) and fold after resume — today's
       "events arriving while the editor owns the terminal queue, never
       paint" guarantee, unchanged.

  ## 8. Teardown ordering (frozen)

  Session death is NOT teardown: on `{:session_down, _}` /
  `{:feed_down, _, _}` the app renders honest notices and the runtime
  KEEPS RUNNING — the transcript above is the permanent record. Teardown
  happens only on `Raxol.Harness.Directive.Lane` `:halt` (or the
  embedder's own halt to the pump), and the PUMP owns the sequence:

    1. gate Engine painting (no frame may race the restore);
    2. `InlineDriver` teardown — cooked mode restored;
    3. alt-screen leave as the session's LAST byte;
    4. stop the Lifecycle.

  `update/2`'s duties before returning `halt`: seal an unsent draft into
  history (never silently destroy composed text), then return the
  directive. It never emits a teardown byte itself.

  ## 9. Deliberately NOT frozen (the reshape's own territory)

  The pump's internal envelope for verbatim delivery; monitor/trap_exit
  wiring; StreamCadence construction and the `:input_check` read;
  forwarder ownership; the StallDetector instance and its observation
  scan; timer management; `client_msg_id` format; the
  `environment: :harness` boot profile (unit F0-env); the Engine
  paint-gate implementation (named in §7, landed by the reshape); the
  `{:debug_state_probe, _, _}` observability seam.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.StallDetector
  alias Raxol.UI.Harness.InputEvent

  # ── Wire-shape types ──────────────────────────────────────────────────

  @typedoc """
  The `Raxol.Harness.EventBoundary.normalize/1` output — the nine-field
  fixture wire shape. The boundary runs in the pump's forwarder, so this
  is the ONLY event shape `update/2` ever sees inside a batch.
  """
  @type normalized_event :: %{
          required(:id) => non_neg_integer(),
          required(:turn_id) => String.t() | nil,
          required(:ts) => integer(),
          required(:family) => term(),
          required(:type) => term(),
          required(:tier) => :durable | :ephemeral,
          required(:scope) => atom() | nil,
          required(:provenance) =>
            %{source: String.t(), trust: :trusted | :tainted} | nil,
          required(:payload) => map()
        }

  @typedoc """
  One element of a `{:batch, items}` message — `Raxol.Harness.StreamCadence`
  output, forwarded verbatim. The union below is the KNOWN vocabulary;
  the cadence layer reserves growth (its moduledoc §3), so `update/2`
  must treat anything `batch_item_kind/1` calls `:unknown` as loss data
  and seal an honest marker (§5 of the moduledoc).
  """
  @type batch_item ::
          {:event, normalized_event()}
          | {:cadence_dropped, non_neg_integer()}
          | {:malformed_event}

  @typedoc """
  A steer terminal result. The first five shapes mirror
  `Raxol.Harness.SessionLane.steer/2`'s reply vocabulary; the pump adds
  `{:error, {:timeout, ms}}` (wedged Task killed after the liveness
  bound), `{:error, {:crashed, reason}}` (Task died), and
  `{:error, :steer_in_flight}` (belief-bug defense, §6). A lane reply
  outside the vocabulary is normalized to
  `{:error, {:invalid_lane_reply, inspected}}` by `steer_result/1` —
  never forwarded raw into the model.
  """
  @type steer_result ::
          {:ok, {:accepted, map()}}
          | {:ok, {:duplicate, map()}}
          | {:error, term()}

  @typedoc "A fire-and-forget dispatch outcome (submit / interrupt / approval answer)."
  @type dispatch_result :: :ok | {:error, term()}

  @typedoc """
  The editor-bracket outcome, `Raxol.Harness.EditorSession`'s own union.
  `width`/`rows` are the re-probed post-resume geometry (informational —
  the Engine learns size via the resize path, §7); a non-empty
  `degraded` list MUST surface as a footer warning.
  """
  @type editor_outcome ::
          {:ok,
           %{
             required(:text) => String.t(),
             required(:width) => pos_integer(),
             required(:rows) => pos_integer(),
             optional(:degraded) => list()
           }}
          | {:kept, term(),
             %{
               required(:width) => pos_integer(),
               required(:rows) => pos_integer(),
               optional(:degraded) => list()
             }}
          | {:error, term()}

  @typedoc "The source of a dead event feed."
  @type feed_source :: :subscribe | :forwarder | :cadence

  # ── Message types ─────────────────────────────────────────────────────

  @type batch_msg :: {:batch, [batch_item()]}
  @type reveal_msg :: {:reveal}
  @type key_msg :: {:key, InputEvent.t()}
  @type resize_msg :: Event.t()
  @type tick_msg :: {:tick, integer()}
  @type session_down_msg :: {:session_down, term()}
  @type feed_down_msg :: {:feed_down, feed_source(), term()}
  @type submit_result_msg :: {:submit_result, dispatch_result()}
  @type steer_result_msg :: {:steer_result, steer_result()}
  @type interrupt_result_msg :: {:interrupt_result, dispatch_result()}
  @type approval_answer_result_msg ::
          {:approval_answer_result, dispatch_result()}
  @type stall_verdict_msg :: {:stall_verdict, StallDetector.Verdict.t() | nil}
  @type editor_result_msg :: {:editor_result, editor_outcome()}
  @type isig_msg :: {:isig_reasserted}
  @type lane_notice_msg :: {:lane_notice, String.t() | nil}
  @type debug_highlight_msg :: {:debug_highlight, atom() | nil}
  @type seal_lines_msg :: {:seal_lines, [term()]}

  @typedoc "The complete frozen vocabulary `update/2` folds."
  @type msg ::
          batch_msg()
          | reveal_msg()
          | key_msg()
          | resize_msg()
          | tick_msg()
          | session_down_msg()
          | feed_down_msg()
          | submit_result_msg()
          | steer_result_msg()
          | interrupt_result_msg()
          | approval_answer_result_msg()
          | stall_verdict_msg()
          | editor_result_msg()
          | isig_msg()
          | lane_notice_msg()
          | debug_highlight_msg()
          | seal_lines_msg()

  # ── Constructors (the pump side builds ONLY through these) ───────────

  @doc """
  FIFO · live pump ← StreamCadence `{:render_batch, batch}`. Items are
  forwarded verbatim — the pump never filters an element it does not
  recognize (§5 loud-loss law).
  """
  @spec batch([batch_item()]) :: batch_msg()
  def batch(items) when is_list(items), do: {:batch, items}

  @doc """
  FIFO · fixture pump only — advance the reveal frontier over
  already-held events (fixture pacing). The live pump never sends it:
  live batch application subsumes the advance.
  """
  @spec reveal() :: reveal_msg()
  def reveal, do: {:reveal}

  @doc """
  INPUT-FIRST · pump ← `InlineDriver` `{:inline_input, raw}`. Total:
  normalizes ANY term via `Raxol.UI.Harness.InputEvent.normalize/1`
  (unrecognized input becomes `kind: :other`, never a crash), so
  `update/2` always receives the canonical normalized map and fixture
  pumps can construct key messages without a tty.
  """
  @spec key(term()) :: key_msg()
  def key(raw), do: {:key, InputEvent.normalize(raw)}

  @doc """
  FIFO · pump (SIGWINCH watch / post-editor re-probe). Builds the real
  `%Raxol.Core.Events.Event{type: :resize}` the Dispatcher's
  system-event path expects (moduledoc §3: the ONE message that must NOT
  ride the verbatim seam — the Engine's size sync lives on the
  system-event path). `update/2` matches the `%Event{}` itself.
  """
  @spec resize(pos_integer(), pos_integer()) :: resize_msg()
  def resize(width, height)
      when is_integer(width) and width > 0 and is_integer(height) and
             height > 0 do
    %Event{type: :resize, data: %{width: width, height: height}}
  end

  @doc """
  FIFO · the pump's ticker (or a fixture pump's script). `now` is the
  pump clock's monotonic milliseconds — time enters `update/2` as data,
  never via a clock read inside the fold (fixture replay and time-travel
  depend on this).
  """
  @spec tick(integer()) :: tick_msg()
  def tick(now) when is_integer(now), do: {:tick, now}

  @doc """
  FIFO · pump's monitor on the lane session fired. Fold: close the
  stream (held trailing blocks seal into history), honest footer
  statement, `session_over?` belief — and KEEP RUNNING (moduledoc §8:
  session death is never teardown).
  """
  @spec session_down(term()) :: session_down_msg()
  def session_down(reason), do: {:session_down, reason}

  @doc """
  FIFO · the event feed died or never attached. `:subscribe` — the
  lane subscription failed (nothing was open; notice only);
  `:forwarder` / `:cadence` — a feed process died (close the stream:
  no further events will ever render, so held blocks seal now).
  """
  @spec feed_down(feed_source(), term()) :: feed_down_msg()
  def feed_down(source, reason)
      when source in [:subscribe, :forwarder, :cadence],
      do: {:feed_down, source, reason}

  @doc """
  FIFO · exactly one per executed submit directive, carrying the lane's
  dispatch reply. `:ok` folds to NOTHING visible — acceptance is
  event-observed (`turn_started` in a later batch seals the prompt
  echo); an error restores the draft and names the failure. A lane
  reply outside `:ok | {:error, _}` is normalized to
  `{:error, {:invalid_lane_reply, inspected}}` — total at the lane
  boundary.
  """
  @spec submit_result(term()) :: submit_result_msg()
  def submit_result(result), do: {:submit_result, dispatch_reply(result)}

  @doc """
  FIFO · exactly ONE terminal result per accepted steer directive
  (moduledoc §6): the lane reply, `{:error, {:timeout, ms}}`,
  `{:error, {:crashed, reason}}`, or `{:error, :steer_in_flight}` for a
  belief-bug double dispatch. Unrecognized lane replies normalize to
  `{:error, {:invalid_lane_reply, inspected}}`. Fold clears the
  `steer_in_flight?` belief and renders a distinct honest notice per
  branch — a CAS failure is NEVER silent.
  """
  @spec steer_result(term()) :: steer_result_msg()
  def steer_result({:ok, {:accepted, %{} = ref}}),
    do: {:steer_result, {:ok, {:accepted, ref}}}

  def steer_result({:ok, {:duplicate, %{} = ref}}),
    do: {:steer_result, {:ok, {:duplicate, ref}}}

  def steer_result({:error, reason}), do: {:steer_result, {:error, reason}}

  def steer_result(other),
    do: {:steer_result, {:error, {:invalid_lane_reply, inspect(other)}}}

  @doc """
  FIFO · one per executed interrupt directive — the DISPATCH outcome
  only ("sent, awaiting confirmation"). The authoritative acks
  (`interrupt_signaled`, `interrupt_kill_failed`, `turn_canceled`)
  arrive as batch events (moduledoc §6); there is no second channel for
  them. Unrecognized lane replies normalize as in `submit_result/1`.
  """
  @spec interrupt_result(term()) :: interrupt_result_msg()
  def interrupt_result(result),
    do: {:interrupt_result, dispatch_reply(result)}

  @doc """
  FIFO · one per executed approval-answer directive — dispatch outcome
  only; the decision receipt folds from the `approval_decided` batch
  event. Unrecognized lane replies normalize as in `submit_result/1`.
  """
  @spec approval_answer_result(term()) :: approval_answer_result_msg()
  def approval_answer_result(result),
    do: {:approval_answer_result, dispatch_reply(result)}

  @doc """
  FIFO · pump-side StallDetector mechanics produced a verdict (`nil`
  clears). The RENDER decision is the model's: suppress while
  `needs_input` holds the frontier (operator-paced is not stalled),
  clear on class `:ok`, else show — the same referent split the driver
  applies today.
  """
  @spec stall_verdict(StallDetector.Verdict.t() | nil) :: stall_verdict_msg()
  def stall_verdict(nil), do: {:stall_verdict, nil}

  def stall_verdict(%StallDetector.Verdict{} = verdict),
    do: {:stall_verdict, verdict}

  @doc """
  FIFO · exactly one per executed editor directive (moduledoc §7).
  Passes `Raxol.Harness.EditorSession`'s own outcome union through;
  anything else normalizes to
  `{:error, {:invalid_editor_outcome, inspected}}`. Fold: `:ok`
  replaces the composer draft; `:kept`/`:error` render notices; a
  non-empty `degraded` list MUST surface a footer warning (the keyboard
  may be dead).
  """
  @spec editor_result(term()) :: editor_result_msg()
  def editor_result({:ok, %{text: text, width: w, rows: r} = outcome})
      when is_binary(text) and is_integer(w) and is_integer(r),
      do: {:editor_result, {:ok, outcome}}

  def editor_result({:kept, reason, %{width: w, rows: r} = geo})
      when is_integer(w) and is_integer(r),
      do: {:editor_result, {:kept, reason, geo}}

  def editor_result({:error, reason}), do: {:editor_result, {:error, reason}}

  def editor_result(other),
    do: {:editor_result, {:error, {:invalid_editor_outcome, inspect(other)}}}

  @doc """
  FIFO · pump ← `InlineDriver` `{:inline_isig_reasserted}` — the tty's
  `-isig` was flipped back on by something external and the driver
  re-asserted raw mode. Fold: honest footer notice so the pilot sees it
  happen.
  """
  @spec isig_reasserted() :: isig_msg()
  def isig_reasserted, do: {:isig_reasserted}

  @doc """
  FIFO · embedder fact (DevTools bridge) forwarded by the pump: set
  (binary) or clear (`nil`) the persistent footer lane notice.
  """
  @spec lane_notice(String.t() | nil) :: lane_notice_msg()
  def lane_notice(text) when is_binary(text) or is_nil(text),
    do: {:lane_notice, text}

  @doc """
  FIFO · embedder fact (DevTools bridge): display-only footer-group
  highlight; `nil` clears, and an unknown group must fold as clear
  (fail-safe — vocabulary validation is the model's job).
  """
  @spec debug_highlight(atom() | nil) :: debug_highlight_msg()
  def debug_highlight(group) when is_atom(group),
    do: {:debug_highlight, group}

  @doc """
  FIFO · embedder fact (boot POST, doctrine §8.1): lines to seal into
  history via the marker path. A non-binary entry seals as its
  `inspect/1` form — an embedder bug shows up ON the record, never as a
  silently shorter block.
  """
  @spec seal_lines([term()]) :: seal_lines_msg()
  def seal_lines(lines) when is_list(lines), do: {:seal_lines, lines}

  # ── Classifiers (total) ───────────────────────────────────────────────

  @doc """
  The ordering class of a message — the pump's selective receive and the
  ordering falsifier both key on this. Total: unknown terms are `:fifo`
  (the input-first guarantee names keystrokes and nothing else).
  """
  @spec ordering_class(term()) :: :input_first | :fifo
  def ordering_class({:key, _normalized}), do: :input_first
  def ordering_class(_other), do: :fifo

  @doc """
  Total classification of a batch element. `:unknown` is loss data —
  `update/2` seals an honest marker for it (moduledoc §5); nobody drops
  it.
  """
  @spec batch_item_kind(term()) ::
          :event | :cadence_dropped | :malformed_event | :unknown
  def batch_item_kind({:event, %{} = _map}), do: :event

  def batch_item_kind({:cadence_dropped, n}) when is_integer(n) and n >= 0,
    do: :cadence_dropped

  def batch_item_kind({:malformed_event}), do: :malformed_event
  def batch_item_kind(_other), do: :unknown

  @doc """
  True when the term is in the frozen vocabulary. FOR TESTS AND
  DIAGNOSTICS ONLY — never a runtime filter (moduledoc §5: filtering
  unrecognized terms would violate the loud-loss law).
  """
  @spec message?(term()) :: boolean()
  def message?({:batch, items}) when is_list(items), do: true
  def message?({:reveal}), do: true
  def message?({:key, %{kind: _, mods: _}}), do: true
  def message?(%Event{type: :resize, data: %{width: _, height: _}}), do: true
  def message?({:tick, now}) when is_integer(now), do: true
  def message?({:session_down, _reason}), do: true

  def message?({:feed_down, source, _reason})
      when source in [:subscribe, :forwarder, :cadence],
      do: true

  def message?({:submit_result, result}), do: dispatch_result?(result)
  def message?({:steer_result, {:ok, {:accepted, %{}}}}), do: true
  def message?({:steer_result, {:ok, {:duplicate, %{}}}}), do: true
  def message?({:steer_result, {:error, _reason}}), do: true
  def message?({:interrupt_result, result}), do: dispatch_result?(result)

  def message?({:approval_answer_result, result}),
    do: dispatch_result?(result)

  def message?({:stall_verdict, nil}), do: true
  def message?({:stall_verdict, %StallDetector.Verdict{}}), do: true
  def message?({:editor_result, {:ok, %{text: _, width: _, rows: _}}}), do: true

  def message?({:editor_result, {:kept, _reason, %{width: _, rows: _}}}),
    do: true

  def message?({:editor_result, {:error, _reason}}), do: true
  def message?({:isig_reasserted}), do: true

  def message?({:lane_notice, text}) when is_binary(text) or is_nil(text),
    do: true

  def message?({:debug_highlight, group}) when is_atom(group), do: true
  def message?({:seal_lines, lines}) when is_list(lines), do: true
  def message?(_other), do: false

  # ── internal ──────────────────────────────────────────────────────────

  # Total decode of a fire-and-forget lane reply (submit / interrupt /
  # approval answer): the two documented shapes pass; anything else is an
  # honest error, never raw garbage into the model.
  defp dispatch_reply(:ok), do: :ok
  defp dispatch_reply({:error, reason}), do: {:error, reason}

  defp dispatch_reply(other),
    do: {:error, {:invalid_lane_reply, inspect(other)}}

  defp dispatch_result?(:ok), do: true
  defp dispatch_result?({:error, _reason}), do: true
  defp dispatch_result?(_other), do: false
end
