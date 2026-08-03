defmodule Raxol.Earn.JobSession.Client do
  @moduledoc """
  Drives a `Raxol.Earn.JobSession` from the BUYER (client) side -- the mirror of
  `Raxol.Earn.JobSession.Provider`. Where the provider reacts to a job that
  already exists, the buyer ORIGINATES one: it discovers an offering (via the
  `Raxol.Earn.Buyer` runtime), gates the spend, creates the job on-chain, funds
  the escrow once the seller sets the budget, and evaluates the delivered work.

  Like `Provider`, this is a plain struct built with `new/1`; its functions are
  pure orchestration over the session, the adapter, the spend gate, and the
  checkpoint (no process of its own -- the `Raxol.Earn.Buyer.Queue` calls them).
  Unlike `Provider` it threads an EVOLVING struct: `job_id`/`session` start `nil`
  and are filled once `create_job` lands, so each function returns the updated
  client alongside its result.

  ## Spend gating

  Every fund-moving step goes through `Raxol.Payments.Actions.SpendGate`: `buy/1`
  reserves the quoted amount atomically (`authorize` -> `Ledger.try_spend`) and
  tags the reservation with the `request_key`. A completed job forgets the tag
  (the spend stands); a rejected or expired one releases it (idempotent refund).
  With no `SpendingPolicy` configured the gate fails closed in production
  (`require_policy` defaults to `Raxol.Payments.Deployment.production?()`).

  ## Crash-resume (checkpointing)

  The seller keys its checkpoint by `job_id`, which pre-exists on the incoming
  event. The buyer has no `job_id` until after `create_job`, so it keys a single
  accreting record by a client-minted `request_key`
  (`Raxol.Earn.Checkpoint.buyer_key/2`) whose `"phase"` field advances
  `reserved -> creating -> created -> bound -> funding -> funded -> released`.
  On any replay `buy/1`/`on_budget_set/2` fetch that record and resume from the
  furthest recorded phase, so budget is reserved once and the escrow funded once.

  `create_job` is the one non-idempotent on-chain write (each call mints a NEW
  job + escrow; there is no phase guard to revert a duplicate, unlike
  `fund`/`submit`). To make it recoverable the buyer stamps a short `request_tag`
  derived from the `request_key` into the job's `description`; if a crash lands
  in the `creating` window (broadcast sent, tx hash not yet recorded) the resume
  path reconciles by that tag through `Raxol.Earn.JobIdResolver.reconcile/4`
  before ever re-broadcasting, and only re-creates when reconcile proves no job
  carries the tag. Honest semantics: **exactly-once-effective for reserve and
  fund; create is at-least-once-attempted with deterministic tag reconcile.**
  With `require_checkpoint: true` and no store, fund-adjacent writes fail closed
  with `{:error, :checkpoint_required}` before any reserve or write.
  """

  alias Raxol.Earn.{AssetToken, HookClient, JobIdResolver, JobSession}
  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.Checkpoint

  @zero_address "0x" <> String.duplicate("0", 40)

  @enforce_keys [:adapter, :chain_id, :acp_core_address, :buyer, :provider, :amount, :request_key]
  defstruct [
    :adapter,
    :api,
    :resolver,
    :chain_id,
    :acp_core_address,
    :buyer,
    :provider,
    :evaluator,
    :hook_address,
    :offering,
    :amount,
    :request_key,
    :expired_at,
    :description,
    :ledger,
    :policy,
    :agent_id,
    :require_policy,
    :checkpoint,
    :evaluate_fn,
    session: nil,
    job_id: nil
  ]

  @type t :: %__MODULE__{
          adapter: Raxol.Earn.ProviderAdapter.adapter(),
          api: Raxol.Earn.JobApi.t() | nil,
          resolver: JobIdResolver.t(),
          chain_id: pos_integer(),
          acp_core_address: String.t(),
          buyer: String.t(),
          provider: String.t(),
          evaluator: String.t(),
          hook_address: String.t(),
          offering: String.t() | nil,
          amount: AssetToken.t(),
          request_key: String.t(),
          expired_at: non_neg_integer() | nil,
          description: String.t() | nil,
          ledger: GenServer.server() | nil,
          policy: Raxol.Payments.SpendingPolicy.t() | nil,
          agent_id: term(),
          require_policy: boolean() | nil,
          checkpoint: Checkpoint.store() | nil,
          evaluate_fn: (map(), map() -> {:approve, term()} | {:reject, term()}),
          session: JobSession.job_key() | nil,
          job_id: non_neg_integer() | nil
        }

  @doc """
  Build a buyer driver.

  Required: `:adapter`, `:chain_id`, `:acp_core_address`, `:buyer`, `:provider`,
  `:amount` (an `AssetToken` -- the reserved spend ceiling). Optional but
  usual: `:api`, `:resolver` (default `JobIdResolver.Receipt`), `:evaluator`
  (default `:buyer`), `:hook_address` (default zero -- a plain job),
  `:expired_at`, `:ledger`, `:policy`, `:agent_id`, `:require_policy`,
  `:checkpoint`, `:evaluate_fn`, `:offering`, and `:nonce` (folded into the
  minted `request_key` so two otherwise-identical buys stay distinct).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    {nonce, opts} = Keyword.pop(opts, :nonce)
    opts = Keyword.put_new_lazy(opts, :request_key, fn -> derive_request_key(opts, nonce) end)

    c = struct!(__MODULE__, opts)

    %{
      c
      | resolver: c.resolver || %{adapter: Raxol.Earn.JobIdResolver.Receipt},
        evaluator: c.evaluator || c.buyer,
        hook_address: c.hook_address || @zero_address,
        evaluate_fn: c.evaluate_fn || (&default_evaluate/2)
    }
  end

  @doc """
  Reserve the spend and create the job on-chain, resolving the assigned `job_id`.

  Runs the fail-closed checkpoint gate, then resumes from any recorded phase:
  a fresh call reserves (`SpendGate.authorize`), pins `creating`, writes
  `createJob` (description carries the request tag), resolves the `job_id`, and
  starts a `JobSession(:client)`. Returns `{:ok, client, %{status: :open,
  job_id: id, tx_hash: tx}}` with the job_id/session filled in.
  """
  @spec buy(t()) ::
          {:ok, t(), map()}
          | {:rejected, term()}
          | {:error, term()}
  def buy(%__MODULE__{} = c) do
    with :ok <- ensure_checkpoint(c) do
      resume_from(c, ck_fetch(c))
    end
  end

  # Resume from the furthest recorded checkpoint phase (or a fresh reserve).
  defp resume_from(c, :error), do: reserve(c)
  defp resume_from(c, {:ok, %{"phase" => "reserved"} = rec}), do: create(c, rec)
  defp resume_from(c, {:ok, %{"phase" => "creating"} = rec}), do: reconcile_or_create(c, rec)
  defp resume_from(c, {:ok, %{"phase" => "created"} = rec}), do: resolve_and_bind(c, rec)

  defp resume_from(c, {:ok, %{"phase" => phase} = rec})
       when phase in ~w(bound funding funded released),
       do: resume(c, rec)

  @doc """
  Fund the escrow after the seller set the budget.

  `observed_budget_raw` is the budget the seller set (from the `:budget_set`
  event); when omitted the reserved amount is used. Asserts the budget does not
  exceed what was reserved -- a seller that over-budgets is rejected (reservation
  released, session expired). Otherwise mirrors `:budget_set` if needed, pins
  `funding`, writes `fund`, and mirrors `:funded`. Idempotent by session status.
  """
  @spec on_budget_set(t(), non_neg_integer() | nil) ::
          {:ok, t(), map()}
          | {:ok, %{status: :funded, idempotent: true}}
          | {:rejected, term()}
          | {:error, term()}
  def on_budget_set(%__MODULE__{} = c, observed_budget_raw \\ nil) do
    case safe_status(c.session) do
      status when status in [:open, :budget_set] -> fund_flow(c, observed_budget_raw)
      :funded -> {:ok, %{status: :funded, idempotent: true}}
      other -> {:error, {:cannot_fund, other}}
    end
  end

  @doc """
  Evaluate a submitted deliverable and settle the job (buyer as evaluator).

  Runs `evaluate_fn/2`; `{:approve, info}` writes `complete` and forgets the
  reservation (spend stands), `{:reject, reason}` writes `reject` and releases
  the reservation (idempotent refund). Both are terminal.
  """
  @spec on_submitted(t(), map()) :: {:ok, t(), map()} | {:error, term()}
  def on_submitted(%__MODULE__{} = c, deliverable) do
    case c.evaluate_fn.(deliverable, ctx(c)) do
      {:approve, info} -> finalize(c, deliverable, :completed, info)
      {:reject, reason} -> finalize(c, deliverable, :rejected, reason)
    end
  end

  @doc """
  Release the reservation for a job that ended without completing (external
  expiry). Idempotent -- safe to call more than once. Drops the checkpoint.
  """
  @spec release(t()) :: :ok
  def release(%__MODULE__{} = c) do
    _ = SpendGate.release_by_intent(spend_ctx(c), c.request_key)
    cleanup(c)
  end

  @doc "Drop this purchase's checkpoint record. Safe with no store."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{} = c), do: Checkpoint.delete(c.checkpoint, ck_key(c))

  @doc "The short tag stamped into the job description for reconcile-by-tag."
  @spec request_tag(t()) :: String.t()
  def request_tag(%__MODULE__{request_key: rk}), do: "raxol-earn:" <> String.slice(rk, 0, 16)

  # -- buy/1 phases --

  defp reserve(c) do
    amount = AssetToken.to_human(c.amount)

    case SpendGate.authorize(spend_ctx(c), amount, metadata: %{request_key: c.request_key}) do
      :ok ->
        :ok = SpendGate.tag_reservation(spend_ctx(c), c.request_key, amount)

        rec = %{
          "phase" => "reserved",
          "request_key" => c.request_key,
          "amount_raw" => c.amount.raw_amount
        }

        :ok = ck_put(c, rec)
        create(c, rec)

      {:error, reason} ->
        {:rejected, {:spend_rejected, reason}}
    end
  end

  # Pin the create parameters (including the tagged description) BEFORE
  # broadcasting, so a resume re-broadcasts byte-identical params -- same tag,
  # so reconcile can still find the job.
  defp create(c, rec) do
    params = create_params(c)
    rec = Map.merge(rec, %{"phase" => "creating", "create_params" => params})
    :ok = ck_put(c, rec)
    broadcast_create(c, rec, params)
  end

  # `creating` on resume: we pinned params and may or may not have broadcast.
  # Reconcile by the request tag first; adopt an existing job, else it is safe
  # to (re)broadcast the pinned params.
  defp reconcile_or_create(c, rec) do
    case reconcile(c) do
      {:ok, job_id} ->
        bind(c, rec, job_id)

      :none ->
        broadcast_create(c, rec, rec["create_params"] || create_params(c))

      {:error, reason} ->
        {:error, {:reconcile_failed, reason}}
    end
  end

  defp broadcast_create(c, rec, params) do
    case HookClient.create_job(c.adapter, c.chain_id, c.acp_core_address, atomize_params(params)) do
      {:ok, tx} ->
        rec = Map.merge(rec, %{"phase" => "created", "create_tx" => tx})
        :ok = ck_put(c, rec)
        resolve_and_bind(c, rec)

      {:error, reason} ->
        {:error, {:create_failed, reason}}
    end
  end

  # `created`: the tx landed and is pinned. Resolve the job_id from the receipt,
  # falling back to reconcile-by-tag when the receipt is not yet available.
  defp resolve_and_bind(c, rec) do
    tx = rec["create_tx"]

    case JobIdResolver.resolve(c.resolver, c.adapter, c.chain_id, tx) do
      {:ok, job_id} ->
        bind(c, rec, job_id)

      :pending ->
        case reconcile(c) do
          {:ok, job_id} -> bind(c, rec, job_id)
          :none -> {:error, :job_id_unresolved}
          {:error, reason} -> {:error, {:reconcile_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:resolve_failed, reason}}
    end
  end

  defp reconcile(%{api: nil}), do: {:error, :reconcile_unavailable}
  defp reconcile(c), do: JobIdResolver.reconcile(c.resolver, c.api, c.chain_id, request_tag(c))

  # Bind the resolved job_id, start the client session, and record `bound`.
  defp bind(c, rec, job_id) do
    with {:ok, session} <- start_session(c, job_id) do
      c = %{c | job_id: job_id, session: session}
      :ok = ck_put(c, Map.merge(rec, %{"phase" => "bound", "job_id" => job_id}))
      {:ok, c, %{status: :open, job_id: job_id, tx_hash: rec["create_tx"]}}
    end
  end

  # Resume a client already past `create`: rebuild job_id/session from the record.
  defp resume(c, rec) do
    job_id = rec["job_id"]

    with {:ok, session} <- start_session(c, job_id) do
      c = %{c | job_id: job_id, session: session}
      {:ok, c, %{status: :resumed, job_id: job_id, phase: rec["phase"]}}
    end
  end

  # -- on_budget_set/2 --

  defp fund_flow(c, observed_budget_raw) do
    with :ok <- ensure_checkpoint(c),
         {:ok, rec} <- require_record(c) do
      reserved = rec["amount_raw"] || c.amount.raw_amount
      budget_raw = observed_budget_raw || reserved

      cond do
        budget_raw > reserved -> over_budget(c, budget_raw, reserved)
        funded?(rec) -> resume_funded(c, rec)
        true -> fund(c, rec, budget_raw)
      end
    end
  end

  defp fund(c, rec, budget_raw) do
    mirror_budget_set(c)
    :ok = ck_put(c, Map.put(rec, "phase", "funding"))

    case HookClient.fund(c.adapter, c.chain_id, c.acp_core_address, c.job_id, budget_raw) do
      {:ok, tx} ->
        rec = Map.merge(rec, %{"phase" => "funded", "fund_tx" => tx, "funded_raw" => budget_raw})
        :ok = ck_put(c, rec)
        {:ok, :funded} = JobSession.apply_event(c.session, :funded, %{tx_hash: tx})
        {:ok, c, %{status: :funded, tx_hash: tx}}

      {:error, reason} ->
        {:error, {:fund_failed, reason}}
    end
  end

  # The fund write committed pre-crash but the mirror lagged: mirror and return,
  # no second fund.
  defp resume_funded(c, %{"fund_tx" => tx}) do
    if safe_status(c.session) == :funded do
      {:ok, %{status: :funded, idempotent: true}}
    else
      {:ok, :funded} = JobSession.apply_event(c.session, :funded, %{tx_hash: tx, resumed: true})
      {:ok, c, %{status: :funded, tx_hash: tx, resumed: true}}
    end
  end

  defp over_budget(c, budget_raw, reserved) do
    _ = SpendGate.release_by_intent(spend_ctx(c), c.request_key)
    JobSession.apply_event(c.session, :expired, %{reason: "budget_over_reserved"})
    cleanup(c)
    {:rejected, {:budget_over_reserved, budget_raw, reserved}}
  end

  # Mirror the observed :budget_set when the session is still :open, so the
  # local status tracks the chain before we fund.
  defp mirror_budget_set(c) do
    if safe_status(c.session) == :open do
      JobSession.apply_event(c.session, :budget_set, %{observed: true})
    end
  end

  # -- on_submitted/2 --

  defp finalize(c, deliverable, :completed, info) do
    with {:ok, tx} <-
           HookClient.complete(
             c.adapter,
             c.chain_id,
             c.acp_core_address,
             c.job_id,
             deliverable_hash(deliverable)
           ),
         {:ok, :completed} <- JobSession.apply_event(c.session, :completed, %{tx_hash: tx}) do
      # The spend stands: forget the tag but keep the ledger entry.
      SpendGate.forget_reservation(spend_ctx(c), c.request_key)
      cleanup(c)
      {:ok, c, %{status: :completed, tx_hash: tx, info: info}}
    end
  end

  defp finalize(c, deliverable, :rejected, reason) do
    with {:ok, tx} <-
           HookClient.reject(
             c.adapter,
             c.chain_id,
             c.acp_core_address,
             c.job_id,
             deliverable_hash(deliverable)
           ),
         {:ok, :rejected} <- JobSession.apply_event(c.session, :rejected, %{tx_hash: tx}) do
      # Rejected: the escrow returns, so release the reservation (idempotent).
      _ = SpendGate.release_by_intent(spend_ctx(c), c.request_key)
      cleanup(c)
      {:ok, c, %{status: :rejected, tx_hash: tx, info: reason}}
    end
  end

  # -- Checkpoint plumbing --

  defp ensure_checkpoint(%{checkpoint: nil}) do
    if Raxol.Earn.Checkpoint.required?(), do: {:error, :checkpoint_required}, else: :ok
  end

  defp ensure_checkpoint(_c), do: :ok

  defp require_record(c) do
    case ck_fetch(c) do
      {:ok, rec} -> {:ok, rec}
      # No record but a buy already ran (session exists): fall back to the
      # reserved amount so funding can proceed without a store in dev.
      :error -> {:ok, %{"amount_raw" => c.amount.raw_amount}}
    end
  end

  defp ck_key(c), do: Raxol.Earn.Checkpoint.buyer_key(c.chain_id, c.request_key)
  defp ck_fetch(c), do: Checkpoint.fetch(c.checkpoint, ck_key(c))
  defp ck_put(c, rec), do: Checkpoint.put(c.checkpoint, ck_key(c), rec)

  defp funded?(%{"fund_tx" => tx}) when is_binary(tx), do: true
  defp funded?(_), do: false

  # -- Spend gate context --

  defp spend_ctx(c) do
    %{policy: c.policy, ledger: c.ledger, agent_id: c.agent_id || :unknown}
    |> maybe_put(:require_policy, c.require_policy)
  end

  # -- Session --

  defp start_session(c, job_id) do
    case Raxol.Earn.JobSession.Supervisor.start_session(
           chain_id: c.chain_id,
           job_id: job_id,
           role: :client
         ) do
      {:ok, _pid} -> {:ok, {c.chain_id, job_id}}
      {:error, {:already_started, _pid}} -> {:ok, {c.chain_id, job_id}}
      {:error, reason} -> {:error, {:session_start_failed, reason}}
    end
  end

  defp safe_status(nil), do: :none

  defp safe_status(session) do
    JobSession.status(session)
  catch
    :exit, _ -> :gone
  end

  # -- create params --

  # Stored with string keys (checkpoint records round-trip as JSON) and rebuilt
  # to the atom-keyed map HookClient.create_job/4 expects.
  defp create_params(c) do
    %{
      "provider" => c.provider,
      "evaluator" => c.evaluator || c.buyer,
      "expired_at" => c.expired_at || 0,
      "hook_address" => c.hook_address || @zero_address,
      "description" => tagged_description(c)
    }
  end

  defp atomize_params(params) do
    %{
      provider: params["provider"],
      evaluator: params["evaluator"],
      expired_at: params["expired_at"],
      hook_address: params["hook_address"],
      description: params["description"]
    }
  end

  # The description always carries the request tag so reconcile-by-tag works,
  # appended to any caller-provided base.
  defp tagged_description(c) do
    tag = request_tag(c)

    case c.description do
      nil -> tag
      base when is_binary(base) -> base <> " [" <> tag <> "]"
    end
  end

  # -- misc --

  defp ctx(c) do
    %{
      job_id: c.job_id,
      buyer: c.buyer,
      seller: c.provider,
      offering: c.offering,
      state: safe_status(c.session)
    }
  end

  # Default evaluator: accept a non-empty deliverable map, reject anything else.
  # Callers pass a real schema check (or an offering's `handle_evaluate`) via
  # `:evaluate_fn`.
  defp default_evaluate(deliverable, _ctx) when is_map(deliverable) and map_size(deliverable) > 0,
    do: {:approve, %{evaluator: :default}}

  defp default_evaluate(_deliverable, _ctx), do: {:reject, :empty_deliverable}

  # 32-byte commitment to the deliverable payload, matching Provider's
  # convention (keccak256 of canonical JSON).
  defp deliverable_hash(deliverable) do
    deliverable
    |> Jason.encode!()
    |> ExKeccak.hash_256()
  end

  defp derive_request_key(opts, nonce) do
    amount = Keyword.fetch!(opts, :amount)

    Checkpoint.derive_key([
      :acp_buy,
      Keyword.fetch!(opts, :chain_id),
      Keyword.fetch!(opts, :buyer),
      Keyword.fetch!(opts, :provider),
      Keyword.get(opts, :offering),
      amount.raw_amount,
      nonce || ""
    ])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
