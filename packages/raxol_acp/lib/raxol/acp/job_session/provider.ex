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

  ## Crash-resume (checkpointing)

  The status guards above make re-drives idempotent while the session process
  survives. Across a BEAM restart the session is gone, so the guards alone
  cannot stop a re-driven `deliver` from re-running a (nondeterministic,
  inference-heavy) handler and submitting a *different* hash than an in-flight
  first attempt. When a `:checkpoint` store is injected (see
  `Raxol.ACP.Checkpoint`), `deliver/2` therefore pins the encoded deliverable
  and its keccak **before** signing, reuses the pinned bytes on any replay, and
  records the tx hash after the write -- so across a crash at any point exactly
  one deliverable hash can ever reach the chain, and a duplicate submit of that
  same hash reverts harmlessly on the phase guard. `accept_request/3` records
  its `setBudget` tx the same way so an API-lagged resync cannot re-sign it.
  With `require_checkpoint: true` and no store configured, both fund-adjacent
  writes fail closed with `{:error, :checkpoint_required}` before invoking the
  handler. Records use string keys and pre-encoded JSON so they survive
  JSON-round-tripping stores byte-identically.
  """

  alias Raxol.ACP.{AssetToken, HookClient, JobSession}
  alias Raxol.ACP.JobSession.HandlerSeam
  alias Raxol.Payments.Checkpoint

  @enforce_keys [:session, :handler, :adapter, :chain_id, :acp_core_address, :job_id]
  defstruct [
    :session,
    :handler,
    :adapter,
    :chain_id,
    :acp_core_address,
    :job_id,
    buyer: nil,
    seller: nil,
    checkpoint: nil
  ]

  @type t :: %__MODULE__{
          session: GenServer.server() | JobSession.job_key(),
          handler: module(),
          adapter: Raxol.ACP.ProviderAdapter.adapter(),
          chain_id: pos_integer(),
          acp_core_address: String.t(),
          job_id: non_neg_integer(),
          buyer: String.t() | nil,
          seller: String.t() | nil,
          checkpoint: Checkpoint.store() | nil
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
      :open -> accept_from_open(p, request, budget)
      :budget_set -> {:ok, %{status: :budget_set, idempotent: true}}
      other -> {:error, {:cannot_accept, other}}
    end
  end

  # A rebuilt/lagging session can read `:open` while the `setBudget` tx already
  # landed pre-crash. The accept checkpoint records the tx after the write; on
  # a hit we mirror and return instead of re-invoking the handler or re-signing.
  defp accept_from_open(p, request, budget) do
    case ck_fetch(p, :accept) do
      {:ok, %{"tx_hash" => tx}} when is_binary(tx) ->
        with {:ok, :budget_set} <-
               JobSession.apply_event(p.session, :budget_set, %{tx_hash: tx, resumed: true}) do
          {:ok, %{status: :budget_set, tx_hash: tx, resumed: true}}
        end

      _ ->
        do_accept_request(p, request, budget)
    end
  end

  defp do_accept_request(p, request, budget) do
    with :ok <- ensure_checkpoint(p) do
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
               :ok = ck_put(p, :accept, %{"tx_hash" => tx}),
               {:ok, :budget_set} <-
                 JobSession.apply_event(p.session, :budget_set, %{tx_hash: tx}) do
            {:ok, %{status: :budget_set, tx_hash: tx, response: response}}
          end

        {:reject, reason} ->
          {:rejected, reason}
      end
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
    with :ok <- ensure_checkpoint(p) do
      case ck_fetch(p, :submit) do
        # The write committed pre-crash but the mirror (or the API the session
        # was rehydrated from) lagged: mirror and return, no handler, no tx.
        {:ok, %{"tx_hash" => tx} = rec} when is_binary(tx) ->
          with {:ok, :submitted} <-
                 JobSession.apply_event(p.session, :submitted, %{tx_hash: tx, resumed: true}) do
            {:ok, %{status: :submitted, tx_hash: tx, deliverable: pinned(rec), resumed: true}}
          end

        # The handler ran pre-crash but the write did not commit: reuse the
        # pinned bytes so the exact same hash is (re)submitted.
        {:ok, rec} ->
          sign_submit(p, rec)

        :error ->
          run_handler_and_submit(p, request)
      end
    end
  end

  defp run_handler_and_submit(p, request) do
    case HandlerSeam.invoke(p.handler, :deliver, request, ctx(p)) do
      {:deliver, deliverable} ->
        json = Jason.encode!(deliverable)
        hash_hex = json |> ExKeccak.hash_256() |> Base.encode16(case: :lower)
        rec = %{"deliverable_json" => json, "hash_hex" => hash_hex}
        # Pin BEFORE signing: from here on, only these bytes can ever be
        # submitted for this job, however many times we crash and replay.
        :ok = ck_put(p, :submit, rec)
        # Return the handler's own deliverable term on the fresh path; a resumed
        # sign returns the decoded pinned form (the JSON bytes are identical).
        sign_submit(p, rec, deliverable)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resume (pinned-but-unsigned) path: only the pinned bytes survived the crash.
  defp sign_submit(p, %{"deliverable_json" => json} = rec),
    do: sign_submit(p, rec, Jason.decode!(json))

  defp sign_submit(p, %{"hash_hex" => hash_hex} = rec, deliverable) do
    with {:ok, tx} <-
           HookClient.submit(
             p.adapter,
             p.chain_id,
             p.acp_core_address,
             p.job_id,
             Base.decode16!(hash_hex, case: :lower)
           ),
         :ok = ck_put(p, :submit, Map.put(rec, "tx_hash", tx)),
         {:ok, :submitted} <-
           JobSession.apply_event(p.session, :submitted, %{tx_hash: tx}) do
      {:ok, %{status: :submitted, tx_hash: tx, deliverable: deliverable}}
    end
  end

  defp pinned(%{"deliverable_json" => json}), do: Jason.decode!(json)

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

  @doc """
  Drop this job's checkpoint records. Call once the job reaches a terminal
  status through an *external* path (evaluator approval, expiry) -- the
  `evaluate/2` terminals clean up on their own. Safe with no store configured.
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{} = p) do
    :ok = Checkpoint.delete(p.checkpoint, ck_key(p, :accept))
    :ok = Checkpoint.delete(p.checkpoint, ck_key(p, :submit))
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
      cleanup(p)
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
      cleanup(p)
      {:ok, %{status: :rejected, tx_hash: tx, info: info}}
    end
  end

  # -- Checkpoint plumbing --

  # Fail closed on fund-adjacent writes: with `require_checkpoint: true` and no
  # injected store, refuse before invoking the handler or touching the chain.
  defp ensure_checkpoint(%{checkpoint: nil}) do
    if Raxol.ACP.Checkpoint.required?(), do: {:error, :checkpoint_required}, else: :ok
  end

  defp ensure_checkpoint(_p), do: :ok

  defp ck_key(p, step), do: Raxol.ACP.Checkpoint.key(p.chain_id, p.job_id, step)

  defp ck_fetch(p, step), do: Checkpoint.fetch(p.checkpoint, ck_key(p, step))

  defp ck_put(p, step, record), do: Checkpoint.put(p.checkpoint, ck_key(p, step), record)

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
