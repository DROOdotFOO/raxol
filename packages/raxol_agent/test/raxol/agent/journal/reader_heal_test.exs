defmodule Raxol.Agent.Journal.ReaderHealTest do
  @moduledoc """
  Only the OWNING Writer may repair a torn tail.

  A reader that truncates one is not merely rude: it computes the cut from a
  file it read moments ago, so against a live session it can delete a record the
  Writer has already committed and counted. The Writer's in-memory offset then
  appends PAST the hole, `continuous?/2` sees an id gap, and the session is
  `{:damaged, _}` forever -- transcript, --replay, /share, attach and checkpoint
  restore all dead, with the committed record silently gone.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Reader

  # Two complete records and a third cut mid-write, the shape a crash leaves.
  @torn ~s({"id":1,"kind":"a"}\n{"id":2,"kind":"b"}\n{"id":3,"ki)

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol-reader-heal-#{System.unique_integer([:positive])}"
      )

    session = "sess-torn"
    dir = Path.join(base, session)
    File.mkdir_p!(Path.join(dir, "journal"))
    path = Path.join([dir, "journal", "000001.jsonl"])
    File.write!(path, @torn)

    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, session: session, dir: dir, path: path}
  end

  describe "read-side scans" do
    test "no read entry point truncates a torn tail", ctx do
      # Reattach.FileReader.attach/4 and Reattach.Tailer.deliver_new/1 both
      # reach the journal through Reader.scan/1 with no options, so the first
      # row covers them too -- and the Tailer re-scans every poll, per viewer.
      readers = [
        {"Reader.scan/1", fn -> Reader.scan(ctx.dir) end},
        {"Reader.last_offset/1", fn -> Reader.last_offset(ctx.dir) end},
        {"FileStore.high_watermark/2",
         fn -> FileStore.high_watermark(ctx.session, base_dir: ctx.base) end},
        {"FileStore.read_records/2",
         fn -> FileStore.read_records(ctx.session, base_dir: ctx.base) end}
      ]

      for {name, read} <- readers do
        File.write!(ctx.path, @torn)
        before = File.stat!(ctx.path).size

        read.()

        assert File.stat!(ctx.path).size == before,
               "#{name} truncated a torn tail it does not own"
      end
    end

    test "a torn tail is still tolerated, not reported as damage", ctx do
      assert {:ok, records} = Reader.scan(ctx.dir)
      assert Enum.map(records, & &1["id"]) == [1, 2]
      assert Reader.last_offset(ctx.dir) == 2
      assert FileStore.high_watermark(ctx.session, base_dir: ctx.base) == 2
    end
  end

  describe "the owning Writer's resume" do
    test "resume_scan repairs the torn tail", ctx do
      before = File.stat!(ctx.path).size

      assert {:ok, records} = Reader.resume_scan(ctx.dir)
      assert Enum.map(records, & &1["id"]) == [1, 2]

      assert File.stat!(ctx.path).size < before

      assert File.read!(ctx.path) ==
               ~s({"id":1,"kind":"a"}\n{"id":2,"kind":"b"}\n)

      # Repaired, so the next append lands cleanly rather than concatenating
      # onto the torn bytes -- which is the whole reason healing exists.
      assert Reader.resume_last_offset(ctx.dir) == 2
    end

    @tag :unix_only
    test "a segment it cannot open for writing scans instead of raising", ctx do
      File.chmod!(ctx.path, 0o444)
      on_exit(fn -> File.chmod(ctx.path, 0o644) end)

      if writable_anyway?(ctx.path) do
        # root ignores the mode bits; nothing to assert.
        assert true
      else
        assert {:ok, records} = Reader.resume_scan(ctx.dir)
        assert Enum.map(records, & &1["id"]) == [1, 2]
        assert File.read!(ctx.path) == @torn
      end
    end
  end

  defp writable_anyway?(path) do
    case :file.open(path, [:read, :write, :binary]) do
      {:ok, io} ->
        :file.close(io)
        true

      {:error, _} ->
        false
    end
  end
end
