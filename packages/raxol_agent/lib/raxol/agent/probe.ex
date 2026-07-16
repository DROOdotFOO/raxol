defmodule Raxol.Agent.Probe do
  @moduledoc """
  U12 — the probe behaviour (frozen interface, `harness-freeze-contracts.md`
  §3.1). **Interface only** — this module carries no runtime; it declares the
  three callbacks a probe implements. The permanent U12-R red suite
  (`test/raxol/agent/red/u12_probe_runner_red_test.exs`) is authored against
  this shape *before* any Runner implementation exists (the red-first fan-out,
  docs PR #569).

  ## Probes are PURE interpreters

  `build/1` and `interpret/2` receive read-only data and return data. A probe
  **never** touches the journal, the bus, the session process, or the provider
  — the `Raxol.Agent.Probe.Runner` does all four. That is the isolation
  guarantee *by construction*, not by convention (§3.1). In particular a probe
  cannot:

    * stamp its own `provenance` — the Runner stamps
      `source = :probe_<spec.id>` and computes `trust` from the context taint
      meet with the drafted refs (U11 taint algebra). A probe that drafts
      `trust: :trusted` from a tainted context is overridden by the Runner
      (N-U12.6).
    * emit anything — the Runner emits `family: :meta` events on the probe's
      behalf; a drafted `family: :loop` event is rejected whole (N-U12.1).
    * extend its own leash — `max_calls`/`timeout_ms` are Runner-owned
      (N-U12.4).

  ## Cache-riding (frozen requirement, mechanism opaque)

  For `mode: :cache_riding`, the provider request the Runner builds is
  `shared_prefix ++ request.suffix`, where the shared prefix is **byte-identical**
  to the primary loop's most recent request prefix at `tip_offset` (AD-5: never
  filter content blocks). `prefix_ref` is opaque — a probe cannot read or mutate
  the prefix, only ride it. Byte-identity is what makes the KV/prompt cache hit
  and is testable without any provider (capture two built requests, compare the
  prefix bytes — P-U12.3).
  """

  @typedoc """
  Read-only context handed to `build/1` and `interpret/2` by the Runner.

    * `tip_offset` — the durable watermark the probe sees (JS-FREEZE tip).
    * `prefix_ref` — OPAQUE handle to the primary conversation prefix; a probe
      may ride it, never read or mutate it.
    * `taint` — the meet of the context the probe reads (U11 algebra); a run
      over tainted context can produce NO trusted event.
    * `budget_scope` — opaque; the Runner resolves it to the SpendGate scope
      (two-level: session-then-run, OQ-U12.1).
  """
  @type context :: %{
          session_id: String.t(),
          tip_offset: non_neg_integer(),
          prefix_ref: term(),
          taint: :trusted | :tainted,
          budget_scope: term()
        }

  @typedoc """
  What `build/1` returns: the messages to append AFTER the shared prefix, the
  output shape, and the per-call output-token ceiling.
  """
  @type request :: %{
          suffix: [map()],
          output: :structured | :text,
          max_output_tokens: pos_integer()
        }

  @typedoc """
  The probe's static registry entry. `id` keys the registry and derives the
  provenance source `:probe_<id>`. `max_parked`/`park_timeout_ms` bound parking
  (F5); a probe may override the pool default.
  """
  @type spec :: %{
          id: atom(),
          mode: :cache_riding | :standalone,
          max_calls: pos_integer(),
          timeout_ms: pos_integer(),
          default_budget: pos_integer(),
          max_parked: pos_integer(),
          park_timeout_ms: pos_integer()
        }

  @typedoc "A meta-event draft — a plain map the Runner stamps + emits."
  @type meta_event_draft :: map()

  @doc """
  The probe's static registry entry (§3.1). `mode: :standalone` (no prefix) is
  frozen but rare — only C6 cross-family uses it, `@tag`-pending until U17
  (OQ-U12.2).
  """
  @callback spec() :: spec()

  @doc """
  Build the provider request suffix from the read-only context, or `:skip` to
  decline this run. PURE — no side effects.
  """
  @callback build(context()) :: {:ok, request()} | :skip

  @doc """
  Interpret a provider response into zero or more meta-event drafts. PURE — the
  Runner stamps provenance and emits. A probe's output is atomic: the Runner
  emits all drafts or none (P-U12.6).
  """
  @callback interpret(response :: map(), context()) ::
              {:ok, [meta_event_draft()]} | {:error, term()}
end
