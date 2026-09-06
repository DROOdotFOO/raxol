defmodule Raxol.Agent.Telemetry do
  @moduledoc """
  The registry of every `:telemetry` event `raxol_agent` emits, each classified
  as exactly one of `:invariant`, `:peer` or `:operational`.

  ## Why this exists

  This package already detected its own impossible states and then did nothing
  about them: a signal was emitted, a warning was logged, and the defect
  shipped anyway because no test ever asserted on the event. A telemetry event
  is only a guard if something fails when it fires. That is what the
  classification buys:

    * `:invariant` -- can only fire if RAXOL ITSELF is wrong. Enforced:
      `Raxol.Agent.Test.InvariantSentinel` fails any test in which one fires
      unless the test declares it with `@tag expect_invariant:`.
    * `:peer` -- caused by the remote agent/client misbehaving (malformed
      frame, unknown notification, duplicate id). Expected in negative tests,
      so not enforced.
    * `:operational` -- normal life (cache hit, policy applied, sandbox
      denied, journal write refused by the filesystem, idle reap). Not
      enforced.

  ## The criterion, applied literally

  If a peer, the network, the filesystem, the clock, or a user can cause it, it
  is NOT an invariant. Err toward `:peer`/`:operational`: a false invariant
  makes the suite flaky, and a flaky guard gets deleted, which is strictly
  worse than a missed one. That criterion is why several alarming-looking
  events below are `:operational` -- `:write_failed` and `:damaged` are the
  filesystem talking, and this package has a deliberate chmod-0500 fault test
  that drives them on purpose.

  This package emits no `:peer` events: it is the agent-side library, and the
  peer-facing wire lives in `raxol_agent_client_protocol`, which carries its
  own registry. The vocabulary is shared but the registries are deliberately
  separate, because the packages publish separately and
  `raxol_agent_client_protocol` must not grow a dependency edge for a test
  helper.

  ## Completeness is asserted, not trusted

  `test/raxol/agent/telemetry_registry_test.exs` parses this package's `lib/`
  for `[:raxol, ...]` event literals and fails if any of them is missing from
  `events/0`. That is the whole point of the design: a new event cannot be
  added without someone classifying it.
  """

  @typedoc "How a fired event should be read."
  @type classification :: :invariant | :peer | :operational

  # Each entry carries WHY it lands where it does. The verdicts were read off
  # the emit sites, not guessed from the event names.
  @events %{
    # INVARIANT. `run_interrupt/1` catches raise/throw/exit deliberately
    # broadly, because the cancel path MUST reach the kill-complete fence no
    # matter what the interrupt implementation does. The moduledoc there pays
    # for that broad catch with a promise: "what review flagged as 'hides real
    # defects' is answered by telemetry, not by narrowing the catch". This
    # classification is what converts that promise into enforcement. The
    # default implementation is our own `Raxol.Agent.Interrupt`, so a failure
    # is our staged kill being broken; a test that injects a deliberately
    # failing double declares it with `@tag expect_invariant:`, which pins the
    # bad path instead of muting it.
    [:raxol, :agent, :acp_turn_runner, :interrupt_failed] => :invariant,

    # OPERATIONAL. `FileStore.append/2` refused the record. The cause is the
    # filesystem (full disk, revoked permission, vanished directory), which
    # the criterion puts outside our control.
    [:raxol, :agent, :acp_turn_runner, :journal_failed] => :operational,

    # OPERATIONAL, despite looking like a violation. `DoneGate` runs in
    # observe-only mode and is fully fail-closed on v0 producer journals (no
    # tool result can green-light a done yet), so EVERY tool-less turn fires
    # this. It measures a boundary that is deliberately open; enforcing it
    # would fail on the happy path.
    [:raxol, :agent, :done_gate, :ungated_done] => :operational,

    # OPERATIONAL. The rejected refs are derived from journal content shaped by
    # what the model chose to call, so a rejection is a fact about the turn,
    # not about our code.
    [:raxol, :agent, :done_gate, :rejected_evidence] => :operational,

    # OPERATIONAL. Fires on every restore through the surrogate checkpoint
    # backend, which is the normal state when no real backend is registered.
    # It exists so a caller cannot mistake the surrogate fold for real harness
    # state -- a disclosure, not an alarm.
    [:raxol, :agent, :journal, :checkpoint, :surrogate] => :operational,

    # OPERATIONAL. Interior segment corruption found on replay: truncated
    # writes, bit rot, an editor that touched a segment. Filesystem-caused, and
    # driven on purpose by this package's fault-injection suite.
    [:raxol, :agent, :journal, :damaged] => :operational,

    # OPERATIONAL. Same reason as `:damaged`: the write was refused by the OS.
    # There is a deliberate chmod-0500 fault test (tagged `:skip_on_ci`) whose
    # entire job is to make this fire.
    [:raxol, :agent, :journal, :write_failed] => :operational,

    # OPERATIONAL x6. The policy family is the routine bookkeeping of
    # `PolicyApplier`: every wrapped call emits `:applied`, and cache
    # hit/miss, retry and timeout are the policies doing exactly what they
    # were configured to do.
    [:raxol, :agent, :policy, :applied] => :operational,
    [:raxol, :agent, :policy, :cache_hit] => :operational,
    [:raxol, :agent, :policy, :cache_miss] => :operational,
    [:raxol, :agent, :policy, :retry_attempt] => :operational,
    [:raxol, :agent, :policy, :retry_exhausted] => :operational,
    [:raxol, :agent, :policy, :timeout] => :operational,

    # OPERATIONAL. A sandbox refusing an action is the sandbox working. The
    # rules come from the app's `sandbox/0`, i.e. from a user.
    [:raxol, :agent, :sandbox, :denied] => :operational,

    # OPERATIONAL. The `{:session, session_id}` registry key was held by a
    # genuinely-live foreign holder for the whole retry budget. Two causes,
    # both outside this library: a caller reusing a session_id, and scheduler
    # timing under load. Enforcing it would make the suite flaky on a busy
    # machine, which is the exact failure mode the criterion warns about.
    [:raxol, :agent, :session, :register_timeout] => :operational,

    # OPERATIONAL. The name-based secret heuristic redacted a field the app
    # explicitly listed in `persist:`. That is a declaration/outcome mismatch
    # in USER code, made loud on purpose so it is not a silently-empty field
    # on restore.
    [:raxol, :agent, :snapshot, :persist_redacted_by_heuristic] => :operational,

    # OPERATIONAL. The exiting hook is app-supplied code, and the documented
    # shape of this event is a downed app dependency (e.g. a spend-ledger
    # GenServer). Contained like a veto and made observable; not our defect.
    [:raxol, :agent, :tool_call_hook, :exit] => :operational
  }

  @invariant_events @events
                    |> Enum.filter(fn {_event, class} -> class == :invariant end)
                    |> Enum.map(fn {event, _class} -> event end)
                    |> Enum.sort()

  @doc """
  Every telemetry event this package emits, mapped to its classification.
  """
  @spec events() :: %{[atom()] => classification()}
  def events, do: @events

  @doc """
  The events that can only fire if this library is wrong, sorted.

  `Raxol.Agent.Test.InvariantSentinel` arms exactly this list.
  """
  @spec invariant_events() :: [[atom()]]
  def invariant_events, do: @invariant_events
end
