defmodule Raxol.Agent.Red.U9CheckpointRedTest do
  @moduledoc """
  U9-R — permanent failing-first (RED) suite for **checkpoint pointer records**
  (AD-10 / AD-3a), authored BEFORE implementation against the frozen shapes in
  `docs/proposals/in-flight/harness-freeze-contracts.md` §1.1–§1.3 (JS-FREEZE).

  These tests assert the *correct* checkpoint behaviour. The enabler skeleton
  `Raxol.Agent.Journal.Records.Checkpoint` returns `{:error, :not_implemented}`
  from `write/3` and `restore/2`, so every contour here is RED by construction
  until U9 lands. The suite carries `@moduletag :harness_red` and is excluded
  from CI (see `test/test_helper.exs`); when U9 lands, the exclusion is dropped
  and these must go green unchanged.

  Journal truth is the independent raw oracle in `Raxol.Agent.Red.CheckpointRed`
  (meta-inv 6), never `FileStore.read/2`. Where the real Writer/FileStore exist
  they ARE driven (single-Writer append, dense offsets); only the checkpoint
  seam is the not-yet-built subject.

  Contours (freeze §1.2/§1.3):

    * P-JS1  — checkpoint consumes exactly one offset; record ids stay dense
    * file-before-record — orphan file harmless; record-without-file → N-JS3
    * P-JS4  — round-trip: restore == fold(0..tip) ⊕ snapshot == full fold
    * OQ-JS1 — tip-only checkpoint (snapshot_ref nil) → full fold(0..tip) restore
    * N-JS3  — sha256 verify at restore: corrupt file → :snapshot_corrupt, nothing deleted
    * N-JS1  — tip_offset validated at write: meta/checkpoint/hole → :invalid_tip, nothing appended
    * N-JS2  — turn-boundary: mid_turn / mid_reserve → typed reject, nothing appended
    * FI-10  — record body carries pointer + hash only (no model keys)
    * reason enum accepted; unknown reason tolerated on READ (forward-compat)

  DEFERRED (do NOT author — freeze marks `@tag :gc`): P-JS11 / N-JS11 (GC
  low-watermark density). See the PR body.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.Red.CheckpointRed, as: CR

  # U9 landed: this suite now runs GREEN in CI (was `@moduletag :harness_red`,
  # excluded, until the checkpoint pointer-record implementation shipped).
  @moduletag :capture_log

  setup do
    base =
      Path.join(System.tmp_dir!(), "u9r_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  # A journal ending at a clean turn boundary (turn_started -> item_completed ->
  # turn_completed), with a trailing NON-conversational record so the tip is
  # never the last physical record (meta-inv 5 — no vacuous tip contour).
  defp seed_conversation!(base) do
    {j, session, dir} = CR.open!(base)

    CR.append_all!(j, [
      CR.loop_event("turn_started"),
      CR.loop_event("item_completed", %{"text" => "hi"}),
      CR.loop_event("turn_completed"),
      CR.meta_event("idle")
    ])

    {j, session, dir}
  end

  # ===========================================================================
  # P-JS1 — a checkpoint consumes exactly one offset; ids stay dense
  # ===========================================================================

  describe "P-JS1 — checkpoint append consumes exactly one offset (single-counter lockstep)" do
    test "write appends one checkpoint record; record-layer ids stay dense 1..n+1",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)
      before_ids = CR.raw_ids(dir)
      tip = CR.tip_of(dir)

      assert tip == 3,
             "tip is the last CONVERSATIONAL record (turn_completed), not the idle tail"

      # The frozen contract: {:ok, offset} where offset is the checkpoint's OWN
      # dense journal offset (last + 1), and the record layer stays dense.
      assert {:ok, offset} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual"),
             "checkpoint write must return its dense offset (RED until U9)"

      assert offset == List.last(before_ids) + 1

      assert CR.dense_ids?(dir),
             "record ids must stay dense after the checkpoint append (N-JS6)"

      records = CR.raw_records(dir)
      cp = Enum.find(records, &(&1["kind"] == "checkpoint"))
      assert cp["id"] == offset
      assert cp["tip_offset"] == tip
      :ok = FileStore.close(j)
    end

    test "the checkpoint is stamped kind=\"checkpoint\" and rides the SAME single Writer",
         %{
           base: base
         } do
      {j, _session, dir} = seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => []}, reason: "auto")

      # Exactly one checkpoint record, appended through the single-writer offset
      # space (dense) — never a side counter (N-JS6).
      cps = CR.raw_records(dir) |> Enum.filter(&(&1["kind"] == "checkpoint"))
      assert length(cps) == 1
      assert CR.dense_ids?(dir)
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # File-before-record ordering (crash windows)
  # ===========================================================================

  describe "file-before-record ordering (FI-8 / FI-7 crash windows)" do
    test "orphan snapshot file + NO record = harmless: journal healthy, restore ignores it",
         %{
           base: base
         } do
      {j, _session, dir} = seed_conversation!(base)

      # A crash AFTER the snapshot file write but BEFORE the record append leaves
      # a content-addressed orphan. FI-7: never deleted implicitly; harmless.
      {_ref, _hash} = CR.stage_snapshot!(dir, %{"applied" => [1, 2, 3]})

      assert FileStore.status(j) == :ok,
             "an orphan snapshot must not damage the journal"

      assert CR.dense_ids?(dir)

      # No checkpoint record exists, so restore must fall back cleanly (RED until U9).
      assert {:error, :no_checkpoint} = Checkpoint.restore(j),
             "with no checkpoint record, restore reports no checkpoint (never reads the orphan)"

      :ok = FileStore.close(j)
    end

    test "record present + snapshot file ABSENT = N-JS3 at restore; journal stays :ok, nothing deleted",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)
      tip = CR.tip_of(dir)

      # The ILLEGAL order made permanent: a checkpoint record that names a
      # snapshot which was never written.
      ref = CR.inject_record_before_file!(dir, tip)
      refute CR.snapshot_present?(dir, ref)
      segs_before = File.ls!(Path.join(dir, "journal"))

      assert {:error, :snapshot_missing} = Checkpoint.restore(j),
             "a referenced-but-absent snapshot must surface :snapshot_missing (N-JS3)"

      # Checkpoint-level damage is NOT journal damage.
      assert FileStore.status(j) == :ok

      assert File.ls!(Path.join(dir, "journal")) == segs_before,
             "nothing deleted (FI-7)"

      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # P-JS4 — checkpoint round-trip (restore == fold(0..tip) ⊕ snapshot == full fold)
  # ===========================================================================

  describe "P-JS4 — round-trip on the persistent slice" do
    # NOTE: expressed against the CheckpointRed toy fold surrogate — the real MS
    # Snapshot codec (dump/load/persistent_slice) is not merged on master. The
    # round-trip EQUATION is exact; re-bind `fold/1` to the real MS fold when it
    # lands. Flagged inexpressible-against-real-codec in the PR body.
    test "restore equals a full fold; equals fold(0..tip) then fold-forward the mutation tail",
         %{
           base: base
         } do
      {j, _session, dir} = seed_conversation!(base)
      tip = CR.tip_of(dir)

      # Checkpoint captures the model as of the tip.
      assert {:ok, _cp_off} =
               Checkpoint.write(j, CR.fold(CR.raw_records(dir)), reason: "manual")

      # Mutate the conversation forward past the checkpoint.
      CR.append_all!(j, [
        CR.loop_event("turn_started"),
        CR.loop_event("item_completed", %{"text" => "more"}),
        CR.loop_event("turn_completed")
      ])

      all = CR.raw_records(dir)
      full = CR.fold(all)

      # The frozen restore identity, computed independently by the oracle:
      #   restore == load(snapshot at tip) ⊕ fold-forward(events with id > tip)
      #           == fold(all)  (a full fold over the persistent slice)
      {events_le_tip, events_gt_tip} = Enum.split_with(all, &(&1["id"] <= tip))
      snapshot = CR.load(CR.dump(CR.fold(events_le_tip)))
      reconstructed = CR.fold_forward(snapshot, events_gt_tip)

      assert reconstructed == full,
             "oracle sanity: the ⊕ identity must hold (non-vacuous round-trip)"

      # The subject under test must reproduce exactly that model.
      assert {:ok, ^full} = Checkpoint.restore(j),
             "restore must equal the full fold on the persistent slice (P-JS4)"

      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # OQ-JS1 — tip-only checkpoint (snapshot_ref nil) is legal
  # ===========================================================================

  describe "OQ-JS1 — tip-only checkpoint (snapshot_ref nil) restores by full fold(0..tip)" do
    test "a nil-snapshot checkpoint is legal and restore falls back to fold(0..tip_offset)",
         %{
           base: base
         } do
      {j, _session, dir} = seed_conversation!(base)
      tip = CR.tip_of(dir)

      # snapshot: nil -> tip-only pointer (permanently legal, OQ-JS1 RULED).
      assert {:ok, _off} = Checkpoint.write(j, nil, reason: "manual"),
             "tip-only checkpoint (nil snapshot) must be accepted"

      cp = CR.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))

      assert cp["snapshot_ref"] == nil,
             "tip-only pointer carries snapshot_ref: nil"

      assert cp["snapshot_hash"] == nil

      expected = CR.fold(Enum.filter(CR.raw_records(dir), &(&1["id"] <= tip)))

      assert {:ok, ^expected} = Checkpoint.restore(j),
             "with no snapshot, restore is a full fold(0..tip_offset)"

      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # N-JS3 — sha256 verification at restore
  # ===========================================================================

  describe "N-JS3 — snapshot hash verification at restore" do
    test "sha256(bytes) == snapshot_hash for a healthy checkpoint", %{
      base: base
    } do
      {j, _session, dir} = seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual")

      cp = CR.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
      assert is_binary(cp["snapshot_ref"]) and is_binary(cp["snapshot_hash"])
      bytes = File.read!(Path.join(dir, cp["snapshot_ref"]))

      assert CR.sha256_hex(bytes) == cp["snapshot_hash"],
             "snapshot_hash must be the lowercase-hex sha256 of the file bytes"

      :ok = FileStore.close(j)
    end

    test "a corrupted snapshot file → :snapshot_corrupt at restore; journal :ok, nothing deleted",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual")

      cp = CR.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
      snap_path = Path.join(dir, cp["snapshot_ref"])

      # Flip the snapshot bytes so sha256 no longer matches snapshot_hash.
      File.write!(snap_path, File.read!(snap_path) <> "corruption")

      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "a hash mismatch must surface :snapshot_corrupt (N-JS3)"

      assert FileStore.status(j) == :ok,
             "checkpoint damage is not journal damage"

      assert File.exists?(snap_path), "nothing deleted on corruption (FI-7)"
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # N-JS1 — tip_offset validated at write
  # ===========================================================================

  describe "N-JS1 — tip_offset validity at write (nothing appended on reject)" do
    test "tip_offset naming a META event → :invalid_tip; offset counter untouched",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)
      before_ids = CR.raw_ids(dir)

      # id 5 is the trailing meta `idle` — not CONVERSATIONAL.
      meta_id =
        CR.raw_records(dir)
        |> Enum.find(&(&1["family"] == "meta"))
        |> Map.fetch!("id")

      refute CR.valid_tip?(CR.raw_records(dir), meta_id),
             "oracle: meta id is not a valid tip"

      assert {:error, :invalid_tip} =
               Checkpoint.write(j, %{"applied" => []}, tip_offset: meta_id),
             "a tip_offset pointing at a meta event must be rejected"

      assert CR.raw_ids(dir) == before_ids, "nothing appended on :invalid_tip"

      # The offset counter is untouched: the next real append continues densely.
      {:ok, next} = FileStore.append(j, CR.loop_event("turn_started"))
      assert next == List.last(before_ids) + 1
      :ok = FileStore.close(j)
    end

    test "tip_offset naming ANOTHER checkpoint → :invalid_tip", %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # Stage a prior checkpoint (single-counter) so its offset exists to point at.
      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => CR.tip_of(dir),
        "snapshot_ref" => nil,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      cp_id =
        CR.raw_records(dir)
        |> Enum.find(&(&1["kind"] == "checkpoint"))
        |> Map.fetch!("id")

      refute CR.valid_tip?(CR.raw_records(dir), cp_id)

      assert {:error, :invalid_tip} =
               Checkpoint.write(j, %{"applied" => []}, tip_offset: cp_id),
             "a tip_offset pointing at a checkpoint record must be rejected"

      :ok = FileStore.close(j)
    end

    test "tip_offset naming a HOLE (beyond last offset) → :invalid_tip; nothing appended",
         %{
           base: base
         } do
      {j, _session, dir} = seed_conversation!(base)
      before_ids = CR.raw_ids(dir)
      hole = List.last(before_ids) + 99

      assert {:error, :invalid_tip} =
               Checkpoint.write(j, %{"applied" => []}, tip_offset: hole)

      assert CR.raw_ids(dir) == before_ids, "nothing appended on a hole tip"
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # N-JS2 — turn-boundary rule
  # ===========================================================================

  describe "N-JS2 — checkpoints never land mid-turn / mid-reserve" do
    test "mid-turn (turn_started with no close) → :mid_turn; nothing appended",
         %{base: base} do
      {j, _session, dir} = CR.open!(base)

      CR.append_all!(j, [
        CR.loop_event("turn_started"),
        CR.loop_event("item_started")
      ])

      before_ids = CR.raw_ids(dir)

      refute CR.at_turn_boundary?(CR.raw_records(dir)),
             "oracle: an open turn is not a boundary"

      assert {:error, :mid_turn} =
               Checkpoint.write(j, %{"applied" => []}, reason: "manual"),
             "a checkpoint between turn_started and its close must be rejected"

      assert CR.raw_ids(dir) == before_ids, "nothing appended mid-turn"
      :ok = FileStore.close(j)
    end

    test "mid-reserve (spend-gate reserve with no terminal) → :mid_reserve; nothing appended",
         %{
           base: base
         } do
      # NOTE: reserve/settle vocabulary is provisional (see CheckpointRed) — the
      # contour is authored so it binds the real spend-gate vocab when it lands.
      {j, _session, dir} = CR.open!(base)

      CR.append_all!(j, [
        CR.loop_event("turn_started"),
        CR.loop_event("turn_completed"),
        CR.meta_event("reserve", %{"amount" => "1.00"})
      ])

      before_ids = CR.raw_ids(dir)

      refute CR.at_turn_boundary?(CR.raw_records(dir)),
             "oracle: an open reserve is not a boundary"

      assert {:error, :mid_reserve} =
               Checkpoint.write(j, %{"applied" => []}, reason: "manual"),
             "a checkpoint between a reserve and its terminal must be rejected"

      assert CR.raw_ids(dir) == before_ids, "nothing appended mid-reserve"
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # FI-10 — record body carries pointer + hash only (no model content)
  # ===========================================================================

  describe "FI-10 — checkpoint record body is pointer + hash only" do
    test "the record carries only frozen keys — no model/messages/tools content",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # A model deliberately laden with secret-looking keys — none may reach the record.
      model = %{
        "applied" => [1, 2, 3],
        "messages" => ["secret"],
        "tools" => ["hammer"],
        "api_key" => "sk-xxx"
      }

      assert {:ok, _off} = Checkpoint.write(j, model, reason: "manual")

      cp = CR.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
      allowed = MapSet.new(Checkpoint.record_keys())

      assert MapSet.subset?(MapSet.new(Map.keys(cp)), allowed),
             "checkpoint record grew keys outside the frozen set: #{inspect(Map.keys(cp))}"

      refute Map.has_key?(cp, "messages")
      refute Map.has_key?(cp, "api_key")
      :ok = FileStore.close(j)
    end

    test "the written record carries branch_id — the frozen field @type t now documents",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => []}, reason: "manual")

      cp = CR.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))

      # branch_id is written (single linear "main" branch, v1) and enumerated by
      # record_keys/0 — the @type t spec must include it too (spec/record parity).
      assert cp["branch_id"] == "main"
      assert "branch_id" in Checkpoint.record_keys()
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # reason enum — accepted set + unknown-reason READ tolerance (forward-compat)
  # ===========================================================================

  describe "reason enum" do
    test "manual / compaction / auto are all accepted at write", %{base: base} do
      for reason <- ~w(manual compaction auto) do
        {j, _session, dir} = seed_conversation!(base)

        assert {:ok, _off} =
                 Checkpoint.write(j, %{"applied" => []}, reason: reason),
               "reason #{reason} must be accepted"

        cp = CR.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
        assert cp["reason"] == reason
        :ok = FileStore.close(j)
      end
    end

    test "an unknown reason is TOLERATED on READ (forward-compat) — journal healthy, restore works",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)
      {ref, hash} = CR.stage_snapshot!(dir, %{"applied" => [1, 2, 3]})

      # A checkpoint written by a FUTURE producer with a reason this version has
      # never seen. The reader seam tolerates it (never errors, never damages).
      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => CR.tip_of(dir),
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "future_reason_v9"
      })

      log =
        capture_log(fn ->
          assert {:ok, records} = FileStore.read(j)
          cp = Enum.find(records, &(&1["kind"] == "checkpoint"))

          assert cp["reason"] == "future_reason_v9",
                 "unknown reason preserved raw"
        end)

      refute log =~ "corruption"
      assert FileStore.status(j) == :ok

      # Restore must still work off a checkpoint whose reason is unknown.
      assert {:ok, %{"applied" => [1, 2, 3]}} = Checkpoint.restore(j),
             "an unknown reason must not block restore (read-side tolerance)"

      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # Restore-path hardening — adversarial disk must TYPED-REJECT, never raise
  # (adversarial-review findings on U9-I, PR #582)
  # ===========================================================================

  describe "restore-path hardening — a non-map snapshot top-level is corrupt, not a raise" do
    test "a hash-matched snapshot decoding to a LIST → :snapshot_corrupt (no BadMapError), with a non-empty conversational tail",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # A non-empty CONVERSATIONAL tail past the frozen tip (id 3): ids 5,6,7.
      # These are exactly the records restore folds FORWARD onto the snapshot, so
      # the snapshot must be a map or `fold_step`'s `Map.update` raises.
      CR.append_all!(j, [
        CR.loop_event("turn_started"),
        CR.loop_event("item_completed", %{"text" => "more"}),
        CR.loop_event("turn_completed")
      ])

      # An adversarial snapshot whose top-level term is a LIST, not the folded
      # model map — staged with a MATCHING content hash so it clears sha256
      # verification and reaches the decoder.
      {ref, hash} = CR.stage_snapshot!(dir, [1, 2, 3])

      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "manual"
      })

      # BEFORE the fix this reached `fold_step` and raised BadMapError; the
      # contract demands a typed reject with the journal left intact.
      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "a non-map snapshot top-level must surface :snapshot_corrupt, never raise"

      assert FileStore.status(j) == :ok,
             "a corrupt snapshot is not journal damage"

      :ok = FileStore.close(j)
    end

    test "a hash-matched snapshot decoding to a SCALAR → :snapshot_corrupt (no raise)",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      CR.append_all!(j, [
        CR.loop_event("turn_started"),
        CR.loop_event("turn_completed")
      ])

      # Top-level scalar (a bare integer) — same class, different shape.
      {ref, hash} = CR.stage_snapshot!(dir, 42)

      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "manual"
      })

      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "a scalar snapshot top-level must surface :snapshot_corrupt, never raise"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end
  end

  describe "restore-path hardening — a checkpoint record missing keys is malformed, not a raise" do
    test "a checkpoint missing tip_offset → :malformed_checkpoint (no KeyError)",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # A truncated checkpoint the tolerant Reader accepts but restore must not
      # blindly `fetch!` — no `tip_offset`.
      CR.inject_single_counter_checkpoint!(dir, %{
        "snapshot_ref" => nil,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      assert {:error, :malformed_checkpoint} = Checkpoint.restore(j),
             "a checkpoint missing tip_offset must surface a typed reject, never raise"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "a checkpoint missing snapshot_ref → :malformed_checkpoint (no KeyError)",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # No `snapshot_ref` key at all — the tip-only clause head needs it present
      # as nil, and the snapshot clause `fetch!`es it; both would blow up.
      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      assert {:error, :malformed_checkpoint} = Checkpoint.restore(j),
             "a checkpoint missing snapshot_ref must surface a typed reject, never raise"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "a checkpoint missing id → typed error, newest selection never raises",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # Raw-appended (bypassing the Writer's id stamp) so the record carries NO
      # `id`. `newest_checkpoint`'s `max_by(fetch! "id")` would have KeyError'd;
      # in practice the tolerant Reader is STRICTER on `id` than on the pointer
      # fields — a missing offset breaks density, so the read surfaces
      # `{:journal, :damaged}` (nothing deleted) before restore ever selects.
      # Either way the guarantee holds: a TYPED error, never an unhandled raise.
      CR.raw_append!(dir, %{
        "kind" => "checkpoint",
        "schema_version" => "1.0.0",
        "tip_offset" => 3,
        "snapshot_ref" => nil,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      assert {:error, reason} = Checkpoint.restore(j),
             "a checkpoint missing id must surface a typed reject, never raise"

      assert reason in [:malformed_checkpoint, {:journal, :damaged}],
             "unexpected reason: #{inspect(reason)}"

      # Nothing deleted on the damaged read (FI-7).
      assert File.ls!(Path.join(dir, "journal")) != []
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # Surrogate-codec safety — the DEFAULT backend must fail loud, never fake
  # (adversarial-review findings on U9, PR #582 HIGH)
  # ===========================================================================

  describe "surrogate-codec guard — write typed-rejects a model the surrogate cannot round-trip" do
    test "a model carrying a pid and a tuple → :surrogate_backend_unbound; nothing appended, nothing staged",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)
      before_ids = CR.raw_ids(dir)

      # A typical folded harness model: structs/tuples/pids everywhere. BEFORE
      # the fix `dump/1` was `Jason.encode!/1` — an uncaught raise inside
      # `stage_snapshot` crashing the caller.
      model = %{"owner" => self(), "shape" => {:grid, 80, 24}}

      assert {:error, :surrogate_backend_unbound} =
               Checkpoint.write(j, model, reason: "manual"),
             "a non-JSON model must surface a typed error, never a Jason raise"

      assert CR.raw_ids(dir) == before_ids, "nothing may be appended"

      assert File.ls!(Path.join(dir, "snapshots")) == [],
             "nothing may be staged for a rejected model"

      :ok = FileStore.close(j)
    end

    test "an atom-keyed model (decode(encode(m)) ≠ m — a silently mangled restore) → typed reject too",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # Jason ENCODES this fine — but it restores string-keyed, so a surrogate
      # snapshot of it can never restore what was written. Corruption by
      # construction; the guard must reject at write.
      assert {:error, :surrogate_backend_unbound} =
               Checkpoint.write(j, %{applied: [1, 2, 3]}, reason: "manual")

      assert File.ls!(Path.join(dir, "snapshots")) == []
      :ok = FileStore.close(j)
    end
  end

  describe "surrogate-codec loudness — a surrogate restore is distinguishable from a real one" do
    test "write and restore emit the [:raxol,:agent,:journal,:checkpoint,:surrogate] marker; restore logs a warning",
         %{base: base} do
      {j, _session, _dir} = seed_conversation!(base)

      handler = "u9-surrogate-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(
          handler,
          [:raxol, :agent, :journal, :checkpoint, :surrogate],
          fn _event, _meas, meta, _cfg -> send(parent, {:surrogate, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual")

      assert_receive {:surrogate, %{op: :write}},
                     100,
                     "staging a surrogate snapshot must be marked at runtime"

      log =
        capture_log(fn ->
          assert {:ok, %{"applied" => [1, 2, 3]}} = Checkpoint.restore(j)
        end)

      assert_receive {:surrogate, %{op: :restore, tip_offset: 3} = meta},
                     100,
                     "a surrogate restore must be marked at runtime"

      # FI-10: the marker carries offsets/session only — never model content.
      refute Map.has_key?(meta, :model)

      assert log =~ "SURROGATE",
             "a surrogate restore must warn — the model is the surrogate fold, not real state"

      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # Restore-path hardening — nesting bounded BEFORE decode
  # (adversarial-review finding on U9, PR #582 HIGH)
  # ===========================================================================

  describe "restore-path hardening — nesting is bounded BEFORE the parser runs" do
    test "a small ~100k-deep hash-valid snapshot → :snapshot_corrupt, no raise, journal :ok",
         %{base: base} do
      {j, _session, dir} = seed_conversation!(base)

      # ~200 KB of bytes, ~100k levels of nesting: passes the 64 MiB size cap
      # and the sha256 check, and BEFORE the fix reached `Jason.decode/1`,
      # which materializes the entire term before any post-hoc depth walk.
      deep = String.duplicate("[", 100_000) <> "1" <> String.duplicate("]", 100_000)
      bytes = ~s({"applied":) <> deep <> "}"
      hash = CR.sha256_hex(bytes)
      ref = "snapshots/#{hash}.json"
      File.mkdir_p!(Path.join(dir, "snapshots"))
      File.write!(Path.join(dir, ref), bytes)

      CR.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "manual"
      })

      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "adversarial nesting must surface the promised typed reject"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "the pre-decode byte scan: over-bound nesting rejected without building a term; brackets inside JSON strings are content",
         %{base: _base} do
      alias Raxol.Agent.Journal.Records.Checkpoint.FileBackend

      # Over the @max_decode_depth 64 bound (65 arrays inside a map = 66 deep).
      deep = String.duplicate("[", 65) <> "1" <> String.duplicate("]", 65)
      refute FileBackend.nesting_within_bound?(~s({"applied":) <> deep <> "}")

      # A real snapshot shape passes.
      assert FileBackend.nesting_within_bound?(~s({"applied":[1,2,3]}))

      # Brackets INSIDE a JSON string are content, not nesting — the scan must
      # not false-positive a legit snapshot whose text contains brackets.
      brackets = String.duplicate("[", 500)
      assert FileBackend.nesting_within_bound?(~s({"a":") <> brackets <> ~s("}))

      # ... including behind an escaped quote.
      assert FileBackend.nesting_within_bound?(~s({"a":"x\\"[[[[["}))
    end
  end

  # ===========================================================================
  # protected_floor/1 — fail-closed on malformed checkpoint records
  # (adversarial-review finding on U9, PR #582 MEDIUM)
  # ===========================================================================

  describe "protected_floor/1 fail-closed — malformed checkpoints protect everything, never raise" do
    test "a checkpoint record missing id → {:offset, 1} (whole journal protected), no KeyError" do
      records = [
        %{"id" => 1, "family" => "loop", "type" => "turn_started"},
        %{"kind" => "checkpoint", "tip_offset" => 3}
      ]

      # BEFORE the fix: Enum.max_by(&Map.fetch!(&1, "id")) → KeyError, crashing
      # the GC admission check that exists to prevent orphaning.
      assert Checkpoint.protected_floor(records) == {:offset, 1}
    end

    test "a checkpoint record missing tip_offset → {:offset, 1}, no KeyError" do
      records = [%{"id" => 5, "kind" => "checkpoint"}]
      assert Checkpoint.protected_floor(records) == {:offset, 1}
    end

    test "a checkpoint with non-integer id/tip_offset junk → {:offset, 1}" do
      assert Checkpoint.protected_floor([
               %{"id" => 5, "kind" => "checkpoint", "tip_offset" => "3"}
             ]) == {:offset, 1}

      assert Checkpoint.protected_floor([
               %{"id" => "5", "kind" => "checkpoint", "tip_offset" => 3}
             ]) == {:offset, 1}
    end

    test "healthy checkpoints → the NEWEST checkpoint's tip; none → :none" do
      cps = [
        %{"id" => 5, "kind" => "checkpoint", "tip_offset" => 3},
        %{"id" => 9, "kind" => "checkpoint", "tip_offset" => 7}
      ]

      assert Checkpoint.protected_floor(cps) == {:offset, 7}
      assert Checkpoint.protected_floor([]) == :none
    end
  end

  # ===========================================================================
  # N-JS2 at the COMMIT POINT — atomic check-and-append inside the Writer
  # (adversarial-review finding on U9, PR #582 MEDIUM: the read-then-append
  # window could let a concurrent turn_started slip a checkpoint mid-turn)
  # ===========================================================================

  describe "N-JS2 at the commit point — check-and-append is one atomic Writer step" do
    test "append_checked validates against the FRESHEST records; a failing check appends nothing",
         %{base: base} do
      {j, _session, dir} = CR.open!(base)
      CR.append_all!(j, [CR.loop_event("turn_started")])
      before_ids = CR.raw_ids(dir)

      check = fn records ->
        if CR.at_turn_boundary?(records), do: :ok, else: {:error, :mid_turn}
      end

      cp = %{"kind" => "checkpoint", "tip_offset" => 1, "reason" => "manual"}

      assert {:error, :mid_turn} = FileStore.append_checked(j, cp, check)
      assert CR.raw_ids(dir) == before_ids, "a rejected checked append appends nothing"

      # Close the turn → the same append is admitted, dense offset consumed.
      CR.append_all!(j, [CR.loop_event("turn_completed")])
      assert {:ok, off} = FileStore.append_checked(j, cp, check)
      assert off == List.last(CR.raw_ids(dir))
      assert CR.dense_ids?(dir)
      :ok = FileStore.close(j)
    end

    test "a raising check fails CLOSED and the Writer survives", %{base: base} do
      {j, _session, _dir} = CR.open!(base)

      assert {:error, {:check_raised, _}} =
               FileStore.append_checked(j, %{"kind" => "checkpoint"}, fn _ ->
                 raise "boom"
               end)

      # The Writer must not have crashed out from under the session.
      assert {:ok, _} = FileStore.append(j, CR.loop_event("turn_started"))
      :ok = FileStore.close(j)
    end

    test "concurrent turn traffic through a shared joiner handle: no checkpoint ever lands mid-turn",
         %{base: base} do
      {j, session, dir} = seed_conversation!(base)

      # A JOINER handle sharing the single Writer (file_store.ex — the exact
      # concurrency topology of the review finding).
      {:ok, j2} = FileStore.open(session, base_dir: base)

      turns =
        Task.async(fn ->
          for _ <- 1..40 do
            {:ok, _} = FileStore.append(j2, CR.loop_event("turn_started"))
            {:ok, _} = FileStore.append(j2, CR.loop_event("turn_completed"))
          end

          :ok
        end)

      # Interleaved checkpoint writes: each either lands at a boundary or
      # typed-rejects (:mid_turn) — never lands mid-turn.
      for _ <- 1..40 do
        case Checkpoint.write(j, %{"applied" => []}, reason: "auto") do
          {:ok, _} -> :ok
          {:error, :mid_turn} -> :ok
          other -> flunk("unexpected write result: #{inspect(other)}")
        end
      end

      assert :ok = Task.await(turns)

      # After the dust settles a write at the boundary must still land.
      assert {:ok, _} = Checkpoint.write(j, %{"applied" => []}, reason: "manual")

      # The raw-journal invariant: for EVERY checkpoint record, the records
      # before it sit at a turn boundary (open-turn balance zero).
      records = CR.raw_records(dir)

      records
      |> Enum.with_index()
      |> Enum.each(fn {r, i} ->
        if r["kind"] == "checkpoint" do
          prefix = Enum.take(records, i)

          assert CR.at_turn_boundary?(prefix),
                 "checkpoint at offset #{r["id"]} landed mid-turn"
        end
      end)

      assert CR.dense_ids?(dir)
      :ok = FileStore.close(j2)
      :ok = FileStore.close(j)
    end
  end
end
