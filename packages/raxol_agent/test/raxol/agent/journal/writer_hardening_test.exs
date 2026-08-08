defmodule Raxol.Agent.Journal.WriterHardeningTest do
  # async: false — starts Writers under the shared :global name space and
  # exercises OS-level locks/perms.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer

  @moduletag :unix_only

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol-writer-hard-#{System.os_time(:millisecond)}-" <>
          "#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base, session: "sess-#{System.unique_integer([:positive])}"}
  end

  defp lock_path(base, session), do: Path.join([base, session, "writer.lock"])

  defp event do
    %{
      v: 0,
      session_id: "s",
      turn_id: "t1",
      ts: 1,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{"prompt" => "x"}
    }
  end

  describe "cross-process lock file" do
    test "is held while open and released on close", %{base: base, session: s} do
      {:ok, journal} = FileStore.open(s, base_dir: base)
      assert File.exists?(lock_path(base, s))

      :ok = FileStore.close(journal)
      refute File.exists?(lock_path(base, s))

      # And the next open re-acquires cleanly.
      {:ok, journal2} = FileStore.open(s, base_dir: base)
      assert File.exists?(lock_path(base, s))
      :ok = FileStore.close(journal2)
    end

    test "refuses a Writer when a live foreign OS process holds the lock", %{
      base: base,
      session: s
    } do
      Process.flag(:trap_exit, true)
      dir = Path.join(base, s)
      File.mkdir_p!(dir)

      # A real, live OS process we own — its pid in the lock file must block a
      # second Writer (the two-OS-processes-on-one-journal corruption case).
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["30"]])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      File.write!(Path.join(dir, "writer.lock"), Integer.to_string(os_pid))

      assert {:error, {:journal_locked, holder}} =
               Writer.start_link(dir: dir, session_id: s)

      assert holder == Integer.to_string(os_pid)

      Port.close(port)
    end

    test "reclaims a stale lock left by a dead process", %{base: base, session: s} do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)
      # A pid that cannot exist on this host -> stale -> reclaimed.
      File.write!(Path.join(dir, "writer.lock"), "999999")

      assert {:ok, pid} = Writer.start_link(dir: dir, session_id: s)
      assert Process.alive?(pid)
      assert File.read!(Path.join(dir, "writer.lock")) == System.pid()

      GenServer.stop(pid)
    end

    test "an init failure after locking releases the lock (no self-lockout)", %{
      base: base,
      session: s
    } do
      Process.flag(:trap_exit, true)
      dir = Path.join(base, s)
      journal = Path.join(dir, "journal")
      File.mkdir_p!(journal)

      # A DIRECTORY where the first segment file must be: open_segment! fails
      # with :eisdir, so init raises AFTER the lock was taken. terminate is not
      # called on an init failure, so the lock must be released on that path or
      # every future open of this session is refused for the node's lifetime.
      blocker = Path.join(journal, "000001.jsonl")
      File.mkdir_p!(blocker)

      assert {:error, _reason} = Writer.start_link(dir: dir, session_id: s)
      refute File.exists?(Path.join(dir, "writer.lock")),
             "the lock must be released when init fails after acquiring it"

      # With the blocker gone, a retry acquires cleanly rather than being
      # refused by a leaked live-pid lock.
      File.rm_rf!(blocker)
      assert {:ok, pid} = Writer.start_link(dir: dir, session_id: s)
      GenServer.stop(pid)
    end
  end

  describe "write-failure resilience" do
    @tag :skip_on_ci
    test "a failing HEAD write does not crash the Writer", %{base: base, session: s} do
      if running_as_root?() do
        # root bypasses directory permissions, so the fault cannot be induced.
        :ok
      else
        {:ok, journal} = FileStore.open(s, base_dir: base)
        dir = Path.join(base, s)

        # Read-only session dir: the already-open segment fd still appends, but
        # creating the HEAD temp file fails — which must be logged, not fatal.
        File.chmod!(dir, 0o500)

        log =
          capture_log(fn ->
            assert {:ok, _offset} = FileStore.append(journal, event())
          end)

        assert Process.alive?(journal.writer)
        assert log =~ "write failed" or log == ""

        # A second append still succeeds — the Writer is not wedged.
        assert {:ok, _} = FileStore.append(journal, event())

        File.chmod!(dir, 0o700)
        FileStore.close(journal)
      end
    end
  end

  defp running_as_root? do
    case System.cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out) == "0"
      _ -> false
    end
  end
end
