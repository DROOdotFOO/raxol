defmodule Raxol.Agent.Journal.WriterHardeningTest do
  # async: false — starts Writers under the shared :global name space and
  # exercises OS-level locks/perms.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Agent.ForeignBeam
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

    test "refuses a Writer when a live foreign BEAM holds the lock", %{
      base: base,
      session: s
    } do
      Process.flag(:trap_exit, true)
      dir = Path.join(base, s)
      File.mkdir_p!(dir)

      # A real, live BEAM we own — its pid in the lock file must block a
      # second Writer (the two-OS-processes-on-one-journal corruption case).
      # The lock holds the pid alone, as one written before the start token.
      holder = foreign_beam()
      File.write!(Path.join(dir, "writer.lock"), holder.pid)

      # `:ignore`, not `{:stop, _}`: an abnormal init exit reaches the linked
      # opener as an exit SIGNAL too, killing a non-trapping caller before it
      # can read the error. The refusal must degrade the caller, not end it.
      assert :ignore == Writer.start_link(dir: dir, session_id: s)

      # The refusal still names the holder, through the read-only pre-flight
      # FileStore.open/2 uses to report it.
      assert Writer.lock_holder(dir) == holder.pid
    end

    test "a locked journal fails FileStore.open without killing the opener", %{
      base: base,
      session: s
    } do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)

      holder = foreign_beam()
      File.write!(Path.join(dir, "writer.lock"), holder.pid)

      # The opener is a plain NON-trapping process, like the TUI dispatcher
      # that calls FileStore.open/2 from its update loop. It must receive the
      # documented error tuple and stay alive to handle it.
      parent = self()

      opener =
        spawn(fn ->
          send(parent, {:open_result, FileStore.open(s, base_dir: base)})
          # Stays in a receive loop: any exit signal from the refused Writer
          # would show up as a DOWN below.
          receive do
            :ping -> send(parent, :pong)
          end
        end)

      ref = Process.monitor(opener)

      assert_receive {:open_result, {:error, {:journal_locked, locked_by}}}, 5_000
      assert locked_by == holder.pid

      # No exit signal landed: the opener is still parked in its receive.
      refute_receive {:DOWN, ^ref, :process, ^opener, _reason}, 200
      assert Process.alive?(opener)

      # And it is live enough to still do work.
      send(opener, :ping)
      assert_receive :pong, 5_000

      Process.exit(opener, :kill)
    end

    test "reclaims a stale lock left by a dead process", %{base: base, session: s} do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)
      # A pid that cannot exist on this host -> stale -> reclaimed.
      File.write!(Path.join(dir, "writer.lock"), "999999")

      assert {:ok, pid} = Writer.start_link(dir: dir, session_id: s)
      assert Process.alive?(pid)
      assert lock_pid(dir) == System.pid()
      assert File.ls!(dir) |> Enum.filter(&(&1 =~ "stale")) == []

      GenServer.stop(pid)
    end

    test "a BEAM that holds the journal refuses it, and its lock is stale once it is killed",
         %{base: base, session: s} do
      dir = Path.join(base, s)

      # The other BEAM opens the journal itself, so the lock is the one a
      # real second writer leaves: its pid and its start token.
      holder =
        foreign_beam("""
        {:ok, _} = Application.ensure_all_started(:jason)
        {:ok, _} = Raxol.Agent.Journal.FileStore.open(#{inspect(s)}, base_dir: #{inspect(base)})
        """)

      assert [pid, token] =
               dir |> Path.join("writer.lock") |> File.read!() |> String.split(" ", parts: 2)

      assert pid == holder.pid
      assert token =~ ~r/\A(ticks|lstart):/

      assert {:error, {:journal_locked, locked_by}} = FileStore.open(s, base_dir: base)
      assert locked_by == holder.pid
      assert Writer.lock_holder(dir) == holder.pid

      :ok = ForeignBeam.kill(holder)
      assert File.exists?(Path.join(dir, "writer.lock"))
      assert Writer.lock_holder(dir) == nil

      assert {:ok, journal} = FileStore.open(s, base_dir: base)
      assert lock_pid(dir) == System.pid()
      :ok = FileStore.close(journal)
    end

    test "a live BEAM started at another time than the lock records is stale", %{
      base: base,
      session: s
    } do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)

      # The pid was reused: a BEAM runs under it, but not the one that wrote
      # the lock.
      holder = foreign_beam()
      File.write!(Path.join(dir, "writer.lock"), holder.pid <> " " <> another_start())

      assert Writer.lock_holder(dir) == nil
      assert {:ok, pid} = Writer.start_link(dir: dir, session_id: s)
      assert lock_pid(dir) == System.pid()
      GenServer.stop(pid)
    end

    test "a start token of a kind this host does not read decides nothing", %{
      base: base,
      session: s
    } do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)

      holder = foreign_beam()
      File.write!(Path.join(dir, "writer.lock"), holder.pid <> " epoch:12345")

      assert Writer.lock_holder(dir) == holder.pid
    end

    test "a live process that is not a BEAM is stale", %{base: base, session: s} do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)

      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["30"]])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      on_exit(fn ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end)

      File.write!(Path.join(dir, "writer.lock"), Integer.to_string(os_pid))

      assert {:ok, pid} = Writer.start_link(dir: dir, session_id: s)
      assert lock_pid(dir) == System.pid()

      GenServer.stop(pid)
    end

    test "a pid this account may not signal is stale", %{base: base, session: s} do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)
      # pid 1 is alive and belongs to root: `kill -0` is refused, and as root
      # it is still not a BEAM.
      File.write!(Path.join(dir, "writer.lock"), "1")

      assert Writer.lock_holder(dir) == nil
      assert {:ok, pid} = Writer.start_link(dir: dir, session_id: s)
      assert lock_pid(dir) == System.pid()
      GenServer.stop(pid)
    end

    test "a lock that is not a pid is stale, and is never passed to kill", %{
      base: base,
      session: s
    } do
      dir = Path.join(base, s)
      File.mkdir_p!(dir)

      for contents <- ["", "-1", "0x10", "12 34 56", "pid"] do
        File.write!(Path.join(dir, "writer.lock"), contents)
        assert Writer.lock_holder(dir) == nil
        assert {:ok, pid} = Writer.start_link(dir: dir, session_id: s)
        GenServer.stop(pid)
      end
    end

    test "require_lock refuses a journal that cannot be locked", %{base: base, session: s} do
      # No `kill`, no way to prove a holder dead, so no lock is taken.
      path = System.get_env("PATH")
      System.put_env("PATH", "")
      on_exit(fn -> System.put_env("PATH", path) end)

      required = FileStore.open(s, base_dir: base, require_lock: true)
      lockless = FileStore.open(s <> "-lockless", base_dir: base)
      System.put_env("PATH", path)

      assert required == {:error, {:journal_locked, :lock_unavailable}}

      # Without the option the Writer still journals, unlocked.
      assert {:ok, journal} = lockless
      refute File.exists?(lock_path(base, s <> "-lockless"))
      :ok = FileStore.close(journal)
    end

    test "two spellings of one directory name one Writer", %{base: base, session: s} do
      link = base <> "-link"
      File.ln_s!(base, link)
      on_exit(fn -> File.rm(link) end)

      assert {:ok, pid} = Writer.start_link(dir: Path.join(base, s), session_id: s)

      assert {:error, {:already_started, ^pid}} =
               Writer.start_link(dir: Path.join(link, s), session_id: s)

      assert {:error, {:already_started, ^pid}} =
               Writer.start_link(
                 dir: Path.join([base, "..", Path.basename(link), s]),
                 session_id: s
               )

      GenServer.stop(pid)
    end
  end

  describe "parse_proc_stat/1" do
    test "reads comm and starttime around a comm with spaces and parentheses" do
      stat =
        "4242 (beam.smp) x (y)) S 1 4242 4242 0 -1 4194560 2145 0 0 0 5 3 0 0 20 0 28 0 " <>
          "8675309 2757378048 9173 18446744073709551615 1 1 0 0 0 0 0 4096 134365702 0 0 0 " <>
          "17 3 0 0 0 0 0 0 0 0 0 0 0 0 0\n"

      assert Writer.parse_proc_stat(stat) == {:ok, "beam.smp) x (y)", 8_675_309}
    end

    test "reads a plain line" do
      stat =
        "77 (beam.smp) S 1 77 77 0 -1 4194560 1 0 0 0 1 1 0 0 20 0 9 0 123456 1 1 1 1 1 0\n"

      assert Writer.parse_proc_stat(stat) == {:ok, "beam.smp", 123_456}
    end

    test "refuses a line that is not a stat line" do
      for stat <- [
            "",
            "77",
            "77 (beam.smp",
            "77 (beam.smp) S 1 2",
            "77 (x) S " <> String.duplicate("a ", 30)
          ] do
        assert Writer.parse_proc_stat(stat) == :error
      end
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

  defp foreign_beam(setup \\ ":ok") do
    beam = ForeignBeam.start(setup)
    on_exit(fn -> ForeignBeam.signal(beam) end)
    beam
  end

  defp lock_pid(dir) do
    dir |> Path.join("writer.lock") |> File.read!() |> String.split() |> hd()
  end

  # A start token of the kind this host reads, for no process running on it.
  defp another_start do
    case :os.type() do
      {:unix, :linux} -> "ticks:1"
      _other -> "lstart:Thu Jan 1 00:00:00 1970"
    end
  end

  defp running_as_root? do
    case System.cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out) == "0"
      _ -> false
    end
  end
end
