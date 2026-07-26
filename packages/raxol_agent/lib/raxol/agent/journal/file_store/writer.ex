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
  """

  use GenServer

  alias Raxol.Agent.Journal.FileStore.Reader

  @default_segment_cap 8 * 1024 * 1024
  @default_sync_ceiling_ms 200
  @default_immediate_types ["tool_result", "approval"]
  @default_schema_version "1.1.0"

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
    dirty: false
  ]

  # --- API -------------------------------------------------------------------

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

    schema_version = Keyword.get(opts, :schema_version, @default_schema_version)
    seg_cap = Keyword.get(opts, :segment_cap, @default_segment_cap)

    immediate_types =
      opts
      |> Keyword.get(:immediate_sync_types, @default_immediate_types)
      |> MapSet.new(&to_string/1)

    write_meta(dir, opts, schema_version)

    offset = resume_offset(dir)
    {seg_num, seg_size} = current_segment(journal_dir, seg_cap)
    io = open_segment(journal_dir, seg_num)

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
      sync_ceiling_ms: Keyword.get(opts, :sync_ceiling_ms, @default_sync_ceiling_ms)
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
          %{state | offset: offset, seg_size: state.seg_size + IO.iodata_length(line)}
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
    if state.io, do: :ok = :file.datasync(state.io)
    if state.sync_timer, do: Process.cancel_timer(state.sync_timer)
    state = %{state | dirty: false, sync_timer: nil}
    write_head(state)
    state
  end

  # --- segment rotation ------------------------------------------------------

  defp maybe_rotate(%{seg_size: size, seg_cap: cap} = state) when size >= cap do
    :ok = :file.datasync(state.io)
    :ok = :file.close(state.io)
    seg_num = state.seg_num + 1
    %{state | io: open_segment(state.journal_dir, seg_num), seg_num: seg_num, seg_size: 0}
  end

  defp maybe_rotate(state), do: state

  defp open_segment(journal_dir, seg_num) do
    path = Path.join(journal_dir, segment_name(seg_num))
    # :raw + :append, never :delayed_write (durability guarantees depend on it).
    {:ok, io} = :file.open(path, [:append, :raw, :binary])
    io
  end

  defp current_segment(journal_dir, seg_cap) do
    case Reader.list_segments(journal_dir) do
      [] ->
        {1, 0}

      segments ->
        path = List.last(segments)
        num = path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()
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

  defp write_head(state) do
    head = %{
      "offset" => state.offset,
      "segment" => state.seg_num,
      "segment_cap" => state.seg_cap,
      "schema_version" => state.schema_version
    }

    atomic_write!(Path.join(state.dir, "HEAD"), Jason.encode_to_iodata!(head))
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

      atomic_write!(path, Jason.encode_to_iodata!(meta))
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

  defp atomic_write!(path, data) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    File.open!(tmp, [:write, :raw, :binary], fn io ->
      :ok = :file.write(io, data)
      :ok = :file.datasync(io)
    end)

    File.rename!(tmp, path)
    # Durability of the rename itself needs the *directory* entry flushed, else
    # a power loss can lose the newly-renamed name. Best-effort (some platforms
    # reject datasync on a dir fd — that's fine, the rename still stands).
    sync_dir(Path.dirname(path))
    :ok
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
