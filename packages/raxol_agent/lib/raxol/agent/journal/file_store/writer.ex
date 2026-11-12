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

  The process name is `{:global, {Writer, key}}`, keyed on the session
  directory's device and inode (its symlink-resolved path where a directory
  has no inode), so every spelling of one directory names one Writer. But
  `:global` only spans a CONNECTED cluster — two unclustered OS processes on
  one session dir would each start a Writer and mint duplicate offsets,
  permanently damaging the journal. A lock file (`writer.lock`) closes the
  same-host case. It holds the writer's OS pid and a token for when that BEAM
  started, and is removed on terminate if it is still this Writer's. The
  token is `ticks:<n>` on Linux (`starttime` in `/proc/<pid>/stat`, clock
  ticks since boot) and `lstart:<time>` elsewhere (`ps -o lstart=`, read with
  `LC_ALL=C TZ=UTC`). Linux does not use `ps`: procps derives `lstart` from
  the current time and the uptime on every run, so one process can print two
  start times.

  The lock appears already filled: its content is written to
  `writer.lock.tmp.<our pid>` and that file is linked to `writer.lock`, which
  fails if a lock exists. No reader sees an empty or partial lock, so an
  empty one is a leftover and stale.

  A holder counts as alive only when `kill -0 <pid>` succeeds and the pid is
  a `beam` whose start equals the recorded token, so a pid the OS reused for
  another program, or for a later BEAM, is stale. So is a pid `kill -0` may
  not signal (another account's process): a private journal's directory is
  0700, and no other account's BEAM can hold its lock. A lock with no token,
  or a token of another kind than this host reads, is judged by the pid and
  the `beam` name alone. A holder whose state cannot be read (`ps` fails, or
  this BEAM cannot read its own start) counts as alive: only "no such
  process" makes it gone. `kill` and `ps` are run from `/bin` or `/usr/bin`
  when they are there, and looked up on `PATH` only otherwise.

  A lock naming this BEAM's own pid is stale: a second Writer for the same
  directory cannot be running here.

  A stale lock is reclaimed by renaming it to `writer.lock.stale.<our pid>`
  (of several reclaimers exactly one rename succeeds) and then creating
  `writer.lock` as above. A reclaimer whose rename took a lock that is not
  the stale one it judged (another reclaimer finished in between) links it
  back and starts over. Residual: `writer.lock` does not exist between that
  rename and the link, and a third process creating it in that instant would
  leave two writers.

  Init refuses when a confirmed-live foreign BEAM holds the lock. Where no
  lock can be taken (non-Unix, no `kill`, the lock file cannot be created)
  the Writer proceeds without one, so a lock-subsystem hiccup never blocks
  journaling, unless it was started with `require_lock: true`: then it
  refuses too, and `FileStore.open/2` answers
  `{:error, {:journal_locked, :lock_unavailable}}`.

  A refusal is `:ignore`, never `{:stop, reason}`: an abnormal init exit also
  reaches the linked opener as an exit signal, which kills a non-trapping
  caller before it can read the `{:error, _}` return. `FileStore.open/2`
  turns the `:ignore` into `{:error, {:journal_locked, _}}`; what the opener
  does then is its own choice (a surface carries on unjournaled, a session
  that requires its journal does not start).

  ## Write-failure tolerance

  A failing disk (e.g. ENOSPC) surfaces as a logged
  `[:raxol, :agent, :journal, :write_failed]` event, never a Writer crash: the
  append's own `:file.write` already returns `{:error, _}`, and the follow-on
  `datasync`, `HEAD`/`meta` atomic writes, and segment rotation all degrade
  (log + continue, retry on the next append) rather than MatchError-exiting the
  process out from under every open handle on the session.

  ## Chained journals

  A journal created with `chain: true` records `"chain": true` in `meta.json`
  and is chained for life, whatever later openers pass. Each record is sealed
  by `Raxol.Agent.Journal.Chain` (`prev_hash` + `hash`), written as its
  canonical JSON, and `HEAD` carries the tip hash beside the durable offset.
  If the chain does not verify when the Writer starts, it refuses every
  append with `{:error, :damaged}` and leaves `HEAD` untouched: a broken
  chain cannot be extended, and its anchor is evidence.

  ## Private journals

  With `private: true` every file this Writer creates -- segments,
  `meta.json`, `HEAD`, `writer.lock` and the temp files behind atomic writes
  -- is chmod 0600 before a byte is written to it, and a segment it reopens
  is tightened the same way. `Raxol.Agent.Journal.FileStore.open/2` has
  already made the directories 0700, so no other account can open a file in
  the moment between its creation and the chmod.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Journal.Chain
  alias Raxol.Agent.Journal.FileStore.Reader

  @default_segment_cap 8 * 1024 * 1024
  @default_sync_ceiling_ms 200
  @default_immediate_types ["tool_result", "approval"]
  @default_schema_version "1.2.0"
  @lock_file "writer.lock"
  @claim_attempts 3

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
    # What this Writer wrote into the lock: it removes only a lock that still
    # says so.
    :lock_identity,
    # The key of this Writer's `:global` name.
    :name_key,
    # Chained journals only: `{:ok, tip_hash}` while the chain verifies,
    # `:damaged` when it did not at start. nil for an unchained journal.
    chain: nil,
    private?: false,
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
    # The name is keyed on the directory's inode, so the directory is made
    # first; `init/1` reports a directory that cannot be.
    _ = File.mkdir_p(dir)
    # Single-writer invariant: at most one Writer per physical journal dir,
    # globally (survives across processes and — on shared storage — nodes).
    # A second `start_link` for the same dir returns `{:error, {:already_started, pid}}`
    # so the opener can reuse the live Writer instead of racing a second one.
    GenServer.start_link(__MODULE__, opts, name: global_name(dir))
  end

  @max_links 32

  @doc false
  def global_name(dir), do: {:global, name_key(dir)}

  # The directory itself, however its path is spelled: another case on a
  # case-insensitive volume, a symlink, `..`. The path stands in only where
  # there is no inode to read.
  defp name_key(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{major_device: device, inode: inode}} when inode != 0 ->
        {__MODULE__, {device, inode}}

      _no_inode ->
        {__MODULE__, canonical(dir, @max_links)}
    end
  end

  # One spelling per directory: expanded, with every symlink on the way
  # resolved, so two paths to one journal cannot name two Writers.
  defp canonical(dir, links) do
    [root | parts] = dir |> Path.expand() |> Path.split()

    Enum.reduce(parts, root, fn part, resolved ->
      path = Path.join(resolved, part)

      case links > 0 and :file.read_link_all(path) do
        {:ok, target} ->
          target |> IO.chardata_to_string() |> Path.expand(resolved) |> canonical(links - 1)

        _not_a_link ->
          path
      end
    end)
  end

  @spec append(pid(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(pid, event), do: GenServer.call(pid, {:append, event})

  @doc """
  Append `events` as consecutive records in ONE Writer call, so no other
  append can land between them. Returns their offsets in order. Nothing is
  appended when any event fails to encode (or, on a chained journal, to seal).

  `timeout` bounds the call (default 5_000 ms). A caller that times out does
  not withdraw the request: it stays queued and the events land later.
  """
  @spec append_many(pid(), [map()], timeout()) :: {:ok, [non_neg_integer()]} | {:error, term()}
  def append_many(pid, events, timeout \\ 5_000) when is_list(events),
    do: GenServer.call(pid, {:append_many, events}, timeout)

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

    # Cross-process single-writer lock. `:global` (the process name) only spans
    # a CONNECTED cluster, so two unclustered OS processes on one session dir
    # would each start a Writer and mint duplicate offsets, permanently
    # damaging the journal. A pid lock file closes the same-host case. It
    # refuses when the holder is a confirmed-live foreign BEAM and, unless
    # `require_lock: true`, proceeds without a lock where none can be taken.
    identity = lock_identity()

    case acquire_lock(dir, identity, opts) do
      {:ok, lock_path} ->
        try do
          # Only now: before the claim, a temp file here may belong to the
          # Writer that holds the journal.
          sweep_tmp_files(dir)
          init_after_lock(opts, dir, session_id, journal_dir, {lock_path, identity})
        rescue
          error ->
            release_lock(lock_path, identity)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            release_lock(lock_path, identity)
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
        Logger.warning("journal writer refused: #{refusal(dir, holder)}")

        :ignore
    end
  end

  defp refusal(dir, :lock_unavailable),
    do: "no lock could be taken on #{inspect(dir)} and :require_lock is set"

  defp refusal(dir, holder),
    do: "#{inspect(dir)} is locked by live OS process #{inspect(holder)}"

  # The lock goes only while it still says what this Writer wrote: one that
  # another process has since claimed is that process's. An init failure
  # after the lock was taken never reaches `terminate/2`, so it releases here,
  # or the lock would name this live BEAM until the node restarts.
  defp release_lock(nil, _identity), do: :ok

  defp release_lock(path, identity) do
    case File.read(path) do
      {:ok, ^identity} -> File.rm(path)
      _not_ours -> :ok
    end
  end

  defp init_after_lock(opts, dir, session_id, journal_dir, {lock_path, lock_identity}) do
    schema_version = Keyword.get(opts, :schema_version, @default_schema_version)
    seg_cap = Keyword.get(opts, :segment_cap, @default_segment_cap)

    immediate_types =
      opts
      |> Keyword.get(:immediate_sync_types, @default_immediate_types)
      |> MapSet.new(&to_string/1)

    write_meta(dir, opts, schema_version)

    chained? = Keyword.get(opts, :chain, false) == true or Reader.chained?(dir)
    {offset, chain} = resume(dir, chained?)
    {seg_num, seg_size} = current_segment(journal_dir, seg_cap)
    io = open_segment!(journal_dir, seg_num, private?(opts))

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
      lock_path: lock_path,
      lock_identity: lock_identity,
      name_key: name_key(dir),
      chain: chain,
      private?: private?(opts)
    }

    write_head(state)
    {:ok, state}
  end

  defp private?(opts), do: Keyword.get(opts, :private, false) == true

  defp resume(dir, false), do: {resume_offset(dir), nil}

  # A chained journal resumes from its verified tip. The torn-tail repair in
  # `resume_scan/1` only ever cuts a line ABOVE the HEAD anchor (one that was
  # never synced); a cut below it is reported as damage instead.
  defp resume(dir, true) do
    case Reader.resume_scan(dir) do
      {:ok, []} -> {0, {:ok, Chain.genesis()}}
      {:ok, records} -> {List.last(records)["id"], {:ok, List.last(records)["hash"]}}
      {:damaged, _before} -> {head_offset(dir), :damaged}
    end
  end

  @impl GenServer
  def handle_call({:append, event}, _from, state), do: do_append(event, state)

  def handle_call({:append_many, events}, _from, state) do
    {reply, state} = append_records(events, state)
    {:reply, reply, state}
  end

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
    case append_records([event], state) do
      {{:ok, [offset]}, state} -> {:reply, {:ok, offset}, state}
      {error, state} -> {:reply, error, state}
    end
  end

  defp append_records([], state), do: {{:ok, []}, state}
  defp append_records(_events, %{chain: :damaged} = state), do: {{:error, :damaged}, state}

  defp append_records(events, state) do
    case frame_all(events, state) do
      {:ok, lines, records, tip} -> write_lines(lines, records, tip, state)
      {:error, _} = error -> {error, state}
    end
  end

  # Stamp and frame every event before writing any, threading the offset and,
  # on a chained journal, the tip hash. One failure appends nothing.
  defp frame_all(events, state) do
    events
    |> Enum.with_index(state.offset + 1)
    |> Enum.reduce_while({:ok, [], [], tip(state)}, &frame_event(&1, &2, state.schema_version))
    |> case do
      {:ok, lines, records, tip} -> {:ok, Enum.reverse(lines), records, tip}
      error -> error
    end
  end

  defp frame_event({event, offset}, {:ok, lines, records, tip}, schema_version) do
    record = stamp(event, offset, schema_version)

    case frame(record, tip) do
      {:ok, line, tip} -> {:cont, {:ok, [line | lines], [record | records], tip}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp tip(%{chain: {:ok, tip}}), do: tip
  defp tip(_state), do: nil

  defp frame(record, nil), do: {:ok, [Jason.encode_to_iodata!(record), ?\n], nil}

  defp frame(record, tip) do
    with {:ok, line, hash} <- Chain.seal(record, tip), do: {:ok, [line, ?\n], hash}
  end

  defp write_lines(lines, records, tip, state) do
    # A write can fail (e.g. `:enospc` on a full disk). Surface it as an error
    # instead of MatchError-crashing the Writer: the offset is NOT advanced, the
    # fd/state stay intact, and the caller can retry once space frees up.
    case :file.write(state.io, lines) do
      :ok ->
        first = state.offset + 1
        last = state.offset + length(lines)

        state =
          %{
            state
            | offset: last,
              seg_size: state.seg_size + IO.iodata_length(lines),
              chain: if(tip, do: {:ok, tip}, else: state.chain)
          }
          |> maybe_rotate()
          |> sync_after_append(Enum.any?(records, &immediate?(&1, state)))

        {{:ok, Enum.to_list(first..last)}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    state = flush_now(state)
    if state.io, do: :file.close(state.io)
    # The lock first, then the name: once the name is free a successor may
    # start, and it must not find this Writer about to remove a lock (a crash
    # leaves the lock behind, and the stale-lock reclaim handles that).
    release_lock(state.lock_path, state.lock_identity)
    # Free the global name synchronously (before the process exits) so a
    # close-then-reopen on the same dir never races the async :global cleanup
    # and gets handed the corpse of the writer we just stopped.
    if state.name_key, do: :global.unregister_name(state.name_key)
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

    case open_segment(state.journal_dir, seg_num, state.private?) do
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

  defp open_segment(journal_dir, seg_num, private?) do
    path = Path.join(journal_dir, segment_name(seg_num))

    # :raw + :append, never :delayed_write (durability guarantees depend on it).
    with {:ok, io} <- :file.open(path, [:append, :raw, :binary]) do
      case restrict(path, private?) do
        :ok ->
          {:ok, io}

        {:error, _reason} = error ->
          _ = :file.close(io)
          error
      end
    end
  end

  # Private journals: 0600 before the first byte (see the moduledoc).
  defp restrict(_path, false), do: :ok
  defp restrict(path, true), do: :file.change_mode(path, 0o600)

  defp open_segment!(journal_dir, seg_num, private?) do
    case open_segment(journal_dir, seg_num, private?) do
      {:ok, io} ->
        io

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "open",
          path: segment_name(seg_num)
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
    max(head_offset(dir), Reader.resume_last_offset(dir))
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
  #
  # A chained journal also anchors the tip hash here, written only after the
  # datasync that made `offset` durable: the Reader treats a record missing at
  # or below this offset as damage, never as a torn tail. A damaged chain's
  # HEAD is never rewritten.
  defp write_head(%{chain: :damaged}), do: :ok

  defp write_head(state) do
    head =
      %{
        "offset" => state.offset,
        "segment" => state.seg_num,
        "segment_cap" => state.seg_cap,
        "schema_version" => state.schema_version
      }
      |> put_tip(state.chain)

    case atomic_write(Path.join(state.dir, "HEAD"), Jason.encode_to_iodata!(head), state.private?) do
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

      meta = if Keyword.get(opts, :chain) == true, do: Map.put(meta, "chain", true), else: meta

      case atomic_write(path, Jason.encode_to_iodata!(meta), private?(opts)) do
        :ok -> :ok
        {:error, reason} -> write_failed(:meta, reason)
      end
    end
  end

  defp put_tip(head, {:ok, tip}), do: Map.put(head, "tip_hash", tip)
  defp put_tip(head, nil), do: head

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
  defp atomic_write(path, data, private?) do
    tmp =
      path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- write_temp(tmp, data, private?),
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

  # The rename carries the temp file's mode, so a private temp file makes a
  # private HEAD / meta.json.
  defp write_temp(tmp, data, private?) do
    case :file.open(tmp, [:write, :raw, :binary]) do
      {:ok, io} ->
        result =
          with :ok <- restrict(tmp, private?),
               :ok <- :file.write(io, data),
               do: :file.datasync(io)

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

  @doc "The path of `dir`'s writer lock file."
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(dir), do: Path.join(dir, @lock_file)

  @doc """
  The OS pid holding `dir`'s writer lock when it is a CONFIRMED-LIVE foreign
  BEAM, else `nil` (no lock, a stale one, our own, or liveness unprovable).

  A read-only pre-flight for `FileStore.open/2`, so a refusal is reported as
  a plain `{:error, {:journal_locked, holder}}` naming the holder. It does not
  replace the claim in `init/1` — that is the authority, this is the message.
  """
  @spec lock_holder(Path.t()) :: String.t() | nil
  def lock_holder(dir) do
    with true <- lockable?(),
         {:ok, contents} <- File.read(lock_path(dir)),
         {:live, holder} <- holder_state(contents) do
      holder
    else
      _no_live_foreign_holder -> nil
    end
  end

  # Returns `{:ok, lock_path}` to proceed holding the lock, `{:ok, nil}` to
  # proceed without one (locking is unavailable and was not required),
  # `{:refused, holder_pid}` when a confirmed-live foreign BEAM holds it, and
  # `{:refused, :lock_unavailable}` when `require_lock: true` and no lock
  # could be taken.
  defp acquire_lock(dir, identity, opts) do
    claimed =
      if lockable?() do
        sweep_lock_leftovers(dir)
        claim_lock(lock_path(dir), identity, private?(opts), @claim_attempts)
      else
        {:ok, nil}
      end

    case {claimed, Keyword.get(opts, :require_lock, false)} do
      {{:ok, nil}, true} -> {:refused, :lock_unavailable}
      {claimed, _required?} -> claimed
    end
  end

  # Two processes that both lose a round (a rename or a create) start over; a
  # claimer still losing after `@claim_attempts` rounds goes without a lock
  # rather than spin.
  defp claim_lock(path, _identity, _private?, 0) do
    Logger.warning(
      "journal writer lock not acquired on #{inspect(Path.dirname(path))}: " <>
        "kept losing the claim"
    )

    {:ok, nil}
  end

  defp claim_lock(path, identity, private?, attempts) do
    case create_lock(path, identity, private?) do
      :ok ->
        {:ok, path}

      {:error, :eexist} ->
        resolve_existing_lock(path, identity, private?, attempts)

      {:error, reason} ->
        # Could not even create the lock (e.g. a read-only dir): do not block
        # journaling on the lock subsystem — proceed lockless with a warning.
        Logger.warning("journal writer lock create failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp resolve_existing_lock(path, identity, private?, attempts) do
    case File.read(path) do
      {:ok, contents} ->
        case holder_state(contents) do
          {:live, holder} -> {:refused, holder}
          :stale -> reclaim_lock(path, contents, identity, private?, attempts)
        end

      {:error, :enoent} ->
        # Released between the create and the read.
        claim_lock(path, identity, private?, attempts - 1)

      {:error, _reason} ->
        # Unreadable lock: treat as stale and reclaim (fail open).
        reclaim_lock(path, :unreadable, identity, private?, attempts)
    end
  end

  # `{:live, pid}` for a lock a live foreign BEAM holds; `:stale` for an empty
  # or malformed one, one naming this BEAM's own pid (left by a Writer here
  # that never ran `terminate/2`, or by an earlier process with the same pid)
  # and one whose holder is gone.
  defp holder_state(contents) do
    with [pid | start] <- String.split(String.trim(contents), " ", parts: 2),
         true <- Regex.match?(~r/\A\d+\z/, pid),
         false <- pid == System.pid(),
         true <- holder_alive?(pid, parse_start(List.first(start))) do
      {:live, pid}
    else
      _ -> :stale
    end
  end

  defp reclaim_lock(path, stale_contents, identity, private?, attempts) do
    aside = path <> ".stale." <> System.pid()

    case :file.rename(path, aside) do
      :ok ->
        discard_or_restore(aside, path, stale_contents)
        claim_lock(path, identity, private?, attempts - 1)

      {:error, _reason} ->
        # Another reclaimer's rename won; it creates the lock next.
        claim_lock(path, identity, private?, attempts - 1)
    end
  end

  # The rename is by name, so it may have taken a lock created after the stale
  # one was judged. Only the stale one is discarded; any other goes back, by a
  # link, which never replaces a lock created since.
  defp discard_or_restore(aside, _path, :unreadable), do: File.rm_rf(aside)

  defp discard_or_restore(aside, path, stale_contents) do
    case File.read(aside) do
      {:ok, ^stale_contents} ->
        File.rm(aside)

      _taken_from_a_new_holder ->
        _ = File.ln(aside, path)
        File.rm(aside)
    end
  end

  # The lock is linked into place from a file that already holds the identity
  # (0600 first, for a private journal), so it never exists empty or half
  # written, and the link fails with `:eexist` if a lock is there.
  defp create_lock(path, identity, private?) do
    tmp = path <> ".tmp." <> System.pid()

    result =
      with :ok <- write_temp(tmp, identity, private?),
           do: :file.make_link(tmp, path)

    _ = File.rm(tmp)
    result
  end

  # What a claimer killed mid-claim left behind: its temp file, or a lock it
  # had renamed aside. One of a live process is in use and stays.
  defp sweep_lock_leftovers(dir) do
    with {:ok, names} <- File.ls(dir) do
      for name <- names,
          [_name, pid] <- [Regex.run(~r/\Awriter\.lock\.(?:tmp|stale)\.(\d+)\z/, name)],
          pid == System.pid() or not signalable?(pid),
          do: File.rm(Path.join(dir, name))
    end

    :ok
  end

  # Locking needs a way to prove the holder is dead before reclaiming a stale
  # lock; without that a crash would lock the session out forever. Only enable
  # it where `kill -0` can answer (Unix with a kill binary).
  defp lockable? do
    match?({:unix, _}, :os.type()) and tool("kill") != nil
  end

  # `kill` and `ps` decide who holds a journal, so a directory early on `PATH`
  # must not be able to stand in for them.
  defp tool(name) do
    Enum.find(["/bin/" <> name, "/usr/bin/" <> name], &File.regular?/1) ||
      System.find_executable(name)
  end

  # What this BEAM writes into a lock: its OS pid and, where it can be read,
  # the token for its start.
  defp lock_identity do
    case own_start() do
      {:ok, start} -> System.pid() <> " " <> format_start(start)
      :unknown -> System.pid()
    end
  end

  defp format_start({:ticks, ticks}), do: "ticks:#{ticks}"
  defp format_start({:lstart, time}), do: "lstart:" <> time

  defp parse_start("ticks:" <> ticks) do
    case Integer.parse(ticks) do
      {ticks, ""} -> {:ticks, ticks}
      _malformed -> :unknown
    end
  end

  defp parse_start("lstart:" <> time), do: {:lstart, time |> String.split() |> Enum.join(" ")}
  defp parse_start(_none_or_unknown_kind), do: :unknown

  # This BEAM's start never changes, so one successful read is kept. A failure
  # is not: it also says other pids cannot be asked about.
  defp own_start do
    case :persistent_term.get({__MODULE__, :own_start}, nil) do
      nil -> read_own_start()
      start -> {:ok, start}
    end
  end

  defp read_own_start do
    case process(System.pid()) do
      {:ok, start, _comm} ->
        :persistent_term.put({__MODULE__, :own_start}, start)
        {:ok, start}

      _gone_or_unknown ->
        :unknown
    end
  end

  defp holder_alive?(pid, recorded) do
    signalable?(pid) and beam_alive?(pid, recorded)
  end

  defp signalable?(pid) do
    case tool("kill") do
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

  # Only a holder known to be gone, or known not to be the BEAM the lock
  # names, is not alive. One whose state cannot be read counts as alive:
  # reclaiming a live holder's lock is the failure that damages a journal.
  defp beam_alive?(pid, recorded) do
    case {own_start(), process(pid)} do
      {{:ok, _ours}, {:ok, start, comm}} -> beam?(comm) and same_start?(recorded, start)
      {{:ok, _ours}, :gone} -> false
      {_ours, _theirs} -> true
    end
  end

  defp beam?(comm), do: comm |> Path.basename() |> String.contains?("beam")

  # Tokens of one kind are compared; any other pairing decides nothing.
  defp same_start?({kind, recorded}, {kind, actual}), do: recorded == actual
  defp same_start?(_recorded, _actual), do: true

  # `{:ok, start, comm}` for a running pid, `:gone` for one that does not
  # exist, `:unknown` when that could not be found out.
  defp process(pid) do
    case :os.type() do
      {:unix, :linux} -> proc_stat(pid)
      _other -> ps(pid)
    end
  end

  defp proc_stat(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         {:ok, comm, ticks} <- parse_proc_stat(stat) do
      {:ok, {:ticks, ticks}, comm}
    else
      {:error, reason} when reason in [:enoent, :esrch] -> :gone
      _unreadable -> :unknown
    end
  end

  @doc false
  # `comm` and `starttime` (field 22) of a `/proc/<pid>/stat` line. `comm` may
  # hold spaces and parentheses, so the fields are counted from its last `)`.
  @spec parse_proc_stat(binary()) :: {:ok, String.t(), non_neg_integer()} | :error
  def parse_proc_stat(stat) do
    with [_pid, rest] <- String.split(stat, "(", parts: 2),
         [_ | _] = closers <- :binary.matches(rest, ")"),
         {close, 1} = List.last(closers),
         {:ok, ticks} <- starttime(binary_part(rest, close + 1, byte_size(rest) - close - 1)) do
      {:ok, binary_part(rest, 0, close), ticks}
    else
      _ -> :error
    end
  end

  # `after_comm` starts at field 3, so field 22 is its twentieth.
  defp starttime(after_comm) do
    with {:ok, starttime} <- after_comm |> String.split() |> Enum.fetch(19),
         {ticks, ""} <- Integer.parse(starttime) do
      {:ok, ticks}
    end
  end

  defp ps(pid) do
    case tool("ps") do
      nil ->
        :unknown

      exe ->
        exe
        |> System.cmd(["-o", "lstart=,comm=", "-p", pid],
          env: [{"LC_ALL", "C"}, {"TZ", "UTC"}],
          stderr_to_stdout: true
        )
        |> classify_ps()
    end
  rescue
    _ -> :unknown
  end

  @doc false
  # What `ps -o lstart=,comm= -p <pid>` said, as `{output, exit status}`.
  # `lstart` is five fields in the C locale and the rest of the line is
  # `comm`. Exit 1 with nothing printed is "no such process"; anything else
  # that is not a row is a `ps` that did not answer.
  @spec classify_ps({String.t(), non_neg_integer()}) ::
          {:ok, {:lstart, String.t()}, String.t()} | :gone | :unknown
  def classify_ps({out, status}) do
    case {String.split(out), status} do
      {[_, _, _, _, _, _ | _] = fields, 0} ->
        {time, comm} = Enum.split(fields, 5)
        {:ok, {:lstart, Enum.join(time, " ")}, Enum.join(comm, " ")}

      {[], 1} ->
        :gone

      _no_answer ->
        :unknown
    end
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

  # Remove stray `*.tmp.*` files left by a crash mid-atomic-write on a prior
  # run. A lock's temp file may be a live claimer's: `sweep_lock_leftovers/1`
  # decides those.
  defp sweep_tmp_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          if String.contains?(name, ".tmp.") and not String.starts_with?(name, @lock_file),
            do: File.rm(Path.join(dir, name))
        end)

      _ ->
        :ok
    end
  end
end
