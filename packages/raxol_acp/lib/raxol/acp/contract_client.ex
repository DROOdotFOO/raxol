defmodule Raxol.ACP.ContractClient do
  @moduledoc """
  Behaviour and dispatcher for the ACP contract methods on Base.

  Mirrors the write surface of the deployed `ACPSimple` /
  `InteractionLedger` contract (ABI vendored at
  `priv/abi/acp_simple.json`): `create_job`, `set_budget`,
  `create_memo`, `sign_memo`, `claim_budget`.

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

      {:ok, job_id} = Raxol.ACP.ContractClient.create_job(provider, evaluator, expired_at)

  Job ids and transaction hashes are opaque binaries; format depends on
  the impl (Onchain returns 0x-prefixed lowercase hex; InMemory returns
  a deterministic synthetic string).
  """

  @type job_id :: binary()
  @type memo_id :: binary() | non_neg_integer()
  @type tx_hash :: binary()
  @type address :: String.t()
  @type amount_usdc :: Decimal.t()
  @type memo_type :: Raxol.ACP.Job.MemoType.t()
  @type job_phase :: Raxol.ACP.Job.StateMachine.state()

  @doc """
  Create a job. Mirrors `ACPSimple.createJob`:

      createJob(address provider, address evaluator, uint256 expiredAt)
        -> uint256 jobId

  `provider` is the seller agent, `evaluator` the address that signs
  off on the deliverable (often the buyer), and `expired_at` a unix
  timestamp after which the job expires.
  """
  @callback create_job(address(), address(), non_neg_integer()) ::
              {:ok, job_id()} | {:error, term()}

  @doc """
  Set the escrow budget for a job. Mirrors `ACPSimple.setBudget`:

      setBudget(uint256 jobId, uint256 amount)

  `amount` is in USDC; it is scaled to the token's 6 decimals on chain.
  """
  @callback set_budget(job_id(), amount_usdc()) ::
              {:ok, tx_hash()} | {:error, term()}

  @callback create_memo(job_id(), String.t(), memo_type(), boolean(), job_phase()) ::
              {:ok, tx_hash()} | {:error, term()}

  @doc """
  Sign (approve or reject) a memo. Mirrors `ACPSimple.signMemo`:

      signMemo(uint256 memoId, bool isApproved, string reason)

  This is how a counterparty accepts a request, approves a deliverable,
  or rejects either with a reason.
  """
  @callback sign_memo(memo_id(), boolean(), String.t()) ::
              {:ok, tx_hash()} | {:error, term()}

  @doc """
  Claim the escrowed budget for a completed job. Mirrors
  `ACPSimple.claimBudget`:

      claimBudget(uint256 jobId)
  """
  @callback claim_budget(job_id()) ::
              {:ok, tx_hash()} | {:error, term()}

  @doc """
  Set the escrow budget in a specific ERC-20 token. Mirrors
  `ACPSimple.setBudgetWithPaymentToken`:

      setBudgetWithPaymentToken(uint256 jobId, uint256 amount, address token)

  Use this instead of `set_budget/2` when the job settles in a token
  other than the contract's default (e.g. a non-USDC stablecoin).
  """
  @callback set_budget_with_payment_token(job_id(), amount_usdc(), address()) ::
              {:ok, tx_hash()} | {:error, term()}

  @doc """
  Confirm receipt of an x402 (HTTP 402) payment for a job. Mirrors
  `ACPSimple.confirmX402PaymentReceived`:

      confirmX402PaymentReceived(uint256 jobId)
  """
  @callback confirm_x402_payment_received(job_id()) ::
              {:ok, tx_hash()} | {:error, term()}

  @doc """
  Create a payable memo -- a memo that moves funds as part of a phase
  transition. Mirrors `ACPSimple.createPayableMemo`:

      createPayableMemo(uint256 jobId, string content, address token,
                        uint256 amount, address recipient,
                        uint256 feeAmount, uint8 feeType, uint8 memoType,
                        uint8 nextPhase, uint256 expiredAt) -> uint256

  `opts` keys:

  - `:token` (required) -- ERC-20 token address
  - `:amount` (required) -- `Decimal`, scaled to the token's 6 decimals
  - `:recipient` (required) -- payout address
  - `:fee_amount` -- `Decimal`, default `0`
  - `:fee_type` -- `Raxol.ACP.Job.FeeType` atom, default `:no_fee`
  - `:memo_type` -- `Raxol.ACP.Job.MemoType` atom, default `:payable_request`
  - `:next_phase` -- state-machine atom (required)
  - `:expired_at` -- unix timestamp, default `0` (no expiry)
  """
  @callback create_payable_memo(job_id(), String.t(), keyword()) ::
              {:ok, tx_hash()} | {:error, term()}

  # -- Delegating API --

  @spec create_job(address(), address(), non_neg_integer()) ::
          {:ok, job_id()} | {:error, term()}
  def create_job(provider, evaluator, expired_at),
    do: impl().create_job(provider, evaluator, expired_at)

  @spec set_budget(job_id(), amount_usdc()) :: {:ok, tx_hash()} | {:error, term()}
  def set_budget(job_id, amount), do: impl().set_budget(job_id, amount)

  @doc """
  Create an on-chain memo. Mirrors `InteractionLedger.createMemo` from
  the Virtuals ACP contract:

      createMemo(uint256 jobId, string content, uint8 memoType,
                 bool isSecured, uint8 nextPhase) -> uint256 memoId

  `memo_type` is an atom from `Raxol.ACP.Job.MemoType`; `next_phase` is
  the state-machine atom the memo transitions the job to.
  """
  @spec create_memo(job_id(), String.t(), memo_type(), boolean(), job_phase()) ::
          {:ok, tx_hash()} | {:error, term()}
  def create_memo(job_id, content, memo_type, is_secured, next_phase),
    do: impl().create_memo(job_id, content, memo_type, is_secured, next_phase)

  @spec sign_memo(memo_id(), boolean(), String.t()) :: {:ok, tx_hash()} | {:error, term()}
  def sign_memo(memo_id, approved, reason),
    do: impl().sign_memo(memo_id, approved, reason)

  @spec claim_budget(job_id()) :: {:ok, tx_hash()} | {:error, term()}
  def claim_budget(job_id), do: impl().claim_budget(job_id)

  @spec set_budget_with_payment_token(job_id(), amount_usdc(), address()) ::
          {:ok, tx_hash()} | {:error, term()}
  def set_budget_with_payment_token(job_id, amount, token),
    do: impl().set_budget_with_payment_token(job_id, amount, token)

  @spec confirm_x402_payment_received(job_id()) :: {:ok, tx_hash()} | {:error, term()}
  def confirm_x402_payment_received(job_id),
    do: impl().confirm_x402_payment_received(job_id)

  @spec create_payable_memo(job_id(), String.t(), keyword()) ::
          {:ok, tx_hash()} | {:error, term()}
  def create_payable_memo(job_id, content, opts),
    do: impl().create_payable_memo(job_id, content, opts)

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
