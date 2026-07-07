defmodule Raxol.ACP.Wallet.NonceServer do
  @moduledoc """
  Serializes EVM transaction nonce assignment for a single wallet.

  ## Why this exists

  The Virtuals ACP integration plan claims that "process-per-job avoids
  the concurrent-Alchemy-call footgun." That is incorrect: distinct
  PIDs do not serialize nonce assignment. Two callers into an EOA write
  path that race on `eth_sendRawTransaction` will produce two signed
  transactions with the same nonce, and one will be silently dropped by
  the RPC.

  This GenServer is the documented OTP fix. An EOA write path calls into
  it (`get_next_if_seeded/1` + `seed_and_next/2`) before signing a
  transaction; the GenServer's mailbox guarantees a strict global order.

  ## v0.1 scope

  RPC reconciliation is intentionally deferred. v0.1 holds an in-memory
  counter and exposes `reset/2` so the calling write path can fold in the
  result of an `eth_getTransactionCount` call. v0.2 adds a periodic
  reconciliation tick.

  ## Multiple wallets

  Each wallet gets its own NonceServer instance, addressed by name:

      {:ok, _} = NonceServer.start_link(name: SellerNonces, initial_nonce: 12)
      NonceServer.get_next(SellerNonces)  #=> 12
      NonceServer.get_next(SellerNonces)  #=> 13

  The default-named instance (`Raxol.ACP.Wallet.NonceServer`) is started
  by `Raxol.ACP.Supervisor` for the umbrella seller wallet.
  """

  use Raxol.Core.Behaviours.BaseManager

  @type server :: GenServer.server()

  # -- Public API --

  @doc """
  Start a NonceServer.

  ## Options

  - `:name` -- registered name (default `__MODULE__`).
  - `:initial_nonce` -- the first nonce that `get_next/1` returns
    (default `0`). When the wallet has prior on-chain history, pass
    the result of `eth_getTransactionCount(addr, "pending")`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    initial = Keyword.get(opts, :initial_nonce, 0)
    # A server that was handed an explicit initial_nonce is already seeded
    # (the caller asserts they know the on-chain count); a default server
    # starts unseeded so the first user reconciles it from chain.
    seeded = Keyword.get(opts, :seeded, Keyword.has_key?(opts, :initial_nonce))
    GenServer.start_link(__MODULE__, %{nonce: initial, seeded: seeded}, name: name)
  end

  @doc """
  Atomically return the current nonce and increment.

  Two concurrent calls always receive distinct values; the GenServer's
  mailbox provides the serialization.
  """
  @spec get_next(server()) :: non_neg_integer()
  def get_next(server \\ __MODULE__) do
    GenServer.call(server, :get_next)
  end

  @doc """
  Return the current nonce without incrementing.

  Useful for telemetry and assertions; not for transaction signing.
  """
  @spec peek(server()) :: non_neg_integer()
  def peek(server \\ __MODULE__) do
    GenServer.call(server, :peek)
  end

  @doc """
  Force the next nonce to a specific value.

  Call this after reconciling with on-chain state (e.g. when an external
  transaction bumped the nonce, or after a transaction failed and we want
  to retry the same nonce). Marks the server seeded. Returns `:ok`.
  """
  @spec reset(server(), non_neg_integer()) :: :ok
  def reset(server \\ __MODULE__, nonce) when is_integer(nonce) and nonce >= 0 do
    GenServer.call(server, {:reset, nonce})
  end

  @doc """
  Mark the server unseeded so the next `get_next_if_seeded/1` returns
  `:unseeded` and the caller re-fetches the on-chain count.

  Use this to recover from suspected nonce drift -- e.g. an external system
  signed a transaction from the same wallet, so the local counter can no
  longer be trusted and must be reconciled from chain. Returns `:ok`.
  """
  @spec resync(server()) :: :ok
  def resync(server \\ __MODULE__) do
    GenServer.call(server, :resync)
  end

  @doc """
  Return the next nonce only if the counter has been seeded from chain
  (via `reset/2`, `seed_and_next/2`, or an explicit `:initial_nonce`).

  Returns `{:ok, nonce}` when seeded, or `:unseeded` otherwise -- in which
  case the caller should fetch `eth_getTransactionCount(addr, "pending")`
  and seed atomically via `seed_and_next/2`. Splitting the check from the
  seed keeps the on-chain fetch outside the GenServer while still closing
  the seeding race.
  """
  @spec get_next_if_seeded(server()) :: {:ok, non_neg_integer()} | :unseeded
  def get_next_if_seeded(server \\ __MODULE__) do
    GenServer.call(server, :get_next_if_seeded)
  end

  @doc """
  Adopt `chain_nonce` as the counter base and return the next nonce -- but
  only if the counter is still unseeded.

  This closes the first-use race: if two callers both observe `:unseeded`
  and both fetch the same on-chain count, the first to call `seed_and_next/2`
  adopts it; the second's `chain_nonce` is ignored and it is handed the
  current local next nonce instead. Either way every caller receives a
  unique, monotonic nonce -- never a duplicate.
  """
  @spec seed_and_next(server(), non_neg_integer()) :: non_neg_integer()
  def seed_and_next(server \\ __MODULE__, chain_nonce)
      when is_integer(chain_nonce) and chain_nonce >= 0 do
    GenServer.call(server, {:seed_and_next, chain_nonce})
  end

  # -- GenServer callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(state), do: {:ok, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_next, _from, %{nonce: n} = state) do
    {:reply, n, %{state | nonce: n + 1}}
  end

  def handle_manager_call(:peek, _from, %{nonce: n} = state) do
    {:reply, n, state}
  end

  def handle_manager_call({:reset, n}, _from, state) do
    {:reply, :ok, %{state | nonce: n, seeded: true}}
  end

  def handle_manager_call(:resync, _from, state) do
    {:reply, :ok, %{state | seeded: false}}
  end

  def handle_manager_call(:get_next_if_seeded, _from, %{seeded: true, nonce: n} = state) do
    {:reply, {:ok, n}, %{state | nonce: n + 1}}
  end

  def handle_manager_call(:get_next_if_seeded, _from, %{seeded: false} = state) do
    {:reply, :unseeded, state}
  end

  # Still unseeded: adopt the chain nonce as the base.
  def handle_manager_call({:seed_and_next, chain_nonce}, _from, %{seeded: false} = state) do
    {:reply, chain_nonce, %{state | nonce: chain_nonce + 1, seeded: true}}
  end

  # Already seeded by a racing caller: ignore the chain nonce, hand out the
  # current local next so the two callers never collide.
  def handle_manager_call(
        {:seed_and_next, _chain_nonce},
        _from,
        %{seeded: true, nonce: n} = state
      ) do
    {:reply, n, %{state | nonce: n + 1}}
  end
end
