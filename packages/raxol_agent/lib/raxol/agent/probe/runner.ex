defmodule Raxol.Agent.Probe.Runner do
  @moduledoc """
  U12 — the probe Runner (frozen observables, `harness-freeze-contracts.md`
  §3.1/§3.3). The in-BEAM Runner Pool (roadmap D2 — no Oban/Postgres; D1
  stayed on files; an UNSUPERVISED lazy singleton today — see
  `Raxol.Agent.Probe.Runner.Pool` for the process model + supervision follow-up)
  that drives a `Raxol.Agent.Probe` through its lifecycle and
  emits the frozen `probe_run` / result meta events, owning everything the pure
  probe does not.

  ## What the Runner owns (the probe does not)

  Probes are pure (`Raxol.Agent.Probe`); the Runner owns the journal, the bus,
  the provider, and provenance:

    * **`submit/3` NEVER blocks and NEVER returns results inline.** Results are
      `family: :meta` events on the bus/journal; injecting them into primary
      context is a **separate, explicit** step owned by the caller (roadmap U12,
      verbatim) — deliberately absent from this interface. Only an unregistered
      probe module fails submit (`{:error, :unknown_probe}`). Saturation /
      budget exhaustion do NOT fail submit: the run is accepted and **parked**
      (`probe_run{status: :parked}`), never dropped (N-U12.3).
    * **Bounded parking (F5).** "Never drop, never fail submit" is not unbounded
      accumulation: `max_parked` (pool cap) and `park_timeout_ms` (per-run TTL)
      bound the parked set. A run that cannot be parked because `max_parked` is
      full terminates `:exhausted` (never `:parked`); a parked run past its TTL
      terminates `:exhausted`. Every shed run still gets its terminal event
      (N-U12.10, additive to N-U12.3).
    * **Reserve-before-call (AD-6a).** Reserve BEFORE each provider call; settle
      actuals after. No reserve ⇒ no call, ever. The two-level budget reserves
      session-then-run (OQ-U12.1); a run-level refusal after a session-level
      success RELEASES the session reservation (partial-failure rollback).
      Settlement is Runner↔Ledger-internal (F4) — no `reservation_id` is
      exposed. The frozen `charge` shape is the post-settlement authoritative
      report.
    * **Provenance stamping (U11).** Result meta events carry
      `provenance.source = :probe_<spec.id>` and `trust = context.taint ⊓ refs`.
      A probe cannot stamp its own provenance; a run over tainted context
      produces no trusted event (P-U12.5).
    * **Isolation.** One isolated process (a linked `Task`) per run; a probe
      crash yields `probe_run{status: :error}` and touches nothing else. `kill/1` is
      effective mid-provider-call and never propagates to the primary loop or
      sibling probes; no meta event for a run may appear after its terminal
      (N-U12.7).

  ## Lifecycle = `probe_run` meta events (U11 registry)

  Every run emits `probe_run` events with
  `payload: %{probe, run_id, status, charge, refs}`. Terminal statuses are
  exclusive and final — **exactly one** opening (`:started`-or-`:parked`) and
  **exactly one** terminal per run (P-U12.1). The terminal carries the
  model/params fingerprint (REQUIRED on probe terminals, via
  `Raxol.Agent.Fingerprint`) and MAY carry `cost_ref` into the Ledger.

  ## The `charge` shape (frozen — §3.1 Budget)

      %{prompt_tokens: non_neg_integer(),
        cached_prompt_tokens: non_neg_integer(),   # the cache-riding dividend
        completion_tokens: non_neg_integer(),
        calls: non_neg_integer()}

  The cost *function* over a charge (how cached tokens are weighted) is policy,
  not frozen — the shape guarantees the UI fork and U18 always see the split.

  ## Injectable seams (interface-only wiring, §3)

  `submit/3` reads its side-effecting seams from `opts` so the U12-R red suite
  can fold them in-memory:

    * `:emit` — a 1-arity sink the Runner calls with each frozen record map
      (the journal / EmitBridge in production).
    * `:provider` — an opaque handle the Runner rides the shared prefix through
      (the real provider in production).
    * `:budget` — an opaque `Ledger.try_spend`-shaped reserve handle.
    * `:context` — the `Raxol.Agent.Probe.context()` the pure probe reads.
  """

  alias Raxol.Agent.Probe.Runner.Pool

  @typedoc "Opaque run identity returned by `submit/3`."
  @type run_id :: String.t()

  @typedoc "Post-settlement authoritative spend report (frozen split)."
  @type charge :: %{
          prompt_tokens: non_neg_integer(),
          cached_prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          calls: non_neg_integer()
        }

  @typedoc "Run status enum (grow-only). `:queued`/`:running` are transient."
  @type status ::
          :queued
          | :parked
          | :running
          | :completed
          | :killed
          | :exhausted
          | :timeout
          | :error

  @doc """
  Submit a probe for `session_id`. NEVER blocks; NEVER returns results inline.
  Returns `{:ok, run_id}` for any registered probe (including under
  saturation/exhaustion — the run parks), `{:error, :unknown_probe}` only for an
  unregistered module.
  """
  @callback submit(session_id :: String.t(), probe :: module(), opts :: keyword()) ::
              {:ok, run_id()} | {:error, :unknown_probe}

  @doc """
  Kill a run. Effective mid-provider-call; never propagates to the primary loop
  or sibling probes. Emits the `:killed` terminal; no meta event for the run may
  follow it (N-U12.7).
  """
  @callback kill(run_id()) :: :ok | {:error, :not_found}

  @doc "Current status of a run, or `{:error, :not_found}`."
  @callback status(run_id()) :: {:ok, status()} | {:error, :not_found}

  @doc """
  Submit `probe` for `session_id`. See the moduledoc: non-blocking, total over
  registered probes, parks under saturation.
  """
  @spec submit(String.t(), module(), keyword()) :: {:ok, run_id()} | {:error, :unknown_probe}
  def submit(session_id, probe, opts \\ []) do
    Pool.submit(session_id, probe, opts)
  end

  @doc "Kill a run (see the moduledoc / N-U12.7)."
  @spec kill(run_id()) :: :ok | {:error, :not_found}
  def kill(run_id), do: Pool.kill(run_id)

  @doc "Current status of a run, or `{:error, :not_found}`."
  @spec status(run_id()) :: {:ok, status()} | {:error, :not_found}
  def status(run_id), do: Pool.status(run_id)
end
