defmodule Raxol.ACP.Wallet.NonceServer do
  @moduledoc """
  Serializes EVM transaction nonce assignment for a single wallet.

  ## Why this exists

  The Virtuals ACP integration plan claims that "process-per-job avoids
  the concurrent-Alchemy-call footgun." That is incorrect: distinct
  PIDs do not serialize nonce assignment. Two `Raxol.ACP.Job.Server`
  processes that race on `eth_sendRawTransaction` will produce two
  signed transactions with the same nonce, and one will be silently
  dropped by the RPC.

  This GenServer is the documented OTP fix. Each `Job.Server` calls
  `get_next/1` before signing a transaction; the GenServer's mailbox
  guarantees a strict global order.

  ## v0.1 scope

  RPC reconciliation is intentionally deferred. v0.1 holds an in-memory
  counter and exposes `reset/2` so external code (the contract client,
  once it lands) can fold in the result of an `eth_getTransactionCount`
  call. v0.2 adds a periodic reconciliation tick.

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
    GenServer.start_link(__MODULE__, %{nonce: initial}, name: name)
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
  to retry the same nonce). Returns `:ok`.
  """
  @spec reset(server(), non_neg_integer()) :: :ok
  def reset(server \\ __MODULE__, nonce) when is_integer(nonce) and nonce >= 0 do
    GenServer.call(server, {:reset, nonce})
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
    {:reply, :ok, %{state | nonce: n}}
  end
end
