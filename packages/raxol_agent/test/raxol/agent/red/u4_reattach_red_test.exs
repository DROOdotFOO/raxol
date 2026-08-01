Code.require_file("support/u4_red_support.ex", __DIR__)

defmodule Raxol.Agent.Red.U4ReattachRedTest do
  @moduledoc """
  U4-R — the PERMANENT FAILING-FIRST red suite for U4 "Reattach/replay"
  (AD-15 / FI-12), authored against the ratified JS-FREEZE contract
  (`docs/proposals/in-flight/harness-freeze-contracts.md` §1) BEFORE any
  implementation exists.

  Every test here is `@moduletag :harness_red`, excluded in `test_helper.exs`,
  and FAILS today by design: `Raxol.Agent.Reattach.attach/3` is a skeleton
  returning `{:error, :not_implemented}`. When U4 lands, the tag is removed
  and these become the unit's acceptance suite — the assertions are the full
  contract, not placeholders. Run them with:

      MIX_ENV=test mix test test/raxol/agent/red/u4_reattach_red_test.exs --include harness_red

  ## The frozen surface these reds drive

    * `Reattach.attach(session_id, from_offset, history_policy)` →
      `{:ok, %{history: [record], from_offset: n, live: _}}`.
    * **Live delivery shape assumed by this suite:** after a successful attach,
      every durable record with `id >= from_offset` — the catch-up tail that
      already exists plus everything appended later — is delivered to the
      attaching process as `{:reattach_live, session_id, record}` messages, in
      offset order. (Frozen here so the implementation is built against the
      red, not the red re-fitted to the implementation.)
    * History policies: `{:from_offset, n}` = records `n..from_offset-1`;
      `:tip` = the single conversational-tip record (frozen predicate,
      `Raxol.Agent.Journal.Tip`); `:none` = no history.
    * **Session resolution:** `attach/3` has no base-dir parameter — the
      implementation resolves `session_id` on its read path where
      `FileStore.open/2` resolves it by default (the ambient sessions base).
      This suite seeds every journal there; the base is pinned once for the
      whole run in `test_helper.exs` and never mutated per-test, so the
      module is `async: true`-safe with no global-env writes.

  ## Contours (freeze §1.2/§1.3)

    * **P-JS5 replay closure** — ∀ split offset o over generated journals
      driven through the REAL FileStore: `read(0..o−1) ++ attach_live(o..)`
      equals the full durable record stream as a SEQUENCE (not a multiset), no
      duplicate delivered as live, no gap. The emit-ahead-of-journal injector
      (N-JS7, invariant I3's publish-ahead window) is the dead injector — its
      negative control runs in CI (see `U4ReattachGuardsTest`).
    * **Writerless reattach** — reattach is a READ-SIDE operation: it must
      succeed against a session whose Writer is gone (dead BEAM / replay-only)
      and must write NOTHING (§1.1: no attach record kind; the meta attach
      audit event is best-effort under a live Writer only, and nothing may
      depend on it).
    * **Self-containment** — a `tar`'d + untar'd session directory reattaches
      identically (§0 clause 5: the session directory is the unit of
      portability).
    * **Dormammu (P-JS3, FI-12)** — a journal ending in checkpoint / meta /
      idle / woken records resumes at the last CONVERSATIONAL loop event,
      never the tail. The generator is REQUIRED to end every journal with ≥1
      non-conversational record (meta-invariant 5 — vacuous otherwise).
    * **History-policy slices** — each policy delivers exactly its specified
      slice.

  Failures dump the generated journal spec; property runs are reproduced by
  the printed ExUnit/StreamData seed (meta-invariant m2).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Tip
  alias Raxol.Agent.Reattach
  alias Raxol.Agent.Red.U4Support

  @moduletag :harness_red
  @moduletag :capture_log

  setup do
    # Per-test scratch space for NON-session artifacts (the tar file). Session
    # journals do NOT live here — see sessions_base/0 / open_session!/0.
    scratch =
      Path.join(
        System.tmp_dir!(),
        "raxol_red_u4_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf(scratch) end)
    {:ok, scratch: scratch}
  end

  describe "P-JS5 — replay closure (the U4 law)" do
    property "∀ split offset o: read(0..o−1) ++ attach_live(o..) == full durable record stream, as a sequence" do
      check all(
              pre_types <-
                list_of(member_of(U4Support.conversational_types()),
                  min_length: 2,
                  max_length: 8
                ),
              post_types <-
                list_of(member_of(U4Support.conversational_types()),
                  min_length: 1,
                  max_length: 4
                ),
              split_pick <- integer(0..1_000),
              max_runs: 8
            ) do
        n_pre = length(pre_types)
        o = rem(split_pick, n_pre + 1) + 1
        spec = %{pre: pre_types, post: post_types, split: o}

        {j, session, dir} = open_session!()

        # Close in `after` so a failing/shrinking property run never leaks the
        # Writer — assertions here MUST run while the journal is still open
        # (live records are appended after the attach), so close-before-assert
        # is not an option in this red.
        try do
          pre_records =
            pre_types
            |> Enum.with_index(1)
            |> Enum.map(fn {t, i} -> U4Support.conv_event(t, marker: "pre-#{i}") end)

          U4Support.append_all!(j, pre_records)

          result = Reattach.attach(session, o, {:from_offset, 1})

          assert match?({:ok, _}, result),
                 "U4-R RED (P-JS5 replay closure): attach(#{inspect(session)}, #{o}, " <>
                   "{:from_offset, 1}) must replay history 1..#{o - 1} and follow live " <>
                   "from #{o} — got #{inspect(result)}. journal spec: #{inspect(spec)}"

          {:ok, %{history: history}} = result

          post_records =
            post_types
            |> Enum.with_index(1)
            |> Enum.map(fn {t, i} -> U4Support.conv_event(t, marker: "post-#{i}") end)

          U4Support.append_all!(j, post_records)

          # Live = catch-up (pre records with id >= o) + everything appended after
          # the attach, delivered as {:reattach_live, session, record} in order.
          expected_live = n_pre - o + 1 + length(post_records)
          live = collect_live(session, expected_live)

          full = FaultJournal.raw_records!(dir)

          assert U4Support.closure_check(history, live, full, o) == :ok,
                 "closure violated at split #{o}: #{inspect(U4Support.closure_check(history, live, full, o))} " <>
                   "(spec: #{inspect(spec)})"
        after
          FileStore.close(j)
        end
      end
    end
  end

  describe "writerless reattach (read-side only, §1.1)" do
    test "reattaches against a dead-Writer session, serves full history, and writes nothing" do
      {j, session, dir} = open_session!()

      records =
        for i <- 1..5, do: U4Support.conv_event("item_completed", marker: "wl-#{i}")

      U4Support.append_all!(j, records)
      :ok = FileStore.close(j)

      # The session is now WRITERLESS — a dead BEAM / replay-only mount. No
      # attach marker exists and none may be required or written.
      bytes_before = journal_bytes(dir)

      result = Reattach.attach(session, 6, {:from_offset, 1})

      assert match?({:ok, %{history: _}}, result),
             "U4-R RED (writerless): reattach MUST work read-side against a " <>
               "closed-Writer session (dead BEAM / tar'd dir) — got #{inspect(result)}"

      {:ok, %{history: history}} = result
      assert Enum.map(history, & &1["id"]) == [1, 2, 3, 4, 5]

      assert journal_bytes(dir) == bytes_before,
             "reattach wrote to a writerless session — reattach is read-side ONLY; " <>
               "the attach audit meta event is best-effort under a live Writer and " <>
               "never a requirement (§1.1)"
    end

    test "a tar'd + untar'd session directory reattaches identically (self-containment, §0.5)",
         %{scratch: scratch} do
      {j, session, dir} = open_session!()

      records =
        for i <- 1..4, do: U4Support.conv_event("item_completed", marker: "tar-#{i}")

      U4Support.append_all!(j, records)
      :ok = FileStore.close(j)

      original = FaultJournal.raw_records!(dir)

      # tar the session dir, DESTROY the original, and restore it purely from
      # the archive — the directory that reattaches below is entirely the
      # untarred artifact (§0 clause 5: the session directory is the unit of
      # portability; every reference a record carries resolves inside it, so
      # the archive alone must be sufficient). No global state is touched:
      # the restored dir lands back under the run-wide ambient sessions base
      # (see sessions_base/0), where the frozen attach/3 resolves session ids.
      tar = Path.join(scratch, "session.tar")

      :ok =
        :erl_tar.create(String.to_charlist(tar), [
          {String.to_charlist(session), String.to_charlist(dir)}
        ])

      File.rm_rf!(dir)

      :ok =
        :erl_tar.extract(
          String.to_charlist(tar),
          [{:cwd, String.to_charlist(Path.dirname(dir))}]
        )

      assert FaultJournal.raw_records!(dir) == original,
             "tar round-trip changed the journal bytes"

      # What is frozen HERE: reattach against a directory restored purely from
      # the tar archive succeeds and serves the identical history.
      result = Reattach.attach(session, 5, {:from_offset, 1})

      assert match?({:ok, %{history: _}}, result),
             "U4-R RED (self-containment): reattach against a tar'd+untar'd session " <>
               "dir must succeed — got #{inspect(result)}"

      {:ok, %{history: history}} = result
      assert Enum.map(history, & &1["id"]) == [1, 2, 3, 4]
    end
  end

  describe "Dormammu (P-JS3, FI-12) — resume never lands on a non-conversational tail" do
    property "attach(:tip) on a journal ending in checkpoint/meta/idle/woken resumes at the last CONVERSATIONAL loop event" do
      check all(
              conv_types <-
                list_of(member_of(U4Support.conversational_types()),
                  min_length: 1,
                  max_length: 5
                ),
              tail_picks <- list_of(integer(0..5), min_length: 1, max_length: 4),
              max_runs: 8
            ) do
        {j, session, dir} = open_session!()

        conv_records =
          conv_types
          |> Enum.with_index(1)
          |> Enum.map(fn {t, i} -> U4Support.conv_event(t, marker: "dor-#{i}") end)

        conv_offsets = U4Support.append_all!(j, conv_records)
        expected_tip = List.last(conv_offsets)

        pool = U4Support.dormammu_tail_pool(expected_tip)
        tail = Enum.map(tail_picks, &Enum.at(pool, &1))
        U4Support.append_all!(j, tail)
        :ok = FileStore.close(j)

        # Required generator shape (meta-inv 5): every tip-test journal ends in
        # >= 1 NON-conversational record, or Dormammu is vacuous.
        last = List.last(FaultJournal.raw_records!(dir))

        refute U4Support.raw_conversational?(last),
               "generator violation: Dormammu journal must END non-conversational"

        spec = %{convs: conv_types, tail_picks: tail_picks, expected_tip: expected_tip}
        result = Reattach.attach(session, expected_tip + 1, :tip)

        assert match?({:ok, _}, result),
               "U4-R RED (Dormammu P-JS3): attach(:tip) must resume at the last " <>
                 "CONVERSATIONAL loop event (offset #{expected_tip}), never the " <>
                 "checkpoint/meta/idle/woken tail — got #{inspect(result)}. " <>
                 "spec: #{inspect(spec)}"

        {:ok, %{history: history}} = result

        assert Enum.map(history, & &1["id"]) == [expected_tip],
               "tip history must be exactly the conversational tip record (spec: #{inspect(spec)})"

        assert Tip.conversational?(hd(history)),
               "Dormammu violated: resume landed on a non-conversational record " <>
                 "(spec: #{inspect(spec)})"
      end
    end
  end

  describe "history-policy slices (attach{offset, historyPolicy}, AD-15)" do
    test "{:from_offset, n} delivers exactly records n..from_offset−1" do
      {j, session, _dir} = open_session!()

      records =
        for i <- 1..6, do: U4Support.conv_event("item_completed", marker: "hp-#{i}")

      U4Support.append_all!(j, records)
      :ok = FileStore.close(j)

      result = Reattach.attach(session, 5, {:from_offset, 2})

      assert match?({:ok, _}, result),
             "U4-R RED (history policy {:from_offset, 2}): got #{inspect(result)}"

      {:ok, %{history: history}} = result

      assert Enum.map(history, & &1["id"]) == [2, 3, 4],
             "{:from_offset, 2} at attach offset 5 must deliver exactly ids 2..4"
    end

    test ":tip delivers exactly the conversational-tip record" do
      {j, session, dir} = open_session!()

      U4Support.append_all!(j, [
        U4Support.conv_event("turn_started", marker: "t1"),
        U4Support.conv_event("turn_completed", marker: "t2"),
        U4Support.meta_event("attach"),
        U4Support.excluded_loop_event("idle")
      ])

      :ok = FileStore.close(j)

      # Frozen predicate names the expected slice; the raw oracle agrees.
      assert {:tip, 2} = U4Support.raw_tip(FaultJournal.raw_records!(dir))

      result = Reattach.attach(session, 5, :tip)

      assert match?({:ok, _}, result),
             "U4-R RED (history policy :tip): got #{inspect(result)}"

      {:ok, %{history: history}} = result
      assert Enum.map(history, & &1["id"]) == [2]
    end

    test ":none delivers no history — live tail only" do
      {j, session, _dir} = open_session!()

      try do
        U4Support.append_all!(j, [
          U4Support.conv_event("turn_started", marker: "n1"),
          U4Support.conv_event("turn_completed", marker: "n2")
        ])

        result = Reattach.attach(session, 3, :none)

        assert match?({:ok, _}, result),
               "U4-R RED (history policy :none): got #{inspect(result)}"

        {:ok, %{history: history}} = result
        assert history == [], ":none must deliver an empty history"

        # Only records from the attach offset onward may arrive, and only as live.
        {:ok, 3} = FileStore.append(j, U4Support.conv_event("error", marker: "n3"))
        live = collect_live(session, 1)
        assert Enum.map(live, & &1["id"]) == [3]
      after
        FileStore.close(j)
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  # The frozen attach/3 (session_id, from_offset, policy) carries no base-dir
  # parameter: an implementation resolves `session_id` on its READ path exactly
  # where `FileStore.open/2` resolves it by default — the ambient sessions
  # base. The suite therefore seeds every journal under $RAXOL_SESSIONS_DIR,
  # which test_helper.exs pins ONCE for the whole run (before any test starts)
  # and which no test may mutate: per-test isolation comes from unique session
  # ids, keeping this module safe under `async: true` with ZERO global-env
  # writes (a System.put_env here would bleed into every concurrently-running
  # module — exactly the nondeterminism this suite exists to forbid).
  defp sessions_base, do: System.fetch_env!("RAXOL_SESSIONS_DIR")

  defp open_session! do
    {j, session, dir} = U4Support.open!(sessions_base())
    on_exit(fn -> File.rm_rf(dir) end)
    {j, session, dir}
  end

  @live_timeout_ms 1_000

  # Live-tail collector: exactly `expected` messages or an HONEST failure.
  # Never returns a partial list — a slow-but-correct delivery must fail as
  # "timed out waiting for live message i/N", not leak downstream and surface
  # as a spurious {:sequence_mismatch, ...} closure violation.
  defp collect_live(session, expected) do
    for i <- 1..expected//1 do
      receive do
        {:reattach_live, ^session, record} -> record
      after
        @live_timeout_ms ->
          flunk(
            "timed out (#{@live_timeout_ms}ms) waiting for live message " <>
              "#{i}/#{expected} ({:reattach_live, #{inspect(session)}, _}) — " <>
              "live delivery incomplete; this is a delivery timeout, NOT a " <>
              "P-JS5 closure violation"
          )
      end
    end
  end

  defp journal_bytes(dir) do
    for path <- FaultJournal.segment_paths(dir), into: %{} do
      {Path.basename(path), File.read!(path)}
    end
  end
end

defmodule Raxol.Agent.Red.U4ReattachGuardsTest do
  @moduledoc """
  U4-R guards — the parts of the U4 contour that run GREEN in CI today:

    1. **Frozen-predicate properties** against the enabler
       `Raxol.Agent.Journal.Tip` (the contract-specified pure function frozen
       by harness-freeze-contracts.md §1.1 "The conversational tip"):
       P-JS2 dual-oracle tip determinism, P-JS3 Dormammu at the predicate
       layer, P-JS8 branch-aware tip + closure-rule corollary, P-JS6
       unknown-kind tolerance, P-JS7 grandfather corpus.
    2. **Dead-injector negative controls** (meta-invariant m4, run in CI):
       each deliberately-broken variant from the freeze's §1.3 table is fired
       against a real journal and shown to DIVERGE from the frozen behavior —
       proving the red suite's detectors are alive, not vacuously green. Every
       injector carries a fired-counter (m1); an armed-but-silent site fails
       the test.

  These are permanent guards: they hold the tip predicate, the reader
  tolerance, and the closure detectors in place while U4 is implemented
  against the red module above.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Tip
  alias Raxol.Agent.Reattach
  alias Raxol.Agent.Red.U4Support

  @moduletag :capture_log

  @golden Path.expand("../../../invariants/fixtures/golden/v1.0.0/golden-v1", __DIR__)

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_red_u4_guards_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  # Mixed-shape record pool: conversational (main / branch-x / grandfathered),
  # meta, Dormammu loop exclusions, checkpoint, unknown future kind.
  defp build_record(:conv_main, i), do: U4Support.conv_event(conv_type(i), marker: "m-#{i}")

  defp build_record(:conv_x, i),
    do: U4Support.conv_event(conv_type(i), branch: "x", marker: "x-#{i}")

  defp build_record(:conv_gf, i),
    do: U4Support.conv_event(conv_type(i), grandfathered: true, marker: "gf-#{i}")

  defp build_record(:meta, _i), do: U4Support.meta_event("attach")
  defp build_record(:idle, _i), do: U4Support.excluded_loop_event("idle")
  defp build_record(:woken, _i), do: U4Support.excluded_loop_event("woken")
  defp build_record(:state_change, _i), do: U4Support.excluded_loop_event("state_change")
  defp build_record(:checkpoint, _i), do: U4Support.checkpoint_record(1)
  defp build_record(:unknown, _i), do: U4Support.unknown_kind_record()

  defp conv_type(i),
    do: Enum.at(U4Support.conversational_types(), rem(i, 7))

  @shapes [
    :conv_main,
    :conv_x,
    :conv_gf,
    :meta,
    :idle,
    :woken,
    :state_change,
    :checkpoint,
    :unknown
  ]

  describe "P-JS2 / P-JS8 — dual-oracle tip determinism, branch-aware" do
    property "raw-file decoder and Reader-path Tip select the same tip (or both :no_tip) on every branch",
             %{base: base} do
      check all(
              shapes <- list_of(member_of(@shapes), min_length: 1, max_length: 12),
              max_runs: 15
            ) do
        {j, _session, dir} = U4Support.open!(base)

        records = shapes |> Enum.with_index(1) |> Enum.map(fn {s, i} -> build_record(s, i) end)
        U4Support.append_all!(j, records)
        :ok = FileStore.close(j)

        # Oracle A: the tolerant Reader path feeding the frozen Tip module.
        {:ok, reader_records} = read_only(dir)
        # Oracle B: raw File.read! + the support module's OWN decoder + OWN
        # backward-scan predicate (m6 — never consults Tip).
        raw_records = FaultJournal.raw_records!(dir)

        for branch <- ["main", "x"] do
          a = Tip.tip(reader_records, branch)
          b = U4Support.raw_tip(raw_records, branch)

          assert a == b,
                 "P-JS2/P-JS8 dual-oracle divergence on branch #{inspect(branch)}: " <>
                   "Tip=#{inspect(a)} raw=#{inspect(b)} (shapes: #{inspect(shapes)})"

          # Closure-rule corollary: a selected tip is conversational and on-branch.
          case a do
            :no_tip ->
              :ok

            {:tip, offset} ->
              record = Enum.find(raw_records, &(&1["id"] == offset))
              assert Tip.conversational?(record)
              assert Map.get(record, "branch_id", "main") == branch
          end
        end

        # tip/1 == tip(_, "main") — the grandfather-safe default.
        assert Tip.tip(reader_records) == Tip.tip(reader_records, "main")
      end
    end
  end

  describe "P-JS3 — Dormammu at the predicate layer (FI-12)" do
    property "a journal ENDING in >= 1 non-conversational record tips at the last conversational loop event",
             %{base: base} do
      check all(
              conv_types <-
                list_of(member_of(U4Support.conversational_types()),
                  min_length: 1,
                  max_length: 5
                ),
              tail_picks <- list_of(integer(0..5), min_length: 1, max_length: 4),
              max_runs: 15
            ) do
        {j, _session, dir} = U4Support.open!(base)

        conv_records =
          conv_types
          |> Enum.with_index(1)
          |> Enum.map(fn {t, i} -> U4Support.conv_event(t, marker: "g3-#{i}") end)

        conv_offsets = U4Support.append_all!(j, conv_records)
        expected_tip = List.last(conv_offsets)

        pool = U4Support.dormammu_tail_pool(expected_tip)
        U4Support.append_all!(j, Enum.map(tail_picks, &Enum.at(pool, &1)))
        :ok = FileStore.close(j)

        raw_records = FaultJournal.raw_records!(dir)

        # Required generator shape (meta-inv 5) — end non-conversational or vacuous.
        refute U4Support.raw_conversational?(List.last(raw_records)),
               "generator violation: Dormammu journal must END non-conversational"

        {:ok, reader_records} = read_only(dir)

        assert Tip.tip(reader_records) == {:tip, expected_tip},
               "Dormammu (P-JS3): tip must be the last CONVERSATIONAL loop event " <>
                 "#{expected_tip}, never the checkpoint/meta/idle/woken tail " <>
                 "(convs: #{inspect(conv_types)}, tail: #{inspect(tail_picks)})"

        assert U4Support.raw_tip(raw_records) == {:tip, expected_tip}
      end
    end

    test "an all-non-conversational journal has no tip", %{base: base} do
      {j, _session, dir} = U4Support.open!(base)

      U4Support.append_all!(j, [
        U4Support.meta_event("attach"),
        U4Support.excluded_loop_event("woken"),
        U4Support.checkpoint_record(1)
      ])

      :ok = FileStore.close(j)

      {:ok, reader_records} = read_only(dir)
      assert Tip.tip(reader_records) == :no_tip
      assert U4Support.raw_tip(FaultJournal.raw_records!(dir)) == :no_tip
    end
  end

  describe "P-JS6 — unknown-kind tolerance" do
    test "a future-kind record replays {:ok, _}, keeps offsets dense, and never moves the tip",
         %{base: base} do
      # Journal A: convs with an unknown kind interleaved AND trailing.
      {ja, _sa, dir_a} = U4Support.open!(base)

      U4Support.append_all!(ja, [
        U4Support.conv_event("turn_started", marker: "u-1"),
        U4Support.unknown_kind_record("annotation"),
        U4Support.conv_event("turn_completed", marker: "u-2"),
        U4Support.unknown_kind_record("future_kind_v9")
      ])

      :ok = FileStore.close(ja)

      # Journal B: the same journal minus the unknown-kind records.
      {jb, _sb, dir_b} = U4Support.open!(base)

      U4Support.append_all!(jb, [
        U4Support.conv_event("turn_started", marker: "u-1"),
        U4Support.conv_event("turn_completed", marker: "u-2")
      ])

      :ok = FileStore.close(jb)

      # Replay {:ok, _}: never {:error, :damaged}, never dropped.
      assert {:ok, records_a} = read_only(dir_a)

      assert Enum.map(records_a, & &1["id"]) == [1, 2, 3, 4],
             "unknown kinds participate in offset continuity (§1.1 reader tolerance)"

      # The tip skips unknown kinds and lands on the same underlying event as
      # the journal without them (compared by payload marker — offsets differ
      # by construction).
      {:ok, records_b} = read_only(dir_b)
      assert {:tip, tip_a} = Tip.tip(records_a)
      assert {:tip, tip_b} = Tip.tip(records_b)

      marker = fn records, offset ->
        records |> Enum.find(&(&1["id"] == offset)) |> get_in(["payload", "marker"])
      end

      assert marker.(records_a, tip_a) == marker.(records_b, tip_b),
             "an unknown-kind record moved the tip"

      assert marker.(records_a, tip_a) == "u-2"
    end
  end

  describe "P-JS7 — grandfather corpus (kind-less golden journal)" do
    test "the pre-freeze golden journal reads identically: absent kind ⇒ event, absent branch_id ⇒ main, tip preserved",
         %{base: base} do
      File.cp_r!(@golden, Path.join(base, "golden-v1"))

      {:ok, j} = FileStore.open("golden-v1", base_dir: base)
      assert {:ok, records} = FileStore.read(j)
      assert length(records) == 8

      # The corpus IS pre-freeze: no record carries "kind" or "branch_id".
      refute Enum.any?(records, &Map.has_key?(&1, "kind"))
      refute Enum.any?(records, &Map.has_key?(&1, "branch_id"))

      # Grandfather clause: every record reads kind="event"/branch="main"; the
      # tip is the final error event (id 8, conversational) on both oracles.
      assert Enum.all?(records, &Tip.conversational?/1) ==
               Enum.all?(records, &U4Support.raw_conversational?/1)

      assert Tip.tip(records) == {:tip, 8}
      assert Tip.tip(records, "main") == {:tip, 8}

      dir = Path.join(base, "golden-v1")
      assert U4Support.raw_tip(FaultJournal.raw_records!(dir)) == {:tip, 8}

      # No other branch exists in a grandfathered journal.
      assert Tip.tip(records, "x") == :no_tip

      :ok = FileStore.close(j)
    end
  end

  describe "frozen facade — session_id hygiene (§0.7 admission decision, runs in CI)" do
    # Reattach resolves `session_id` into a filesystem path on its read path,
    # so traversal names must die at the frozen facade — BEFORE any impl — or
    # the frozen shape bakes in path-traversal exposure for the eventual U4
    # implementation. Mirrors FileStore's write-side session-id rule.
    test "attach/3 rejects traversal/separator/empty session ids before any impl dispatch" do
      for evil <- [
            "../../other-tenant/session",
            "..",
            ".",
            "nested/session",
            "back\\slash",
            "",
            <<"nul", 0, "byte">>
          ] do
        assert Reattach.attach(evil, 0, :none) == {:error, :invalid_session_id},
               "the frozen facade must reject #{inspect(evil)} as :invalid_session_id"
      end
    end

    test "a well-formed session id is never rejected by the facade" do
      refute Reattach.attach("red-u4-wellformed_1.0", 0, :none) ==
               {:error, :invalid_session_id}
    end
  end

  describe "dead injectors (m4 negative controls — each must break its red)" do
    test "N-JS7 emit-ahead-of-journal: the live id surfaces before the record is readable (I3 window)",
         %{base: base} do
      harness = U4Support.new()
      U4Support.arm(harness, :emit_ahead)

      {j, session, dir} = U4Support.open!(base)
      {:ok, 1} = FileStore.append(j, U4Support.conv_event("turn_started", marker: "ea-1"))

      # The BUGGY ordering: publish, THEN append. The probe models the late
      # subscriber raw-reading at delivery time — inside the window the id must
      # NOT be durable yet, which is exactly what the P-JS5 closure red / I3
      # catches (an attach_live id absent from read(0..o−1) ++ durable stream).
      {predicted, violation_in_window} =
        U4Support.emit_ahead_publish!(
          harness,
          j,
          dir,
          session,
          self(),
          U4Support.conv_event("item_completed", marker: "ea-2"),
          fn live_id -> U4Support.publish_ahead_violation?(dir, live_id) end
        )

      assert_receive {:reattach_live, ^session, %{"id" => ^predicted}}

      assert violation_in_window,
             "emit-ahead injector is DEAD: the published live id was already durable — " <>
               "the closure red could never catch this variant"

      # Control discrimination: the CORRECT order (append then publish — the
      # real EmitBridge) shows no violation at delivery time.
      {:ok, offset} = FileStore.append(j, U4Support.conv_event("error", marker: "ea-3"))
      refute U4Support.publish_ahead_violation?(dir, offset)

      U4Support.assert_all_fired!(harness, :emit_ahead_control)
      FileStore.close(j)
    end

    test "N-JS5 tip predicate collapsed to kind==\"event\" fails Dormammu", %{base: base} do
      harness = U4Support.new()
      U4Support.arm(harness, :tip_kind_only)

      {j, _session, dir} = U4Support.open!(base)

      U4Support.append_all!(j, [
        U4Support.conv_event("turn_started", marker: "ko-1"),
        U4Support.conv_event("turn_completed", marker: "ko-2"),
        # Dormammu tail whose LAST record is kind "event" but family "meta" —
        # exactly what the family/type clauses exist to exclude.
        U4Support.excluded_loop_event("woken"),
        U4Support.meta_event("attach")
      ])

      :ok = FileStore.close(j)
      records = FaultJournal.raw_records!(dir)

      frozen = Tip.tip(records)
      mutated = U4Support.kind_only_tip(harness, records)

      assert frozen == {:tip, 2}

      assert mutated == {:tip, 4},
             "kind-only injector is DEAD: it agreed with the frozen predicate on a " <>
               "Dormammu journal — the Dormammu red could never catch this variant"

      {:tip, mutated_offset} = mutated
      mutated_record = Enum.find(records, &(&1["id"] == mutated_offset))

      refute Tip.conversational?(mutated_record),
             "the mutated predicate selected a record the frozen predicate accepts — no divergence"

      U4Support.assert_all_fired!(harness, :tip_kind_only_control)
    end

    test "N-JS8 branch-blind tip scan selects another branch's record as the main tip",
         %{base: base} do
      harness = U4Support.new()
      U4Support.arm(harness, :branch_blind)

      {j, _session, dir} = U4Support.open!(base)

      U4Support.append_all!(j, [
        U4Support.conv_event("turn_started", marker: "bb-1"),
        U4Support.conv_event("turn_completed", marker: "bb-2"),
        # A HIGHER-offset conversational record on branch "x".
        U4Support.conv_event("item_completed", branch: "x", marker: "bb-x")
      ])

      :ok = FileStore.close(j)
      records = FaultJournal.raw_records!(dir)

      assert Tip.tip(records, "main") == {:tip, 2}
      assert Tip.tip(records, "x") == {:tip, 3}

      blind = U4Support.branch_blind_tip(harness, records)

      assert blind == {:tip, 3},
             "branch-blind injector is DEAD: it agreed with the frozen branch-aware " <>
               "tip — the branch red could never catch this variant"

      {:tip, blind_offset} = blind
      blind_record = Enum.find(records, &(&1["id"] == blind_offset))
      assert Map.get(blind_record, "branch_id") == "x"

      U4Support.assert_all_fired!(harness, :branch_blind_control)
    end

    test "N-JS4 a reader that damages-on-unknown-kind fails the tolerance red", %{base: base} do
      harness = U4Support.new()
      U4Support.arm(harness, :strict_reader)

      {j, _session, dir} = U4Support.open!(base)

      U4Support.append_all!(j, [
        U4Support.conv_event("turn_started", marker: "sr-1"),
        U4Support.unknown_kind_record("future_kind_v9"),
        U4Support.conv_event("turn_completed", marker: "sr-2")
      ])

      :ok = FileStore.close(j)

      # The REAL reader is tolerant: {:ok, _}, all records preserved.
      assert {:ok, records} = read_only(dir)
      assert length(records) == 3

      # The injected strict reader marks the same journal damaged — the
      # tolerance red's `assert {:ok, _}` catches it.
      assert {:damaged, {:unknown_kind, "future_kind_v9", 2}} =
               U4Support.strict_reader_scan(harness, dir)

      U4Support.assert_all_fired!(harness, :strict_reader_control)
    end

    test "a reattach that depends on an attach marker record fails the writerless red",
         %{base: base} do
      harness = U4Support.new()
      U4Support.arm(harness, :marker_dependent)

      # Writerless session — no live Writer ever wrote a best-effort attach
      # audit event, which is the ONLY legal way one appears (§1.1).
      {j, _session, dir} = U4Support.open!(base)

      U4Support.append_all!(j, [
        U4Support.conv_event("turn_started", marker: "md-1"),
        U4Support.conv_event("turn_completed", marker: "md-2")
      ])

      :ok = FileStore.close(j)

      marker_result = U4Support.marker_dependent_attach(harness, dir, 3)

      assert marker_result == {:error, :no_attach_marker},
             "marker-dependent injector is DEAD: it served history without a marker " <>
               "(got #{inspect(marker_result)}) — the writerless red could never " <>
               "catch this variant"

      # Discrimination: with a journaled marker it "works" — proving the
      # variant's failure is exactly the forbidden marker dependence.
      {j2, _s2, dir2} = U4Support.open!(base)

      U4Support.append_all!(j2, [
        U4Support.conv_event("turn_started", marker: "md-3"),
        U4Support.meta_event("attach")
      ])

      :ok = FileStore.close(j2)
      assert {:ok, %{history: _}} = U4Support.marker_dependent_attach(harness, dir2, 3)

      U4Support.assert_all_fired!(harness, :marker_dependent_control)
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Reader-path read of a CLOSED session (no Writer restarted): scan via the
  # production Reader, mapped exactly as FileStore.read/2 maps it.
  defp read_only(dir) do
    case Raxol.Agent.Journal.FileStore.Reader.scan(dir) do
      {:ok, records} -> {:ok, records}
      {:damaged, _} -> {:error, :damaged}
    end
  end
end
