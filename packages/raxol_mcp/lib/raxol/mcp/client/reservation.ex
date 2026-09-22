defmodule Raxol.MCP.Client.Reservation do
  @moduledoc """
  Single-use handles for a priced `tools/call` (ADR-0037 decision 7).

  The transport refuses a priced tool whose call carries no spend-gate
  handle. That refusal was `Map.get(request, :reservation)` truthiness, which
  is not a check: `Raxol.MCP.Client.call_tool/4` is public, so any caller
  could pass `reservation: "anything"` and the transport could not tell a
  live reservation from a settled one, a refused one, or a string someone
  invented. The metering gate sits on the function that issues the request,
  and a nominal gate there is the same hole as no gate at all.

  So a handle is a value that must be MINTED and can be spent once. `mint/1`
  writes 18 bytes of `:crypto.strong_rand_bytes/1` into the shared table
  `Raxol.MCP.Client.Tables` owns; `consume/2` takes it out. A literal, a
  replay of a handle already spent, and one past its TTL are all
  indistinguishable from an absent handle, which is what
  `Raxol.Agent.McpSpendHook` mints against and the transport refuses.

  ## What this does and does not defend

  It defends the transport's own gate: a call arriving through the public API
  with a forged, reused or stale handle is refused, and a handle the spend
  hook minted is good for exactly one request. It does not pretend to defend
  against arbitrary code on this node -- the table is `:public`, because the
  minting side is `raxol_agent` and the consuming side is this package, and a
  process that can write another process's ETS table can equally call this
  transport directly. The authority being protected is the SPEND HOOK's: only
  the hook that reserved against a budget has a handle to hand on.

  ## Why a TTL

  A minted handle is not always spent. The transport refuses before issuing
  for a full in-flight window (`:busy`), an open breaker, or an unknown
  price, and each of those leaves the handle unconsumed. Every mint sweeps
  what has expired, so the table is bounded by the handles minted inside one
  TTL rather than by the lifetime of the node.
  """

  alias Raxol.MCP.Client.Tables

  # Comfortably longer than the client's 30 s `call_timeout`, so a handle
  # cannot expire underneath a request that is still queued, and short enough
  # that an unspent one is not still valid a session later.
  @ttl_ms 120_000

  @bytes 18

  @doc "A table for minted handles. `Raxol.MCP.Client.Tables` owns the shared one."
  @spec new(atom()) :: :ets.table()
  def new(name) do
    :ets.new(name, [:set, :public, read_concurrency: true, write_concurrency: true])
  end

  @doc """
  Mint a single-use handle in the shared table, starting its owner if needed.
  """
  @spec mint() :: String.t()
  def mint, do: mint(Tables.ensure_started().reservations)

  @doc "Mint a single-use handle in `table`."
  @spec mint(:ets.table()) :: String.t()
  def mint(table) do
    sweep(table)
    token = @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    :ets.insert(table, {token, now_ms() + @ttl_ms})
    token
  end

  @doc """
  Spend `token`, or refuse it.

  `:ok` exactly once per minted handle. `:error` for anything else: a handle
  never minted, one already spent, one whose TTL has passed, or a term that
  is not a handle at all.
  """
  @spec consume(:ets.table(), term()) :: :ok | :error
  def consume(table, token) when is_binary(token) do
    # `take/2` is the single-use half: two concurrent calls carrying the same
    # handle cannot both find it.
    case :ets.take(table, token) do
      [{^token, expires_at}] -> if now_ms() <= expires_at, do: :ok, else: :error
      [] -> :error
    end
  end

  def consume(_table, _not_a_handle), do: :error

  defp sweep(table) do
    :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now_ms()}], [true]}])
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
