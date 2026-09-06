defmodule Raxol.Telemetry do
  @moduledoc """
  The registry of every `:telemetry` event the main `raxol` project emits,
  each classified as exactly one of `:invariant`, `:peer` or `:operational`.

  ## Why this exists

  A telemetry event is only a guard if something fails when it fires. The
  sibling `raxol_agent_client_protocol` package proved the negative case: it
  both logged a warning AND emitted an event when a turn completed with no
  output, and the defect shipped anyway, because no test asserted on the
  event (and, worse, the emit site was guarded by a `Code.ensure_loaded?`
  that was permanently false). The classification below is what converts
  "the system noticed" into "the suite fails":

    * `:invariant` -- can only fire if RAXOL ITSELF is wrong. Enforced:
      `Raxol.Core.Telemetry.InvariantSentinel` fails any test in which one
      fires unless the test declares it with `@tag expect_invariant:`.
    * `:peer` -- caused by a remote party misbehaving: a malformed or
      out-of-order inbound agent-stream event, wrong-shaped content from a
      producer we do not control. Expected in negative tests, so not
      enforced.
    * `:operational` -- normal life: startup timing, supervisor recovery,
      load shedding, cache bookkeeping, the terminal device or filesystem
      refusing something, and user/app-supplied styles, themes and props
      being invalid. Not enforced.

  ## The criterion, applied literally

  If a peer, the network, the filesystem, the clock, the terminal, or a user
  can cause it, it is NOT an invariant. Err toward `:peer`/`:operational`: a
  false invariant makes the suite flaky, and a flaky guard gets deleted,
  which is strictly worse than a missed one.

  That criterion is why the two most invariant-SOUNDING events here are not
  invariants. `[:raxol, :ui, :prominence, :floor_unreachable]` fires when a
  contrast floor cannot be met by the full-strength seed color -- but both
  the floor and the seed come from a caller-supplied `%ColorIntent{}`, so it
  reports a palette-design gap in USER data (`color_resolver_test.exs` drives
  it on purpose with `tier: :recede` against a dark ground).
  `[:raxol, :layout, :invalid_style]` fires on `overflow: :bogus` or
  `flex_grow: -1` -- values that arrive from an app's style map.

  ## Events built at runtime

  Three families compute their last segment at runtime, so a source scan
  cannot spell them and the sentinel could not subscribe to them; they are
  declared as `dynamic:` families and may not be `:invariant` (the kit
  enforces that at compile time).

  ## Not this project's events

  `[:raxol, :runtime, :backpressure]` appears in
  `Raxol.UI.Rendering.RenderBatcher`'s moduledoc but is emitted by
  `Raxol.Core.Runtime.Backpressure` in `packages/raxol_core`, so it is that
  package's event to classify. `Raxol.Performance.AdaptiveOptimizer`,
  `AutomatedMonitor` and `DevHints` name a dozen more `[:raxol, ...]` events
  in `:telemetry.attach_many/4` SUBSCRIPTION lists (terminal parse/render,
  cache hit/miss); those are emitted by `raxol_terminal` and friends.
  `Raxol.Core.Telemetry.Invariants.scan_lib!/1` only reports first-argument
  literals of `:telemetry.execute`/`span`, so neither kind is mistaken for
  ours.

  ## Completeness is asserted, not trusted

  `test/raxol/telemetry_registry_test.exs` scans this project's `lib/` for
  emit sites and fails if any of them is missing from `events/0`. A new event
  cannot be added without someone classifying it.
  """

  use Raxol.Core.Telemetry.Invariants,
    events: %{
      # OPERATIONAL. Startup duration plus a `success` flag derived from the
      # supervisor's return. A failed boot is an environment/config fact
      # (missing optional child, taken port), and the event fires on the
      # happy path too, so enforcing it would fail every successful start.
      [:raxol, :application, :startup] => :operational,

      # OPERATIONAL x2. `Raxol.Minimal`'s boot duration and per-input
      # timing, emitted only when `telemetry_enabled` -- measurements, not
      # alarms.
      [:raxol, :minimal, :startup] => :operational,
      [:raxol, :minimal, :input] => :operational,

      # OPERATIONAL x3. `RecoverySupervisor` doing its job: opening a
      # circuit after repeated child failures, announcing a degraded
      # fallback, and recording how long a restart took. The trigger is a
      # crashing child (often app-supplied) plus the health thresholds in
      # `check_system_health/1`, i.e. load. A supervisor that never recovers
      # anything is the only way these stay silent.
      [:raxol, :error_recovery, :circuit_break] => :operational,
      [:raxol, :error_recovery, :degradation] => :operational,
      [:raxol, :error_recovery, :restart] => :operational,

      # OPERATIONAL. Emitted on every successful dispatcher sync in the
      # render loop -- the happy path itself.
      [:raxol, :runtime, :view_tree_updated] => :operational,

      # OPERATIONAL. `EditorSession` could not put the terminal reader into
      # raw mode, so the run completes with keyboard input dead. The cause
      # is the terminal device/OS (no tty, revoked access), and
      # `editor_session_test.exs` drives it on purpose.
      [:raxol, :harness, :editor, :reader_enable_failed] => :operational,

      # OPERATIONAL. A live device refused the seal write. That is the
      # device/filesystem talking; `surface_seal_pipeline_test.exs` pins the
      # refusal as observable using a device that always refuses.
      [:raxol, :harness, :seal, :write_failed] => :operational,

      # OPERATIONAL. Drop-oldest load shedding at the `:max_pending`
      # watermark. A producer faster than the flush cadence is load, not a
      # defect -- `StreamCadence`'s whole contract is that ingest never
      # blocks and excess is shed loudly.
      [:raxol, :harness, :stream_cadence, :overflow] => :operational,

      # PEER. Projection recovery: duplicate, out-of-order or forward-gapped
      # ids and unknown item types in the inbound agent journal. Every reason
      # is a fact about what the remote producer sent.
      [:raxol, :harness, :projection, :recovered] => :peer,

      # PEER x2. The same story one layer up: `Block.from_events/3` rescued a
      # raise while projecting peer-supplied events, and `BlockBody` fell
      # back after a mounted body component raised on wrong-shaped content
      # (or an app-registered body provider raised). Inbound content shape
      # and app code, not our own consistency.
      [:raxol, :harness, :block, :recovered] => :peer,
      [:raxol, :harness, :block_body, :recovered] => :peer,

      # OPERATIONAL. User API misuse, made loud instead of raising: an
      # `overflow` mode the engine does not know, or a flex factor that is
      # not a non-negative integer. Both values come from a caller's style
      # map, layout clamps and continues, and `flex_item_test.exs` drives it
      # deliberately. Layout never raises on style input.
      [:raxol, :layout, :invalid_style] => :operational,

      # OPERATIONAL, despite the name. The floor clamp could not reach the
      # requested WCAG ratio even at the full-strength ceiling. Both inputs
      # -- the floor class and the seed color/tier -- arrive in a
      # caller-supplied `%ColorIntent{}`, so this reports an unsatisfiable
      # request in USER data, not an inconsistency in our own declarations.
      # `color_resolver_test.exs` asserts exactly that reading ("a real
      # palette-design gap, not a resolver bug").
      [:raxol, :ui, :prominence, :floor_unreachable] => :operational,

      # INVARIANT. The RP-N-03 writer guard: a cell still carried a
      # `%ColorIntent{}` or `{:fixed, _}` when it reached the terminal
      # writer. `resolve_cells/2` promises every clause terminates in a
      # literal and runs `enforce_resolved!/1` as its own postcondition, so
      # this can only mean our resolver missed a clause or a render path
      # skipped resolution -- no theme, style map or peer can produce it,
      # because their intents are exactly what resolution consumes. In
      # dev/test `@dev_guard?` makes the guard RAISE instead, so the only
      # way to reach the emit in the suite is the explicit prod-flag arity
      # `enforce_resolved!(cells, false)`, which one test uses and declares
      # with `@tag expect_invariant:`.
      [:raxol, :ui, :color_resolver, :unresolved_intent] => :invariant,

      # OPERATIONAL. A detection seam, not a fault: the session's terminal
      # is known to reflow sealed history, and a geometry- or width-changing
      # resize happened. Nothing is re-emitted yet; the event exists so a
      # future reflow-aware unit can gate on it. A user resizing a window
      # fires it.
      [:raxol, :ui, :paint_authority, :reflow_capable_resize] => :operational
    },
    dynamic: [
      # `Raxol.Performance.MetricsCollector.send_telemetry/3` builds
      # `[:raxol, :performance, event_name]` from the metric it is
      # forwarding, and `Raxol.Performance.Caches.CacheHelper.emit_telemetry/3`
      # appends `:hit`/`:miss`/`:invalidate`/`:warmup_complete` to a
      # per-cache prefix under the same family. Cache and metric bookkeeping:
      # operational by construction.
      [:raxol, :performance],

      # `Raxol.Workflow.Runtime` emits `:started`/`:completed`/`:failed`
      # (plus `:interrupted` for runs) with the outcome as the last segment.
      # A failed node is the workflow reporting a step's result -- the step
      # is user-supplied work -- not a defect in the runtime.
      [:raxol, :workflow, :run],
      [:raxol, :workflow, :node]
    ]
end
