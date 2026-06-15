defmodule Raxol.ACP.Directive do
  @moduledoc """
  Semantic on-chain directives for the Virtuals ACP contract surface.

  Each struct is a semantic, observable representation of one
  `Raxol.ACP.ContractClient` write. Returning a directive from an
  agent's `update/2` (instead of a `Raxol.Core.Runtime.Command.async/1`
  closure) lets external observers see the intent: "this agent is
  creating a memo on job X" rather than "this agent is running some
  opaque async closure".

  ## Built-in directives

  | Directive | Contract call |
  | --- | --- |
  | `CreateJob` | `createJob(provider, evaluator, expiredAt)` |
  | `SetBudget` | `setBudget(jobId, amount)` |
  | `SetBudgetWithPaymentToken` | `setBudgetWithPaymentToken(jobId, amount, token)` |
  | `CreateMemo` | `createMemo(jobId, content, memoType, isSecured, nextPhase)` |
  | `CreatePayableMemo` | `createPayableMemo(jobId, content, opts)` |
  | `SignMemo` | `signMemo(memoId, isApproved, reason)` |
  | `ClaimBudget` | `claimBudget(jobId)` |
  | `ConfirmX402Payment` | `confirmX402PaymentReceived(jobId)` (V1-only) |

  ## Result messages

  Results land at the agent's `update/2` as:

    * `{:command_result, {:acp_<op>_result, payload}}` on `{:ok, payload}`
    * `{:command_result, {:acp_<op>_error, reason}}` on `{:error, reason}`
    * `{:command_result, {:acp_<op>_error, {:exception, message}}}` on raise

  Where `<op>` is `create_job`, `set_budget`, `set_budget_with_payment_token`,
  `create_memo`, `create_payable_memo`, `sign_memo`, `claim_budget`, or
  `confirm_x402`.

  ## Example

      Raxol.ACP.Directive.create_memo(
        job_id: "job-1",
        content: "ack",
        memo_type: :message,
        next_phase: :negotiation
      )

  ## Dispatch

  Routes through the configured `Raxol.ACP.ContractClient` impl. Tests
  should configure `Raxol.ACP.ContractClient.InMemory`; production uses
  `Raxol.ACP.ContractClient.Onchain`.
  """

  alias __MODULE__.{
    ClaimBudget,
    ConfirmX402Payment,
    CreateJob,
    CreateMemo,
    CreatePayableMemo,
    SetBudget,
    SetBudgetWithPaymentToken,
    SignMemo
  }

  @type t ::
          CreateJob.t()
          | SetBudget.t()
          | SetBudgetWithPaymentToken.t()
          | CreateMemo.t()
          | CreatePayableMemo.t()
          | SignMemo.t()
          | ClaimBudget.t()
          | ConfirmX402Payment.t()

  defmodule CreateJob do
    @moduledoc """
    Create a new ACP job. Mirrors `ACPSimple.createJob(provider, evaluator, expiredAt)`.
    """

    @type t :: %__MODULE__{
            provider: String.t(),
            evaluator: String.t(),
            expired_at: non_neg_integer(),
            meta: map()
          }

    @enforce_keys [:provider, :evaluator, :expired_at]
    defstruct [:provider, :evaluator, :expired_at, meta: %{}]
  end

  defmodule SetBudget do
    @moduledoc """
    Set the escrow budget for a job in the contract's default token.
    Mirrors `ACPSimple.setBudget(jobId, amount)`.
    """

    @type t :: %__MODULE__{
            job_id: binary(),
            amount: Decimal.t(),
            meta: map()
          }

    @enforce_keys [:job_id, :amount]
    defstruct [:job_id, :amount, meta: %{}]
  end

  defmodule SetBudgetWithPaymentToken do
    @moduledoc """
    Set the escrow budget in a specific ERC-20. Mirrors
    `ACPSimple.setBudgetWithPaymentToken(jobId, amount, token)`.
    """

    @type t :: %__MODULE__{
            job_id: binary(),
            amount: Decimal.t(),
            token: String.t(),
            meta: map()
          }

    @enforce_keys [:job_id, :amount, :token]
    defstruct [:job_id, :amount, :token, meta: %{}]
  end

  defmodule CreateMemo do
    @moduledoc """
    Create an on-chain memo. Mirrors
    `InteractionLedger.createMemo(jobId, content, memoType, isSecured, nextPhase)`.
    """

    @type t :: %__MODULE__{
            job_id: binary(),
            content: String.t(),
            memo_type: Raxol.ACP.Job.MemoType.t(),
            is_secured: boolean(),
            next_phase: Raxol.ACP.Job.StateMachine.state(),
            meta: map()
          }

    @enforce_keys [:job_id, :content, :memo_type, :next_phase]
    defstruct [:job_id, :content, :memo_type, :next_phase, is_secured: false, meta: %{}]
  end

  defmodule CreatePayableMemo do
    @moduledoc """
    Create a payable memo (moves funds as part of a phase transition).
    Mirrors `ACPSimple.createPayableMemo(jobId, content, ...)`. `opts`
    keys mirror `Raxol.ACP.ContractClient.create_payable_memo/3`.
    """

    @type t :: %__MODULE__{
            job_id: binary(),
            content: String.t(),
            opts: keyword(),
            meta: map()
          }

    @enforce_keys [:job_id, :content, :opts]
    defstruct [:job_id, :content, :opts, meta: %{}]
  end

  defmodule SignMemo do
    @moduledoc """
    Sign (approve or reject) a memo. Mirrors
    `ACPSimple.signMemo(memoId, isApproved, reason)`.
    """

    @type t :: %__MODULE__{
            memo_id: binary() | non_neg_integer(),
            approved: boolean(),
            reason: String.t(),
            meta: map()
          }

    @enforce_keys [:memo_id, :approved, :reason]
    defstruct [:memo_id, :approved, :reason, meta: %{}]
  end

  defmodule ClaimBudget do
    @moduledoc """
    Claim the escrowed budget for a completed job. Mirrors
    `ACPSimple.claimBudget(jobId)`.
    """

    @type t :: %__MODULE__{job_id: binary(), meta: map()}

    @enforce_keys [:job_id]
    defstruct [:job_id, meta: %{}]
  end

  defmodule ConfirmX402Payment do
    @moduledoc """
    Confirm receipt of an x402 payment for a job. Mirrors
    `ACPSimple.confirmX402PaymentReceived(jobId)`. V1-only; returns
    `{:error, :unsupported_in_v2}` when `:acp_version :v2` is configured.
    """

    @type t :: %__MODULE__{job_id: binary(), meta: map()}

    @enforce_keys [:job_id]
    defstruct [:job_id, meta: %{}]
  end

  @doc "Construct a `CreateJob` directive."
  @spec create_job(keyword()) :: CreateJob.t()
  def create_job(opts) do
    %CreateJob{
      provider: Keyword.fetch!(opts, :provider),
      evaluator: Keyword.fetch!(opts, :evaluator),
      expired_at: Keyword.fetch!(opts, :expired_at),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Construct a `SetBudget` directive."
  @spec set_budget(keyword()) :: SetBudget.t()
  def set_budget(opts) do
    %SetBudget{
      job_id: Keyword.fetch!(opts, :job_id),
      amount: Keyword.fetch!(opts, :amount),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Construct a `SetBudgetWithPaymentToken` directive."
  @spec set_budget_with_payment_token(keyword()) :: SetBudgetWithPaymentToken.t()
  def set_budget_with_payment_token(opts) do
    %SetBudgetWithPaymentToken{
      job_id: Keyword.fetch!(opts, :job_id),
      amount: Keyword.fetch!(opts, :amount),
      token: Keyword.fetch!(opts, :token),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Construct a `CreateMemo` directive."
  @spec create_memo(keyword()) :: CreateMemo.t()
  def create_memo(opts) do
    %CreateMemo{
      job_id: Keyword.fetch!(opts, :job_id),
      content: Keyword.fetch!(opts, :content),
      memo_type: Keyword.fetch!(opts, :memo_type),
      next_phase: Keyword.fetch!(opts, :next_phase),
      is_secured: Keyword.get(opts, :is_secured, false),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Construct a `CreatePayableMemo` directive."
  @spec create_payable_memo(keyword()) :: CreatePayableMemo.t()
  def create_payable_memo(opts) do
    %CreatePayableMemo{
      job_id: Keyword.fetch!(opts, :job_id),
      content: Keyword.fetch!(opts, :content),
      opts: Keyword.fetch!(opts, :opts),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Construct a `SignMemo` directive."
  @spec sign_memo(keyword()) :: SignMemo.t()
  def sign_memo(opts) do
    %SignMemo{
      memo_id: Keyword.fetch!(opts, :memo_id),
      approved: Keyword.fetch!(opts, :approved),
      reason: Keyword.fetch!(opts, :reason),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Construct a `ClaimBudget` directive."
  @spec claim_budget(keyword()) :: ClaimBudget.t()
  def claim_budget(opts) do
    %ClaimBudget{
      job_id: Keyword.fetch!(opts, :job_id),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Construct a `ConfirmX402Payment` directive."
  @spec confirm_x402_payment(keyword()) :: ConfirmX402Payment.t()
  def confirm_x402_payment(opts) do
    %ConfirmX402Payment{
      job_id: Keyword.fetch!(opts, :job_id),
      meta: Keyword.get(opts, :meta, %{})
    }
  end
end
