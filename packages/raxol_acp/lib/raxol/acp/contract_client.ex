defmodule Raxol.ACP.ContractClient do
  @moduledoc """
  Behaviour and dispatcher for the four ACP contract methods on Base.

  ## Why a behaviour, not a hard-coded RPC client

  Per the project's "no mocks" rule, we ship two real implementations:

  - `Raxol.ACP.ContractClient.Onchain` -- hits Base mainnet/sepolia via
    JSON-RPC. The production impl. (Lands in a follow-up chunk; not
    included in this v0.1 cut.)
  - `Raxol.ACP.ContractClient.InMemory` -- an Agent-backed test impl
    living in `test/support/`. Lets the job lifecycle code be tested
    without an RPC endpoint.

  This is the same pattern as `Raxol.Payments.Wallets.Env` vs
  `Raxol.Payments.Wallets.Op`: two real impls of one behaviour, picked
  via configuration. Neither is a mock.

  ## Configuration

      config :raxol_acp,
        contract_client: Raxol.ACP.ContractClient.Onchain   # production
        # or
        contract_client: Raxol.ACP.ContractClient.InMemory  # tests / dev

  Callers use the delegating functions on this module:

      {:ok, job_id} = Raxol.ACP.ContractClient.create_job(seller, price, data)

  Job ids and transaction hashes are opaque binaries; format depends on
  the impl (Onchain returns 0x-prefixed lowercase hex; InMemory returns
  a deterministic synthetic string).
  """

  @type job_id :: binary()
  @type tx_hash :: binary()
  @type seller_address :: String.t()
  @type price_usdc :: Decimal.t()
  @type memo_type :: :request | :negotiation | :transaction | :evaluation | :completed
  @type signature :: binary()

  @callback create_job(seller_address(), price_usdc(), binary()) ::
              {:ok, job_id()} | {:error, term()}

  @callback submit_memo(job_id(), memo_type(), map(), signature()) ::
              {:ok, tx_hash()} | {:error, term()}

  @callback complete_job(job_id(), binary()) ::
              {:ok, tx_hash()} | {:error, term()}

  @callback pay_and_accept_requirement(job_id(), binary()) ::
              {:ok, tx_hash()} | {:error, term()}

  # -- Delegating API --

  @spec create_job(seller_address(), price_usdc(), binary()) ::
          {:ok, job_id()} | {:error, term()}
  def create_job(seller, price, data), do: impl().create_job(seller, price, data)

  @spec submit_memo(job_id(), memo_type(), map(), signature()) ::
          {:ok, tx_hash()} | {:error, term()}
  def submit_memo(job_id, type, payload, signature),
    do: impl().submit_memo(job_id, type, payload, signature)

  @spec complete_job(job_id(), binary()) :: {:ok, tx_hash()} | {:error, term()}
  def complete_job(job_id, deliverable_hash),
    do: impl().complete_job(job_id, deliverable_hash)

  @spec pay_and_accept_requirement(job_id(), binary()) ::
          {:ok, tx_hash()} | {:error, term()}
  def pay_and_accept_requirement(job_id, authorization),
    do: impl().pay_and_accept_requirement(job_id, authorization)

  @doc """
  Return the configured implementation module.

  Raises `RuntimeError` if no implementation is configured. Set one with:

      config :raxol_acp, contract_client: Raxol.ACP.ContractClient.InMemory
  """
  @spec impl() :: module()
  def impl do
    case Application.get_env(:raxol_acp, :contract_client) do
      nil ->
        raise """
        raxol_acp: no contract client configured. Set one of:

          config :raxol_acp, contract_client: Raxol.ACP.ContractClient.Onchain   # production
          config :raxol_acp, contract_client: Raxol.ACP.ContractClient.InMemory  # tests
        """

      mod when is_atom(mod) ->
        mod
    end
  end
end
