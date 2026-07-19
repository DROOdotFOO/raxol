defmodule Raxol.Agent.Compaction do
  @moduledoc """
  Compaction = Resume (U10, disposition AD-3b).

  This module implements the U10 seam pinned by the permanent red suite
  (`test/raxol/agent/red/u10_compaction_red_test.exs`). A compaction is **one
  artifact** — a `checkpoint` record with `reason: "compaction"` — and resuming
  from a compaction is the *ordinary checkpoint-restore path*. There is no
  second record kind and no side-channel state (AD-3b, the one-artifact thesis).

  ## The one-artifact thesis (AD-3b)

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

  ## Reuse of the U9 checkpoint write AND restore paths (no restore fork)

  `compact/2` does not reimplement checkpoint storage: it delegates the append
  to `Raxol.Agent.Journal.Records.Checkpoint.write/3` (the U9 pointer-record
  discipline — snapshot-file-before-record, tip validation, turn-boundary rule,
  single-Writer append) with `reason: "compaction"` and the model's persistent
  slice as the snapshot content. The compaction record IS a checkpoint record;
  the offset it consumes is one dense offset from the single id space.

  `resume/2` does not reimplement restore either. It walks the checkpoints
  newest-first (U10's value-add: skip a corrupt newest, fall back to the
  previous healthy one, surfacing the typed reason in `resume_info.skipped` —
  never silently), but **each single-checkpoint restore is delegated to the U9
  hardened path** (`Checkpoint.restore_checkpoint/3` → `FileBackend`). This makes
  resume-equivalence **structural** — compaction-restore IS checkpoint-restore,
  literally the same code — and inherits every U9 restore-path hardening:

    * the `tip_offset`/pointer guard (`validate_checkpoint`): a checkpoint with a
      nil/missing `tip_offset` or `snapshot_ref` yields a typed
      `:malformed_checkpoint` and is skipped, never a silent zero-fold that
      drops the whole tail;
    * the `@ref_re` path-traversal reject (`:malformed_pointer`), the snapshot
      size ceiling, the depth-bounded decode, and the `$s` deref-gadget guard —
      a hostile `snapshot_ref` (`../` traversal, non-hex, oversized) is rejected
      on the compaction resume path exactly as on `Checkpoint.restore/2`.

  There is exactly ONE surrogate fold (in `FileBackend`), re-bound in one place
  when MS lands — `resume/2` no longer carries a private divergent copy.

  ## Surrogate MS codec (re-bind when the real event reducer lands)

  The model-snapshot (MS) contract owns *serialization* (`Raxol.Agent.Snapshot`
  — the persistent-slice codec + dropped/redacted manifest). The concrete
  *event reducer* (applying conversational events onto a model) is not yet
  frozen against MS. The **fold** now lives solely in `FileBackend` (the single
  surrogate); `compact/2` here retains only the persistent-slice projection
  `persist/1` and its omission manifest `manifest/1` — the same
  surrogate-boundary discipline U9's `Checkpoint.FileBackend` documents (secret
  exclusion is the `_`-prefix boundary until the real MS codec lands; a plain-key
  secret is the MS codec's responsibility, exactly as in U9). The round-trip
  **equation** (compact-then-resume ≡ a full fold on the persistent slice,
  P-JS4) is codec-independent; re-bind `persist/1`/`manifest/1` to the real MS
  projection when it lands and the laws still hold.

  ## GC readiness

  Compaction only ever **appends** (FI-7: nothing below the checkpoint offset is
  rewritten or truncated — GC is deferred to a future `gc` record). When GC
  ships it MUST consult `Checkpoint.protected_floor/2` and never truncate at or
  above the newest **healthy** checkpoint's tip, so a compaction's restore path
  (including U10's fall-back to an older healthy checkpoint) stays intact.

  ## Behaviour

  `compact/2` and `resume/2` are also `@callback`s so alternate compaction
  strategies can slot in behind the same contract; the module functions are the
  default facade.
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
          skipped: [{pos_integer(), skip_reason()}]
        }

  @typedoc """
  Why a newer checkpoint was skipped during the newest-first resume walk — the
  typed reasons the U9 hardened restore path (`Checkpoint.restore_checkpoint/3`)
  surfaces.
  """
  @type skip_reason ::
          :snapshot_corrupt
          | :snapshot_missing
          | :malformed_checkpoint
          | :malformed_pointer
          | term()

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

  Options: `:at` — restore ONE specific checkpoint by its journal offset (no
  fall-back walk); an unknown offset is `{:error, :no_such_checkpoint}`.

  Returns `{:ok, model, resume_info}` or `{:error, reason}`.

  When NO checkpoint restores (total snapshot loss), the error is
  `{:error, {:no_healthy_checkpoint, skipped}}` with every attempt's typed
  reason — deliberately richer than `Checkpoint.restore/2`'s `:no_checkpoint`
  (that path never walks, so it has no provenance to surface). Resume FAILS
  CLOSED here rather than silently folding the journal from offset 0: an
  automatic zero-fold arm would synthesize state with no checkpoint
  provenance, which is a contract ruling (AD-3b: resuming IS
  checkpoint-restore), not a local fix. The journal itself stays intact and
  `:ok` — a caller may still fold from offset 0 explicitly.
  """
  @callback resume(journal, opts :: keyword()) ::
              {:ok, model :: map(), resume_info()} | {:error, term()}

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint

  # Every compaction is a checkpoint with this reason — the one-artifact thesis.
  @reason "compaction"

  # Compile-time link to the grow-only reason enum (adversarial-review finding:
  # no link coupled the two, so dropping "compaction" from `Checkpoint.reasons/0`
  # would only surface at runtime as `{:error, {:unknown_reason, "compaction"}}`).
  # If the enum ever loses this member, this module fails to COMPILE.
  true = @reason in Checkpoint.reasons()

  @checkpoint_kind Checkpoint.kind()

  @doc """
  Compact `journal` by appending a `checkpoint{reason: "compaction"}` record
  whose content-addressed snapshot is the persistent slice of `opts[:model]`.

  Reuses `Checkpoint.write/3` for the append (single Writer, one dense offset,
  snapshot-file-before-record). Returns `{:ok, compact_result}` or a typed
  `{:error, reason}` propagated from the checkpoint write path.

  If the checkpoint COMMITS but the enrichment re-read of the journal fails,
  the error is `{:error, {:checkpoint_committed_unreadable, offset, reason}}`
  — the committed offset is surfaced so a retrying caller never appends a
  duplicate checkpoint believing the first one failed.
  """
  @spec compact(journal, keyword()) ::
          {:ok, compact_result()} | {:error, term()}
  def compact(journal, opts \\ [])

  def compact(journal, opts) do
    model = Keyword.fetch!(opts, :model)
    # SURROGATE MS BOUNDARY (call site): `persist/1` is the deterministic
    # surrogate persistent-slice projection — secret exclusion is the `_`-prefix
    # boundary only (see moduledoc). A plain-key secret is the real MS codec's
    # responsibility, exactly as U9's `FileBackend` leaves it. Re-bind here when
    # the MS `@persist` projection lands.
    slice = persist(model)
    manifest = manifest(model)

    with {:ok, offset} <- Checkpoint.write(journal, slice, reason: @reason) do
      # FOLLOW-UP (double read): `Checkpoint.write/3` returns only the offset,
      # so we re-read the journal to recover the snapshot_ref/hash/tip_offset
      # it already computed. Enriching the U9 write return shape is deferred —
      # it would change the frozen `{:ok, offset}` `@callback` the U9-R suite
      # pins.
      case read_record(journal, offset) do
        {:ok, record} ->
          {:ok,
           %{
             checkpoint_offset: offset,
             snapshot_ref: Map.get(record, "snapshot_ref"),
             snapshot_hash: Map.get(record, "snapshot_hash"),
             tip_offset: Map.get(record, "tip_offset"),
             reason: @reason,
             manifest: manifest
           }}

        {:error, reason} ->
          # The checkpoint IS durably committed — `Checkpoint.write/3` returned
          # its offset; only the enrichment re-read failed. Surface the
          # committed offset in the error (adversarial-review finding: a caller
          # that retries on a bare error would append a DUPLICATE checkpoint
          # believing the first one failed).
          {:error, {:checkpoint_committed_unreadable, offset, reason}}
      end
    end
  end

  @doc """
  Resume from the latest healthy compaction/checkpoint — the ordinary
  checkpoint-restore path (compaction = resume).

  Walks checkpoints newest-first, delegating each single-checkpoint restore to
  the U9 hardened path (`Checkpoint.restore_checkpoint/3` — snapshot hash verify,
  tip/pointer guard, path-traversal reject, size ceiling, PRE-decode nesting
  bound, `$s` deref guard). A corrupt/missing/malformed newer checkpoint is
  surfaced (typed reason) in `resume_info.skipped` before falling back to the
  previous healthy one. With `at: offset`, restores that ONE checkpoint (no
  fall-back walk; unknown offset ⇒ `{:error, :no_such_checkpoint}`).

  Returns `{:ok, model, resume_info}` or `{:error, reason}`. See `c:resume/2`
  for the fail-closed total-snapshot-loss contract
  (`{:no_healthy_checkpoint, skipped}` — never an implicit zero-fold).
  """
  @spec resume(journal, keyword()) ::
          {:ok, map(), resume_info()} | {:error, term()}
  def resume(journal, opts \\ [])

  def resume(journal, opts) do
    with {:ok, records} <- FileStore.read(journal) do
      checkpoints =
        records
        |> Enum.filter(&(Map.get(&1, "kind") == @checkpoint_kind))
        |> Enum.sort_by(&Map.get(&1, "id"), :desc)

      case Keyword.get(opts, :at) do
        nil -> select_latest_healthy(checkpoints, journal, records, [])
        offset -> resume_at(checkpoints, journal, records, offset)
      end
    end
  end

  # --- resume selection (newest healthy, corrupt-newer surfaced) -------------
  #
  # U10's value-add lives HERE (the newest-first walk with typed-error fall-back)
  # and NOWHERE else: each individual restore goes through the U9 hardened path
  # (`Checkpoint.restore_checkpoint/3`), so there is no second surrogate fold and
  # no bypassed hardening.

  defp select_latest_healthy([], _journal, _records, skipped),
    do: {:error, {:no_healthy_checkpoint, Enum.reverse(skipped)}}

  defp select_latest_healthy([cp | rest], journal, records, skipped) do
    case Checkpoint.restore_checkpoint(journal, records, cp) do
      {:ok, model} ->
        {:ok, model, %{selected_offset: Map.get(cp, "id"), skipped: Enum.reverse(skipped)}}

      {:error, reason} ->
        select_latest_healthy(rest, journal, records, [
          {Map.get(cp, "id"), reason} | skipped
        ])
    end
  end

  # `:at` — restore ONE named checkpoint (no fall-back walk), through the same
  # U9 hardened path. Matches the reference compactor's `:at` semantics: an
  # unknown offset is `:no_such_checkpoint`; a named-but-unhealthy checkpoint
  # surfaces its typed restore error rather than silently selecting another.
  defp resume_at(checkpoints, journal, records, offset) do
    case Enum.find(checkpoints, &(Map.get(&1, "id") == offset)) do
      nil ->
        {:error, :no_such_checkpoint}

      cp ->
        with {:ok, model} <- Checkpoint.restore_checkpoint(journal, records, cp) do
          {:ok, model, %{selected_offset: offset, skipped: []}}
        end
    end
  end

  # --- surrogate MS projection (re-bind to the real MS `@persist` when it lands)

  # Persistent slice: every key NOT prefixed `_` survives (volatile keys — pids,
  # secrets, connection handles — never reach the snapshot). See the SURROGATE MS
  # BOUNDARY note at the `compact/2` call site.
  defp persist(model) do
    for {k, v} <- model, not volatile?(k), into: %{}, do: {k, v}
  end

  # Omission accounting: every volatile (omitted) key classified — `_secret*`
  # redacted, other `_*` dropped. Nothing omitted is ever left silent.
  defp manifest(model) do
    omitted = for {k, _v} <- model, volatile?(k), do: k
    {redacted, dropped} = Enum.split_with(omitted, &redacted_key?/1)
    %{dropped: Enum.sort(dropped), redacted: Enum.sort(redacted)}
  end

  defp volatile?(<<"_", _::binary>>), do: true
  defp volatile?(_), do: false

  defp redacted_key?(<<"_secret", _::binary>>), do: true
  defp redacted_key?(_), do: false

  # --- helpers ---------------------------------------------------------------

  defp read_record(journal, offset) do
    with {:ok, records} <- FileStore.read(journal) do
      case Enum.find(records, &(Map.get(&1, "id") == offset)) do
        nil -> {:error, :checkpoint_not_found}
        record -> {:ok, record}
      end
    end
  end
end
