defmodule Raxol.Terminal.Telemetry do
  @moduledoc """
  The registry of every `:telemetry` event `raxol_terminal` emits, each
  classified as exactly one of `:invariant`, `:peer` or `:operational`.

  ## Why this exists

  A sibling package shipped a defect that its own telemetry had already
  detected: the event fired, a warning was logged, and nothing failed, because
  no test ever asserted on the event. A telemetry event is only a guard if
  something fails when it fires. This package is a sharper case of the same
  hazard, because its largest event family is `[:raxol, :emulator, :recovery,
  *]` -- the "we broke and self-healed" class, which hides defects by design:
  the louder the recovery machinery is, the quieter the underlying bug.

    * `:invariant` -- can only fire if RAXOL ITSELF is wrong. Enforced:
      `Raxol.Core.Telemetry.InvariantSentinel` fails any test in which one
      fires unless the test declares it with `@tag expect_invariant:`.
    * `:peer` -- caused by a remote party misbehaving. This package emits
      none: the "remote party" of a terminal emulator is the byte stream, and
      bytes arriving over a pty are input, which the criterion below puts in
      `:operational`.
    * `:operational` -- normal life (a parser rejecting garbage, a periodic
      health tick, an env-var override, a checkpoint the caller asked for).
      Not enforced.

  ## The criterion, applied literally

  If a peer, the network, the chain, the filesystem, the clock, or a user can
  cause it, it is NOT an invariant. Err toward `:peer`/`:operational`: a false
  invariant makes the suite flaky, and a flaky guard gets deleted, which is
  strictly worse than a missed one.

  For a terminal emulator that criterion does most of the work by itself. A
  parser that recovers from arbitrary bytes is a parser doing its job, so the
  whole error/recovery/health family below is `:operational` even though the
  names read like alarms -- `Raxol.Terminal.Emulator.SafeEmulator` turns
  hostile input (`\\e[`, a lone `0xFF`, a 15000-column resize, a 1MB blob) into
  `{:error, reason}` on purpose, and its own test suite drives exactly that.

  Two things survive the criterion, and both are about our own state machine
  rather than about input:

    * a raise escaping one of the three `SafeEmulator` spans, and
    * a recovery that FAILED after being attempted.

  See the per-entry comments for the evidence.

  ## Span families

  `SafeEmulator` instruments three calls with
  `Raxol.Core.Telemetry.TraceContext.span/3`, which appends `:start`, `:stop`
  or `:exception` to the prefix at runtime. The prefixes are therefore declared
  as `dynamic:` families (default `:operational`, which is what `:start` and
  `:stop` are), while the three `:exception` leaves are spelled out in
  `events:` so the sentinel can subscribe to them. That split is the only
  reason `dynamic:` appears here: nothing in this package computes an event
  segment from data.
  """

  use Raxol.Core.Telemetry.Invariants,
    events: %{
      # INVARIANT x3. `Raxol.Core.Telemetry.TraceContext.span/3` emits
      # `:exception` only when the wrapped function raises, throws or exits
      # (and then re-raises). The wrapped functions are the three
      # `SafeEmulator.handle_manager_call/3` bodies, and that module exists to
      # be unraisable: every step inside those bodies is either a guard-based
      # validation (`validate_input/1`, `validate_sequence_type/1`) or wrapped
      # in `Raxol.Core.ErrorHandling.safe_call/1`, which rescues exceptions AND
      # catches `:exit`/`:throw`. So no byte sequence, no dimension and no
      # sequence term can produce this event; input produces `{:error,
      # reason}`. There is also no I/O in those bodies -- they manipulate an
      # in-memory map -- so the filesystem, the clock and the network are out.
      # What is left is the thin unwrapped glue we own (the `with` else
      # clauses, `handle_processing_error/3`, `update_error_stats/3`, our own
      # telemetry calls). A raise there is SafeEmulator breaking the promise in
      # its own moduledoc, which is exactly what "can only fire if Raxol is
      # wrong" means.
      [:raxol, :emulator, :input, :exception] => :invariant,
      [:raxol, :emulator, :sequence, :exception] => :invariant,
      [:raxol, :emulator, :resize, :exception] => :invariant,

      # INVARIANT. This is the one place the recovery family earns teeth, and
      # it earns them from the code rather than from the name. It is emitted
      # only by `handle_recovery_check/2` when `perform_recovery/1` returns an
      # error, and `perform_recovery/1` has exactly one error path:
      # `recover_from_checkpoint(nil, _state) -> {:error, :no_checkpoint}`.
      # `recover_from_checkpoint/2` with any non-nil checkpoint always returns
      # `{:ok, _}`. So the event means `state.last_checkpoint` was nil -- and
      # SafeEmulator guarantees it never is: `init_manager/1` seeds it with the
      # initial emulator state, and the only other write is
      # `create_checkpoint/1`, which returns `Map.new/1`. No caller can reach
      # that field (`restore/2` replaces `emulator_state`, not
      # `last_checkpoint`), no input path clears it, and there is no I/O
      # involved. A recovery that fails is therefore our own state machine
      # having lost the checkpoint it promises to hold, which is strictly
      # stronger evidence than the attempt that preceded it.
      [:raxol, :emulator, :recovery, :failed] => :invariant,

      # OPERATIONAL. Emitted by `perform_recovery/1`, reached from the public
      # `SafeEmulator.recover/1` (a user call) and from the health-check tick
      # once input errors have moved `recovery_state` to `:recovering`. Both
      # triggers are outside us; the existing suite calls `recover/1` five
      # times in a row on purpose.
      [:raxol, :emulator, :recovery, :attempted] => :operational,

      # OPERATIONAL. The success half of the same input-driven path. A
      # recovery that worked is the safety net working.
      [:raxol, :emulator, :recovery, :succeeded] => :operational,

      # OPERATIONAL. Every error SafeEmulator records: `:processing_error`
      # (garbage or non-binary input), `:sequence_error` (a sequence term we
      # will not accept), `:resize_error` and `:restore_error` (a checkpoint
      # the caller handed back). Every one of those is caller- or
      # input-caused, and "handles malformed sequences gracefully" in
      # `safe_emulator_test.exs` exists to drive them.
      [:raxol, :emulator, :error, :recorded] => :operational,

      # OPERATIONAL. A 30-second `Process.send_after/3` heartbeat that reports
      # `:healthy | :degraded | :critical` derived from the error counter. It
      # fires on a clock, and it fires on the happy path.
      [:raxol, :emulator, :health, :check] => :operational,

      # OPERATIONAL x2. Both are the direct result of a caller invoking
      # `SafeEmulator.checkpoint/1` or `restore/2`. Nothing about either is a
      # violation -- they are the API reporting that it did what it was asked.
      [:raxol, :emulator, :checkpoint, :created] => :operational,
      [:raxol, :emulator, :checkpoint, :restored] => :operational,

      # OPERATIONAL, despite `degradation` in the name. `Ladder.select/2`
      # emits this when `RAXOL_FORCE_FLAT`/`RAXOL_FORCE_MODE=flat` downgrades a
      # terminal that could have hosted `:inline_log`. An environment variable
      # is a user, and the event's stated purpose (LAD-N-02) is to make a
      # deliberate downgrade observable rather than silent. The refusal case --
      # forcing a mode an incapable terminal cannot host -- deliberately raises
      # `IncapableModeError` instead of emitting anything, so the loud path is
      # already covered by ordinary assertions.
      [:raxol, :degradation, :forced_downgrade] => :operational,

      # OPERATIONAL. A duration measurement, and only when the host app sets
      # `config :raxol, enable_performance_metrics: true`. A performance number
      # cannot be a violation: there is no threshold in the emit site to
      # violate.
      [:raxol, :terminal, :event_processing] => :operational
    },
    # The `:start`/`:stop` leaves of SafeEmulator's three spans. They are the
    # entry and exit of an instrumented call, i.e. the most operational events
    # in the package; the `:exception` leaves are classified above and take
    # precedence because `classification/1` prefers an exact key.
    dynamic: [
      [:raxol, :emulator, :input],
      [:raxol, :emulator, :sequence],
      [:raxol, :emulator, :resize]
    ]
end
