defmodule Raxol.AgentClientProtocol.Ext.Journal.Mem do
  @moduledoc """
  ETS-backed in-memory journal — the v1 default impl of
  `Raxol.AgentClientProtocol.Ext.Journal` (the durable on-disk cell is later,
  behind the SAME behaviour + the SAME OFFSET LAW).

  ## Layout

  One `:ordered_set` ETS table per session, keyed by `offset`
  (`{offset, %Record{}}`). Because the table is an `:ordered_set` keyed on the
  integer offset, `:ets.last/1` is the durable high-watermark in O(log n) and
  `read/3` is an offset-ordered range select.

  ## Ownership (why it survives Writer death)

  `open/2` creates the table owned by the CALLING process (the app supervisor in
  production, the test process in tests) — deliberately NOT the Writer. The
  journal therefore outlives any single Writer crash/restart, which is the
  precondition for the Writer-restart tip-fold orphan repair (design §2.6 / C14).

  ## Protection level (`:public`, deliberate)

  The table is `:public`, not `:protected`. `:protected` would forbid all
  non-owner writes, but the single-publisher Writer is a DIFFERENT process from
  the owner (the owner OUTLIVES the Writer, per the ownership note above — the
  C14 precondition), so `:protected` would break every append. Offset integrity
  is instead structural: exactly one Writer per session (the unique Writer
  Registry) is the sole appender in production. Records are stored in PLAINTEXT —
  co-resident BEAM processes are trusted; this store is not a confidentiality
  boundary.

  ## Atomic offset assignment — no counter

  `append/2` computes `offset = high_watermark(j) + 1` by reading the table max
  (`:ets.last/1`), NEVER a cached counter (the decision-time-fold law, §1.3.2 /
  J2). Atomicity across concurrent appenders is the Writer's job: a single Writer
  process per session serializes every `append` through one mailbox, so the
  read-then-insert is race-free by construction (the behaviour may assume
  single-writer-per-session, §1.4).
  """

  @behaviour Raxol.AgentClientProtocol.Ext.Journal

  alias Raxol.AgentClientProtocol.Ext.Journal.Record

  @enforce_keys [:session_id, :table]
  defstruct [:session_id, :table]

  @type t :: %__MODULE__{session_id: String.t(), table: :ets.tid()}

  @doc """
  Open a fresh per-session handle. The ETS table is owned by the caller (see the
  ownership note in the moduledoc). `opts` is accepted for behaviour conformance
  and future latitude (ETS tuning); v1 ignores it.
  """
  @impl true
  @spec open(String.t(), keyword()) :: {:ok, t()}
  def open(session_id, _opts \\ []) when is_binary(session_id) do
    table = :ets.new(:acp_journal_mem, [:ordered_set, :public])
    {:ok, %__MODULE__{session_id: session_id, table: table}}
  end

  @doc """
  Assign the next offset atomically (max + 1, read from the store), stamp
  `session_id` + `ts_hook`, persist, and return the COMPLETE `%Record{}`.
  """
  @impl true
  @spec append(t(), Raxol.AgentClientProtocol.Ext.Journal.entry()) ::
          {:ok, Record.t()}
  def append(%__MODULE__{} = j, %{kind: kind, payload: payload, taint: taint})
      when is_binary(kind) and is_map(payload) and is_binary(taint) do
    offset = high_watermark(j) + 1

    record = %Record{
      offset: offset,
      session_id: j.session_id,
      kind: kind,
      payload: payload,
      taint: taint,
      ts_hook: System.system_time(:millisecond)
    }

    true = :ets.insert(j.table, {offset, record})
    {:ok, record}
  end

  @doc """
  Offset-ordered records in `[from, to]`. An empty or inverted range yields
  `{:ok, []}`. Reads directly from the store — value-identical to what `append`
  stored (§1.3.3).
  """
  @impl true
  @spec read(t(), pos_integer(), non_neg_integer()) :: {:ok, [Record.t()]}
  def read(%__MODULE__{} = j, from, to)
      when is_integer(from) and from >= 1 and is_integer(to) do
    if from > to do
      {:ok, []}
    else
      match_spec = [
        {{:"$1", :"$2"}, [{:andalso, {:>=, :"$1", from}, {:"=<", :"$1", to}}], [:"$2"]}
      ]

      {:ok, :ets.select(j.table, match_spec)}
    end
  end

  @doc """
  Last DURABLE offset, read from the store (`:ets.last/1`); `0` for an empty
  session. NEVER a cached counter (§1.3.2 / J2).
  """
  @impl true
  @spec high_watermark(t()) :: non_neg_integer()
  def high_watermark(%__MODULE__{table: table}) do
    case :ets.last(table) do
      :"$end_of_table" -> 0
      offset when is_integer(offset) -> offset
    end
  end

  @doc "Delete the backing table. Idempotent-ish: a double close raises like any ETS misuse."
  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{table: table}) do
    :ets.delete(table)
    :ok
  end
end
