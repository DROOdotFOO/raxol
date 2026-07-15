defmodule Raxol.Agent.Invariants.FaultJournal do
  @moduledoc """
  Fault-injection harness for the invariant suite (see
  `docs/proposals/in-flight/harness-invariants.md`, meta-invariants section).

  Instruments the REAL `Raxol.Agent.Journal.FileStore` (no mock journal — the
  code under test is the production storage path) with five named fault sites:

    * `:append_fail`                  — the Writer's `:file.write` fails
      (`:enospc`-class): a dead fd is swapped into the live Writer so the next
      append returns `{:error, _}` from the production error arm, offset not
      advanced, Writer alive.
    * `:open_fail`                    — `FileStore.open/2` fails: the session
      dir path is occupied by a regular file, so `File.mkdir_p!` in the
      Writer's `init/1` raises and `start_link` returns `{:error, _}`.
    * `:kill_after_write_before_head` — bytes reached the OS but the crash
      beat the HEAD rewrite: complete framed records are appended raw to the
      newest segment (exactly what a flushed `:file.write` leaves behind), then
      the Writer is killed, leaving HEAD stale behind the journal.
    * `:kill_after_head_before_publish` — journal + HEAD carry a record the
      live tail never saw: the record is appended through a shared (joiner)
      FileStore handle, bypassing the publish step.
    * `:writer_down`                  — the Writer process dies under a live
      handle; the next `append/2` through that handle returns
      `{:error, {:writer_down, _}}`.

  ## Meta-invariant support

    * **m1 dead-injector detection** — every site keeps a per-harness fire
      counter; `assert_all_fired!/2` fails the test if an armed site never
      fired. A dead injector = green lies.
    * **m2 seed-reproducible schedules** — fault schedules are StreamData
      generated, so a failing run prints the shrunk schedule and the ExUnit
      seed reproduces it exactly. `assert_all_fired!/2` takes the schedule so
      dead-injector failures also dump it.
    * **m6 oracle independence** — journal truth comes from `raw_scan/1` /
      `raw_records!/1`: a raw `File.read!` plus this module's OWN framed-line
      decoder. It never consults the Writer's in-memory offset or
      `FileStore.read/2`. Live truth is a subscriber process (the test
      process), never a publisher return value.
  """

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer

  @sites [
    :append_fail,
    :open_fail,
    :kill_after_write_before_head,
    :kill_after_head_before_publish,
    :writer_down
  ]

  @doc "All named fault sites."
  def sites, do: @sites

  # --- harness lifecycle (fire counters, m1) ---------------------------------

  @doc "Start a fresh harness (an Agent holding armed-site set + fire counters)."
  def new do
    {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
    pid
  end

  @doc "Arm a fault site: it MUST fire before `assert_all_fired!/2` or the test fails."
  def arm(harness, site) when site in @sites do
    Agent.update(harness, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    harness
  end

  @doc "Record that a site fired (called by the site injectors below)."
  def record_fired(harness, site) when site in @sites do
    Agent.update(harness, fn s ->
      %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
    end)

    :ok
  end

  @doc "Per-site fire counts."
  def fired(harness), do: Agent.get(harness, & &1.fired)

  @doc """
  Meta-invariant m1: fail if any armed site never fired (dead injector).

  `schedule` (any term) is included in the failure message so a failing run
  dumps its fault schedule alongside the ExUnit seed (m2).
  """
  def assert_all_fired!(harness, schedule \\ nil) do
    %{armed: armed, fired: fired} = Agent.get(harness, & &1)
    dead = Enum.filter(armed, fn site -> Map.get(fired, site, 0) == 0 end)

    if dead != [] do
      raise ExUnit.AssertionError,
        message:
          "dead injector(s): armed fault site(s) never fired: #{inspect(dead)}\n" <>
            "fired counts: #{inspect(fired)}\n" <>
            "schedule: #{inspect(schedule)}"
    end

    fired
  end

  # --- fault sites ------------------------------------------------------------

  @doc """
  Site `:append_fail`: swap a dead (closed) fd into the live Writer so its next
  `:file.write` returns `{:error, _}` — the `:enospc` branch. Returns the
  original io term; pass it to `heal_append_fail/2` to restore the Writer.

  The dead fd is opened+closed INSIDE the Writer process (the replace_state fun
  runs there) so the Writer owns it.
  """
  def inject_append_fail(harness, writer, scratch_dir) do
    %{io: original} = :sys.get_state(writer)
    scratch = Path.join(scratch_dir, "dead_fd_#{System.unique_integer([:positive])}")

    :sys.replace_state(writer, fn state ->
      {:ok, dead} = :file.open(scratch, [:write, :raw, :binary])
      :ok = :file.close(dead)
      %{state | io: dead}
    end)

    record_fired(harness, :append_fail)
    original
  end

  @doc "Restore the Writer's real fd after `inject_append_fail/3`."
  def heal_append_fail(writer, original_io) do
    :sys.replace_state(writer, fn state -> %{state | io: original_io} end)
    :ok
  end

  @doc """
  Site `:open_fail`: occupy the session dir path with a regular file so
  `FileStore.open/2` (Writer `init/1` -> `File.mkdir_p!`) fails. Only valid for
  a session with no journal on disk yet.
  """
  def inject_open_fail(harness, session_id, base_dir) do
    path = Path.join(base_dir, session_id)

    if File.exists?(path) do
      raise "inject_open_fail is only valid before the session dir exists (#{path})"
    end

    File.write!(path, "not a directory — open_fail fault site")
    record_fired(harness, :open_fail)
    :ok
  end

  @doc "Remove the blocking file so the next open succeeds."
  def heal_open_fail(session_id, base_dir) do
    File.rm!(Path.join(base_dir, session_id))
    :ok
  end

  @doc """
  Site `:kill_after_write_before_head` (data half): append fully-framed,
  newline-terminated records raw to the newest segment — byte-for-byte what a
  flushed `:file.write` leaves when the crash beats the HEAD rewrite. Records
  must already carry `"id"` (continuing the sequence) and `"schema_version"`.

  Pair with `stop_writer/1` / `kill_writer_brutal/2` for the "kill" half; the
  Writer must NOT append again through its stale in-memory offset afterwards.
  """
  def inject_write_before_head(harness, dir, records) when is_list(records) do
    seg =
      case segment_paths(dir) do
        [] -> raise "no segment to raw-append into (journal empty at #{dir})"
        paths -> List.last(paths)
      end

    lines = Enum.map(records, &[Jason.encode_to_iodata!(&1), ?\n])
    File.write!(seg, IO.iodata_to_binary(lines), [:append])
    record_fired(harness, :kill_after_write_before_head)
    :ok
  end

  @doc """
  Site `:kill_after_head_before_publish`: append `record` through a joiner
  FileStore handle sharing the session's single Writer — journal + HEAD get the
  record, the live tail never does (the "crash after append, before publish"
  window made permanent). Returns the assigned offset.
  """
  def inject_head_before_publish(harness, session_id, base_dir, record) do
    {:ok, handle} = FileStore.open(session_id, base_dir: base_dir)
    {:ok, offset} = FileStore.append(handle, record)
    :ok = FileStore.close(handle)
    record_fired(harness, :kill_after_head_before_publish)
    offset
  end

  @doc """
  Site `:writer_down`: stop the Writer (graceful stop — terminate/2 frees the
  `:global` name synchronously, so a later reopen never races the cleanup).
  Any handle still holding this pid gets `{:error, {:writer_down, _}}`.
  """
  def stop_writer(harness, writer) do
    if Process.alive?(writer), do: GenServer.stop(writer)
    record_fired(harness, :writer_down)
    :ok
  end

  @doc """
  A REAL brutal kill (meta-invariant m7: no timer cheats for durability).
  `Process.exit(writer, :kill)` — terminate/2 never runs. Waits for the death
  and then for `:global` to release the Writer's name (the async cleanup a
  graceful stop does synchronously), so a reopen is deterministic.
  """
  def kill_writer_brutal(harness_or_nil, writer, dir) do
    # The Writer is linked to whoever opened it (usually the test process);
    # unlink first so the :killed exit models the writer dying alone, not the
    # whole world (a full-BEAM death needs no test to observe it).
    Process.unlink(writer)
    ref = Process.monitor(writer)
    Process.exit(writer, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      2_000 -> raise "writer did not die under :kill"
    end

    await_global_release(dir, 200)
    if harness_or_nil, do: record_fired(harness_or_nil, :writer_down)
    :ok
  end

  defp await_global_release(dir, tries) do
    case :global.whereis_name({Writer, dir}) do
      :undefined ->
        :ok

      _pid when tries > 0 ->
        Process.sleep(10)
        await_global_release(dir, tries - 1)

      pid ->
        raise "global writer name for #{dir} not released (still #{inspect(pid)})"
    end
  end

  # --- independent oracle (m6) -------------------------------------------------
  #
  # Journal truth via raw File.read! + our OWN line decoder. Never FileStore.read,
  # never the Writer's in-memory offset.

  @segment_re ~r/^\d{6}\.jsonl$/

  @doc "Segment file paths under `dir/journal`, ascending — raw `File.ls`, no Reader."
  def segment_paths(dir) do
    journal = Path.join(dir, "journal")

    case File.ls(journal) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@segment_re, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(journal, &1))

      {:error, _} ->
        []
    end
  end

  @typedoc """
  One raw-scan entry:
    * `{:ok, record, raw_line}` — a complete, decodable framed line
    * `{:corrupt, path, raw_line}` — a complete line that does not decode
    * `{:torn, path, raw_bytes}` — unterminated trailing bytes of the LAST segment
  """
  @type scan_entry ::
          {:ok, map(), String.t()}
          | {:corrupt, Path.t(), String.t()}
          | {:torn, Path.t(), String.t()}

  @doc """
  Independent decode of every segment. An unterminated trailing chunk of a
  non-last segment is classified `:corrupt` (bytes can only legally be torn at
  the very end of the journal).
  """
  @spec raw_scan(Path.t()) :: [scan_entry()]
  def raw_scan(dir) do
    segs = segment_paths(dir)
    last = List.last(segs)

    Enum.flat_map(segs, fn path ->
      raw = File.read!(path)
      {complete, torn} = complete_lines(raw)

      decoded =
        Enum.map(complete, fn line ->
          case Jason.decode(line) do
            {:ok, record} -> {:ok, record, line}
            {:error, _} -> {:corrupt, path, line}
          end
        end)

      case torn do
        nil -> decoded
        bytes when path == last -> decoded ++ [{:torn, path, bytes}]
        bytes -> decoded ++ [{:corrupt, path, bytes}]
      end
    end)
  end

  @doc "Decoded records from a journal expected to be fully healthy — raises on corrupt/torn entries."
  def raw_records!(dir) do
    Enum.map(raw_scan(dir), fn
      {:ok, record, _line} -> record
      other -> raise "journal at #{dir} is not clean: #{inspect(other)}"
    end)
  end

  @doc "Ids of a healthy journal, in file order."
  def raw_ids!(dir), do: dir |> raw_records!() |> Enum.map(& &1["id"])

  @doc "`{record, raw_line}` pairs of a healthy journal (for byte-identity checks)."
  def raw_lines!(dir) do
    Enum.map(raw_scan(dir), fn
      {:ok, record, line} -> {record, line}
      other -> raise "journal at #{dir} is not clean: #{inspect(other)}"
    end)
  end

  @doc "Raw HEAD read: `{:ok, map}`, `{:error, reason}` (unparseable), or `:missing`."
  def raw_head(dir) do
    case File.read(Path.join(dir, "HEAD")) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} -> {:ok, map}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        :missing
    end
  end

  # Split raw segment bytes into complete (newline-terminated) lines and an
  # optional torn (unterminated) trailing chunk. Blank lines are dropped, same
  # as the contract promises.
  defp complete_lines(""), do: {[], nil}

  defp complete_lines(raw) do
    parts = String.split(raw, "\n")

    {complete, torn} =
      if String.ends_with?(raw, "\n") do
        {Enum.drop(parts, -1), nil}
      else
        {Enum.drop(parts, -1), List.last(parts)}
      end

    {Enum.reject(complete, &(&1 == "")), torn}
  end

  # --- shared runtime setup helpers -------------------------------------------
  #
  # The bridge/session-based invariant tests need the same app-level singletons
  # the existing keystone tests bootstrap. Kept here so every module shares one
  # idiom.

  @doc false
  def ensure_registry(keys, name) do
    case Registry.start_link(keys: keys, name: name) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  @doc false
  def ensure_running({DynamicSupervisor, opts}) do
    case DynamicSupervisor.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  def ensure_running({mod, opts}) do
    case mod.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end
end
