defmodule Raxol.ACP.JobIdResolver do
  @moduledoc """
  Behaviour for resolving the on-chain `jobId` that `createJob` assigns.

  `Raxol.ACP.HookClient.create_job/4` returns only the transaction hash --
  the assigned `jobId` is emitted in a `JobCreated` event log. A BUYER
  (`Raxol.ACP.JobSession.Client`) originates the job, so unlike the seller it
  must resolve that id before it can `fund`. This seam keeps that resolution
  injectable (like `Raxol.ACP.ProviderAdapter` / `Raxol.ACP.JobApi`), so it is
  fully exercisable in tests via `Mock` and the real receipt-decode path stays
  behind one boundary that a Sepolia dry-run can confirm.

  Two paths, both needed by the crash-safe buyer:

  - `resolve/4` -- decode the id from the `createJob` receipt (the normal path
    and the resume path where we DO have the tx hash). May return `:pending`
    when the receipt is not yet available.
  - `reconcile/4` -- when a crash left us without a tx hash (we broadcast
    `createJob` but crashed before recording the hash), correlate an
    already-created job by the `request_tag` the buyer stamped into the job's
    `description`. This is what makes the non-idempotent `createJob` recoverable
    without minting a second job + escrow.

  ## Implementations

  - `Raxol.ACP.JobIdResolver.Receipt` (default) -- reads the receipt via
    `ProviderAdapter.get_transaction_receipt` and decodes the `JobCreated` topic
    with `Raxol.ACP.Onchain.LogDecoder`; reconciles via `JobApi.get_active_jobs`.
    The exact event signature, indexed position, and emitter address are config
    with placeholders that **must be confirmed against the deployed
    `AgenticCommerceV3` in the Sepolia dry-run** (see the module).
  - `Raxol.ACP.JobIdResolver.Mock` -- canned tx->id and tag->id maps for tests.
  """

  alias Raxol.ACP.{JobApi, ProviderAdapter}

  @type t :: %{required(:adapter) => module(), optional(:config) => map()}
  @type job_id :: non_neg_integer()

  @callback resolve(t(), ProviderAdapter.adapter(), pos_integer(), String.t()) ::
              {:ok, job_id()} | :pending | {:error, term()}

  @callback reconcile(t(), JobApi.t(), pos_integer(), String.t()) ::
              {:ok, job_id()} | :none | {:error, term()}

  @doc "Decode the `jobId` from the `createJob` receipt for `tx_hash`."
  @spec resolve(t(), ProviderAdapter.adapter(), pos_integer(), String.t()) ::
          {:ok, job_id()} | :pending | {:error, term()}
  def resolve(resolver, adapter, chain_id, tx_hash),
    do: resolver.adapter.resolve(resolver, adapter, chain_id, tx_hash)

  @doc "Correlate an already-created job by the `request_tag` in its description."
  @spec reconcile(t(), JobApi.t(), pos_integer(), String.t()) ::
          {:ok, job_id()} | :none | {:error, term()}
  def reconcile(resolver, api, chain_id, request_tag),
    do: resolver.adapter.reconcile(resolver, api, chain_id, request_tag)
end
