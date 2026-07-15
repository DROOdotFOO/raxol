defmodule Raxol.Agent.JournalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Reader

  setup do
    # NEVER touch the real home: every test gets its own tmp base dir.
    base =
      Path.join(System.tmp_dir!(), "raxol_journal_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, session: "sess-#{System.unique_integer([:positive])}"}
  end

  defp segments(base, session) do
    Reader.list_segments(Path.join([base, session, "journal"]))
  end

  describe "directory layout" do
    test "creates the per-session directory skeleton", %{base: base, session: session} do
      {:ok, j} = FileStore.open(session, base_dir: base)
      dir = Path.join(base, session)

      assert File.dir?(Path.join(dir, "journal"))
      assert File.dir?(Path.join(dir, "snapshots"))
      assert File.exists?(Path.join(dir, "meta.json"))
      assert File.exists?(Path.join(dir, "HEAD"))

      FileStore.close(j)
    end
  end

  describe "append + replay round-trip" do
    test "append N, close, reopen, read returns the full trace in order", %{
      base: base,
      session: session
    } do
      {:ok, j} = FileStore.open(session, base_dir: base)

      offsets =
        for n <- 1..10 do
          {:ok, off} = FileStore.append(j, %{"type" => "chunk", "n" => n})
          off
        end

      assert offsets == Enum.to_list(1..10)
      assert :ok = FileStore.close(j)

      {:ok, j2} = FileStore.open(session, base_dir: base)
      assert {:ok, records} = FileStore.read(j2)

      assert length(records) == 10
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..10)
      assert Enum.map(records, & &1["n"]) == Enum.to_list(1..10)
      assert Enum.all?(records, &(&1["type"] == "chunk"))
      assert FileStore.status(j2) == :ok

      FileStore.close(j2)
    end

    test "offset = the event id, monotonic and continued across reopen", %{
      base: base,
      session: session
    } do
      {:ok, j} = FileStore.open(session, base_dir: base)
      {:ok, 1} = FileStore.append(j, %{"type" => "a"})
      {:ok, 2} = FileStore.append(j, %{"type" => "b"})
      FileStore.close(j)

      {:ok, j2} = FileStore.open(session, base_dir: base)
      assert {:ok, 3} = FileStore.append(j2, %{"type" => "c"})

      {:ok, records} = FileStore.read(j2)
      assert Enum.map(records, & &1["id"]) == [1, 2, 3]
      FileStore.close(j2)
    end

    test "from_offset filters the replay", %{base: base, session: session} do
      {:ok, j} = FileStore.open(session, base_dir: base)
      for n <- 1..5, do: FileStore.append(j, %{"type" => "e", "n" => n})

      {:ok, records} = FileStore.read(j, from_offset: 3)
      assert Enum.map(records, & &1["id"]) == [3, 4, 5]
      FileStore.close(j)
    end

    test "schema_version passes through and defaults", %{base: base, session: session} do
      {:ok, j} = FileStore.open(session, base_dir: base, schema_version: "2.0.0")
      FileStore.append(j, %{"type" => "x"})
      FileStore.append(j, %{"type" => "y", "schema_version" => "9.9.9"})

      {:ok, [a, b]} = FileStore.read(j)
      assert a["schema_version"] == "2.0.0"
      assert b["schema_version"] == "9.9.9"
      FileStore.close(j)
    end
  end

  describe "torn-tail recovery (crash mid-write)" do
    test "truncating the last segment mid-final-line recovers all complete records", %{
      base: base,
      session: session
    } do
      {:ok, j} = FileStore.open(session, base_dir: base)
      for n <- 1..5, do: FileStore.append(j, %{"type" => "chunk", "n" => n})
      FileStore.close(j)

      [seg] = segments(base, session)

      # Simulate a crash: append a partial, unterminated final line.
      File.write!(seg, ~s({"id":6,"type":"chunk","n":6,), [:append])

      {:ok, j2} = FileStore.open(session, base_dir: base)
      assert {:ok, records} = FileStore.read(j2)

      assert length(records) == 5
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..5)
      assert FileStore.status(j2) == :ok

      # The torn bytes were physically truncated; the file is clean now.
      assert String.ends_with?(File.read!(seg), "\n")
      FileStore.close(j2)
    end

    test "torn tail is dropped, not surfaced, and appends continue cleanly", %{
      base: base,
      session: session
    } do
      {:ok, j} = FileStore.open(session, base_dir: base)
      FileStore.append(j, %{"type" => "chunk", "n" => 1})
      FileStore.close(j)

      [seg] = segments(base, session)
      File.write!(seg, ~s({"id":2,"type":"cho), [:append])

      {:ok, j2} = FileStore.open(session, base_dir: base)
      {:ok, [only]} = FileStore.read(j2)
      assert only["id"] == 1

      # Next append gets id 2 again (the torn one never committed).
      assert {:ok, 2} = FileStore.append(j2, %{"type" => "chunk", "n" => 2})
      {:ok, records} = FileStore.read(j2)
      assert Enum.map(records, & &1["id"]) == [1, 2]
      FileStore.close(j2)
    end
  end

  describe "interior corruption (hard alarm, damaged)" do
    test "corrupting a middle line marks damaged, fires an alarm, deletes nothing, leaks nothing",
         %{base: base, session: session} do
      # Force multiple small segments so corruption lands in a non-last segment.
      {:ok, j} = FileStore.open(session, base_dir: base, segment_cap: 64)
      for n <- 1..8, do: FileStore.append(j, %{"type" => "chunk", "n" => n})
      FileStore.close(j)

      segs = segments(base, session)
      assert length(segs) > 1

      first_seg = List.first(segs)
      before_bytes = File.read!(first_seg)

      # Corrupt a middle (non-final, terminated) line of a non-last segment.
      lines = String.split(before_bytes, "\n", trim: true)
      assert length(lines) >= 2
      corrupted = List.replace_at(lines, 1, "{not valid json")
      File.write!(first_seg, Enum.join(corrupted, "\n") <> "\n")

      telemetry_ref = attach_damaged_telemetry()
      {:ok, j2} = FileStore.open(session, base_dir: base, segment_cap: 64)

      log =
        capture_log(fn ->
          # Interior corruption never returns the damaged content downstream.
          assert {:error, :damaged} = FileStore.read(j2)
          assert FileStore.status(j2) == :damaged
        end)

      assert log =~ "interior corruption"

      assert_received {:journal_damaged, %{dir: _}, %{segment: _}},
                      "expected a damaged telemetry alarm"

      # NOTHING deleted: every segment file still on disk.
      assert segments(base, session) == segs
      assert Enum.all?(segs, &File.exists?/1)

      :telemetry.detach(telemetry_ref)
      FileStore.close(j2)
    end
  end

  describe "meta.json / HEAD atomicity" do
    test "meta.json is written once and is valid JSON", %{base: base, session: session} do
      {:ok, j} = FileStore.open(session, base_dir: base, cwd: "/tmp/wd", title: "hello")
      meta_path = Path.join([base, session, "meta.json"])
      {:ok, meta} = meta_path |> File.read!() |> Jason.decode()

      assert meta["cwd"] == "/tmp/wd"
      assert meta["title"] == "hello"
      assert is_binary(meta["created_at"])
      assert meta["schema_version"] == "1.0.0"

      created = meta["created_at"]
      FileStore.append(j, %{"type" => "x"})
      FileStore.close(j)

      # Reopen must not clobber meta.json (created_at preserved).
      {:ok, j2} = FileStore.open(session, base_dir: base)
      {:ok, meta2} = meta_path |> File.read!() |> Jason.decode()
      assert meta2["created_at"] == created
      FileStore.close(j2)
    end

    test "HEAD tracks the durable offset and is valid JSON", %{base: base, session: session} do
      {:ok, j} = FileStore.open(session, base_dir: base)
      for _ <- 1..3, do: FileStore.append(j, %{"type" => "x"})
      FileStore.close(j)

      {:ok, head} = Path.join([base, session, "HEAD"]) |> File.read!() |> Jason.decode()
      assert head["offset"] == 3
      assert is_integer(head["segment"])

      # No stray temp files left behind by atomic writes.
      names = File.ls!(Path.join(base, session))
      refute Enum.any?(names, &String.contains?(&1, ".tmp."))
    end
  end

  describe "segment rotation" do
    test "rotates to a new segment past the size cap, offsets stay ascending", %{
      base: base,
      session: session
    } do
      {:ok, j} = FileStore.open(session, base_dir: base, segment_cap: 128)

      for n <- 1..20,
          do: FileStore.append(j, %{"type" => "chunk", "n" => n, "pad" => "xxxxxxxxxx"})

      FileStore.close(j)

      assert length(segments(base, session)) > 1

      {:ok, j2} = FileStore.open(session, base_dir: base)
      {:ok, records} = FileStore.read(j2)
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..20)
      FileStore.close(j2)
    end
  end

  defp attach_damaged_telemetry do
    ref = "journal-damaged-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      ref,
      [:raxol, :agent, :journal, :damaged],
      fn _event, _measurements, metadata, _ ->
        send(test_pid, {:journal_damaged, %{dir: metadata.dir}, %{segment: metadata.segment}})
      end,
      nil
    )

    ref
  end
end
