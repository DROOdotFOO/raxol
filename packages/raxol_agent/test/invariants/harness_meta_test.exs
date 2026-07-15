defmodule Raxol.Agent.Invariants.HarnessMetaTest do
  @moduledoc """
  The harness proving itself (harness-invariants.md, meta-invariants):

    * m1 — dead-injector detection: every named fault site actually injects
      (each one is fired here against a real journal and its counter observed),
      and an armed-but-never-fired site FAILS `assert_all_fired!/2`.
    * m2 — failure reports carry the schedule: the dead-injector error message
      dumps the fault schedule (the ExUnit/StreamData seed reproduces the run).
    * m6 — oracle independence: the raw decoder is exercised against a journal
      written behind its back (bytes on disk, no Writer state consulted) and
      classifies torn vs corrupt correctly.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Journal.FileStore

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_inv_meta_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  describe "m1 — every injector is alive" do
    test "each of the five named fault sites fires against a real journal and bumps its counter",
         %{base: base} do
      harness = FaultJournal.new()
      for site <- FaultJournal.sites(), do: FaultJournal.arm(harness, site)

      # :open_fail (fresh session, then heal)
      s_open = "meta-open-#{System.unique_integer([:positive])}"
      :ok = FaultJournal.inject_open_fail(harness, s_open, base)
      assert {:error, {:mkdir_failed, _, _}} = FileStore.open(s_open, base_dir: base)
      :ok = FaultJournal.heal_open_fail(s_open, base)
      assert {:ok, j0} = FileStore.open(s_open, base_dir: base)
      :ok = FileStore.close(j0)

      # A live journal for the writer-facing sites.
      session = "meta-#{System.unique_integer([:positive])}"
      dir = Path.join(base, session)
      {:ok, j} = FileStore.open(session, base_dir: base)
      {:ok, 1} = FileStore.append(j, %{"type" => "chunk", "n" => 1})

      # :append_fail (m3 probe: {:error, _} reply, offset NOT advanced, writer alive)
      original_io = FaultJournal.inject_append_fail(harness, j.writer, base)
      assert {:error, _} = FileStore.append(j, %{"type" => "chunk", "n" => :lost})
      assert Process.alive?(j.writer)
      :ok = FaultJournal.heal_append_fail(j.writer, original_io)

      assert {:ok, 2} = FileStore.append(j, %{"type" => "chunk", "n" => 2}),
             "offset must not advance across a failed append"

      # :kill_after_write_before_head (raw bytes ahead of HEAD)
      :ok =
        FaultJournal.inject_write_before_head(harness, dir, [
          %{"id" => 3, "type" => "chunk", "n" => 3, "schema_version" => "1.0.0"}
        ])

      assert FaultJournal.raw_ids!(dir) == [1, 2, 3]

      # :kill_after_head_before_publish (joiner append, never published)
      offset =
        FaultJournal.inject_head_before_publish(harness, session, base, %{
          "type" => "chunk",
          "n" => 4
        })

      # The joiner shares the (stale-offset) live writer — the raw record above
      # was invisible to it, so it hands out 3 again: exactly why the composite
      # site REQUIRES the kill half before any writer append. Both shapes are
      # legal for the meta check; what matters is the injector fired.
      assert offset in [3, 4]

      # :writer_down
      :ok = FaultJournal.stop_writer(harness, j.writer)
      assert {:error, {:writer_down, _}} = FileStore.append(j, %{"type" => "chunk"})

      fired = FaultJournal.assert_all_fired!(harness, :meta_self_test)
      assert Enum.sort(Map.keys(fired)) == Enum.sort(FaultJournal.sites())
      assert Enum.all?(fired, fn {_site, n} -> n >= 1 end)
    end

    test "an armed site that never fires FAILS the suite and dumps the schedule (m2)" do
      harness = FaultJournal.new()
      FaultJournal.arm(harness, :append_fail)
      FaultJournal.arm(harness, :writer_down)
      FaultJournal.record_fired(harness, :writer_down)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          FaultJournal.assert_all_fired!(harness, [:the, :schedule, :under, :test])
        end

      assert err.message =~ "dead injector"
      assert err.message =~ "append_fail"
      refute err.message =~ ~r/dead injector.*writer_down/
      # m2: the failure dumps the schedule for seed reproduction.
      assert err.message =~ "[:the, :schedule, :under, :test]"
    end

    test "brutal kill really is brutal: terminate/2 never runs, :global is released", %{
      base: base
    } do
      session = "meta-kill-#{System.unique_integer([:positive])}"
      dir = Path.join(base, session)
      {:ok, j} = FileStore.open(session, base_dir: base)
      {:ok, 1} = FileStore.append(j, %{"type" => "tool_result"})

      writer = j.writer
      :ok = FaultJournal.kill_writer_brutal(nil, writer, dir)
      refute Process.alive?(writer)

      # :global released -> a reopen wins a FRESH writer immediately.
      {:ok, j2} = FileStore.open(session, base_dir: base)
      refute j2.writer == writer
      assert j2.owner?
      :ok = FileStore.close(j2)
    end
  end

  describe "m6 — the independent oracle stands on raw bytes alone" do
    test "raw_scan decodes a journal written behind its back and classifies torn vs corrupt", %{
      base: base
    } do
      session = "meta-oracle-#{System.unique_integer([:positive])}"
      dir = Path.join(base, session)
      journal_dir = Path.join(dir, "journal")
      File.mkdir_p!(journal_dir)

      # No Writer involved at all: bytes straight to disk.
      File.write!(Path.join(journal_dir, "000001.jsonl"), """
      {"id":1,"type":"chunk"}
      {"id":2,"type":"chunk"}
      """)

      File.write!(
        Path.join(journal_dir, "000002.jsonl"),
        ~s({"id":3,"type":"chunk"}\n{"id":4,"ty)
      )

      entries = FaultJournal.raw_scan(dir)

      assert [
               {:ok, %{"id" => 1}, _},
               {:ok, %{"id" => 2}, _},
               {:ok, %{"id" => 3}, _},
               {:torn, _, ~s({"id":4,"ty)}
             ] = entries

      # An unterminated chunk in a NON-last segment is corruption, not torn.
      File.write!(Path.join(journal_dir, "000003.jsonl"), ~s({"id":5,"type":"chunk"}\n))
      entries = FaultJournal.raw_scan(dir)

      assert Enum.any?(entries, fn
               {:corrupt, path, ~s({"id":4,"ty)} -> String.ends_with?(path, "000002.jsonl")
               _ -> false
             end)

      # raw_records! refuses to bless a dirty journal.
      assert_raise RuntimeError, ~r/not clean/, fn -> FaultJournal.raw_records!(dir) end
    end
  end
end
