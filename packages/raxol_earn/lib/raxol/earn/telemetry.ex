defmodule Raxol.Earn.Telemetry do
  @moduledoc """
  The registry of every `:telemetry` event `raxol_earn` emits, each classified
  as exactly one of `:invariant`, `:peer` or `:operational`.

  ## Why this exists

  A telemetry event is only a guard if something fails when it fires. The
  classification is what makes that possible: `:invariant` events are armed by
  `Raxol.Core.Telemetry.InvariantSentinel`, which fails any test in which one
  fires undeclared. `:peer` (a remote party misbehaved) and `:operational`
  (normal life) are recorded but not enforced.

  The criterion, applied literally: if a peer, the network, the chain, the
  filesystem, the clock, or a user can cause it, it is NOT an invariant. Err
  toward `:peer`/`:operational` -- a false invariant makes the suite flaky, and
  a flaky guard gets deleted, which is strictly worse than a missed one.

  ## Finding: this package currently has no expressible invariant

  Every entry below is `:operational`, and that is a fact about this package's
  telemetry vocabulary rather than a claim that nothing here can go wrong.
  `raxol_earn` emits BROAD CHANNELS, not one-event-per-condition: the ACP job
  state machine, both runtimes and the Xochi solver each publish a single event
  name and put the specific occurrence in metadata.

  The sentinel keys on the EVENT NAME (that is what `:telemetry.attach_many/4`
  subscribes to), so a channel that carries the happy path cannot be enforced,
  no matter how alarming an individual metadata value looks. Concretely, for
  `[:raxol, :earn, :job_session, :transition]`:

    * `Raxol.Earn.JobSession.commit_status/4` is the only emit site, and it is
      reached only AFTER `check_role/3`, `Status.target_status/1` and
      `Status.validate/2` all pass -- so every LEGAL transition fires it;
    * an ILLEGAL transition never reaches the emit site at all. It short-circuits
      to `{:reply, {:error, reason}, state}` and emits nothing, so "impossible
      transition" is not merely indistinguishable from a legal one here, it is
      invisible to telemetry;
    * `apply_event/3` deliberately bypasses adjacency validation (an observed
      on-chain/SSE status is authoritative and an agent joining mid-stream may
      jump), and reports through the same name with `action: :apply_event`.

  Expressing "the state machine took a transition it cannot take" would need a
  DISTINCT event name emitted from the rejection branch. Adding one is out of
  scope for this registry; recording the gap is not.

  ## Dynamic families

  The buyer/seller `queue` and `resync` modules build the last segment at run
  time (`:telemetry.execute([:raxol, :earn, :buyer, :queue, suffix], ...)`), so
  a source scan cannot enumerate the names. They are declared as `dynamic:`
  families with the suffix range recorded per family below. A dynamic family
  cannot be `:invariant` -- the sentinel cannot subscribe to a name it cannot
  spell -- and each of these four is `:operational` as an umbrella even though
  some members (a drain against an unreachable job API, a drop of a malformed
  inbound event) are `:peer` in isolation. `:peer` for the whole family would
  misdescribe the healthy-path members that share the prefix.

  ## Completeness is asserted, not trusted

  `test/raxol/earn/telemetry_registry_test.exs` scans this package's `lib/` and
  fails if an emitted event is missing here, so a new event cannot be added
  without someone classifying it.
  """

  # Each entry carries WHY it lands where it does, read off the emit site
  # rather than guessed from the event name.
  use Raxol.Core.Telemetry.Invariants,
    events: %{
      # OPERATIONAL. The single channel for every COMMITTED status change of an
      # ACP job session (`Raxol.Earn.JobSession.commit_status/4`). Legal
      # role-gated transitions and authoritative observed events
      # (`action: :apply_event`) share the name; rejected transitions emit
      # nothing. Enforcing it would fail on the happy path. See the moduledoc
      # for why the invariant this event's name suggests is not expressible.
      [:raxol, :earn, :job_session, :transition] => :operational,

      # OPERATIONAL x2. `Buyer.Runtime`/`Seller.Runtime` are deliberately thin
      # bridges: they emit once per `{:acp_event, event}` message received from
      # the configured backend and forward it to the Queue uninterpreted. The
      # event is a receipt for EVERY inbound message, so it fires constantly on
      # the normal path. The message content originates with a remote ACP event
      # source, which the criterion puts outside our control anyway.
      [:raxol, :earn, :buyer, :runtime, :event_received] => :operational,
      [:raxol, :earn, :seller, :runtime, :event_received] => :operational,

      # OPERATIONAL. `Xochi.SolverAgent.emit/4` funnels its whole lifecycle
      # through one name with the occurrence in `metadata.event`: normal steps
      # (`:job_created`, `:job_funded`, `:settling`, `:submitted`,
      # `:job_completed`, `:reattached`, `:budget_proposed`) alongside
      # RPC/chain/peer failures (`:settle_error`, `:submit_error`,
      # `:budget_error`, `:requirement_error`, `:reattach_failed`). A channel
      # that carries `:job_created` cannot be enforced.
      [:raxol, :earn, :xochi, :solver, :event] => :operational,

      # OPERATIONAL. `Xochi.Heartbeat` emits on a fixed interval regardless of
      # job flow, because the solver is an outbound SSE client with no inbound
      # port and a wedged stream looks identical to an idle one. Its firing is
      # the healthy signal; its ABSENCE is the alarm, and absence is what
      # external monitoring watches. Emitted via the `@telemetry_event`
      # attribute, which is why the registry test also does a text-level scan.
      [:raxol, :earn, :xochi, :solver, :heartbeat] => :operational
    },
    # Umbrella :operational (the `dynamic:` default). Suffixes recorded so a
    # future reader knows exactly what each family hides.
    dynamic: [
      # Buyer dispatch authority. Suffixes: `:purchased` (a job we originated),
      # `:dispatched` (a lifecycle event routed to its client), `:dropped`
      # (unknown type, untracked job_id, or a spend policy rejection). Drops are
      # peer- or policy-caused; purchases and dispatches are the happy path.
      [:raxol, :earn, :buyer, :queue],

      # Buyer drain-before-act on boot. Suffixes: `:rehydrated` (a job re-tracked
      # from the authoritative job list), `:skipped` (a job we could not adopt),
      # `:drain_failed` (the job API was unreachable -- peer). Best-effort by
      # design: a failed drain does not block buying.
      [:raxol, :earn, :buyer, :resync],

      # Seller dispatch authority. Suffixes: `:dispatched`, `:dropped` (unknown
      # type/job_id), `:oob_post_failed` (an out-of-band delivery POST to the
      # remote endpoint failed -- peer, and deliberately not a dispatch failure).
      [:raxol, :earn, :seller, :queue],

      # Seller drain-before-act on boot and after a backend restart. Suffixes:
      # `:completed` (drain summary), `:skipped` (unknown or numeric phase, or a
      # session that would not start), `:failed` (the job API was unreachable).
      # Unknown phases are skipped rather than guessed, so `:skipped` is a
      # report about remote data, not about us.
      [:raxol, :earn, :seller, :resync]
    ]
end
