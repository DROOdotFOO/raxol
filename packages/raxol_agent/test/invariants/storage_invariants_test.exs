defmodule Raxol.Agent.Invariants.StorageInvariantsTest do
  @moduledoc """
  Tier-1 storage invariants I5–I8 + I10 (see `docs/harness/architecture.md`'s
  "Journal and projection" section for the durable-journal model).

    * I5  — recovery beyond byte-cut: truncation fuzz, multi-segment, corrupt
      interior, corrupt HEAD, mid-UTF-8 cut, empty file, zero-length segment.
      Silent-prefix-drop or a silently-fabricated gap counts as FAILURE.
    * I6  — rotation continuity + no-delete: ids strictly continuous across
      segments, concat(segments) == journal, missing middle segment => damaged,
      no code path but explicit GC deletes a file.
    * I7  — single-writer + successor: concurrent opens -> one writer; kill
      under load -> exactly one successor, no dual-append interleave.
    * I8  — HEAD/meta discipline: HEAD.offset <= max(journal) under random
      kills, resume = max(HEAD, journal), allowlisted keys only, atomic writes
      never torn.
    * I10 — immediate-sync types are on disk at reply time and survive a REAL
      brutal kill (m7: no timer cheats).

  Oracle independence (m6): journal truth is `FaultJournal.raw_*` — raw
  `File.read!` + the harness's own line decoder — never `FileStore.read/2`,
  never the Writer's in-memory offset. Where `FileStore.read/2` appears it is
  the SUBJECT under test, cross-checked against the raw oracle.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Journal.FileStore

  @moduletag :capture_log

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_inv_storage_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp session!(base, opts \\ []) do
    session = "inv-#{System.unique_integer([:positive])}"
    {:ok, j} = FileStore.open(session, Keyword.put(opts, :base_dir, base))
    {j, session, Path.join(base, session)}
  end

  # Seed a closed multi-segment journal of `n` records and return its dir plus
  # the pristine per-segment bytes (captured for restore + independent expected
  # computation). segment_cap kept tiny so ~50 records span several segments.
  defp seeded_journal!(base, n, opts \\ []) do
    cap = Keyword.get(opts, :segment_cap, 256)
    {j, session, dir} = session!(base, segment_cap: cap)

    for k <- 1..n do
      {:ok, ^k} =
        FileStore.append(j, %{"type" => "chunk", "n" => k, "pad" => "xxxxxxxx"})
    end

    :ok = FileStore.close(j)

    pristine =
      for path <- FaultJournal.segment_paths(dir), into: %{} do
        {path, File.read!(path)}
      end

    {session, dir, pristine}
  end

  defp restore!(pristine) do
    Enum.each(pristine, fn {path, bytes} -> File.write!(path, bytes) end)
  end

  # A crash that loses journal-tail bytes is only physical when HEAD does not
  # claim offsets past the surviving bytes (HEAD is written AFTER the journal
  # datasync). Model that by removing HEAD — resume then comes from the reader.
  defp make_crash_physical!(dir), do: File.rm(Path.join(dir, "HEAD"))

  # Expected complete-record prefix of one segment's pristine bytes after a
  # truncation at byte `pos` — computed from the raw bytes alone, independently
  # of any production code. A record is complete iff its full line INCLUDING
  # the newline frame survived the cut; an unterminated trailing fragment is
  # torn, whether or not its bytes happen to decode.
  defp expected_prefix_ids(pristine_bytes, pos) do
    kept = binary_part(pristine_bytes, 0, pos)

    # String.split's final part is either "" (kept ends in "\n") or the torn
    # unterminated fragment — dropping it leaves exactly the terminated lines.
    kept
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!(&1)["id"])
  end

  # ===========================================================================
  # I5 — recovery beyond byte-cut
  # ===========================================================================

  describe "I5 — truncation fuzz on the last segment (torn tail at every byte)" do
    property "any byte-cut of the last segment recovers EXACTLY the complete-record prefix — no crash, no silent prefix drop, no fabrication" do
      base = tmp_base_for_property()
      {_session, dir, pristine} = seeded_journal!(base, 50)

      segs = FaultJournal.segment_paths(dir)
      assert length(segs) > 1, "seed journal must span multiple segments"
      last_seg = List.last(segs)
      last_bytes = Map.fetch!(pristine, last_seg)

      # Ids fully contained in the earlier (untouched) segments:
      earlier_ids =
        segs
        |> Enum.drop(-1)
        |> Enum.flat_map(fn p ->
          Map.fetch!(pristine, p)
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!(&1)["id"])
        end)

      check all(pos <- integer(0..byte_size(last_bytes)), max_runs: 60) do
        restore!(pristine)
        truncate_file!(last_seg, pos)
        make_crash_physical!(dir)

        expected = earlier_ids ++ expected_prefix_ids(last_bytes, pos)

        {:ok, j} = FileStore.open(session_of(dir), base_dir: Path.dirname(dir))
        result = FileStore.read(j)

        # Never crashes; never loses a complete record; never fabricates one.
        # `{:ok, []}` while `expected != []` is the silent-prefix-drop hole —
        # covered because we assert EXACT equality with the independent oracle.
        assert {:ok, records} = result

        assert Enum.map(records, & &1["id"]) == expected,
               "byte-cut at #{pos}: recovered ids diverged from the independent prefix oracle"

        # Resume continues densely after the recovered prefix.
        next = List.last(expected, 0) + 1

        assert {:ok, ^next} =
                 FileStore.append(j, %{"type" => "chunk", "n" => next})

        :ok = FileStore.close(j)
      end
    end

    @tag :slow
    property "heavy variant: every byte position (exhaustive walk over the last segment)" do
      base = tmp_base_for_property()
      {_session, dir, pristine} = seeded_journal!(base, 50)
      last_seg = List.last(FaultJournal.segment_paths(dir))
      last_bytes = Map.fetch!(pristine, last_seg)

      earlier_ids =
        FaultJournal.segment_paths(dir)
        |> Enum.drop(-1)
        |> Enum.flat_map(fn p ->
          Map.fetch!(pristine, p)
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!(&1)["id"])
        end)

      for pos <- 0..byte_size(last_bytes) do
        restore!(pristine)
        truncate_file!(last_seg, pos)
        make_crash_physical!(dir)

        expected = earlier_ids ++ expected_prefix_ids(last_bytes, pos)

        {:ok, j} = FileStore.open(session_of(dir), base_dir: Path.dirname(dir))
        assert {:ok, records} = FileStore.read(j)

        assert Enum.map(records, & &1["id"]) == expected,
               "exhaustive cut at #{pos}"

        :ok = FileStore.close(j)
      end
    end
  end

  describe "I5 — truncating an EARLIER segment (multi-segment cut)" do
    property "a cut inside a non-last segment is DAMAGED — never a silent gap, never fabricated continuity" do
      base = tmp_base_for_property()
      {_session, dir, pristine} = seeded_journal!(base, 50)

      segs = FaultJournal.segment_paths(dir)
      assert length(segs) >= 3
      # never the last segment:
      middle_segs = Enum.drop(segs, -1)

      check all(
              seg_idx <- integer(0..(length(middle_segs) - 1)),
              frac <- integer(1..99),
              max_runs: 40
            ) do
        seg = Enum.at(middle_segs, seg_idx)
        bytes = Map.fetch!(pristine, seg)
        # Cut strictly inside the segment (losing at least its tail record).
        pos = max(div(byte_size(bytes) * frac, 100), 0)
        pos = min(pos, byte_size(bytes) - 1)

        restore!(pristine)
        truncate_file!(seg, pos)
        make_crash_physical!(dir)

        {:ok, j} = FileStore.open(session_of(dir), base_dir: Path.dirname(dir))

        capture_log(fn ->
          case FileStore.read(j) do
            {:error, :damaged} ->
              :ok

            {:ok, records} ->
              # Only acceptable when the cut happens to reproduce the FULL
              # segment (frac rounding) — otherwise a gap in ids was silently
              # returned, fabricating continuity across lost interior records.
              ids = Enum.map(records, & &1["id"])

              assert ids == Enum.to_list(1..50),
                     "interior byte-cut at #{seg}:#{pos} returned a gapped id " <>
                       "sequence as healthy: #{inspect(ids)}"
          end
        end)

        :ok = FileStore.close(j)
      end
    end
  end

  describe "I5 — corrupt interior / corrupt HEAD / mid-UTF-8 / empty & zero-length segments" do
    test "corrupt interior line => damaged, alarm, nothing deleted, prefix never silently surfaced",
         %{base: base} do
      {session, dir, _} = seeded_journal!(base, 20)
      [first | _] = segs = FaultJournal.segment_paths(dir)

      lines = File.read!(first) |> String.split("\n", trim: true)
      corrupted = List.replace_at(lines, 1, "{interior corruption")
      File.write!(first, Enum.join(corrupted, "\n") <> "\n")

      {:ok, j} = FileStore.open(session, base_dir: base)

      log =
        capture_log(fn ->
          assert {:error, :damaged} = FileStore.read(j)
          assert FileStore.status(j) == :damaged
        end)

      assert log =~ "interior corruption"
      # I6 no-delete: every segment survives damage detection, byte-identical
      # apart from the one we corrupted ourselves.
      assert FaultJournal.segment_paths(dir) == segs
      :ok = FileStore.close(j)
    end

    test "corrupt HEAD (garbage bytes) is ignored: open succeeds, resume comes from the journal",
         %{base: base} do
      {session, dir, _} = seeded_journal!(base, 7)
      File.write!(Path.join(dir, "HEAD"), "\x00\x01garbage{{{")

      {:ok, j} = FileStore.open(session, base_dir: base)
      assert {:ok, 8} = FileStore.append(j, %{"type" => "chunk", "n" => 8})
      assert FaultJournal.raw_ids!(dir) == Enum.to_list(1..8)
      :ok = FileStore.close(j)
    end

    test "corrupt HEAD (valid JSON, wrong offset type) is ignored the same way",
         %{base: base} do
      {session, dir, _} = seeded_journal!(base, 4)
      File.write!(Path.join(dir, "HEAD"), ~s({"offset": "not-an-int"}))

      {:ok, j} = FileStore.open(session, base_dir: base)
      assert {:ok, 5} = FileStore.append(j, %{"type" => "chunk", "n" => 5})
      assert FaultJournal.raw_ids!(dir) == Enum.to_list(1..5)
      :ok = FileStore.close(j)
    end

    test "a cut mid-UTF-8-codepoint in the torn tail recovers the prefix without crashing",
         %{
           base: base
         } do
      {j, session, dir} = session!(base)

      {:ok, 1} =
        FileStore.append(j, %{"type" => "chunk", "text" => "héllo 日本語 ünïcode"})

      {:ok, 2} =
        FileStore.append(j, %{"type" => "chunk", "text" => "日本語だけの行です"})

      :ok = FileStore.close(j)

      [seg] = FaultJournal.segment_paths(dir)
      bytes = File.read!(seg)

      # Find a multibyte char in record 2's line and cut inside it.
      lines = String.split(bytes, "\n", trim: true)
      line2 = List.last(lines)
      offset_of_line2 = byte_size(bytes) - byte_size(line2) - 1
      {mb_offset, _} = :binary.match(line2, "日")
      # +1 lands strictly inside the 3-byte UTF-8 sequence for 日.
      cut = offset_of_line2 + mb_offset + 1

      truncate_file!(seg, cut)
      make_crash_physical!(dir)

      {:ok, j2} = FileStore.open(session, base_dir: base)
      assert {:ok, [only]} = FileStore.read(j2)
      assert only["id"] == 1
      assert only["text"] == "héllo 日本語 ünïcode"
      :ok = FileStore.close(j2)
    end

    test "an entirely empty journal dir reads as [] and appends from 1", %{
      base: base
    } do
      {j, _session, dir} = session!(base)
      assert {:ok, []} = FileStore.read(j)
      assert {:ok, 1} = FileStore.append(j, %{"type" => "chunk"})
      assert FaultJournal.raw_ids!(dir) == [1]
      :ok = FileStore.close(j)
    end

    test "a zero-length trailing segment (crash right after rotation) is harmless",
         %{base: base} do
      {session, dir, _} = seeded_journal!(base, 12)
      segs = FaultJournal.segment_paths(dir)

      last_num =
        segs
        |> List.last()
        |> Path.basename()
        |> String.slice(0, 6)
        |> String.to_integer()

      empty = Path.join([dir, "journal", segment_name(last_num + 1)])
      File.write!(empty, "")

      {:ok, j} = FileStore.open(session, base_dir: base)
      assert {:ok, records} = FileStore.read(j)
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..12)
      assert {:ok, 13} = FileStore.append(j, %{"type" => "chunk", "n" => 13})
      :ok = FileStore.close(j)
    end

    test "a zero-length MIDDLE segment does not break replay of its neighbors",
         %{base: base} do
      {session, dir, _} = seeded_journal!(base, 12)
      segs = FaultJournal.segment_paths(dir)
      assert length(segs) >= 2

      # A middle segment that never received bytes (crash between open and write).
      # Simulate by emptying an EXISTING middle segment is data loss (I6 damaged);
      # a genuinely empty extra file between numbers cannot exist under ascending
      # naming — so the closest physical shape is a zero-length LAST segment
      # (covered above). Here: an empty file with a number BEYOND last + 1 (a
      # stray) must also be harmless.
      stray = Path.join([dir, "journal", segment_name(900_000)])
      File.write!(stray, "")

      {:ok, j} = FileStore.open(session, base_dir: base)
      assert {:ok, records} = FileStore.read(j)
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..12)
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # I6 — rotation continuity + no-delete
  # ===========================================================================

  describe "I6 — rotation continuity" do
    property "forced rotations keep ids strictly continuous across segments; concat(segments) == journal" do
      base = tmp_base_for_property()

      check all(
              n <- integer(20..60),
              cap <- member_of([128, 256, 512]),
              max_runs: 15
            ) do
        {j, _session, dir} = session!(base, segment_cap: cap)

        for k <- 1..n do
          {:ok, ^k} =
            FileStore.append(j, %{
              "type" => "chunk",
              "n" => k,
              "pad" => "xxxxxxxxxxxx"
            })
        end

        segs = FaultJournal.segment_paths(dir)
        assert length(segs) > 1, "cap #{cap} with #{n} records must rotate"

        # Independent oracle: concatenation of per-segment decodes.
        per_segment =
          Enum.map(segs, fn p ->
            File.read!(p)
            |> String.split("\n", trim: true)
            |> Enum.map(&Jason.decode!(&1)["id"])
          end)

        concat = List.flatten(per_segment)
        assert concat == Enum.to_list(1..n)

        # Strict continuity ACROSS each segment boundary (no gap, no overlap).
        per_segment
        |> Enum.reject(&(&1 == []))
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [a, b] ->
          assert hd(b) == List.last(a) + 1,
                 "segment boundary gap: #{List.last(a)} -> #{hd(b)}"
        end)

        # The production reader agrees with the oracle.
        assert {:ok, records} = FileStore.read(j)
        assert Enum.map(records, & &1["id"]) == concat
        :ok = FileStore.close(j)
      end
    end

    test "a missing MIDDLE segment is damaged — not a silent skip fabricating continuity",
         %{
           base: base
         } do
      {session, dir, _} = seeded_journal!(base, 50)
      segs = FaultJournal.segment_paths(dir)
      assert length(segs) >= 3

      victim = Enum.at(segs, 1)
      File.rm!(victim)

      {:ok, j} = FileStore.open(session, base_dir: base)

      capture_log(fn ->
        assert {:error, :damaged} = FileStore.read(j),
               "deleting segment #{victim} must mark the session damaged, " <>
                 "not silently concatenate around the hole"

        assert FileStore.status(j) == :damaged
      end)

      # No-delete under damage: the surviving segments are all still there.
      assert FaultJournal.segment_paths(dir) == segs -- [victim]
      :ok = FileStore.close(j)
    end

    test "crash/damage/reopen cycles never remove a segment file", %{base: base} do
      {session, dir, _} = seeded_journal!(base, 30)
      segs = FaultJournal.segment_paths(dir)
      bytes = Map.new(segs, &{&1, File.read!(&1)})

      # Corrupt an interior line, then hammer open/read/status/reopen cycles.
      [first | _] = segs
      lines = File.read!(first) |> String.split("\n", trim: true)

      File.write!(
        first,
        Enum.join(List.replace_at(lines, 0, "{bad"), "\n") <> "\n"
      )

      capture_log(fn ->
        for _ <- 1..3 do
          {:ok, j} = FileStore.open(session, base_dir: base)
          {:error, :damaged} = FileStore.read(j)
          :damaged = FileStore.status(j)
          :ok = FileStore.close(j)
        end
      end)

      assert FaultJournal.segment_paths(dir) == segs

      for seg <- segs, seg != first do
        assert File.read!(seg) == Map.fetch!(bytes, seg),
               "segment #{seg} was modified by damage handling"
      end
    end
  end

  # ===========================================================================
  # I7 — single-writer + successor
  # ===========================================================================

  describe "I7 — single writer" do
    test "N concurrent opens race to exactly one Writer; interleaved appends stay dense",
         %{
           base: base
         } do
      session = "inv-race-#{System.unique_integer([:positive])}"
      test_pid = self()

      # Openers must OUTLIVE their open: a Writer terminates when its parent
      # (the process that start_link'ed it) exits, so racing opens from
      # short-lived Tasks would tear the Writer down. Park each opener until
      # the test releases it.
      openers =
        for _ <- 1..8 do
          spawn_link(fn ->
            result = FileStore.open(session, base_dir: base)
            send(test_pid, {:opened, self(), result})

            receive do
              :stop -> :ok
            end
          end)
        end

      handles =
        for _ <- openers do
          receive do
            {:opened, _pid, {:ok, h}} -> h
          after
            2_000 -> flunk("an opener never reported")
          end
        end

      writers = handles |> Enum.map(& &1.writer) |> Enum.uniq()

      assert length(writers) == 1,
             "concurrent opens produced #{length(writers)} writers"

      assert Enum.count(handles, & &1.owner?) == 1, "exactly one owner handle"

      # Interleave appends through every handle from concurrent tasks (handles
      # are usable from any process; only the Writer's parent must stay alive).
      1..8
      |> Enum.flat_map(fn _ -> handles end)
      |> Enum.map(fn h ->
        Task.async(fn ->
          {:ok, off} = FileStore.append(h, %{"type" => "chunk"})
          off
        end)
      end)
      |> Enum.map(&Task.await/1)

      dir = Path.join(base, session)
      ids = FaultJournal.raw_ids!(dir)

      assert ids == Enum.to_list(1..64),
             "single writer must serialize to dense ids"

      owner = Enum.find(handles, & &1.owner?)
      :ok = FileStore.close(owner)
      Enum.each(openers, &send(&1, :stop))
    end

    test "kill the writer under load: exactly one successor, no dual-append interleave, no lost dense prefix",
         %{base: base} do
      harness = FaultJournal.new()
      FaultJournal.arm(harness, :writer_down)

      session = "inv-succ-#{System.unique_integer([:positive])}"
      dir = Path.join(base, session)
      {:ok, j} = FileStore.open(session, base_dir: base)

      # Load: concurrent appenders that tolerate the writer dying mid-flight.
      appenders =
        for _ <- 1..4 do
          Task.async(fn ->
            Enum.reduce(1..30, 0, fn _, ok_count ->
              case FileStore.append(j, %{"type" => "chunk"}) do
                {:ok, _} -> ok_count + 1
                {:error, _} -> ok_count
              end
            end)
          end)
        end

      # Kill the writer somewhere inside the storm (brutal — m7).
      Process.sleep(5)
      FaultJournal.kill_writer_brutal(harness, j.writer, dir)
      Enum.each(appenders, &Task.await(&1, 5_000))

      # Exactly one successor on reopen; both raced reopens converge on it.
      # (Opened from parked processes: a Writer terminates with its parent.)
      test_pid = self()

      openers =
        for _ <- 1..2 do
          spawn_link(fn ->
            result = FileStore.open(session, base_dir: base)
            send(test_pid, {:opened, self(), result})

            receive do
              :stop -> :ok
            end
          end)
        end

      [s1, s2] =
        for _ <- openers do
          receive do
            {:opened, _pid, {:ok, h}} -> h
          after
            2_000 -> flunk("successor opener never reported")
          end
        end

      on_exit(fn -> Enum.each(openers, &send(&1, :stop)) end)
      assert s1.writer == s2.writer
      assert Process.alive?(s1.writer)

      # The successor resumes past the survivors: appends stay dense on disk.
      pre = FaultJournal.raw_ids!(dir)

      assert pre == Enum.to_list(1..length(pre)),
             "pre-kill journal must be dense"

      assert pre != [], "some appends must have landed before the kill"

      {:ok, next} = FileStore.append(s1, %{"type" => "chunk"})
      assert next == length(pre) + 1

      ids = FaultJournal.raw_ids!(dir)
      assert ids == Enum.to_list(1..next)

      assert ids == Enum.uniq(ids),
             "no duplicate ids across the writer succession"

      owner = if s1.owner?, do: s1, else: s2
      :ok = FileStore.close(owner)
      FaultJournal.assert_all_fired!(harness)
    end
  end

  # ===========================================================================
  # I8 — HEAD/meta discipline
  # ===========================================================================

  describe "I8 — HEAD discipline" do
    property "HEAD.offset <= max(journal) after a brutal kill at a random point" do
      base = tmp_base_for_property()

      check all(n <- integer(1..25), max_runs: 15) do
        harness = FaultJournal.new()
        FaultJournal.arm(harness, :writer_down)
        {j, _session, dir} = session!(base)

        for k <- 1..n,
            do: {:ok, ^k} = FileStore.append(j, %{"type" => "chunk", "n" => k})

        FaultJournal.kill_writer_brutal(harness, j.writer, dir)

        max_journal =
          FaultJournal.raw_scan(dir)
          |> Enum.flat_map(fn
            {:ok, r, _} -> [r["id"]]
            _ -> []
          end)
          |> Enum.max(fn -> 0 end)

        case FaultJournal.raw_head(dir) do
          {:ok, %{"offset" => offset}} ->
            assert offset <= max_journal,
                   "HEAD (#{offset}) points past the journal (#{max_journal}) after a kill"

          :missing ->
            :ok

          {:error, reason} ->
            flunk(
              "HEAD torn after kill: #{inspect(reason)} — atomic write violated"
            )
        end

        FaultJournal.assert_all_fired!(harness, {:kill_after, n})
      end
    end

    test "resume = max(HEAD, journal), never HEAD alone (stale HEAD cannot cause id reuse)",
         %{
           base: base
         } do
      harness = FaultJournal.new()
      FaultJournal.arm(harness, :kill_after_write_before_head)
      {j, session, dir} = session!(base)
      {:ok, 1} = FileStore.append(j, %{"type" => "chunk", "n" => 1})
      :ok = FileStore.close(j)

      # Crash-between-write-and-HEAD: flushed bytes for 2 and 3, HEAD stuck at 1.
      FaultJournal.inject_write_before_head(harness, dir, [
        %{"id" => 2, "type" => "chunk", "n" => 2, "schema_version" => "1.0.0"},
        %{"id" => 3, "type" => "chunk", "n" => 3, "schema_version" => "1.0.0"}
      ])

      assert {:ok, %{"offset" => 1}} = FaultJournal.raw_head(dir)

      {:ok, j2} = FileStore.open(session, base_dir: base)
      # HEAD-alone resume would hand out 2 again — a duplicate id.
      assert {:ok, 4} = FileStore.append(j2, %{"type" => "chunk", "n" => 4})

      ids = FaultJournal.raw_ids!(dir)
      assert ids == [1, 2, 3, 4]
      assert ids == Enum.uniq(ids)
      :ok = FileStore.close(j2)
      FaultJournal.assert_all_fired!(harness)
    end

    test "HEAD and meta keys stay inside the allowlist — model state never leaks",
         %{base: base} do
      # Deliberately poison the append payloads with model-looking keys.
      {j, _session, dir} =
        session!(base,
          title: "inv",
          cwd: "/tmp/inv-wd",
          git_branch: "inv-branch"
        )

      for k <- 1..5 do
        {:ok, ^k} =
          FileStore.append(j, %{
            "type" => "chunk",
            "model" => %{"secret" => "state"},
            "messages" => ["a", "b"],
            "tools" => ["hammer"],
            "offset" => 999,
            "n" => k
          })
      end

      :ok = FileStore.close(j)

      head_allow = MapSet.new(~w(offset segment segment_cap schema_version))

      meta_allow =
        MapSet.new(~w(created_at cwd git_branch title schema_version))

      {:ok, head} = FaultJournal.raw_head(dir)

      assert MapSet.subset?(MapSet.new(Map.keys(head)), head_allow),
             "HEAD grew keys outside the allowlist: #{inspect(Map.keys(head))}"

      {:ok, meta} =
        Path.join(dir, "meta.json") |> File.read!() |> Jason.decode()

      assert MapSet.subset?(MapSet.new(Map.keys(meta)), meta_allow),
             "meta.json grew keys outside the allowlist: #{inspect(Map.keys(meta))}"
    end

    test "HEAD is never observably torn: concurrent raw reads during an append storm always parse",
         %{base: base} do
      {j, _session, dir} = session!(base)
      head_path = Path.join(dir, "HEAD")
      {:ok, 1} = FileStore.append(j, %{"type" => "chunk"})

      reader =
        Task.async(fn ->
          Enum.reduce_while(1..2_000, :ok, fn _, :ok ->
            case File.read(head_path) do
              {:ok, body} ->
                case Jason.decode(body) do
                  {:ok, %{"offset" => o}} when is_integer(o) -> {:cont, :ok}
                  bad -> {:halt, {:torn, body, bad}}
                end

              {:error, :enoent} ->
                # A rename window where the name briefly vanishes would also be
                # a torn observation — atomic rename must never unlink first.
                {:halt, {:missing, :enoent}}
            end
          end)
        end)

      for k <- 2..200,
          do: {:ok, ^k} = FileStore.append(j, %{"type" => "chunk", "n" => k})

      assert Task.await(reader, 10_000) == :ok
      :ok = FileStore.close(j)
    end

    test "stray atomic-write tmp files from a crashed run are swept on reopen; canonical HEAD survives",
         %{base: base} do
      {session, dir, _} = seeded_journal!(base, 3)
      {:ok, head_before} = FaultJournal.raw_head(dir)

      # A crash mid-atomic-write leaves tmp files but NEVER a torn canonical path.
      File.write!(Path.join(dir, "HEAD.tmp.99999"), "{\"offset\": 77")
      File.write!(Path.join(dir, "meta.json.tmp.4242"), "half")

      {:ok, j} = FileStore.open(session, base_dir: base)

      names = File.ls!(dir)

      refute Enum.any?(names, &String.contains?(&1, ".tmp.")),
             "tmp debris not swept"

      {:ok, head_after} = FaultJournal.raw_head(dir)
      assert head_after["offset"] == head_before["offset"]
      :ok = FileStore.close(j)
    end
  end

  # ===========================================================================
  # I10 — immediate-sync durability (REAL kill, m7: no timer cheats)
  # ===========================================================================

  describe "I10 — immediate-sync types survive a brutal writer kill" do
    test "tool_result/approval are fully on disk AT REPLY TIME and survive Process.exit(:kill)",
         %{base: base} do
      harness = FaultJournal.new()
      FaultJournal.arm(harness, :writer_down)
      {j, session, dir} = session!(base)

      {:ok, 1} =
        FileStore.append(j, %{"type" => "tool_result", "result" => "42"})

      {:ok, 2} =
        FileStore.append(j, %{"type" => "approval", "approved" => true})

      # m3 branch probe: the immediate-sync arm's SPECIFIC observable — at the
      # moment the {:ok, offset} reply lands, an independent raw read already
      # returns the complete framed records. No waiting, no timers.
      ids_at_reply = FaultJournal.raw_ids!(dir)
      assert ids_at_reply == [1, 2]

      # The REAL kill: terminate/2 never runs, nothing gets a chance to flush.
      FaultJournal.kill_writer_brutal(harness, j.writer, dir)

      assert FaultJournal.raw_ids!(dir) == [1, 2],
             "immediate-sync records lost across a brutal kill"

      {:ok, j2} = FileStore.open(session, base_dir: base)
      assert {:ok, records} = FileStore.read(j2)
      assert Enum.map(records, & &1["id"]) == [1, 2]
      assert Enum.map(records, & &1["type"]) == ["tool_result", "approval"]
      assert {:ok, 3} = FileStore.append(j2, %{"type" => "chunk"})
      :ok = FileStore.close(j2)
      FaultJournal.assert_all_fired!(harness)
    end

    test "immediate sync holds even under a busy mailbox (the batched path must not swallow it)",
         %{base: base} do
      {j, _session, dir} = session!(base)

      # Storm the writer with batched-type appends from concurrent tasks so its
      # mailbox is non-empty, then land tool_results in the middle of it. Each
      # tool_result must be raw-readable the moment its own reply arrives.
      storm =
        for _ <- 1..4 do
          Task.async(fn ->
            for _ <- 1..50, do: FileStore.append(j, %{"type" => "chunk"})
          end)
        end

      results =
        for _ <- 1..10 do
          {:ok, off} =
            FileStore.append(j, %{"type" => "tool_result", "result" => "x"})

          on_disk =
            FaultJournal.raw_scan(dir)
            |> Enum.any?(fn
              {:ok, %{"id" => ^off, "type" => "tool_result"}, _} -> true
              _ -> false
            end)

          {off, on_disk}
        end

      Enum.each(storm, &Task.await(&1, 10_000))

      for {off, on_disk} <- results do
        assert on_disk,
               "tool_result #{off} not on disk at reply time under load"
      end

      :ok = FileStore.close(j)
    end

    test "custom :immediate_sync_types are honored", %{base: base} do
      {j, _session, dir} = session!(base, immediate_sync_types: ["checkpoint"])
      {:ok, 1} = FileStore.append(j, %{"type" => "checkpoint", "ptr" => 1})
      assert FaultJournal.raw_ids!(dir) == [1]
      FaultJournal.kill_writer_brutal(nil, j.writer, dir)
      assert FaultJournal.raw_ids!(dir) == [1]
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp truncate_file!(path, pos) do
    {:ok, io} = :file.open(path, [:read, :write, :binary])

    try do
      {:ok, _} = :file.position(io, pos)
      :ok = :file.truncate(io)
    after
      :file.close(io)
    end

    :ok
  end

  defp session_of(dir), do: Path.basename(dir)

  defp segment_name(num),
    do: :io_lib.format(~c"~6..0B.jsonl", [num]) |> List.to_string()

  # Properties outlive the per-test setup block's tmp dir only within the test,
  # which is fine — but each property wants its own base to keep session dirs
  # (and their :global writer names) unique across runs.
  defp tmp_base_for_property do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_inv_storage_prop_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    base
  end
end
