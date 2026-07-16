defmodule Raxol.AgentClientProtocol.Ext.Journal.Record do
  @moduledoc """
  One grow-only journal record (`acp-reattach-design.md` §1.1).

  Fields ONLY ever get ADDED (optional-with-default); never renamed, retyped,
  reordered, narrowed. A reader that meets an unknown `kind` skips/passes it
  through — never an error. This is what makes the generic `_raxol/session.record`
  delivery frame future-proof.

  Field meanings:

    * `offset` — per-session positive integer, from 1, contiguous, strictly
      increasing in append order (THE OFFSET LAW, §1.3 / J8). Assigned
      atomically inside `append` (offset = current `high_watermark` + 1, under
      the Writer's single-mailbox serialization). Never reused/reordered.
    * `session_id` — binary, NEVER atomized (supervision I14).
    * `kind` — grow-only vocabulary, a STRING on disk/wire (`"session_created"`,
      `"session_update"`, `"turn_started"`, `"turn_completed"`, …). Never
      `String.to_atom`'d on read.
    * `payload` — JSON-safe wire map (string keys); value-identity under any
      Layer-2 codec so a writerless reader in another language needs no Elixir
      terms.
    * `taint` — §6 classification, STAMPED at append, NEVER filtered on the
      delivery path (annotate-never-filter, V-ratified 2026-07-16).
    * `ts_hook` — ms epoch assigned by the store clock at append; a HOOK for
      richer decision-time time models to fold over later (grow-only).

  Ported/derived from the frozen `acp-reattach-design.md` (danger-zone, G5-PASS).
  """

  @enforce_keys [:offset, :session_id, :kind, :payload, :taint, :ts_hook]
  defstruct [:offset, :session_id, :kind, :payload, :taint, :ts_hook]

  @type t :: %__MODULE__{
          offset: pos_integer(),
          session_id: String.t(),
          kind: String.t(),
          payload: map(),
          taint: String.t(),
          ts_hook: integer()
        }
end

