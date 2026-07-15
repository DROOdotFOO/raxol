defmodule Raxol.Agent.Journal do
  @moduledoc """
  Behaviour for a session's durable append-only journal — the source of truth
  for the durable tier of harness events (harness-spec-backend §4).

  A journal is an ordered, append-only log of events. Each appended event is
  assigned a monotonic `offset` (= the event's id) and framed as one complete,
  self-delimited JSON object per line. Replaying a journal yields the events
  back in offset order.

  The behaviour exists so alternate storage backends (S3, a database, ...) can
  slot in later behind the same contract. The concrete file-backed
  implementation is `Raxol.Agent.Journal.FileStore` — one directory per session,
  size-capped JSONL segments, torn-tail recovery on replay.

  ## Callbacks

    * `open/2`    — open (creating if needed) the journal for a session, returning an opaque handle.
    * `append/2`  — append one event, returning `{:ok, offset}`.
    * `read/2`    — replay durable events in offset order.
    * `close/2`   — release the handle (flush + stop the writer).
    * `status/1`  — `:ok` for a healthy journal, `:damaged` if interior corruption was detected.

  ## Durability & recovery

  Only *complete* records are ever returned. On replay a parse failure on the
  final line of the last segment is treated as a torn tail (a crash mid-write)
  and truncated away — everything before it is recovered and `status/1` stays
  `:ok`. A parse failure anywhere interior marks the session `:damaged`, raises a
  hard alarm, deletes nothing, and never returns the damaged content downstream.
  """

  @typedoc "Stable identifier for a session (also the on-disk directory name)."
  @type session_id :: String.t()

  @typedoc "Opaque, backend-specific handle returned by `open/2`."
  @type handle :: term()

  @typedoc "An event to append — any JSON-encodable map."
  @type event :: map()

  @typedoc "A durable record read back from the journal (a decoded map with an `\"id\"`)."
  @type journal_record :: map()

  @typedoc "Monotonic offset assigned to an appended event (= its id)."
  @type offset :: non_neg_integer()

  @doc "Open (creating if needed) the journal for `session_id`. Returns an opaque handle."
  @callback open(session_id, opts :: keyword()) :: {:ok, handle} | {:error, term()}

  @doc "Append one event. Returns the assigned monotonic offset."
  @callback append(handle, event) :: {:ok, offset} | {:error, term()}

  @doc """
  Replay durable events in offset order.

  Returns `{:ok, records}` for a healthy (or torn-tail-recovered) journal, or
  `{:error, :damaged}` when interior corruption was detected — in which case the
  damaged content is never returned.

  Options:

    * `:from_offset` — only return records whose id is `>=` this value.
  """
  @callback read(handle, opts :: keyword()) :: {:ok, [journal_record]} | {:error, term()}

  @doc "Release the handle (flush pending writes and stop the writer)."
  @callback close(handle) :: :ok

  @doc "`:ok` for a healthy journal, `:damaged` if interior corruption was detected."
  @callback status(handle) :: :ok | :damaged
end
