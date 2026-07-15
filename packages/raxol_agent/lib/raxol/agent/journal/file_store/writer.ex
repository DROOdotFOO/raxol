defmodule Raxol.Agent.Journal.FileStore.Writer do
  @moduledoc """
  The single-writer GenServer for one session's journal (harness-spec-backend
  §4, component 1 — the Writer).

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
  @default_schema_version "1.0.0"

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
    GenServer.start_link(__MODULE__, opts)
  end

  @spec append(pid(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(pid, event), do: GenServer.call(pid, {:append, event})

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
  def handle_call({:append, event}, _from, state) do
    offset = state.offset + 1
    record = stamp(event, offset, state.schema_version)
    line = [Jason.encode_to_iodata!(record), ?\n]
    :ok = :file.write(state.io, line)

    state =
      %{state | offset: offset, seg_size: state.seg_size + IO.iodata_length(line)}
      |> maybe_rotate()
      |> sync_after_append(immediate?(record, state))

    {:reply, {:ok, offset}, state}
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

  @impl GenServer
  def terminate(_reason, state) do
    state = flush_now(state)
    if state.io, do: :file.close(state.io)
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

  defp resume_offset(dir) do
    case read_head(dir) do
      {:ok, %{"offset" => offset}} when is_integer(offset) -> offset
      _ -> Reader.last_offset(dir)
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
    :ok
  end
end
