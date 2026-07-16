defmodule Raxol.Agent.Red.Support.U10Compaction do
  @moduledoc """
  Support for the U10 "Compaction = Resume" (AD-3b) red suite.

  Three responsibilities, all in service of the freeze contract in
  `docs/proposals/in-flight/harness-freeze-contracts.md` §1 (JS-FREEZE) — the
  one-artifact thesis: a compaction IS a `checkpoint{reason: "compaction"}`
  record, resume IS the ordinary checkpoint-restore path.

    1. **A real reference MS codec** — a concrete event-sourced model, its fold,
       and its persistent-slice projection. This is the honest oracle the fold
       laws compare against (P-JS4). It is *real*, not a mock that fakes
       equality: `RefCompactor.resume/2` folds actual snapshot bytes ⊕ actual
       post-checkpoint events, and the expected value is an independent full
       fold on the persistent slice.

    2. **Contour checkers** — pure predicates over the on-disk journal (read
       through this module's OWN raw decoder — oracle independence, meta-inv 6)
       and over compact/resume results. Both the RED contours (against the real
       `Raxol.Agent.Compaction`) and the CI controls (against the reference +
       dead injectors) run these same checkers.

    3. **A reference compactor + four dead injectors** — `RefCompactor` is a
       correct implementation used only as a negative-control reference (proves
       each checker is not vacuously false). Each injector violates exactly one
       law so the matching checker MUST reject it (meta-inv m4 negative
       controls; m1 fired-counters via `FaultCounter`).

  The production `Raxol.Agent.Compaction` module stays `:not_implemented` — the
  reference lives here, in test support, never in `lib/`.
  """

  alias Raxol.Agent.Journal.FileStore

  # --- CONVERSATIONAL whitelist (JS-FREEZE §1.1-tip, frozen closure rule) -----
  @conversational ~w(turn_started item_started item_completed turn_completed
                     turn_canceled error approval_requested)

  @segment_re ~r/^\d{6}\.jsonl$/

  # ===========================================================================
  # Reference MS codec — a real event-sourced model + fold + persistent slice
  # ===========================================================================

  @doc "Initial model: an empty `applied` id-list (the single surrogate fold)."
  def initial_model, do: %{"applied" => []}

  @doc """
  Fold one journal record into the model. This mirrors the ONE surrogate fold
  that now lives in `Raxol.Agent.Journal.Records.Checkpoint.FileBackend`
  (`fold_step/2`): each CONVERSATIONAL loop record appends its `id` to
  `model["applied"]`. Checkpoints and any non-event kinds are inert (reader
  tolerance — a checkpoint never perturbs an event fold).

  Unified deliberately: compaction resume now DELEGATES each single-checkpoint
  restore to the U9 hardened path, so this oracle and the implementation share
  exactly one surrogate fold (re-bound in one place when the real MS reducer
  lands). The `op`/`amount`/`text` payloads the seeder writes are inert to the
  fold — only the record `id` matters, exactly as in FileBackend.
  """
  def apply_event(model, %{"kind" => kind}) when kind not in [nil, "event"], do: model

  def apply_event(model, %{"family" => "loop", "type" => type, "id" => id})
      when type in @conversational,
      do: Map.update(model, "applied", [id], &(&1 ++ [id]))

  def apply_event(model, _record), do: model

  @doc "Full fold of a record list into a model (checkpoints skipped)."
  def fold(records), do: Enum.reduce(records, initial_model(), &flip_apply/2)

  defp flip_apply(record, model), do: apply_event(model, record)

  @doc """
  The persistent slice (MS `@persist` projection): every key NOT prefixed `_`.
  Volatile keys (`_pid`, `_secret_*`, ...) are excluded — none JSON-safe.
  """
  def persist(model) do
    for {k, v} <- model, not volatile?(k), into: %{}, do: {k, v}
  end

  defp volatile?(<<"_", _::binary>>), do: true
  defp volatile?(_), do: false

  @doc """
  The omission manifest MS discipline demands: every volatile (omitted) key,
  classified. `_secret*` → `:redacted` (scrubbed value), other `_*` → `:dropped`.
  Nothing omitted is ever left silent.
  """
  def manifest(model) do
    omitted = for {k, _v} <- model, volatile?(k), do: k
    {redacted, dropped} = Enum.split_with(omitted, &redacted_key?/1)
    %{dropped: Enum.sort(dropped), redacted: Enum.sort(redacted)}
  end

  defp redacted_key?(<<"_secret", _::binary>>), do: true
  defp redacted_key?(_), do: false

  # ===========================================================================
  # Snapshot files (content-addressed, FI-8-style; written BEFORE the record)
  # ===========================================================================

  @doc "sha256 of `bytes`, lowercase hex (the freeze's `snapshot_hash` shape)."
  def sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Write a snapshot file for `slice` under `<dir>/snapshots/<sha>.json`, content
  addressed. Returns `{ref, hash, bytes}`.
  """
  def write_snapshot!(dir, slice) do
    bytes = Jason.encode!(slice)
    hash = sha256_hex(bytes)
    ref = "snapshots/#{hash}.json"
    path = Path.join(dir, ref)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {ref, hash, bytes}
  end

  @doc "Read + hash a snapshot: `{:ok, slice}` | `{:error, :snapshot_missing | :snapshot_corrupt}`."
  def read_snapshot(_dir, nil, _hash), do: {:ok, %{}}

  def read_snapshot(dir, ref, hash) do
    path = Path.join(dir, ref)

    case File.read(path) do
      {:error, _} ->
        {:error, :snapshot_missing}

      {:ok, bytes} ->
        if sha256_hex(bytes) == hash do
          {:ok, Jason.decode!(bytes)}
        else
          {:error, :snapshot_corrupt}
        end
    end
  end

  # ===========================================================================
  # Independent raw journal oracle (meta-inv 6 — our OWN decoder, not FileStore)
  # ===========================================================================

  @doc "Every record decoded from the raw segment files, in file order."
  def raw_records(dir) do
    dir
    |> segment_paths()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end)
  end

  @doc "Ids of a healthy journal, in file order."
  def raw_ids(dir), do: dir |> raw_records() |> Enum.map(& &1["id"])

  @doc "The record at a given offset (or nil)."
  def raw_record_at(dir, offset), do: dir |> raw_records() |> Enum.find(&(&1["id"] == offset))

  @doc "All checkpoint records, newest-first."
  def checkpoints(dir) do
    dir
    |> raw_records()
    |> Enum.filter(&(&1["kind"] == "checkpoint"))
    |> Enum.sort_by(& &1["id"], :desc)
  end

  @doc "Concatenated raw bytes of every segment, ascending — for byte-identity (FI-7)."
  def concat_bytes(dir) do
    dir
    |> segment_paths()
    |> Enum.map_join("", &File.read!/1)
  end

  @doc "Segment file paths under `<dir>/journal`, ascending."
  def segment_paths(dir) do
    journal = Path.join(dir, "journal")

    case File.ls(journal) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@segment_re, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(journal, &1))

      {:error, _} ->
        []
    end
  end

  @doc "Highest conversational-event offset (JS-FREEZE tip predicate), or `:no_tip`."
  def conversational_tip(records) do
    case records
         |> Enum.filter(&conversational?/1)
         |> Enum.map(& &1["id"]) do
      [] -> :no_tip
      ids -> Enum.max(ids)
    end
  end

  defp conversational?(record) do
    record["kind"] in [nil, "event"] and record["family"] == "loop" and
      record["type"] in @conversational
  end

  # ===========================================================================
  # Contour checkers (the shared oracle — reds AND controls call these)
  # ===========================================================================

  @doc """
  P1 / dead-injector (a): the compaction artifact is ONE artifact — a
  `checkpoint` record with `reason: "compaction"` at `checkpoint_offset`. A
  separate `"compaction"` kind is NOT one artifact.
  """
  def one_artifact?(dir, %{checkpoint_offset: offset}) do
    case raw_record_at(dir, offset) do
      %{"kind" => "checkpoint", "reason" => "compaction"} -> true
      _ -> false
    end
  end

  @doc """
  P1 density: exactly one new record was appended (the checkpoint), ids stay
  dense `1..n`, and the checkpoint is the tail (one offset, dense).
  """
  def single_dense_append?(before_ids, dir, %{checkpoint_offset: offset}) do
    after_ids = raw_ids(dir)

    after_ids == Enum.to_list(1..length(after_ids)//1) and
      after_ids -- before_ids == [offset] and
      List.last(after_ids) == offset
  end

  @doc """
  P3 / dead-injector (b): FI-7 no-truncation — the journal bytes present before
  compaction are a byte-identical PREFIX of the bytes after (append-only; below
  the checkpoint offset nothing was rewritten or truncated).
  """
  def no_truncation?(before_bytes, after_bytes),
    do: String.starts_with?(after_bytes, before_bytes)

  @doc """
  P4 / dead-injector (c): omission accounting — every field of `model` omitted
  from the persistent slice is named in the manifest (dropped ∪ redacted),
  exactly (nothing silently dropped, nothing fabricated).
  """
  def omission_accounted?(model, slice, manifest) do
    omitted = MapSet.difference(MapSet.new(Map.keys(model)), MapSet.new(Map.keys(slice)))
    accounted = MapSet.new(manifest.dropped ++ manifest.redacted)
    MapSet.equal?(omitted, accounted)
  end

  @doc "P4/P-JS4: a checkpoint is healthy iff its snapshot file exists and hashes match."
  def checkpoint_healthy?(dir, %{snapshot_ref: ref, snapshot_hash: hash}) do
    match?({:ok, _}, read_snapshot(dir, ref, hash))
  end

  @doc """
  P6 / dead-injector (d): resume-selection surfaced the typed error — when the
  newest checkpoint was corrupt, the fallback names it in `skipped` with a typed
  reason. A silent fallback (empty `skipped`) is the violation.
  """
  def resume_selection_surfaced?({:ok, _model, %{skipped: skipped}}, corrupt_offset) do
    Enum.any?(skipped, fn {off, reason} ->
      off == corrupt_offset and reason in [:snapshot_corrupt, :snapshot_missing]
    end)
  end

  def resume_selection_surfaced?(_other, _corrupt_offset), do: false

  # ===========================================================================
  # Fault counters (meta-inv m1 — every armed dead injector MUST fire)
  # ===========================================================================

  defmodule FaultCounter do
    @moduledoc "Armed-site set + per-site fire counters (dead-injector detection, m1)."

    @sites [:separate_kind, :pre_checkpoint_truncation, :lossy_summarizer, :silent_stale_restore]

    def sites, do: @sites

    def new do
      {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
      pid
    end

    def arm(counter, site) when site in @sites do
      Agent.update(counter, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
      counter
    end

    def record_fired(counter, site) when site in @sites do
      Agent.update(counter, fn s -> %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))} end)
      :ok
    end

    def fired(counter, site), do: Agent.get(counter, &Map.get(&1.fired, site, 0))

    def assert_fired!(counter, site) do
      count = fired(counter, site)

      if count == 0 do
        raise ExUnit.AssertionError,
          message: "dead injector never fired: #{inspect(site)} (armed but silent = green lies)"
      end

      :ok
    end
  end

  # ===========================================================================
  # RefCompactor — the correct reference implementation (negative-control only)
  # ===========================================================================

  defmodule RefCompactor do
    @moduledoc """
    A correct U10 implementation used ONLY as a control reference: proves every
    contour checker accepts conformant behavior (so a checker cannot be
    vacuously false). It is NOT wired into `lib/` — production
    `Raxol.Agent.Compaction` stays `:not_implemented`.
    """

    alias Raxol.Agent.Journal.FileStore
    alias Raxol.Agent.Red.Support.U10Compaction, as: S

    @doc "Compact = append `checkpoint{reason: compaction}` with a content-addressed snapshot."
    def compact(journal, opts) do
      model = Keyword.fetch!(opts, :model)
      reason = Keyword.get(opts, :reason, "compaction")
      %{dir: dir, session_id: session} = journal

      {:ok, records} = FileStore.read(journal)
      tip = S.conversational_tip(records)
      slice = S.persist(model)
      manifest = S.manifest(model)
      {ref, hash, _bytes} = S.write_snapshot!(dir, slice)

      checkpoint = %{
        "kind" => "checkpoint",
        "session_id" => session,
        "ts" => System.system_time(:microsecond),
        "tip_offset" => tip,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => reason
      }

      {:ok, offset} = FileStore.append(journal, checkpoint)

      {:ok,
       %{
         checkpoint_offset: offset,
         snapshot_ref: ref,
         snapshot_hash: hash,
         tip_offset: tip,
         reason: reason,
         manifest: manifest
       }}
    end

    @doc """
    Resume = ordinary checkpoint-restore. With `:at`, restore from a specific
    checkpoint; otherwise select the newest healthy one, surfacing every skipped
    corrupt newer checkpoint in `resume_info.skipped`.
    """
    def resume(journal, opts) do
      %{dir: dir} = journal
      {:ok, records} = FileStore.read(journal)

      cps =
        records |> Enum.filter(&(&1["kind"] == "checkpoint")) |> Enum.sort_by(& &1["id"], :desc)

      case Keyword.get(opts, :at) do
        nil -> select_latest_healthy(dir, records, cps, [])
        offset -> restore_from(dir, records, Enum.find(cps, &(&1["id"] == offset)))
      end
    end

    defp select_latest_healthy(_dir, _records, [], skipped),
      do: {:error, {:no_healthy_checkpoint, skipped}}

    defp select_latest_healthy(dir, records, [cp | rest], skipped) do
      case restore_from(dir, records, cp) do
        {:ok, model, _info} ->
          {:ok, model, %{selected_offset: cp["id"], skipped: Enum.reverse(skipped)}}

        {:error, reason} ->
          select_latest_healthy(dir, records, rest, [{cp["id"], reason} | skipped])
      end
    end

    defp restore_from(_dir, _records, nil), do: {:error, :no_such_checkpoint}

    defp restore_from(dir, records, cp) do
      case S.read_snapshot(dir, cp["snapshot_ref"], cp["snapshot_hash"]) do
        {:error, reason} ->
          {:error, reason}

        {:ok, slice} ->
          tip = cp["tip_offset"]
          after_tip = Enum.filter(records, &(&1["id"] > tip))
          model = Enum.reduce(after_tip, slice, fn r, m -> S.apply_event(m, r) end)
          {:ok, model, %{selected_offset: cp["id"], skipped: []}}
      end
    end
  end

  # ===========================================================================
  # Dead injectors — each violates exactly one law (must fail its checker)
  # ===========================================================================

  defmodule Injectors do
    @moduledoc "Broken compactors/restorers — the negative controls (m4)."

    alias Raxol.Agent.Journal.FileStore
    alias Raxol.Agent.Red.Support.U10Compaction, as: S
    alias Raxol.Agent.Red.Support.U10Compaction.{FaultCounter, RefCompactor}

    @doc """
    (a) Emits a SEPARATE `"compaction"` kind instead of `checkpoint{reason}`.
    Forks the artifact U10 exists to unify — must fail `one_artifact?/2`.
    """
    def separate_kind(journal, opts) do
      counter = Keyword.fetch!(opts, :fault_counter)
      model = Keyword.fetch!(opts, :model)
      %{dir: dir, session_id: session} = journal

      {:ok, records} = FileStore.read(journal)
      tip = S.conversational_tip(records)
      slice = S.persist(model)
      {ref, hash, _} = S.write_snapshot!(dir, slice)

      record = %{
        "kind" => "compaction",
        "session_id" => session,
        "ts" => System.system_time(:microsecond),
        "tip_offset" => tip,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash
      }

      {:ok, offset} = FileStore.append(journal, record)
      FaultCounter.record_fired(counter, :separate_kind)

      {:ok,
       %{
         checkpoint_offset: offset,
         snapshot_ref: ref,
         snapshot_hash: hash,
         tip_offset: tip,
         reason: "compaction",
         manifest: S.manifest(model)
       }}
    end

    @doc """
    (b) Truncates pre-checkpoint bytes — appends a valid checkpoint, then chops
    the tail off the FIRST (earliest, pre-checkpoint) segment. Must fail
    `no_truncation?/2` (FI-7: nothing below the checkpoint may be rewritten).
    Returns a normal-looking result.
    """
    def pre_checkpoint_truncation(journal, opts) do
      counter = Keyword.fetch!(opts, :fault_counter)
      %{dir: dir} = journal

      # Compact healthily first (checkpoint lands in the LAST segment)...
      {:ok, result} = RefCompactor.compact(journal, opts)
      # ...flush everything to disk, then rewrite history BELOW the checkpoint.
      {:ok, _} = FileStore.read(journal)
      [first | _] = S.segment_paths(dir)
      bytes = File.read!(first)
      keep = max(byte_size(bytes) - 6, 0)
      File.write!(first, binary_part(bytes, 0, keep))
      FaultCounter.record_fired(counter, :pre_checkpoint_truncation)

      {:ok, result}
    end

    @doc """
    (c) The lossy summarizer (ContextCompactor-shaped): drops the volatile
    fields but returns an EMPTY manifest — silent loss. Must fail
    `omission_accounted?/3`.
    """
    def lossy_summarizer(journal, opts) do
      counter = Keyword.fetch!(opts, :fault_counter)
      {:ok, result} = RefCompactor.compact(journal, opts)
      FaultCounter.record_fired(counter, :lossy_summarizer)
      {:ok, %{result | manifest: %{dropped: [], redacted: []}}}
    end

    @doc """
    (d) Silent stale restore: on a corrupt newest checkpoint, falls back to an
    older one but reports EMPTY `skipped` — no typed error surfaced. Must fail
    `resume_selection_surfaced?/2`.
    """
    def silent_stale_restore(journal, opts) do
      counter = Keyword.fetch!(opts, :fault_counter)
      %{dir: dir} = journal
      {:ok, records} = FileStore.read(journal)

      cps =
        records |> Enum.filter(&(&1["kind"] == "checkpoint")) |> Enum.sort_by(& &1["id"], :desc)

      # Skip corrupt checkpoints silently; report no skips at all.
      healthy = Enum.find(cps, fn cp -> S.checkpoint_healthy?(dir, atomize(cp)) end)
      {:ok, model, _} = RefCompactor.resume(journal, at: healthy["id"])
      FaultCounter.record_fired(counter, :silent_stale_restore)
      {:ok, model, %{selected_offset: healthy["id"], skipped: []}}
    end

    defp atomize(cp),
      do: %{snapshot_ref: cp["snapshot_ref"], snapshot_hash: cp["snapshot_hash"]}
  end

  # ===========================================================================
  # Session + seeding helpers
  # ===========================================================================

  @doc "Open a fresh throwaway session journal; returns `{handle, session_id, dir}`."
  def fresh_session(base) do
    session = "u10-#{System.unique_integer([:positive])}"
    {:ok, journal} = FileStore.open(session, base_dir: base, segment_cap: 512)
    {journal, session, Path.join(base, session)}
  end

  @doc "Append conversational `item_completed` events carrying fold ops (`%{\"op\" => ...}`)."
  def seed_events!(journal, ops) do
    Enum.each(ops, fn op ->
      {:ok, _} =
        FileStore.append(journal, %{
          "kind" => "event",
          "family" => "loop",
          "type" => "item_completed",
          "payload" => op
        })
    end)

    :ok
  end

  @doc "Flush + read the journal's records (also forces batched writes to disk)."
  def records_of(journal) do
    {:ok, records} = FileStore.read(journal)
    records
  end

  @doc "Corrupt a snapshot file so its bytes no longer hash to `snapshot_hash`."
  def corrupt_snapshot!(dir, ref), do: File.write!(Path.join(dir, ref), "corrupted-not-the-slice")
end
