defmodule Raxol.ACP.JobSession.Provider do
  @moduledoc """
  Drives a `Raxol.ACP.JobSession` from the PROVIDER side, tying together the
  three things a provider must do at each lifecycle point:

  1. invoke the offering's `Raxol.ACP.Offering.Handler` callback (via
     `Raxol.ACP.JobSession.HandlerSeam`) to make the accept / deliver /
     evaluate decision,
  2. write the corresponding hook call on-chain through
     `Raxol.ACP.HookClient` + the injected `Raxol.ACP.ProviderAdapter`, and
  3. mirror the resulting status into the local `JobSession` via
     `JobSession.apply_event/3`.

  The on-chain write is the commit point: it happens FIRST, and the local
  `apply_event` mirror only runs once the chain write succeeds -- so a failed
  write leaves the session untouched (local never claims more than the chain
  has). Because the mirror is an observed transition it bypasses role and
  adjacency gating, so it never fights the state machine.

  This is the generic form of what `Raxol.ACP.Xochi.SolverAgent` does bespoke
  for the storefront. Jobs are plain (no hook data on `setBudget`); carrying
  `FundTransferHook` data is a later extension.

  A `Provider` is a plain struct built with `new/1`; its functions are pure
  orchestration over the session and the adapter (no process of its own -- a
  runtime such as the seller `Queue` calls them).
  """

  alias Raxol.ACP.{AssetToken, HookClient, JobSession}
  alias Raxol.ACP.JobSession.HandlerSeam

  @enforce_keys [:session, :handler, :adapter, :chain_id, :acp_core_address, :job_id]
  defstruct [
    :session,
    :handler,
    :adapter,
    :chain_id,
    :acp_core_address,
    :job_id,
    buyer: nil,
    seller: nil
  ]

  @type t :: %__MODULE__{
          session: GenServer.server() | JobSession.job_key(),
          handler: module(),
          adapter: Raxol.ACP.ProviderAdapter.adapter(),
          chain_id: pos_integer(),
          acp_core_address: String.t(),
          job_id: non_neg_integer(),
          buyer: String.t() | nil,
          seller: String.t() | nil
        }

  @type ok(status) ::
          {:ok, %{:status => status, :tx_hash => String.t(), optional(atom()) => term()}}

  @doc "Build a provider driver. See the struct fields for the required keys."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Decide on a buyer's job request.

  Invokes `handle_request/2`. On `{:accept, response}` it writes
  `setBudget(job, budget)` on-chain and mirrors the session to `:budget_set`.
  On `{:reject, reason}` it makes no on-chain or local change and returns
  `{:rejected, reason}` -- the caller decides whether to expire the job.

  Idempotent by the session status: `handle_request/2` + `setBudget` run only
  from `:open`. On an already-`:budget_set` session it is a no-op returning
  `{:ok, %{status: :budget_set, idempotent: true}}` (no second handler call or
  on-chain write); from any other status it returns
  `{:error, {:cannot_accept, status}}` without invoking the handler.
  """
  @spec accept_request(t(), map(), AssetToken.t()) ::
          ok(:budget_set)
          | {:ok, %{status: :budget_set, idempotent: true}}
          | {:rejected, term()}
          | {:error, term()}
  def accept_request(%__MODULE__{} = p, request, %AssetToken{} = budget) do
    # Guard the side-effecting handler + on-chain `setBudget` on the current
    # status. accept_request is the INITIAL accept: the seller's budget is fixed
    # by the offering spec, so a re-offer never carries a new price and never
    # means an intentional re-budget. If the session already reflects
    # `:budget_set` -- because the write and mirror landed but the seller Queue
    # lost its in-memory job tracking (a crash before it recorded the job) and
    # the backend redelivered the offer, or via SSE reconciliation of the
    # on-chain event -- a re-accept must not re-invoke the handler or re-write
    # `setBudget`. Only `:open` runs the write.
    case safe_status(p.session) do
      :open -> do_accept_request(p, request, budget)
      :budget_set -> {:ok, %{status: :budget_set, idempotent: true}}
      other -> {:error, {:cannot_accept, other}}
    end
  end

  defp do_accept_request(p, request, budget) do
    case HandlerSeam.invoke(p.handler, :request, request, ctx(p)) do
      {:accept, response} ->
        with {:ok, tx} <-
               HookClient.set_budget(
                 p.adapter,
                 p.chain_id,
                 p.acp_core_address,
                 p.job_id,
                 budget.raw_amount
               ),
             {:ok, :budget_set} <-
               JobSession.apply_event(p.session, :budget_set, %{tx_hash: tx}) do
          {:ok, %{status: :budget_set, tx_hash: tx, response: response}}
        end

      {:reject, reason} ->
        {:rejected, reason}
    end
  end

  @doc """
  Produce and submit the deliverable once the job is funded.

  Invokes `handle_deliver/2`. On `{:deliver, deliverable}` it writes
  `submit(job, keccak256(deliverable))` on-chain and mirrors the session to
  `:submitted`. On `{:error, reason}` it makes no change and returns the error.

  Idempotent by the session status: `handle_deliver/2` runs only from `:funded`.
  On an already-`:submitted` session it is a no-op returning
  `{:ok, %{status: :submitted, idempotent: true}}` (no second handler call or
  on-chain write); from any other status it returns
  `{:error, {:cannot_deliver, status}}` without invoking the handler.
  """
  @spec deliver(t(), map()) ::
          ok(:submitted)
          | {:ok, %{status: :submitted, idempotent: true}}
          | {:error, term()}
  def deliver(%__MODULE__{} = p, request) do
    # Guard the side-effecting handler on the current status. `handle_deliver`
    # produces the deliverable (its work runs BEFORE the on-chain commit), so a
    # re-drive -- a redelivered payment event, or a retry after the commit landed
    # but the mirror did not -- must not run it twice. Once the session reflects
    # `:submitted` (via this driver's mirror or the SSE reconciliation of the
    # on-chain event), a re-`deliver` is an idempotent no-op.
    case safe_status(p.session) do
      :funded -> do_deliver(p, request)
      :submitted -> {:ok, %{status: :submitted, idempotent: true}}
      other -> {:error, {:cannot_deliver, other}}
    end
  end

  defp do_deliver(p, request) do
    case HandlerSeam.invoke(p.handler, :deliver, request, ctx(p)) do
      {:deliver, deliverable} ->
        with {:ok, tx} <-
               HookClient.submit(
                 p.adapter,
                 p.chain_id,
                 p.acp_core_address,
                 p.job_id,
                 deliverable_hash(deliverable)
               ),
             {:ok, :submitted} <-
               JobSession.apply_event(p.session, :submitted, %{tx_hash: tx}) do
          {:ok, %{status: :submitted, tx_hash: tx, deliverable: deliverable}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Evaluate a submitted deliverable, when this provider is also the evaluator.

  Invokes `handle_evaluate/2`. `{:approve, _}` writes `complete/3` and mirrors
  `:completed`; `{:reject, reason}` writes `reject/3` and mirrors `:rejected`
  (both terminal, so the session then stops). When the handler does not
  implement `handle_evaluate/2`, returns `{:error, :evaluate_not_supported}`
  so the caller can defer to an external evaluator.
  """
  @spec evaluate(t(), map()) ::
          ok(:completed) | ok(:rejected) | {:error, :evaluate_not_supported} | {:error, term()}
  def evaluate(%__MODULE__{} = p, deliverable) do
    case HandlerSeam.invoke(p.handler, :evaluate, deliverable, ctx(p)) do
      {:approve, response} -> finalize_evaluation(p, deliverable, :completed, response)
      {:reject, reason} -> finalize_evaluation(p, deliverable, :rejected, reason)
      {:error, :evaluate_not_supported} = err -> err
    end
  end

  # -- Internals --

  defp finalize_evaluation(p, deliverable, :completed, info) do
    with {:ok, tx} <-
           HookClient.complete(
             p.adapter,
             p.chain_id,
             p.acp_core_address,
             p.job_id,
             deliverable_hash(deliverable)
           ),
         {:ok, :completed} <- JobSession.apply_event(p.session, :completed, %{tx_hash: tx}) do
      {:ok, %{status: :completed, tx_hash: tx, info: info}}
    end
  end

  defp finalize_evaluation(p, deliverable, :rejected, info) do
    with {:ok, tx} <-
           HookClient.reject(
             p.adapter,
             p.chain_id,
             p.acp_core_address,
             p.job_id,
             deliverable_hash(deliverable)
           ),
         {:ok, :rejected} <- JobSession.apply_event(p.session, :rejected, %{tx_hash: tx}) do
      {:ok, %{status: :rejected, tx_hash: tx, info: info}}
    end
  end

  # Handler ctx: the job id plus the parties and current status, matching the
  # v1 `Job.Server` ctx shape so offering handlers are unchanged.
  defp ctx(p) do
    %{job_id: p.job_id, buyer: p.buyer, seller: p.seller, state: JobSession.status(p.session)}
  end

  # Read the session status without crashing on a terminal session, which stops
  # its process once it reaches `:completed`/`:rejected`/`:expired`. A gone
  # session is treated as an unknown status, so `deliver` refuses rather than
  # racing a finished job.
  defp safe_status(session) do
    JobSession.status(session)
  catch
    :exit, _ -> :gone
  end

  # 32-byte commitment to the deliverable payload: keccak256 of its canonical
  # JSON (matching `Xochi.SolverAgent`). HookClient.submit takes 32 raw bytes.
  defp deliverable_hash(deliverable) do
    deliverable
    |> Jason.encode!()
    |> ExKeccak.hash_256()
  end
end
