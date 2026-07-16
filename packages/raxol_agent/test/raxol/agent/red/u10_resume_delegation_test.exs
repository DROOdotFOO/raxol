defmodule Raxol.Agent.Red.U10ResumeDelegationTest do
  @moduledoc """
  Regression suite for the U10-I adversarial-review PRIMARY finding (PR #581):
  `Compaction.resume/2` REIMPLEMENTED restore (its own `fold_forward` + snapshot
  read) instead of delegating to the U9 hardened path. That fork bypassed every
  U9 restore hardening AND ran a second, divergent surrogate fold.

  These CI-green regressions pin the collapse of the fork:

    * (c) STRUCTURAL EQUIVALENCE — resume from a compaction checkpoint returns
      the SAME restored state as `Checkpoint.restore/2` from the same checkpoint,
      because it IS `Checkpoint.restore_checkpoint/3` (not a private copy).
    * (a) TIP GUARD — a checkpoint with a missing OR nil `tip_offset` is a
      typed `:malformed_checkpoint`, skipped (surfaced), never a silent zero-fold
      that drops the whole conversational tail.
    * (b) POINTER HARDENING — a hostile `snapshot_ref` (`../` traversal,
      non-hex) is rejected (`:malformed_pointer`) on the compaction resume path
      EXACTLY as on `Checkpoint.restore/2` — no `Path.join` with an unvalidated
      ref.

  Plus the follow-up adversarial-review round on the same PR:

    * (d) DECODE-GUARD INHERITANCE — the U9 PRE-decode nesting bound
      (`nesting_within_bound?/1`) covers the compaction resume path: a small,
      hash-valid, ~100k-deep snapshot is a typed `:snapshot_corrupt` skip,
      never an unbounded decode.
    * (e) `:at` SELECTOR — `resume/2` honors the advertised `opts` (reference
      semantics: restore that ONE checkpoint, no fall-back walk).
    * (f) COMMITTED-OFFSET SURFACING — when the checkpoint commits but the
      enrichment re-read fails, `compact/2` surfaces the committed offset
      (`{:checkpoint_committed_unreadable, offset, reason}`), so a retrying
      caller cannot double-append.
    * (g) TOTAL-SNAPSHOT-LOSS FAIL-CLOSED — when no checkpoint restores, the
      typed `{:no_healthy_checkpoint, skipped}` error carries every attempt's
      reason and the journal stays intact and `:ok` (no implicit zero-fold —
      a contract ruling, see `Compaction.resume/2` docs).
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Compaction
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.Red.CheckpointRed, as: CR
  alias Raxol.Agent.Red.Support.U10Compaction, as: S

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "u10_deleg_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  # A healthy compaction checkpoint over one seeded event, then more events after
  # it (so restore must fold a real tail forward, not just return the snapshot).
  defp healthy_compaction_with_tail(base) do
    {journal, _session, dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])
    {:ok, c1} = Compaction.compact(journal, model: S.fold(S.records_of(journal)))
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 2}])
    _ = S.records_of(journal)
    {journal, dir, c1}
  end

  # ===========================================================================
  # (c) structural equivalence — resume IS Checkpoint.restore
  # ===========================================================================

  describe "(c) structural resume-equivalence: compaction-restore IS checkpoint-restore" do
    test "resume from a single compaction checkpoint equals Checkpoint.restore from it",
         %{base: base} do
      {journal, _dir, _c1} = healthy_compaction_with_tail(base)

      assert {:ok, resumed, %{selected_offset: sel}} = Compaction.resume(journal, [])
      assert {:ok, restored} = Checkpoint.restore(journal)

      assert resumed == restored,
             "resume must return the SAME model as Checkpoint.restore (same hardened path, not a fork)"

      # ...and both equal a full fold over the persistent slice (P-JS4), proving
      # the shared fold really folded the post-checkpoint tail forward.
      assert resumed == S.persist(S.fold(S.records_of(journal)))
      assert is_integer(sel)

      FileStore.close(journal)
    end
  end

  # ===========================================================================
  # (a) — nil / missing tip_offset is a typed reject, tail NOT dropped
  # ===========================================================================

  describe "(a) tip-offset guard — a malformed newest is skipped, tail preserved" do
    test "newest checkpoint MISSING tip_offset → skipped :malformed_checkpoint, falls back, tail intact",
         %{base: base} do
      {journal, dir, c1} = healthy_compaction_with_tail(base)

      # Inject a NEWER checkpoint (dense id = last+1) that omits tip_offset — the
      # tolerant Reader keeps it, restore must not silently zero-fold.
      {ref, hash} = CR.stage_snapshot!(dir, %{"applied" => []})

      CR.inject_single_counter_checkpoint!(dir, %{
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "compaction"
      })

      _ = S.records_of(journal)
      newest_id = List.last(S.raw_ids(dir))

      assert {:ok, resumed, %{selected_offset: sel, skipped: skipped}} =
               Compaction.resume(journal, [])

      assert {newest_id, :malformed_checkpoint} in skipped,
             "a missing tip_offset must be surfaced as :malformed_checkpoint, never silently skipped"

      assert sel == c1.checkpoint_offset, "falls back to the healthy checkpoint"

      # Tail NOT dropped: the fallback restored the full fold, not a truncated model.
      assert resumed == S.persist(S.fold(S.records_of(journal)))

      FileStore.close(journal)
    end

    test "newest checkpoint with tip_offset: null → :malformed_checkpoint (no silent zero-fold), on BOTH paths",
         %{base: base} do
      {journal, dir, c1} = healthy_compaction_with_tail(base)
      {ref, hash} = CR.stage_snapshot!(dir, %{"applied" => []})

      # tip_offset present but nil — `id > nil` is always false under Elixir term
      # order, so the OLD code folded nothing forward and dropped the tail.
      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => nil,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "compaction"
      })

      _ = S.records_of(journal)
      newest_id = List.last(S.raw_ids(dir))

      # Parity: Checkpoint.restore (newest = the nil-tip checkpoint) rejects it.
      assert {:error, :malformed_checkpoint} = Checkpoint.restore(journal),
             "a nil tip_offset must be a typed reject on the checkpoint path"

      # Compaction resume skips it (surfaced) and falls back to the healthy one.
      assert {:ok, resumed, %{selected_offset: sel, skipped: skipped}} =
               Compaction.resume(journal, [])

      assert {newest_id, :malformed_checkpoint} in skipped
      assert sel == c1.checkpoint_offset
      assert resumed == S.persist(S.fold(S.records_of(journal)))

      FileStore.close(journal)
    end
  end

  # ===========================================================================
  # (b) — hostile snapshot_ref rejected on the resume path, path parity
  # ===========================================================================

  describe "(b) pointer hardening — a hostile snapshot_ref is rejected identically on both paths" do
    for {label, hostile_ref} <- [
          {"path traversal", "snapshots/../../../../etc/passwd"},
          {"non-hex ref", "snapshots/not-a-sha.json"},
          {"bare traversal", "../secrets.json"}
        ] do
      test "newest checkpoint with a #{label} ref → :malformed_pointer on resume AND Checkpoint.restore",
           %{base: base} do
        {journal, dir, c1} = healthy_compaction_with_tail(base)
        tip = S.conversational_tip(S.records_of(journal))

        CR.inject_single_counter_checkpoint!(dir, %{
          "tip_offset" => tip,
          "snapshot_ref" => unquote(hostile_ref),
          "snapshot_hash" => String.duplicate("a", 64),
          "reason" => "compaction"
        })

        _ = S.records_of(journal)
        newest_id = List.last(S.raw_ids(dir))

        # Parity with the checkpoint path: newest is the hostile pointer.
        assert {:error, :malformed_pointer} = Checkpoint.restore(journal),
               "a hostile ref must be rejected before any file read on the checkpoint path"

        # Resume rejects it the same way, surfaces it, and falls back.
        assert {:ok, resumed, %{selected_offset: sel, skipped: skipped}} =
                 Compaction.resume(journal, [])

        assert {newest_id, :malformed_pointer} in skipped,
               "the hostile ref must be surfaced as :malformed_pointer, never Path.join'd"

        assert sel == c1.checkpoint_offset
        assert resumed == S.persist(S.fold(S.records_of(journal)))

        FileStore.close(journal)
      end
    end
  end

  # ===========================================================================
  # (d) — decode-guard inheritance: PRE-decode nesting bound on the resume path
  # ===========================================================================

  describe "(d) decode-guard inheritance — deep-nested hash-valid snapshot is a typed skip on resume" do
    test "newest checkpoint with a small ~100k-deep snapshot → skipped :snapshot_corrupt, falls back, journal :ok",
         %{base: base} do
      {journal, dir, c1} = healthy_compaction_with_tail(base)
      tip = S.conversational_tip(S.records_of(journal))

      # ~200 KB of bytes, ~100k levels of nesting: passes the size cap and the
      # sha256 check. The U9 PRE-decode byte scan (nesting_within_bound?/1) must
      # reject it BEFORE the parser materializes the term — and because resume
      # delegates to the same hardened path, the compaction walk inherits the
      # bound (this pins the inheritance: a re-forked resume without the
      # pre-scan would decode adversarial disk data).
      deep = String.duplicate("[", 100_000) <> "1" <> String.duplicate("]", 100_000)
      bytes = ~s({"applied":) <> deep <> "}"
      hash = CR.sha256_hex(bytes)
      ref = "snapshots/#{hash}.json"
      File.mkdir_p!(Path.join(dir, "snapshots"))
      File.write!(Path.join(dir, ref), bytes)

      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => tip,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "compaction"
      })

      _ = S.records_of(journal)
      newest_id = List.last(S.raw_ids(dir))

      # Parity with the checkpoint path (same code, so the same typed reject).
      assert {:error, :snapshot_corrupt} = Checkpoint.restore(journal)

      assert {:ok, resumed, %{selected_offset: sel, skipped: skipped}} =
               Compaction.resume(journal, [])

      assert {newest_id, :snapshot_corrupt} in skipped,
             "adversarial nesting must surface the promised typed reject on the resume path"

      assert sel == c1.checkpoint_offset
      assert resumed == S.persist(S.fold(S.records_of(journal)))
      assert FileStore.status(journal) == :ok

      FileStore.close(journal)
    end
  end

  # ===========================================================================
  # (e) — resume honors the advertised opts: the `:at` selector
  # ===========================================================================

  defp two_compactions(base) do
    {journal, _session, dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])
    {:ok, c1} = Compaction.compact(journal, model: S.fold(S.records_of(journal)))
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 2}])
    {:ok, c2} = Compaction.compact(journal, model: S.fold(S.records_of(journal)))
    {journal, dir, c1, c2}
  end

  describe "(e) :at selector — resume/2 honors opts instead of silently discarding them" do
    test "at: an OLDER checkpoint's offset restores THAT checkpoint, not the newest",
         %{base: base} do
      {journal, _dir, c1, c2} = two_compactions(base)

      assert {:ok, _model, %{selected_offset: sel, skipped: []}} =
               Compaction.resume(journal, at: c1.checkpoint_offset)

      assert sel == c1.checkpoint_offset,
             "resume(at: offset) must select the NAMED checkpoint (pre-fix: opts were discarded and the newest #{c2.checkpoint_offset} won)"

      FileStore.close(journal)
    end

    test "at: an unknown offset → {:error, :no_such_checkpoint} (reference semantics, no silent fall-back)",
         %{base: base} do
      {journal, _dir, _c1, c2} = two_compactions(base)

      assert {:error, :no_such_checkpoint} =
               Compaction.resume(journal, at: c2.checkpoint_offset + 999)

      FileStore.close(journal)
    end

    test "at: a corrupt checkpoint surfaces its typed restore error, never silently selects another",
         %{base: base} do
      {journal, dir, _c1, c2} = two_compactions(base)
      S.corrupt_snapshot!(dir, c2.snapshot_ref)
      _ = S.records_of(journal)

      assert {:error, :snapshot_corrupt} =
               Compaction.resume(journal, at: c2.checkpoint_offset)

      FileStore.close(journal)
    end
  end

  # ===========================================================================
  # (g) — total snapshot loss FAILS CLOSED (pinning: no implicit zero-fold)
  # ===========================================================================

  describe "(g) total snapshot loss — typed {:no_healthy_checkpoint, skipped}, journal intact" do
    test "every checkpoint unreadable → every attempt surfaced, no implicit zero-fold, journal stays :ok",
         %{base: base} do
      {journal, _session, dir} = S.fresh_session(base)
      S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])
      {:ok, c1} = Compaction.compact(journal, model: S.fold(S.records_of(journal)))
      S.seed_events!(journal, [%{"op" => "incr", "amount" => 2}])
      {:ok, c2} = Compaction.compact(journal, model: S.fold(S.records_of(journal)))

      # Loss of the whole snapshots subtree (bit-rot class).
      S.corrupt_snapshot!(dir, c1.snapshot_ref)
      S.corrupt_snapshot!(dir, c2.snapshot_ref)
      _ = S.records_of(journal)

      # FAIL CLOSED (contract ruling, see Compaction.resume/2 docs): resume
      # never silently folds from offset 0 — it surfaces every attempt so the
      # caller decides. The append-only journal is untouched and remains fully
      # foldable by an EXPLICIT zero-fold.
      assert {:error, {:no_healthy_checkpoint, skipped}} = Compaction.resume(journal, [])

      assert {c2.checkpoint_offset, :snapshot_corrupt} in skipped
      assert {c1.checkpoint_offset, :snapshot_corrupt} in skipped

      assert {:ok, records} = FileStore.read(journal)
      assert FileStore.status(journal) == :ok
      # The conversational history is all still there for an explicit recovery.
      assert S.fold(records)["applied"] != []

      FileStore.close(journal)
    end
  end
end
