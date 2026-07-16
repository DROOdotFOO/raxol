defmodule Raxol.Agent.Journal.FileStore do
  @moduledoc """
  File-backed `Raxol.Agent.Journal` — one directory per session, the directory
  *is* the session (portable, tar-able, rsync-able, grep-able).

      <base>/<session_id>/
      ├── meta.json          # created_at, cwd, git branch, title, schema_version
      ├── HEAD               # sidecar: current durable offset + config
      ├── journal/
      │   ├── 000001.jsonl   # framed JSONL, size-capped ascending segments
      │   └── 000002.jsonl
      └── snapshots/         # checkpoint payloads (populated by a later unit)

  The base directory defaults to `~/.raxol/sessions/`, overridable via the
  `:base_dir` option or the `RAXOL_SESSIONS_DIR` env var.

  Storage splits into a single-writer GenServer
  (`Raxol.Agent.Journal.FileStore.Writer`) and a tolerant replay reader
  (`Raxol.Agent.Journal.FileStore.Reader`). See those modules and
  `Raxol.Agent.Journal` for the durability and torn-tail-recovery contract.
  """

  @behaviour Raxol.Agent.Journal

  alias Raxol.Agent.Journal.FileStore.{Reader, Writer}

  @enforce_keys [:session_id, :dir, :writer]
  defstruct [:session_id, :dir, :writer, owner?: true]

  @type t :: %__MODULE__{
          session_id: String.t(),
          dir: Path.t(),
          writer: pid(),
          owner?: boolean()
        }

  @env_base "RAXOL_SESSIONS_DIR"
  @default_base "~/.raxol/sessions"

  # A session_id is also the on-disk directory name, so it must not be able to
  # escape the base dir. Allow only a conservative filename charset (no `/`, no
  # NUL, no empty string) and reject the `.`/`..` traversal names explicitly.
  @session_id_re ~r/\A[A-Za-z0-9._-]+\z/

  @doc """
  Open (creating if needed) the journal for `session_id`.

  Options:

    * `:base_dir` — base directory (defaults to `$RAXOL_SESSIONS_DIR` or `~/.raxol/sessions`).
    * `:segment_cap` — segment size cap in bytes before rotation (default 8 MiB).
    * `:immediate_sync_types` — event `type`s that force an immediate datasync
      (default `["tool_result", "approval"]`).
    * `:sync_ceiling_ms` — batched-sync ceiling in ms (default 200).
    * `:schema_version`, `:cwd`, `:git_branch`, `:title` — recorded in `meta.json` on first open.
  """
  @impl Raxol.Agent.Journal
  def open(session_id, opts \\ []) when is_binary(session_id) do
    dir = Path.join(base_dir(opts), session_id)

    # Pre-flight the session layout HERE, where a failure is a plain
    # `{:error, reason}` return. A raising `Writer.init` (e.g. the session dir
    # path blocked by a regular file, or an unwritable base) exits ABNORMALLY,
    # and an abnormal init exit kills a non-trapping linked caller outright —
    # so without this check the documented `{:error, _}` open contract (and
    # EmitBridge's fail-closed `:journal_open_failed` arm) never fires for
    # real filesystem failures. (Found by the I1 `:open_fail` fault site in
    # test/invariants/identity_invariants_test.exs.)
    with :ok <- validate_session_id(session_id),
         :ok <- ensure_layout(dir) do
      writer_opts = Keyword.merge(opts, dir: dir, session_id: session_id)

      case Writer.start_link(writer_opts) do
        {:ok, pid} ->
          {:ok,
           %__MODULE__{
             session_id: session_id,
             dir: dir,
             writer: pid,
             owner?: true
           }}

        # Single-writer invariant: a Writer already owns this session's journal.
        # Reuse the live one rather than spawning a second writer on the segment.
        # This handle JOINS a shared Writer it did not start — mark it a joiner
        # so `close/1` does not stop the Writer out from under the owner.
        {:error, {:already_started, pid}} ->
          {:ok,
           %__MODULE__{
             session_id: session_id,
             dir: dir,
             writer: pid,
             owner?: false
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  @impl Raxol.Agent.Journal
  def append(%__MODULE__{writer: pid}, event) when is_map(event) do
    Writer.append(pid, event)
  catch
    # The Writer died underneath this handle (owner closed it, crash, ...).
    # Surface a normal error tuple instead of exiting the caller — the handle
    # is stale and should be reopened.
    :exit, reason -> {:error, {:writer_down, exit_reason(reason)}}
  end

  @doc """
  Atomic check-and-append: `check` runs against the freshest on-disk records
  INSIDE the single Writer, and `event` is appended only if it returns `:ok` —
  one atomic step, so no concurrent append (e.g. through a shared joiner
  handle) can interleave between validation and commit. See
  `Raxol.Agent.Journal.FileStore.Writer.append_checked/3`.
  """
  @spec append_checked(t(), map(), ([map()] -> :ok | {:error, term()})) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append_checked(%__MODULE__{writer: pid}, event, check)
      when is_map(event) and is_function(check, 1) do
    Writer.append_checked(pid, event, check)
  catch
    :exit, reason -> {:error, {:writer_down, exit_reason(reason)}}
  end

  @impl Raxol.Agent.Journal
  def read(%__MODULE__{dir: dir, writer: pid}, opts \\ []) do
    flush(pid)

    case Reader.scan(dir) do
      {:ok, records} -> {:ok, filter(records, opts)}
      {:damaged, _partial} -> {:error, :damaged}
    end
  end

  # Only the handle that STARTED the Writer may stop it. A joiner handle (one
  # whose `open/2` found the Writer `{:already_started, _}`) shares the Writer
  # with its owner; stopping it here would crash the owner's next append.
  # Joiners just drop their reference.
  @impl Raxol.Agent.Journal
  def close(%__MODULE__{writer: pid, owner?: true}) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  def close(%__MODULE__{owner?: false}), do: :ok

  @impl Raxol.Agent.Journal
  def status(%__MODULE__{dir: dir, writer: pid}) do
    flush(pid)

    case Reader.scan(dir) do
      {:ok, _} -> :ok
      {:damaged, _} -> :damaged
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Non-raising layout creation, so open failures surface as error tuples
  # instead of an abnormal Writer.init exit (see the comment in open/2).
  defp ensure_layout(dir) do
    Enum.reduce_while(["journal", "snapshots"], :ok, fn sub, :ok ->
      case File.mkdir_p(Path.join(dir, sub)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mkdir_failed, reason, dir}}}
      end
    end)
  end

  defp validate_session_id(id) when id in [".", ".."],
    do: {:error, :invalid_session_id}

  defp validate_session_id(id) do
    if Regex.match?(@session_id_re, id) do
      :ok
    else
      {:error, :invalid_session_id}
    end
  end

  defp flush(pid) do
    if Process.alive?(pid), do: Writer.flush(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Strip GenServer.call decoration ({reason, {GenServer, :call, ...}}) down to
  # the bare exit reason.
  defp exit_reason({reason, {GenServer, :call, _}}), do: reason
  defp exit_reason(reason), do: reason

  defp filter(records, opts) do
    case Keyword.get(opts, :from_offset) do
      nil -> records
      from -> Enum.filter(records, fn %{"id" => id} -> id >= from end)
    end
  end

  defp base_dir(opts) do
    (Keyword.get(opts, :base_dir) || System.get_env(@env_base) || @default_base)
    |> Path.expand()
  end
end
