defmodule Raxol.Harness.EditorSessionTest do
  @moduledoc """
  Suite for `Raxol.Harness.EditorSession` -- the thin, impure runner that
  interprets `Raxol.Harness.EditorSuspend`'s machine against real (here:
  injected) side effects.

  Every seam is injected: a fake stty module recording calls, a fake
  reader-gate module, a fake `spawn_fun`, a `StringIO` device, a
  test-owned tmp dir. `run/2` is synchronous and executes in the CALLING
  process, so the fakes record through the test process's own process
  dictionary -- no agents, no races (each test still gets its own process,
  so `async: true` stays safe).

  Interleaving evidence: `StringIO` can't participate in a single shared
  recorder, so the stty/reader-gate fakes snapshot the device's
  bytes-so-far at call time -- "suspend bytes were on the device BEFORE
  stty restore ran" is assertable without a custom IO server.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.EditorSession
  alias Raxol.Terminal.InlineDriver.Sequences

  @rows 24
  @width 80

  # -- recording fakes (process-dictionary recorder; see moduledoc) ------

  defp events, do: Process.get(:editor_session_events, [])

  defp device_bytes do
    case Process.get(:editor_session_device) do
      nil ->
        ""

      device ->
        {_in, out} = StringIO.contents(device)
        out
    end
  end

  # `run/2` executes in the test process, so a fake that `send`s to
  # `self()` would deposit messages in the test mailbox -- workable, but
  # the process dictionary is simpler and strictly ordered. These
  # module-based fakes route through the pdict via the helpers above by
  # being called IN the test process.
  defmodule PdictStty do
    def restore(saved) do
      pdict_record({:stty_restore, saved, pdict_device_bytes()})
      :ok
    end

    def raw! do
      pdict_record({:stty_raw, pdict_device_bytes()})
      :ok
    end

    def size do
      pdict_record(:size)
      {:ok, 100, 30}
    end

    def pdict_record(event) do
      Process.put(
        :editor_session_events,
        Process.get(:editor_session_events, []) ++ [event]
      )
    end

    def pdict_device_bytes do
      case Process.get(:editor_session_device) do
        nil ->
          ""

        device ->
          {_in, out} = StringIO.contents(device)
          out
      end
    end
  end

  defmodule PdictReaderGate do
    def disable(reader) do
      PdictStty.pdict_record(
        {:disable_reader, reader, PdictStty.pdict_device_bytes()}
      )

      Process.get(:reader_gate_disable_result, :ok)
    end

    def enable(reader) do
      PdictStty.pdict_record(
        {:enable_reader, reader, PdictStty.pdict_device_bytes()}
      )

      Process.get(:reader_gate_enable_result, :ok)
    end
  end

  # Extracts the single-quoted tmp path from the spawned shell command
  # (`shell_quote/1` wraps in single quotes; test paths carry none).
  defp quoted_path(cmd) do
    [_pre, path | _rest] = String.split(cmd, "'")
    path
  end

  defp base_opts(device, tmp_dir, spawn_fun) do
    Process.put(:editor_session_device, device)

    [
      device: device,
      rows: @rows,
      width: @width,
      stty: PdictStty,
      reader_gate: PdictReaderGate,
      reader: self(),
      env: %{"EDITOR" => "fake-editor"},
      tmp_dir: tmp_dir,
      spawn_fun: spawn_fun
    ]
  end

  defp fresh_tmp_dir(context_line) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_editor_session_#{context_line}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp event_names do
    Enum.map(events(), fn
      {name, _a} -> name
      {name, _a, _b} -> name
      name when is_atom(name) -> name
    end)
  end

  # ---------------------------------------------------------------------
  # happy path
  # ---------------------------------------------------------------------

  test "happy path: side-effect order, edited text returned, tmp file gone" do
    tmp_dir = fresh_tmp_dir("happy")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn cmd ->
      PdictStty.pdict_record({:spawn, cmd})
      path = quoted_path(cmd)
      # a POSIX editor: saves the buffer with exactly one trailing newline
      File.write!(path, "edited draft\n")
      0
    end

    result =
      EditorSession.run(
        "original draft",
        base_opts(device, tmp_dir, spawn_fun)
      )

    assert {:ok, %{text: "edited draft", width: 100, rows: 30}} = result

    # the recorded side-effect order, exactly
    assert event_names() == [
             :disable_reader,
             :stty_restore,
             :spawn,
             :size,
             :stty_raw,
             :enable_reader
           ]

    # interleaving evidence via bytes-so-far snapshots:
    # nothing on the device before the reader was disabled...
    assert [{:disable_reader, _reader, bytes_at_disable} | _] = events()
    assert bytes_at_disable == ""

    # ...the suspend bytes were written BEFORE the stty restore ran...
    {:stty_restore, nil, bytes_at_restore} =
      Enum.find(events(), &match?({:stty_restore, _, _}, &1))

    assert bytes_at_restore =~ Sequences.suspend_bytes(@rows)

    # ...and init_bytes only landed AFTER the reader was re-enabled.
    {:enable_reader, _reader, bytes_at_enable} =
      Enum.find(events(), &match?({:enable_reader, _, _}, &1))

    refute bytes_at_enable =~ Sequences.init_bytes()
    assert device_bytes() =~ Sequences.init_bytes()

    # tmp file gone
    assert File.ls!(tmp_dir) == []
  end

  # ---------------------------------------------------------------------
  # editor exit statuses
  # ---------------------------------------------------------------------

  test "editor exits 3 -> {:kept, :editor_nonzero, geo}; resume still ran; tmp gone" do
    tmp_dir = fresh_tmp_dir("nonzero")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn cmd ->
      PdictStty.pdict_record({:spawn, cmd})
      # editor scribbled something before dying -- must NOT come back
      File.write!(quoted_path(cmd), "half-saved garbage\n")
      3
    end

    result =
      EditorSession.run("keep me", base_opts(device, tmp_dir, spawn_fun))

    assert {:kept, :editor_nonzero, %{width: 100, rows: 30}} = result

    # resume side effects still ran despite the nonzero exit
    assert :stty_raw in event_names()
    assert :enable_reader in event_names()
    assert device_bytes() =~ Sequences.init_bytes()

    assert File.ls!(tmp_dir) == []
  end

  test "editor exits 127 -> {:kept, {:editor_not_found, cmd}, geo}" do
    tmp_dir = fresh_tmp_dir("notfound")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn _cmd -> 127 end

    result =
      EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))

    assert {:kept, {:editor_not_found, "fake-editor"}, %{width: 100, rows: 30}} =
             result

    assert File.ls!(tmp_dir) == []
  end

  test "port crash (:crashed from spawn_fun) -> {:kept, :editor_crashed, geo}" do
    tmp_dir = fresh_tmp_dir("crashed")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn _cmd -> :crashed end

    result =
      EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))

    assert {:kept, :editor_crashed, %{width: 100, rows: 30}} = result
    assert File.ls!(tmp_dir) == []
  end

  test "exit 0 but the tmp file was deleted by the editor -> {:kept, :reload_failed, geo}" do
    tmp_dir = fresh_tmp_dir("reload")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn cmd ->
      File.rm!(quoted_path(cmd))
      0
    end

    result =
      EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))

    assert {:kept, :reload_failed, %{width: 100, rows: 30}} = result
    assert File.ls!(tmp_dir) == []
  end

  # ---------------------------------------------------------------------
  # exception mid-run: compensation runs, then the exception propagates
  # ---------------------------------------------------------------------

  test "spawn_fun raises -> compensation ran (raw + enable recorded), tmp gone, exception propagates" do
    tmp_dir = fresh_tmp_dir("raise")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn _cmd -> raise "editor spawn exploded" end

    assert_raise RuntimeError, "editor spawn exploded", fn ->
      EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))
    end

    # the machine's recovery compensation was interpreted: raw_tty, then
    # enable_reader (in that order -- no cooked-echo race), then reinit
    names = event_names()
    raw_idx = Enum.find_index(names, &(&1 == :stty_raw))
    enable_idx = Enum.find_index(names, &(&1 == :enable_reader))
    assert raw_idx != nil and enable_idx != nil
    assert raw_idx < enable_idx
    assert device_bytes() =~ Sequences.init_bytes()

    # tmp gone even on the raise path (the try/after wrap)
    assert File.ls!(tmp_dir) == []
  end

  # ---------------------------------------------------------------------
  # reader-disable failure: abort BEFORE any bytes touch the device
  # ---------------------------------------------------------------------

  test "reader disable {:error, :timeout} -> {:error, {:reader_disable, :timeout}}, NO device bytes, tmp gone" do
    tmp_dir = fresh_tmp_dir("gate")
    {:ok, device} = StringIO.open("")

    Process.put(:reader_gate_disable_result, {:error, :timeout})

    spawn_fun = fn _cmd ->
      flunk("the editor must never be spawned when the reader gate fails")
    end

    result =
      EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))

    assert result == {:error, {:reader_disable, :timeout}}

    # never hand the tty to an editor while the BEAM reader competes for
    # its bytes -- and never release the screen either: zero device bytes.
    assert device_bytes() == ""

    assert File.ls!(tmp_dir) == []
  end

  # ---------------------------------------------------------------------
  # reader re-enable failure: DEGRADED, never silent (review CRITICAL)
  # ---------------------------------------------------------------------

  test "enable failure is reported as a degradation on the OK outcome -- never swallowed" do
    tmp_dir = fresh_tmp_dir("degraded_ok")
    {:ok, device} = StringIO.open("")

    Process.put(:reader_gate_enable_result, {:error, {:reader_down, :noproc}})

    spawn_fun = fn cmd ->
      File.write!(quoted_path(cmd), "edited\n")
      0
    end

    result =
      EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))

    assert {:ok,
            %{
              text: "edited",
              degraded: [{:enable_reader, {:reader_down, :noproc}}]
            }} = result

    # the resume still completed: modes re-inited despite the dead reader
    assert device_bytes() =~ Sequences.init_bytes()
    assert File.ls!(tmp_dir) == []
  end

  test "enable failure is reported as a degradation on KEPT outcomes too" do
    tmp_dir = fresh_tmp_dir("degraded_kept")
    {:ok, device} = StringIO.open("")

    Process.put(:reader_gate_enable_result, {:error, :timeout})

    spawn_fun = fn _cmd -> 3 end

    assert {:kept, :editor_nonzero, %{degraded: [{:enable_reader, :timeout}]}} =
             EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))
  end

  test "a clean run reports an EMPTY degradation list" do
    tmp_dir = fresh_tmp_dir("degraded_none")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn cmd ->
      File.write!(quoted_path(cmd), "x\n")
      0
    end

    assert {:ok, %{degraded: []}} =
             EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))
  end

  test "enable failure emits the reader_enable_failed telemetry event" do
    tmp_dir = fresh_tmp_dir("degraded_tel")
    {:ok, device} = StringIO.open("")
    parent = self()
    handler_id = "editor-session-test-#{:erlang.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:raxol, :harness, :editor, :reader_enable_failed],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Process.put(:reader_gate_enable_result, {:error, {:reader_down, :killed}})

    spawn_fun = fn cmd ->
      File.write!(quoted_path(cmd), "x\n")
      0
    end

    {:ok, _} = EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))

    assert_received {:telemetry, %{reason: {:reader_down, :killed}}}
  end

  # ---------------------------------------------------------------------
  # temp-file confidentiality (review security finding)
  # ---------------------------------------------------------------------

  @tag :unix_only
  test "the draft lives in a fresh 0700 per-run directory as a 0600 file -- never bare in the shared tmp dir" do
    tmp_dir = fresh_tmp_dir("perms")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn cmd ->
      path = quoted_path(cmd)
      %File.Stat{mode: file_mode} = File.stat!(path)
      dir = Path.dirname(path)
      %File.Stat{mode: dir_mode} = File.stat!(dir)

      PdictStty.pdict_record(
        {:perms, Bitwise.band(file_mode, 0o777), Bitwise.band(dir_mode, 0o777),
         dir}
      )

      File.write!(path, "x\n")
      0
    end

    {:ok, _} = EditorSession.run("secret draft", base_opts(device, tmp_dir, spawn_fun))

    {:perms, file_perms, dir_perms, draft_dir} =
      Enum.find(events(), &match?({:perms, _, _, _}, &1))

    assert file_perms == 0o600
    assert dir_perms == 0o700
    # a per-run SUBDIRECTORY of the injected tmp dir, not the tmp dir itself
    assert Path.dirname(draft_dir) == tmp_dir
    refute draft_dir == tmp_dir

    # the whole per-run directory is gone afterward
    assert File.ls!(tmp_dir) == []
  end

  @tag :unix_only
  test "draft creation is O_EXCL: a pre-existing file (or pre-planted symlink) is refused, never followed" do
    tmp_dir = fresh_tmp_dir("excl")

    existing = Path.join(tmp_dir, "existing.md")
    File.write!(existing, "already here")
    assert {:error, :eexist} = EditorSession.write_draft_file(existing, "draft")
    # the pre-existing content was NOT truncated or replaced
    assert File.read!(existing) == "already here"

    target = Path.join(tmp_dir, "attacker_target")
    File.write!(target, "victim file")
    link = Path.join(tmp_dir, "planted.md")
    :ok = :file.make_symlink(target, link)

    assert {:error, :eexist} = EditorSession.write_draft_file(link, "draft")
    # the symlink's target is untouched
    assert File.read!(target) == "victim file"
  end

  # ---------------------------------------------------------------------
  # editor timeout (review finding: unbounded synchronous wait)
  # ---------------------------------------------------------------------

  # The fake wedged editor is `sleep 3` spawned via sh — Unix-only tools;
  # on Windows the spawn fails instantly and the timeout path never runs.
  @tag :unix_only
  test "a wedged editor is bounded by :editor_timeout_ms -> {:kept, :editor_timeout, geo}" do
    tmp_dir = fresh_tmp_dir("timeout")
    {:ok, device} = StringIO.open("")

    # REAL default spawn (no :spawn_fun injected): "sleep 3" plays the
    # wedged editor; the 300ms bound must kill the wait long before the
    # 3s exit would deliver a status.
    opts =
      base_opts(device, tmp_dir, nil)
      |> Keyword.delete(:spawn_fun)
      |> Keyword.merge(
        env: %{"EDITOR" => "sleep 3 #"},
        editor_timeout_ms: 300
      )

    started = System.monotonic_time(:millisecond)
    result = EditorSession.run("draft", opts)
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:kept, :editor_timeout, %{}} = result
    assert elapsed < 2_000

    # the resume bracket still ran
    assert :stty_raw in event_names()
    assert File.ls!(tmp_dir) == []
  end

  test "spawn_fun returning :timeout maps to {:kept, :editor_timeout, geo}" do
    tmp_dir = fresh_tmp_dir("timeout_map")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn _cmd -> :timeout end

    assert {:kept, :editor_timeout, %{width: 100, rows: 30}} =
             EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))
  end

  # ---------------------------------------------------------------------
  # suspend-segment byte content
  # ---------------------------------------------------------------------

  test "suspend bytes: modes off, region release, autowrap, park -- no \\e[2J/\\e[3J, no trailing CRLF after the park" do
    tmp_dir = fresh_tmp_dir("bytes")
    {:ok, device} = StringIO.open("")

    spawn_fun = fn cmd ->
      # snapshot the SUSPEND segment: everything written before the
      # editor ran
      PdictStty.pdict_record({:suspend_segment, PdictStty.pdict_device_bytes()})
      File.write!(quoted_path(cmd), "x\n")
      0
    end

    {:ok, _} = EditorSession.run("draft", base_opts(device, tmp_dir, spawn_fun))

    {:suspend_segment, suspend_segment} =
      Enum.find(events(), &match?({:suspend_segment, _}, &1))

    park = "\e[#{@rows};1H"

    assert suspend_segment =~ Sequences.modes_off()
    assert suspend_segment =~ "\e[r"
    assert suspend_segment =~ "\e[?7h\e[?25h"
    assert suspend_segment =~ park

    refute suspend_segment =~ "\e[2J"
    refute suspend_segment =~ "\e[3J"

    # the park is the LAST thing in the suspend segment -- no trailing
    # CRLF (the teardown-vs-suspend distinction: a CRLF here would scroll
    # a stale footer row into un-repaintable history)
    assert String.ends_with?(suspend_segment, park)
    refute suspend_segment =~ park <> "\r\n"

    # ordering: modes off, then release, then autowrap, then park
    {modes_idx, _} = :binary.match(suspend_segment, Sequences.modes_off())
    {release_idx, _} = :binary.match(suspend_segment, "\e[r")
    {autowrap_idx, _} = :binary.match(suspend_segment, "\e[?7h\e[?25h")
    {park_idx, _} = :binary.match(suspend_segment, park)

    assert modes_idx < release_idx
    assert release_idx < autowrap_idx
    assert autowrap_idx < park_idx
  end
end
