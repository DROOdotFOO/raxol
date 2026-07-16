defmodule Raxol.Agent.Red.U10CompactionRedTest do
  @moduledoc """
  U10-R — permanent failing-first red suite for "Compaction = Resume" (AD-3b).

  These POSITIVE contours run against the REAL `Raxol.Agent.Compaction`. With
  U10 landed (compaction = a `checkpoint{reason: "compaction"}` record, resume =
  the ordinary checkpoint-restore path, reusing the U9 checkpoint write path)
  they are GREEN and run every CI pass — the `:harness_red` exclusion was
  dropped when the implementation landed.

  Governing contract: `docs/proposals/in-flight/harness-freeze-contracts.md` §1
  (JS-FREEZE) — the one-artifact thesis. The five laws:

    1. compact-then-resume ≡ checkpoint-restore (P-JS4 fold equality);
    2. compaction never loses un-manifested data (MS discipline);
    3. compaction is observable in-journal (the checkpoint record IS the event);
    4. journal bytes below the checkpoint offset are never truncated (FI-7);
    5. repeated compaction is idempotent-safe.

  The CI-green companion `Raxol.Agent.Red.U10CompactionControlsTest` (below)
  proves each contour checker discriminates (reference passes, dead injector
  fails) with fired-counters.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Compaction
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Red.Support.U10Compaction, as: S

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "u10_red_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  # -- Law 3: compaction is one observable in-journal artifact ----------------

  test "P1 — compaction is one artifact: a checkpoint{reason: compaction}, one dense offset via the real Writer",
       %{base: base} do
    {journal, _session, dir} = S.fresh_session(base)

    S.seed_events!(journal, [
      %{"op" => "incr", "amount" => 2},
      %{"op" => "note", "text" => "a"}
    ])

    before_ids = Enum.map(S.records_of(journal), & &1["id"])
    model = S.fold(S.records_of(journal))

    # RED: skeleton returns {:error, :not_implemented}.
    assert {:ok, result} = Compaction.compact(journal, model: model)

    assert S.one_artifact?(dir, result),
           "compaction must be a checkpoint{reason: \"compaction\"} record, not a side-channel or a separate kind"

    assert S.single_dense_append?(before_ids, dir, result),
           "compaction must consume exactly one dense Writer offset (no dual-id, no gap)"

    FileStore.close(journal)
  end

  # -- Law 1: compact-then-resume ≡ full fold on the persistent slice ---------

  test "P2 — compact then resume equals a direct full fold on the persistent slice (real MS codec)",
       %{base: base} do
    {journal, _session, _dir} = S.fresh_session(base)

    S.seed_events!(journal, [
      %{"op" => "incr", "amount" => 2},
      %{"op" => "note", "text" => "x"}
    ])

    model_at_tip = S.fold(S.records_of(journal))

    # RED here: compact is :not_implemented.
    assert {:ok, _result} = Compaction.compact(journal, model: model_at_tip)

    # Events accrue AFTER the compaction checkpoint...
    S.seed_events!(journal, [
      %{"op" => "incr", "amount" => 5},
      %{"op" => "note", "text" => "y"}
    ])

    # ...and resume must land exactly where a full fold on the persistent slice does.
    assert {:ok, resumed, _info} = Compaction.resume(journal, [])
    expected = S.persist(S.fold(S.records_of(journal)))

    assert resumed == expected,
           "resume must equal fold(0..now) on the persistent slice (P-JS4)"

    FileStore.close(journal)
  end

  # -- Law 4: FI-7 no truncation of bytes below the checkpoint ----------------

  test "P3 — journal bytes below the checkpoint offset are byte-identical before/after compaction (FI-7)",
       %{base: base} do
    {journal, _session, dir} = S.fresh_session(base)
    # Enough events to span multiple segments (segment_cap 512).
    S.seed_events!(
      journal,
      for(n <- 1..16, do: %{"op" => "incr", "amount" => n})
    )

    _ = S.records_of(journal)
    before_bytes = S.concat_bytes(dir)
    model = S.fold(S.records_of(journal))

    # RED: compact is :not_implemented.
    assert {:ok, _result} = Compaction.compact(journal, model: model)

    _ = S.records_of(journal)
    after_bytes = S.concat_bytes(dir)

    assert S.no_truncation?(before_bytes, after_bytes),
           "compaction may only APPEND — pre-checkpoint bytes must survive verbatim (nothing deleted implicitly)"

    FileStore.close(journal)
  end

  # -- Law 2: omission accounting (MS discipline) -----------------------------

  test "P4 — every non-persistable field omitted from the snapshot appears in the manifest",
       %{base: base} do
    {journal, _session, _dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])

    # A model carrying volatile fields (a PID stand-in + a secret) that MUST NOT
    # hit the snapshot — and MUST be accounted, not silently dropped.
    model =
      S.fold(S.records_of(journal))
      |> Map.merge(%{
        "_conn_pid" => "#PID<0.123.0>",
        "_secret_token" => "sk-live-xyz"
      })

    # RED: compact is :not_implemented.
    assert {:ok, result} = Compaction.compact(journal, model: model)

    slice = S.persist(model)

    assert S.omission_accounted?(model, slice, result.manifest),
           "the dropped/redacted manifest must name EVERY omitted field — nothing silently lost"

    refute "_secret_token" in Map.keys(slice),
           "secrets never reach the snapshot slice"

    FileStore.close(journal)
  end

  # -- Law 5: repeated compaction is idempotent-safe --------------------------

  test "P5 — a second compaction appends a fresh checkpoint; the older stays healthy, resume selects the newest",
       %{base: base} do
    {journal, _session, dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 2}])

    # RED: first compact is :not_implemented.
    assert {:ok, c1} =
             Compaction.compact(journal, model: S.fold(S.records_of(journal)))

    S.seed_events!(journal, [%{"op" => "incr", "amount" => 3}])

    assert {:ok, c2} =
             Compaction.compact(journal, model: S.fold(S.records_of(journal)))

    assert c2.checkpoint_offset > c1.checkpoint_offset

    assert S.checkpoint_healthy?(dir, c1),
           "the first checkpoint must remain healthy after the second"

    assert S.checkpoint_healthy?(dir, c2)

    assert {:ok, _model, %{selected_offset: sel}} =
             Compaction.resume(journal, [])

    assert sel == c2.checkpoint_offset,
           "resume must select the LATEST healthy checkpoint"

    FileStore.close(journal)
  end

  # -- Law 1 + selection: corrupt newest surfaces a typed error, falls back ---

  test "P6 — resume picks the latest healthy checkpoint; a corrupt newest falls back WITH the typed error surfaced",
       %{base: base} do
    {journal, _session, dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])

    assert {:ok, c1} =
             Compaction.compact(journal, model: S.fold(S.records_of(journal)))

    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])

    assert {:ok, c2} =
             Compaction.compact(journal, model: S.fold(S.records_of(journal)))

    # Corrupt the NEWEST snapshot so its bytes no longer hash.
    S.corrupt_snapshot!(dir, c2.snapshot_ref)

    result = Compaction.resume(journal, [])

    assert S.resume_selection_surfaced?(result, c2.checkpoint_offset),
           "a corrupt newest must be reported (skipped + typed reason), never silently skipped"

    assert {:ok, _model, %{selected_offset: sel}} = result

    assert sel == c1.checkpoint_offset,
           "resume must fall back to the previous healthy checkpoint"

    FileStore.close(journal)
  end
end

defmodule Raxol.Agent.Red.U10CompactionControlsTest do
  @moduledoc """
  CI-green controls for U10-R (meta-inv m1 fired-counters, m4 negative
  controls). NOT tagged `:harness_red` — these run every CI pass and prove the
  contour checkers in `Raxol.Agent.Red.U10CompactionRedTest` are not vacuous: a
  correct reference (`RefCompactor`) passes each checker, and a dead injector
  violating exactly one law fails the matching checker while firing its counter.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Red.Support.U10Compaction, as: S

  alias Raxol.Agent.Red.Support.U10Compaction.{
    FaultCounter,
    Injectors,
    RefCompactor
  }

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "u10_ctl_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp seed_one(base) do
    {journal, _session, dir} = S.fresh_session(base)

    S.seed_events!(journal, [
      %{"op" => "incr", "amount" => 2},
      %{"op" => "note", "text" => "a"}
    ])

    {journal, dir}
  end

  # -- (a) separate "compaction" kind fails the one-artifact contour ----------

  test "dead injector (a): a separate \"compaction\" kind fails one_artifact?; the reference passes",
       %{base: base} do
    fc = FaultCounter.new()
    FaultCounter.arm(fc, :separate_kind)

    {ref_j, ref_dir} = seed_one(base)
    before = Enum.map(S.records_of(ref_j), & &1["id"])

    {:ok, ref_result} =
      RefCompactor.compact(ref_j, model: S.fold(S.records_of(ref_j)))

    assert S.one_artifact?(ref_dir, ref_result)
    assert S.single_dense_append?(before, ref_dir, ref_result)
    FileStore.close(ref_j)

    {bad_j, bad_dir} = seed_one(base)

    {:ok, bad_result} =
      Injectors.separate_kind(bad_j,
        model: S.fold(S.records_of(bad_j)),
        fault_counter: fc
      )

    refute S.one_artifact?(bad_dir, bad_result),
           "a record with kind \"compaction\" must NOT satisfy the one-artifact contour"

    FileStore.close(bad_j)
    FaultCounter.assert_fired!(fc, :separate_kind)
  end

  # -- (b) rewriting pre-checkpoint bytes fails the no-truncation contour ------

  test "dead injector (b): truncating pre-checkpoint bytes fails no_truncation?; the reference (append-only) passes",
       %{base: base} do
    fc = FaultCounter.new()
    FaultCounter.arm(fc, :pre_checkpoint_truncation)

    # Reference: append-only compaction preserves the byte prefix.
    {ref_j, ref_dir} = multi_segment(base)
    _ = S.records_of(ref_j)
    ref_before = S.concat_bytes(ref_dir)
    {:ok, _} = RefCompactor.compact(ref_j, model: S.fold(S.records_of(ref_j)))
    _ = S.records_of(ref_j)
    assert S.no_truncation?(ref_before, S.concat_bytes(ref_dir))
    FileStore.close(ref_j)

    # Injector: rewrites history below the checkpoint.
    {bad_j, bad_dir} = multi_segment(base)
    _ = S.records_of(bad_j)
    bad_before = S.concat_bytes(bad_dir)

    {:ok, _} =
      Injectors.pre_checkpoint_truncation(bad_j,
        model: S.fold(S.records_of(bad_j)),
        fault_counter: fc
      )

    refute S.no_truncation?(bad_before, S.concat_bytes(bad_dir)),
           "truncating pre-checkpoint bytes must break the byte-prefix (FI-7)"

    FaultCounter.assert_fired!(fc, :pre_checkpoint_truncation)
  end

  defp multi_segment(base) do
    {journal, _session, dir} = S.fresh_session(base)

    S.seed_events!(
      journal,
      for(n <- 1..16, do: %{"op" => "incr", "amount" => n})
    )

    {journal, dir}
  end

  # -- (c) the lossy summarizer fails the omission-accounting contour ----------

  test "dead injector (c): a lossy summarizer (empty manifest) fails omission_accounted?; the reference accounts every field",
       %{base: base} do
    fc = FaultCounter.new()
    FaultCounter.arm(fc, :lossy_summarizer)

    volatile = %{"_conn_pid" => "#PID<0.1.0>", "_secret_token" => "sk-xyz"}

    {ref_j, _ref_dir} = seed_one(base)
    ref_model = S.fold(S.records_of(ref_j)) |> Map.merge(volatile)
    {:ok, ref_result} = RefCompactor.compact(ref_j, model: ref_model)

    assert S.omission_accounted?(
             ref_model,
             S.persist(ref_model),
             ref_result.manifest
           )

    FileStore.close(ref_j)

    {bad_j, _bad_dir} = seed_one(base)
    bad_model = S.fold(S.records_of(bad_j)) |> Map.merge(volatile)

    {:ok, bad_result} =
      Injectors.lossy_summarizer(bad_j, model: bad_model, fault_counter: fc)

    refute S.omission_accounted?(
             bad_model,
             S.persist(bad_model),
             bad_result.manifest
           ),
           "dropping fields with no manifest entry must fail omission accounting"

    FileStore.close(bad_j)
    FaultCounter.assert_fired!(fc, :lossy_summarizer)
  end

  # -- (d) silent stale restore fails the resume-selection contour ------------

  test "dead injector (d): a silent fallback on a corrupt newest fails resume_selection_surfaced?; the reference surfaces the typed error",
       %{base: base} do
    fc = FaultCounter.new()
    FaultCounter.arm(fc, :silent_stale_restore)

    {journal, dir} = two_checkpoints(base)
    [newest | _] = S.checkpoints(dir)
    corrupt_offset = newest["id"]
    S.corrupt_snapshot!(dir, newest["snapshot_ref"])
    _ = S.records_of(journal)

    # Reference: surfaces the corrupt newest AND falls back.
    ref_res = RefCompactor.resume(journal, [])
    assert S.resume_selection_surfaced?(ref_res, corrupt_offset)
    assert {:ok, _m, %{selected_offset: sel}} = ref_res

    assert sel < corrupt_offset,
           "reference falls back to the previous healthy checkpoint"

    # Injector: silently uses the stale checkpoint, surfaces nothing.
    bad_res = Injectors.silent_stale_restore(journal, fault_counter: fc)

    refute S.resume_selection_surfaced?(bad_res, corrupt_offset),
           "a silent fallback (empty skipped) must fail the resume-selection contour"

    FileStore.close(journal)
    FaultCounter.assert_fired!(fc, :silent_stale_restore)
  end

  defp two_checkpoints(base) do
    {journal, _session, dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])

    {:ok, _c1} =
      RefCompactor.compact(journal, model: S.fold(S.records_of(journal)))

    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])

    {:ok, _c2} =
      RefCompactor.compact(journal, model: S.fold(S.records_of(journal)))

    {journal, dir}
  end

  # -- P2 discrimination: the fold-equality oracle is not trivially true ------

  test "control: reference compact+resume equals the full fold; a resume that drops post-checkpoint events does NOT",
       %{base: base} do
    {journal, _session, _dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 2}])

    {:ok, _c} =
      RefCompactor.compact(journal, model: S.fold(S.records_of(journal)))

    S.seed_events!(journal, [
      %{"op" => "incr", "amount" => 5},
      %{"op" => "note", "text" => "z"}
    ])

    {:ok, resumed, _} = RefCompactor.resume(journal, [])
    full = S.persist(S.fold(S.records_of(journal)))

    assert resumed == full,
           "correct resume equals fold(0..now) on the persistent slice"

    # A resume that ignored post-checkpoint events would NOT match — the oracle
    # discriminates (P2 is not vacuously true).
    stale_slice = S.persist(S.fold(Enum.take(S.records_of(journal), 2)))
    refute stale_slice == full

    FileStore.close(journal)
  end

  # -- P5 discrimination: both checkpoints healthy, restore-from-each consistent

  test "control: repeated compaction — both checkpoints healthy, resume selects newest, restore-from-each is consistent",
       %{base: base} do
    {journal, dir} = two_checkpoints(base)
    [c2_rec, c1_rec] = S.checkpoints(dir)

    c1 = %{
      snapshot_ref: c1_rec["snapshot_ref"],
      snapshot_hash: c1_rec["snapshot_hash"]
    }

    c2 = %{
      snapshot_ref: c2_rec["snapshot_ref"],
      snapshot_hash: c2_rec["snapshot_hash"]
    }

    assert S.checkpoint_healthy?(dir, c1)
    assert S.checkpoint_healthy?(dir, c2)

    {:ok, from_latest, %{selected_offset: sel}} =
      RefCompactor.resume(journal, [])

    assert sel == c2_rec["id"], "resume selects the newest checkpoint"

    # Restoring from the OLDER checkpoint replays forward to the same current
    # tip — a checkpoint is a fold-acceleration point, restore is always to-tip.
    {:ok, from_older, _} = RefCompactor.resume(journal, at: c1_rec["id"])

    assert from_older == from_latest,
           "restore-from-each converges on the current tip state"

    FileStore.close(journal)
  end

  # -- m1 registry completeness: every named dead injector has a control ------

  test "meta: the four AD-3b dead injectors are all registered fault sites (m1 completeness)" do
    assert Enum.sort(FaultCounter.sites()) ==
             Enum.sort([
               :separate_kind,
               :pre_checkpoint_truncation,
               :lossy_summarizer,
               :silent_stale_restore
             ])
  end
end
