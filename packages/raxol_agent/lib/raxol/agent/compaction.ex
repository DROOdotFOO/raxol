defmodule Raxol.Agent.Compaction do
  @moduledoc """
  Compaction = Resume (U10, disposition AD-3b) — **skeleton only**.

  This module names the U10 seam so the permanent failing-first red suite
  (`test/raxol/agent/red/u10_compaction_red_test.exs`) can be authored against a
  real API *before* any implementation exists. Every function here returns
  `{:error, :not_implemented}`; the red contours stay RED until U9 (checkpoint
  pointer records) + MS (model-snapshot contract) land and this skeleton is
  replaced with the real implementation.

  ## The one-artifact thesis (AD-3b, `harness-freeze-contracts.md` §1.1)

  Compaction is **not** a separate record kind and **not** a lossy summarizer
  side-channel. Compacting a session is writing a **`checkpoint` record with
  `reason: "compaction"`** whose content-addressed snapshot is the structured,
  JSON-safe persistent slice (MS-owned `@persist` projection). Resuming from a
  compaction is the *ordinary checkpoint-restore path* — the context handed to
  the model afterwards is DERIVED from that one checkpoint artifact, losslessly
  w.r.t. the persistent slice plus manifest-accounted omissions.

  The laws the red suite pins (all against this seam):

    1. compact-then-resume ≡ checkpoint-restore (the P-JS4 fold equality).
    2. compaction never loses un-manifested data — every omitted field is named
       in the dropped/redacted manifest (MS discipline).
    3. compaction is observable in-journal — the `checkpoint` record IS the
       compaction event; there is no side-channel state.
    4. journal bytes below the checkpoint offset are never rewritten or
       truncated (FI-7: nothing deleted implicitly; GC is deferred).
    5. repeated compaction is idempotent-safe — a second compaction at the same
       tip appends a fresh checkpoint and never corrupts the first.

  This retires the lossy `Raxol.Agent.ContextCompactor` (prose summary that
  drops message content with no manifest) as the continuity model.

  ## Behaviour

  `compact/2` and `resume/2` are also `@callback`s so alternate compaction
  strategies can slot in behind the same contract; the module functions are the
  default facade (`:not_implemented` until U10 is built).
  """

  @typedoc "An open journal handle (`Raxol.Agent.Journal` implementation struct)."
  @type journal :: term()

  @typedoc """
  The compaction artifact returned by a successful `compact/2`.

    * `:checkpoint_offset` — journal offset of the appended
      `checkpoint{reason: "compaction"}` record.
    * `:snapshot_ref` — relative CAS path `"snapshots/<sha256>.json"` (or `nil`
      for a tip-only pointer, OQ-JS1 LEGAL).
    * `:snapshot_hash` — lowercase hex sha256 of the snapshot bytes (or `nil`).
    * `:tip_offset` — the conversational tip frozen at write time.
    * `:reason` — `"compaction"`.
    * `:manifest` — `%{dropped: [key], redacted: [key]}`: every field omitted
      from the persistent slice, accounted (MS discipline).
  """
  @type compact_result :: %{
          checkpoint_offset: pos_integer(),
          snapshot_ref: String.t() | nil,
          snapshot_hash: String.t() | nil,
          tip_offset: pos_integer(),
          reason: String.t(),
          manifest: %{dropped: [String.t()], redacted: [String.t()]}
        }

  @typedoc """
  Provenance of a resume/restore: which healthy checkpoint was selected and
  which newer ones were skipped, with the typed reason surfaced (never silent).
  """
  @type resume_info :: %{
          selected_offset: pos_integer() | nil,
          skipped: [{pos_integer(), :snapshot_corrupt | :snapshot_missing}]
        }

  @doc """
  Compact a session by appending a `checkpoint{reason: "compaction"}` record
  (via the single Writer) whose snapshot is the persistent slice of the model.

  Returns `{:ok, compact_result}` or `{:error, reason}`.
  """
  @callback compact(journal, opts :: keyword()) ::
              {:ok, compact_result()} | {:error, term()}

  @doc """
  Resume from the latest healthy compaction/checkpoint (ordinary
  checkpoint-restore path). Picks the newest healthy checkpoint; a corrupt
  newest falls back to the previous healthy one **with the typed error
  surfaced** in `resume_info.skipped`, never silently.

  Returns `{:ok, model, resume_info}` or `{:error, reason}`.
  """
  @callback resume(journal, opts :: keyword()) ::
              {:ok, model :: map(), resume_info()} | {:error, term()}

  @doc "Facade for `c:compact/2`. Skeleton: `{:error, :not_implemented}` until U10 lands."
  @spec compact(journal, keyword()) :: {:ok, compact_result()} | {:error, :not_implemented}
  def compact(journal, opts \\ [])
  def compact(_journal, _opts), do: {:error, :not_implemented}

  @doc "Facade for `c:resume/2`. Skeleton: `{:error, :not_implemented}` until U10 lands."
  @spec resume(journal, keyword()) :: {:ok, map(), resume_info()} | {:error, :not_implemented}
  def resume(journal, opts \\ [])
  def resume(_journal, _opts), do: {:error, :not_implemented}
end
