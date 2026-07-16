defmodule Raxol.Agent.Compaction do
  @moduledoc """
  Compaction = Resume (U10, disposition AD-3b).

  This module implements the U10 seam pinned by the permanent red suite
  (`test/raxol/agent/red/u10_compaction_red_test.exs`). A compaction is **one
  artifact** — a `checkpoint` record with `reason: "compaction"` — and resuming
  from a compaction is the *ordinary checkpoint-restore path*. There is no
  second record kind and no side-channel state (AD-3b, the one-artifact thesis).

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

  ## Reuse of the U9 checkpoint write path

  `compact/2` does not reimplement checkpoint storage: it delegates the append
  to `Raxol.Agent.Journal.Records.Checkpoint.write/3` (the U9 pointer-record
  discipline — snapshot-file-before-record, tip validation, turn-boundary rule,
  single-Writer append) with `reason: "compaction"` and the model's persistent
  slice as the snapshot content. The compaction record IS a checkpoint record;
  the offset it consumes is one dense offset from the single id space.

  `resume/2` walks the checkpoints newest-first, verifying each snapshot's
  content hash. It selects the newest healthy checkpoint and folds the
  conversational tail forward onto its snapshot slice — identical to restoring
  from any checkpoint (compaction = resume). A corrupt newer checkpoint is
  **surfaced** (typed reason) in `resume_info.skipped`, never silently skipped,
  before falling back to the previous healthy one.

  ## Surrogate MS codec (re-bind when the real event reducer lands)

  The model-snapshot (MS) contract owns *serialization* (`Raxol.Agent.Snapshot`
  — the persistent-slice codec + dropped/redacted manifest). The concrete
  *event reducer* (applying conversational events onto a model) is not yet
  frozen against MS, so `persist/1`, `manifest/1`, and `apply_event/2` here are
  the deterministic surrogate the U10-R red suite pins — the same
  surrogate-fold discipline U9's `Checkpoint.FileBackend` documents. The
  round-trip **equation** (compact-then-resume ≡ a full fold on the persistent
  slice, P-JS4) is codec-independent; re-bind these three private functions to
  the real MS reducer when it lands and the laws still hold.

  ## GC readiness

  Compaction only ever **appends** (FI-7: nothing below the checkpoint offset is
  rewritten or truncated — GC is deferred to a future `gc` record). When GC
  ships it MUST consult `Checkpoint.protected_floor/1` and never truncate at or
  above the newest checkpoint's tip, so a compaction's restore path stays
  intact.

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

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint

  # Every compaction is a checkpoint with this reason — the one-artifact thesis.
  @reason "compaction"

  @checkpoint_kind Checkpoint.kind()

  # The frozen CONVERSATIONAL whitelist (JS-FREEZE §1.1 — the closure rule).
  @conversational MapSet.new(~w(
    turn_started item_started item_completed
    turn_completed turn_canceled error approval_requested
  ))

  @doc """
  Compact `journal` by appending a `checkpoint{reason: "compaction"}` record
  whose content-addressed snapshot is the persistent slice of `opts[:model]`.

  Reuses `Checkpoint.write/3` for the append (single Writer, one dense offset,
  snapshot-file-before-record). Returns `{:ok, compact_result}` or a typed
  `{:error, reason}` propagated from the checkpoint write path.
  """
  @spec compact(journal, keyword()) ::
          {:ok, compact_result()} | {:error, term()}
  def compact(journal, opts \\ [])

  def compact(journal, opts) do
    model = Keyword.fetch!(opts, :model)
    slice = persist(model)
    manifest = manifest(model)

    with {:ok, offset} <- Checkpoint.write(journal, slice, reason: @reason),
         {:ok, record} <- read_record(journal, offset) do
      {:ok,
       %{
         checkpoint_offset: offset,
         snapshot_ref: Map.get(record, "snapshot_ref"),
         snapshot_hash: Map.get(record, "snapshot_hash"),
         tip_offset: Map.get(record, "tip_offset"),
         reason: @reason,
         manifest: manifest
       }}
    end
  end

  @doc """
  Resume from the latest healthy compaction/checkpoint — the ordinary
  checkpoint-restore path (compaction = resume).

  Walks checkpoints newest-first, verifying each snapshot's content hash. A
  corrupt/missing newer checkpoint is surfaced (typed reason) in
  `resume_info.skipped` before falling back to the previous healthy one; the
  selected checkpoint's snapshot slice is folded forward over the conversational
  tail. Returns `{:ok, model, resume_info}` or `{:error, reason}`.
  """
  @spec resume(journal, keyword()) ::
          {:ok, map(), resume_info()} | {:error, term()}
  def resume(journal, opts \\ [])

  def resume(journal, _opts) do
    with {:ok, records} <- FileStore.read(journal) do
      records
      |> Enum.filter(&(Map.get(&1, "kind") == @checkpoint_kind))
      |> Enum.sort_by(&Map.get(&1, "id"), :desc)
      |> select_latest_healthy(journal, records, [])
    end
  end

  # --- resume selection (newest healthy, corrupt-newer surfaced) -------------

  defp select_latest_healthy([], _journal, _records, skipped),
    do: {:error, {:no_healthy_checkpoint, Enum.reverse(skipped)}}

  defp select_latest_healthy([cp | rest], journal, records, skipped) do
    case restore_from(journal, records, cp) do
      {:ok, model} ->
        {:ok, model,
         %{selected_offset: Map.get(cp, "id"), skipped: Enum.reverse(skipped)}}

      {:error, reason} ->
        select_latest_healthy(rest, journal, records, [
          {Map.get(cp, "id"), reason} | skipped
        ])
    end
  end

  # Restore one specific checkpoint: verify its snapshot, then fold the
  # conversational tail (id > tip_offset) forward onto the slice (P-JS4).
  defp restore_from(%{dir: dir}, records, cp) do
    with {:ok, slice} <-
           load_snapshot(
             dir,
             Map.get(cp, "snapshot_ref"),
             Map.get(cp, "snapshot_hash")
           ) do
      {:ok, fold_forward(slice, records, Map.get(cp, "tip_offset"))}
    end
  end

  # A tip-only pointer (nil snapshot_ref) restores from an empty slice, then
  # folds the full conversational prefix forward (OQ-JS1).
  defp load_snapshot(_dir, nil, _hash), do: {:ok, %{}}

  defp load_snapshot(dir, ref, hash) when is_binary(ref) do
    path = Path.join(dir, ref)

    case File.read(path) do
      {:error, _} ->
        {:error, :snapshot_missing}

      {:ok, bytes} ->
        cond do
          sha256_hex(bytes) != hash -> {:error, :snapshot_corrupt}
          true -> decode_slice(bytes)
        end
    end
  end

  defp decode_slice(bytes) do
    case Jason.decode(bytes) do
      {:ok, slice} when is_map(slice) -> {:ok, slice}
      _ -> {:error, :snapshot_corrupt}
    end
  end

  # --- surrogate MS codec (re-bind to the real MS reducer when it lands) -----

  # Persistent slice: every key NOT prefixed `_` survives (volatile keys — pids,
  # secrets, connection handles — never reach the snapshot).
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

  # Fold the conversational tail (id > tip) forward onto a restored slice.
  defp fold_forward(slice, records, tip) do
    records
    |> Enum.filter(fn r -> conversational?(r) and Map.get(r, "id") > tip end)
    |> Enum.reduce(slice, fn record, model -> apply_event(model, record) end)
  end

  defp apply_event(model, record) do
    case Map.get(record, "payload") do
      %{"op" => "incr", "amount" => amount} ->
        Map.update(model, "counter", amount, &(&1 + amount))

      %{"op" => "note", "text" => text} ->
        Map.update(model, "notes", [text], &(&1 ++ [text]))

      _ ->
        model
    end
  end

  # The frozen tip predicate over a STRING-keyed record (grandfather-safe:
  # absent kind ⇒ "event"). Only conversational loop events fold.
  defp conversational?(record) do
    Map.get(record, "kind", "event") == "event" and
      Map.get(record, "family") == "loop" and
      MapSet.member?(@conversational, Map.get(record, "type"))
  end

  # --- helpers ---------------------------------------------------------------

  defp read_record(journal, offset) do
    with {:ok, records} <- FileStore.read(journal) do
      case Enum.find(records, &(Map.get(&1, "id") == offset)) do
        nil -> {:error, :checkpoint_not_found}
        record -> {:ok, record}
      end
    end
  end

  defp sha256_hex(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
