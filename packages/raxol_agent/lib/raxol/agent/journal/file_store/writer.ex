defmodule Raxol.Agent.Journal.FileStore.Writer do
  @moduledoc """
  The single-writer GenServer for one session's journal (see
  `docs/harness/architecture.md`, "Journal and projection").

  Exactly one Writer per session enforces the single-writer invariant. It:

    * appends framed JSONL (one complete self-delimited JSON object per line),
      assigning each event a monotonic `offset` = the event's id;
    * batches `:file.datasync` on mailbox drain with a `≤200ms` ceiling, but syncs
      **immediately** for side-effect events (`tool_result`, `approval`, ...);
    * never uses `delayed_write`;
    * rotates to the next `NNNNNN.jsonl` segment when one passes the size cap;
    * writes `meta.json` and `HEAD` **atomically only** (temp + fsync + rename).

  `HEAD` records the last *durable* offset (+ config) and is persisted together
  with each datasync, never in place.

  ## Single-writer across OS processes

  The process name is `{:global, {Writer, dir}}`, but `:global` only spans a
  CONNECTED cluster — two unclustered OS processes on one session dir would
  each start a Writer and mint duplicate offsets, permanently damaging the
  journal. A pid lock file (`writer.lock`) closes the same-host case: it is
  acquired at init and released on terminate, a stale lock (dead holder) is
  reclaimed via `kill -0`, and init refuses (`{:stop, {:journal_locked, _}}`)
  ONLY when a confirmed-live foreign process holds it. The lock fails OPEN
  (proceeds lockless) where it cannot prove liveness (non-Unix / no `kill`) so
  a lock-subsystem hiccup can never block journaling. Residual: two processes
  both reclaiming the same stale lock in the same instant still race.

  A refusal is `:ignore`, never `{:stop, reason}`: an abnormal init exit also
  reaches the linked opener as an exit signal, which kills a non-trapping
  caller before it can read the `{:error, _}` return. Refusing to journal must
  degrade the session, not end it — `FileStore.open/2` turns the `:ignore`
  into `{:error, {:journal_locked, _}}` and the surface carries on unjournaled.

  ## Write-failure tolerance

  A failing disk (e.g. ENOSPC) surfaces as a logged
  `[:raxol, :agent, :journal, :write_failed]` event, never a Writer crash: the
  append's own `:file.write` already returns `{:error, _}`, and the follow-on
  `datasync`, `HEAD`/`meta` atomic writes, and segment rotation all degrade
  (log + continue, retry on the next append) rather than MatchError-exiting the
  process out from under every open handle on the session.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Journal.FileStore.Reader

  @default_segment_cap 8 * 1024 * 1024
  @default_sync_ceiling_ms 200
  @default_immediate_types ["tool_result", "approval"]
  @default_schema_version "1.1.0"
  @lock_file "writer.lock"

  defstruct [
    :session_id,
    :dir,
    :journal_dir,
    :io,
    :seg_num,
    :seg_size,
    :seg_cap,
    :offset,
    :schema_version,
    :immediate_types,
    :sync_ceiling_ms,
    :sync_timer,
    # The path of the cross-process lock file when THIS Writer owns it; nil
    # when the lock was skipped (non-Unix / no `kill`) or not acquired.
    :lock_path,
    dirty: false
  ]

  # --- API -------------------------------------------------------------------

  @doc """
  The `schema_version` stamped on records written without an explicit override.

  Bumping this is a freeze event: `scripts/check_journal_goldens.exs` refuses a
  bump that arrives without a frozen golden corpus for the version being left
  behind, so every historical shape stays replayable by a future
  upcast-on-read. Freeze one with `scripts/freeze_golden_journal.exs`.
  """
  @spec default_schema_version() :: String.t()
  def default_schema_version, do: @default_schema_version

  def start_link(opts) do
    dir = Keyword.fetch!(opts, :dir)
    # Single-writer invariant: at most one Writer per physical journal dir,
    # globally (survives across processes and — on shared storage — nodes).
    # A second `start_link` for the same dir returns `{:error, {:already_started, pid}}`
    # so the opener can reuse the live Writer instead of racing a second one.
    GenServer.start_link(__MODULE__, opts, name: global_name(dir))
  end

  @doc false
  def global_name(dir), do: {:global, {__MODULE__, dir}}

  @spec append(pid(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(pid, event), do: GenServer.call(pid, {:append, event})

  @doc """
  Atomic check-and-append: run `check` against the freshest on-disk records
  and append `event` only if it returns `:ok` — as ONE step inside the single
  Writer, so no other append can interleave between the check and the append.

  Closes the read-then-append race of a caller that validates against its own
  (possibly stale) `read` snapshot: e.g. the checkpoint turn-boundary rule,
  where a concurrent `turn_started` through a shared joiner handle must not
  slip in between validation and commit.

  `check` receives the current record list and returns `:ok` or `{:error,
  reason}` (relayed verbatim; nothing appended). A raising `check` replies
  `{:error, {:check_raised, ...}}` — fail-closed — rather than crashing the
  Writer out from under every other handle on the session.
  """
  @spec append_checked(pid(), map(), ([map()] -> :ok | {:error, term()})) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append_checked(pid, event, check) when is_function(check, 1),
    do: GenServer.call(pid, {:append_checked, event, check})

  @spec flush(pid()) :: :ok
  def flush(pid), do: GenServer.call(pid, :flush)

  # --- lifecycle -------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    dir = Keyword.fetch!(opts, :dir)
    session_id = Keyword.fetch!(opts, :session_id)
    journal_dir = Path.join(dir, "journal")

    File.mkdir_p!(journal_dir)
    File.mkdir_p!(Path.join(dir, "snapshots"))
    sweep_tmp_files(dir)

    # Cross-process single-writer lock. `:global` (the process name) only spans
    # a CONNECTED cluster, so two unclustered OS processes on one session dir
    # would each start a Writer and mint duplicate offsets, permanently
    # damaging the journal. A pid lock file closes the same-host case; it fails
    # OPEN (proceeds without a lock) on any uncertainty, and refuses ONLY when
    # the holder is a confirmed-live foreign OS process.
    case acquire_lock(dir) do
      {:ok, lock_path} ->
        try do
          init_after_lock(opts, dir, session_id, journal_dir, lock_path)
        rescue
          error ->
            release_lock_on_init_failure(lock_path)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            release_lock_on_init_failure(lock_path)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:refused, holder} ->
        # `:ignore`, NOT `{:stop, reason}`. An abnormal init exit is delivered
        # to the linked caller as an exit SIGNAL as well as an `{:error, _}`
        # return, so a non-trapping opener (the TUI dispatcher, via
        # `FileStore.open/2`) dies of it before it can handle the error — and
        # the whole point of refusing is to protect the journal, not to take
        # the session down with it. `:ignore` exits `:normal`, so `start_link`
        # returns cleanly and `FileStore.open/2` maps it to the documented
        # `{:error, {:journal_locked, _}}`.
        Logger.warning(
          "journal writer refused: #{inspect(dir)} is locked by live " <>
            "OS process #{inspect(holder)}"
        )

        :ignore
    end
  end

  # An init failure AFTER the lock was taken (a segment open on a full disk, a
  # stat race) never reaches terminate, so the lock would be left holding THIS
  # live BEAM's pid — and every future open of the session would then be
  # refused (a confirmed-live holder) until the node restarts. Release it here.
  defp release_lock_on_init_failure(nil), do: :ok
  defp release_lock_on_init_failure(path), do: File.rm(path)

  defp init_after_lock(opts, dir, session_id, journal_dir, lock_path) do
    schema_version = Keyword.get(opts, :schema_version, @default_schema_version)
    seg_cap = Keyword.get(opts, :segment_cap, @default_segment_cap)

    immediate_types =
      opts
      |> Keyword.get(:immediate_sync_types, @default_immediate_types)
      |> MapSet.new(&to_string/1)

    write_meta(dir, opts, schema_version)

    offset = resume_offset(dir)
    {seg_num, seg_size} = current_segment(journal_dir, seg_cap)
    io = open_segment!(journal_dir, seg_num)

    state = %__MODULE__{
      session_id: session_id,
      dir: dir,
      journal_dir: journal_dir,
      io: io,
      seg_num: seg_num,
      seg_size: seg_size,
      seg_cap: seg_cap,
      offset: offset,
      schema_version: schema_version,
      immediate_types: immediate_types,
      sync_ceiling_ms: Keyword.get(opts, :sync_ceiling_ms, @default_sync_ceiling_ms),
      lock_path: lock_path
    }

    write_head(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:append, event}, _from, state), do: do_append(event, state)

  # Atomic check-and-append (see `append_checked/3`). The scan + check + append
  # all happen inside this one call: the Writer is the only appender, so the
  # records the check sees are exactly the records the append lands after.
  def handle_call({:append_checked, event, check}, _from, state) do
    # Everything already appended is visible to the Reader (raw writes, no
    # delayed_write); flush anyway so HEAD/durability match what we validate.
    state = flush_now(state)

    case Reader.scan(state.dir) do
      {:ok, records} ->
        case run_check(check, records) do
          :ok -> do_append(event, state)
          {:error, _} = err -> {:reply, err, state}
        end

      {:damaged, _partial} ->
        {:reply, {:error, :damaged}, state}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_now(state)}
  end

  @impl GenServer
  def handle_info(:flush_sync, state) do
    {:noreply, flush_now(%{state | sync_timer: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_check(check, records) do
    case check.(records) do
      :ok -> :ok
      {:error, _} = err -> err
      other -> {:error, {:check_raised, {:bad_return, other}}}
    end
  rescue
    e -> {:error, {:check_raised, Exception.message(e)}}
  end

  defp do_append(event, state) do
    offset = state.offset + 1
    record = stamp(event, offset, state.schema_version)
    line = [Jason.encode_to_iodata!(record), ?\n]

    # A write can fail (e.g. `:enospc` on a full disk). Surface it as an error
    # instead of MatchError-crashing the Writer: the offset is NOT advanced, the
    # fd/state stay intact, and the caller can retry once space frees up.
    case :file.write(state.io, line) do
      :ok ->
        state =
          %{
            state
            | offset: offset,
              seg_size: state.seg_size + IO.iodata_length(line)
          }
          |> maybe_rotate()
          |> sync_after_append(immediate?(record, state))

        {:reply, {:ok, offset}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    state = flush_now(state)
    if state.io, do: :file.close(state.io)
    # Free the global name synchronously (before the process exits) so a
    # close-then-reopen on the same dir never races the async :global cleanup
    # and gets handed the corpse of the writer we just stopped.
    if state.dir, do: :global.unregister_name({__MODULE__, state.dir})
    # Release the cross-process lock so the next opener re-acquires cleanly
    # (a crash leaves it behind, but the stale-pid reclaim below handles that).
    if state.lock_path, do: File.rm(state.lock_path)
    :ok
  end

  # --- append helpers --------------------------------------------------------

  defp stamp(event, offset, default_schema) when is_map(event) do
    event
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("id", offset)
    |> Map.put_new("schema_version", default_schema)
  end

  defp immediate?(record, state) do
    type = Map.get(record, "type")
    is_binary(type) and MapSet.member?(state.immediate_types, type)
  end

  # Batched datasync: side-effect events sync immediately; otherwise flush as
  # soon as the mailbox is drained, bounded by the ≤200ms ceiling timer.
  defp sync_after_append(state, true), do: flush_now(state)

  defp sync_after_append(state, false) do
    state = %{state | dirty: true}

    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, 0} -> flush_now(state)
      _ -> ensure_timer(state)
    end
  end

  defp ensure_timer(%{sync_timer: nil} = state) do
    ref = Process.send_after(self(), :flush_sync, state.sync_ceiling_ms)
    %{state | sync_timer: ref}
  end

  defp ensure_timer(state), do: state

  defp flush_now(%{dirty: false, sync_timer: nil} = state), do: state

  defp flush_now(state) do
    case safe_datasync(state) do
      :ok ->
        if state.sync_timer, do: Process.cancel_timer(state.sync_timer)
        state = %{state | dirty: false, sync_timer: nil}
        write_head(state)
        state

      :error ->
        # Durability could not be confirmed (e.g. a full disk). Do NOT crash
        # the Writer — the already-buffered bytes are not lost, and keeping
        # `dirty: true` lets a later flush retry once space frees. Drop the
        # timer so we do not spin retrying on a wedged disk.
        if state.sync_timer, do: Process.cancel_timer(state.sync_timer)
        %{state | sync_timer: nil}
    end
  end

  # datasync can fail on a full/failing disk; never let that MatchError-crash
  # the Writer out from under every open handle on the session.
  defp safe_datasync(%{io: nil}), do: :ok

  defp safe_datasync(%{io: io}) do
    case :file.datasync(io) do
      :ok -> :ok
      {:error, reason} -> write_failed(:datasync, reason)
    end
  end

  # --- segment rotation ------------------------------------------------------

  # Open the NEXT segment BEFORE closing the current one, so a failed open
  # (e.g. ENOSPC) leaves the Writer appending to the current (over-cap) segment
  # rather than crashing or dropping its fd. Retried on the next append.
  defp maybe_rotate(%{seg_size: size, seg_cap: cap} = state) when size >= cap do
    seg_num = state.seg_num + 1

    case open_segment(state.journal_dir, seg_num) do
      {:ok, io} ->
        _ = safe_datasync(state)
        if state.io, do: :file.close(state.io)
        %{state | io: io, seg_num: seg_num, seg_size: 0}

      {:error, reason} ->
        _ = write_failed(:rotate, reason)
        state
    end
  end

  defp maybe_rotate(state), do: state

  defp open_segment(journal_dir, seg_num) do
    path = Path.join(journal_dir, segment_name(seg_num))
    # :raw + :append, never :delayed_write (durability guarantees depend on it).
    :file.open(path, [:append, :raw, :binary])
  end

  defp open_segment!(journal_dir, seg_num) do
    case open_segment(journal_dir, seg_num) do
      {:ok, io} ->
        io

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open", path: segment_name(seg_num)
    end
  end

  defp current_segment(journal_dir, seg_cap) do
    case Reader.list_segments(journal_dir) do
      [] ->
        {1, 0}

      segments ->
        path = List.last(segments)

        num =
          path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()

        size = File.stat!(path).size
        if size >= seg_cap, do: {num + 1, 0}, else: {num, size}
    end
  end

  defp segment_name(seg_num) do
    :io_lib.format(~c"~6..0B.jsonl", [seg_num]) |> List.to_string()
  end

  # --- meta.json / HEAD (atomic writes only) ---------------------------------

  # HEAD is only rewritten on flush (≤200ms / datasync), but `:file.write`
  # already reached the OS ahead of it — so after a crash HEAD can lag the real
  # journal. Trusting HEAD alone would reuse an already-written offset (duplicate
  # id, non-monotonic, id ≠ offset). Resume from the max of HEAD and the reader's
  # torn-tail-recovered real last offset, so id stays monotonic and == offset.
  defp resume_offset(dir) do
    max(head_offset(dir), Reader.last_offset(dir))
  end

  defp head_offset(dir) do
    case read_head(dir) do
      {:ok, %{"offset" => offset}} when is_integer(offset) -> offset
      _ -> 0
    end
  end

  defp read_head(dir) do
    with {:ok, body} <- File.read(Path.join(dir, "HEAD")) do
      Jason.decode(body)
    end
  end

  # HEAD lagging the real journal is already tolerated on resume (resume_offset
  # takes the max of HEAD and the reader's recovered last offset), so a failed
  # HEAD write is logged and swallowed rather than crashing the Writer.
  defp write_head(state) do
    head = %{
      "offset" => state.offset,
      "segment" => state.seg_num,
      "segment_cap" => state.seg_cap,
      "schema_version" => state.schema_version
    }

    case atomic_write(Path.join(state.dir, "HEAD"), Jason.encode_to_iodata!(head)) do
      :ok -> :ok
      {:error, reason} -> write_failed(:head, reason)
    end
  end

  defp write_meta(dir, opts, schema_version) do
    path = Path.join(dir, "meta.json")

    unless File.exists?(path) do
      cwd = Keyword.get(opts, :cwd) || File.cwd!()

      meta = %{
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "cwd" => cwd,
        "git_branch" => Keyword.get(opts, :git_branch) || git_branch(cwd),
        "title" => Keyword.get(opts, :title),
        "schema_version" => schema_version
      }

      case atomic_write(path, Jason.encode_to_iodata!(meta)) do
        :ok -> :ok
        {:error, reason} -> write_failed(:meta, reason)
      end
    end
  end

  # Best-effort current branch from <cwd>/.git/HEAD; nil if not a git repo.
  defp git_branch(cwd) do
    with {:ok, body} <- File.read(Path.join([cwd, ".git", "HEAD"])),
         "ref: refs/heads/" <> branch <- String.trim(body) do
      branch
    else
      _ -> nil
    end
  end

  # Non-raising: a full/failing disk returns {:error, reason} so the caller can
  # log and continue instead of crashing the Writer mid-append.
  defp atomic_write(path, data) do
    tmp =
      path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- write_temp(tmp, data),
         :ok <- :file.rename(tmp, path) do
      # Durability of the rename itself needs the *directory* entry flushed,
      # else a power loss can lose the newly-renamed name. Best-effort (some
      # platforms reject datasync on a dir fd — fine, the rename still stands).
      sync_dir(Path.dirname(path))
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp write_temp(tmp, data) do
    case :file.open(tmp, [:write, :raw, :binary]) do
      {:ok, io} ->
        result = with :ok <- :file.write(io, data), do: :file.datasync(io)
        _ = :file.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_failed(stage, reason) do
    Logger.warning("journal writer #{stage} write failed: #{inspect(reason)}")

    :telemetry.execute(
      [:raxol, :agent, :journal, :write_failed],
      %{},
      %{stage: stage, reason: reason}
    )

    :error
  end

  # --- cross-process single-writer lock --------------------------------------

  # Acquire the pid lock for `dir`. Returns `{:ok, lock_path | nil}` to proceed
  # (lock_path is nil when locking is unavailable — we degrade rather than block
  # journaling) or `{:refused, holder_pid}` only when a CONFIRMED-live foreign
  # OS process already holds it.
  @doc """
  The OS pid holding `dir`'s writer lock when it is a CONFIRMED-LIVE foreign
  process, else `nil` (no lock, a stale one, our own, or liveness unprovable).

  A read-only pre-flight for `FileStore.open/2`, so a refusal is reported as
  a plain `{:error, {:journal_locked, holder}}` naming the holder. It does not
  replace the claim in `init/1` — that is the authority, this is the message.
  """
  @spec lock_holder(Path.t()) :: String.t() | nil
  def lock_holder(dir) do
    with true <- lockable?(),
         {:ok, contents} <- File.read(Path.join(dir, @lock_file)),
         holder when holder != "" <- String.trim(contents),
         false <- holder == System.pid(),
         true <- os_pid_alive?(holder) do
      holder
    else
      _no_live_foreign_holder -> nil
    end
  end

  defp acquire_lock(dir) do
    if lockable?() do
      claim_lock(Path.join(dir, @lock_file), System.pid())
    else
      {:ok, nil}
    end
  end

  defp claim_lock(path, our_pid) do
    case File.write(path, our_pid, [:exclusive]) do
      :ok ->
        {:ok, path}

      {:error, :eexist} ->
        resolve_existing_lock(path, our_pid)

      {:error, reason} ->
        # Could not even create the lock (e.g. a read-only dir): do not block
        # journaling on the lock subsystem — proceed lockless with a warning.
        Logger.warning("journal writer lock create failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp resolve_existing_lock(path, our_pid) do
    case File.read(path) do
      {:ok, contents} ->
        holder = String.trim(contents)

        cond do
          holder == "" or holder == our_pid -> reclaim_lock(path, our_pid)
          os_pid_alive?(holder) -> {:refused, holder}
          true -> reclaim_lock(path, our_pid)
        end

      {:error, _reason} ->
        # Unreadable lock: treat as stale and reclaim (fail open).
        reclaim_lock(path, our_pid)
    end
  end

  defp reclaim_lock(path, our_pid) do
    case File.write(path, our_pid) do
      :ok -> {:ok, path}
      {:error, _reason} -> {:ok, nil}
    end
  end

  # Locking needs a way to prove the holder is dead before reclaiming a stale
  # lock; without that a crash would lock the session out forever. Only enable
  # it where `kill -0` can answer (Unix with a kill binary).
  defp lockable? do
    match?({:unix, _}, :os.type()) and System.find_executable("kill") != nil
  end

  defp os_pid_alive?(pid) do
    case System.find_executable("kill") do
      nil ->
        # Cannot determine liveness — assume alive so we never reclaim a lock
        # that might be held (fail toward refusing a second writer).
        true

      kill ->
        match?({_, 0}, System.cmd(kill, ["-0", pid], stderr_to_stdout: true))
    end
  rescue
    _ -> true
  end

  defp sync_dir(dir) do
    case :file.open(dir, [:read, :raw]) do
      {:ok, io} ->
        _ = :file.datasync(io)
        :file.close(io)

      _ ->
        :ok
    end

    :ok
  end

  # Remove stray `*.tmp.*` files left by a crash mid-atomic-write on a prior run.
  defp sweep_tmp_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          if String.contains?(name, ".tmp."), do: File.rm(Path.join(dir, name))
        end)

      _ ->
        :ok
    end
  end
end