defmodule Raxol.AgentClientProtocol.Ext.Journal do
  @moduledoc """
  The durable session journal — behaviour + live-bus registration facade.

  This is the foundation cell of the reattach extension (`acp-reattach-design.md`,
  frozen and G5-PASS). Sessions hold only ephemeral turn state; the DURABLE state
  lives here, and a reattach replays it from an exact offset.

  ## THE OFFSET LAW (§1.3 / invariant J8 — frozen, storage-independent)

  1. Offsets are **per-session positive integers starting at 1, contiguous,
     strictly increasing in append order**. Assigned atomically inside `append`
     (offset = current `high_watermark` + 1), under the Writer's single-mailbox
     serialization. Never reused, never reordered, never reassigned.
  2. `high_watermark(j)` returns the **last DURABLE offset** (`0` = empty
     session), **read from the store** — a conforming impl MUST NOT serve a
     cached counter that can lag or lead the durable state (the
     decision-time-fold law; the cached-counter injector is the dead test).
  3. `read(j, from, to)` returns exactly the records with `from <= offset <= to`,
     in offset order, value-identical to what `append` stored.
  4. A record, once `append` returns `{:ok, record}`, is read-visible: a
     `high_watermark` or `read` issued after that return observes it. This is
     what makes the bus I3 "append THEN publish" meaningful.
  5. **Genesis:** offset 1 of a journal-managed session is ALWAYS a
     `"session_created"` record (appended by the Writer on first use).
  6. Retention v1: grow-only, no truncation.

  ## The handle is PER-SESSION

  Unlike the multi-session sketch in the design's §1.4 code block, this cell
  binds `session_id` into the opaque handle `j`, so the callbacks are
  `append(j, entry)` / `read(j, from, to)` / `high_watermark(j)` (see the
  deviation note at the bottom). `session_id` is carried inside `j` and stamped
  into every record; a per-session `:ordered_set` keyed by `offset` is the ETS
  layout (`Raxol.AgentClientProtocol.Ext.Journal.Mem`).

  ## Storage callbacks

    * `open(session_id, opts)` — construct a per-session handle. The store (ETS
      table / on-disk log) is owned by a process that OUTLIVES any single Writer
      (the app supervisor in production), so the journal survives Writer death —
      the precondition for the Writer-restart tip-fold orphan repair.
    * `append(j, entry)` — assign the next offset atomically, stamp `session_id`
      + `ts_hook`, persist, and return the COMPLETE stamped `%Record{}` (the
      Writer needs the whole record to publish it — the offset is
      `record.offset`). `entry` is `%{kind:, payload:, taint:}`.
    * `read(j, from, to)` — offset-ordered records in `[from, to]`.
    * `high_watermark(j)` — last durable offset, read from the store.
    * `close(j)` — release the handle (grow-only convenience; not load-bearing).

  ## Live-bus registration (facade → Writer)

  `subscribe/2` and `unsubscribe/2` are the "live bus registration" surface. They
  are DELIBERATELY NOT storage callbacks: the frozen bus law (CDI-4 / §2.3)
  requires registration to be **serialized against appends in ONE mailbox** — the
  Writer's — so the P-JS5 closure proof is a mailbox-order argument, not a
  memory-model one. These facade functions therefore route to
  `Raxol.AgentClientProtocol.Ext.Journal.Writer` (the single publisher), which
  owns the subscriber set in its own state. A bare journal-level registry insert
  would break that seam.

  ## Deviation note (reported, not improvised)

  The frozen `acp-reattach-design.md` §1.4 sketches the behaviour with
  multi-session arities (`append/5`, `read/4`, `high_watermark/2`, plus
  `sessions/1`) and treats subscription as Writer state (`Writer.subscribe/2`),
  not a journal callback. This W18a foundation instead uses PER-SESSION arities
  (`append/2`, `read/3`, `high_watermark/1`) per its assignment, and exposes
  `subscribe/2`/`unsubscribe/2` as a facade over the Writer. The OFFSET LAW, the
  decision-time `high_watermark`, single-publisher append-then-publish, and the
  record shape are all preserved byte-for-byte; only the handle granularity and
  the subscription entry point differ. Integration coders binding the harness
  journal should reconcile the arity granularity against §1.4.
  """

  alias Raxol.AgentClientProtocol.Ext.Journal.Record
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer

  @typedoc "Opaque, per-session storage handle."
  @type j :: term()

  @typedoc "An append request: the Writer supplies kind/payload/taint; the store stamps the rest."
  @type entry :: %{
          required(:kind) => String.t(),
          required(:payload) => map(),
          required(:taint) => String.t()
        }

  @callback open(session_id :: String.t(), opts :: keyword()) ::
              {:ok, j} | {:error, term()}
  @callback append(j, entry()) ::
              {:ok, Record.t()} | {:error, :read_only | term()}
  @callback read(j, from :: pos_integer(), to :: non_neg_integer()) ::
              {:ok, [Record.t()]} | {:error, term()}
  @callback high_watermark(j) :: non_neg_integer()
  @callback close(j) :: :ok

  @optional_callbacks close: 1

  # -- Live-bus registration facade (→ Writer, the single publisher) ----------

  @doc """
  Register `subscriber` for the live tail of `session_id`. Routed through the
  session's Writer so it is serialized against appends in ONE mailbox (CDI-4 /
  §2.3). Returns `{:error, :no_writer}` if no live Writer serves the session
  (writerless / history-only sessions have no live tail).
  """
  @spec subscribe(String.t(), pid()) :: :ok | {:error, :no_writer}
  def subscribe(session_id, subscriber)
      when is_binary(session_id) and is_pid(subscriber) do
    case Writer.whereis(session_id) do
      nil -> {:error, :no_writer}
      server -> Writer.subscribe(server, subscriber)
    end
  end

  @doc """
  Idempotently detach `subscriber` from the live tail of `session_id`. A missing
  Writer is a no-op (`:ok`) — there is nothing to detach from.
  """
  @spec unsubscribe(String.t(), pid()) :: :ok
  def unsubscribe(session_id, subscriber)
      when is_binary(session_id) and is_pid(subscriber) do
    case Writer.whereis(session_id) do
      nil -> :ok
      server -> Writer.unsubscribe(server, subscriber)
    end
  end
end
