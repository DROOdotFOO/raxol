defmodule Raxol.ACP.JobIdResolver.Receipt do
  @moduledoc """
  Default `Raxol.ACP.JobIdResolver`: decode the `jobId` from the `createJob`
  transaction receipt, and reconcile a lost `createJob` via the discovery API.

  `resolve/4` reads the receipt through `ProviderAdapter.get_transaction_receipt`
  and decodes the `JobCreated` event's indexed `uint256 jobId` from its topics
  with `Raxol.ACP.Onchain.LogDecoder`. `reconcile/4` lists active jobs via
  `JobApi.get_active_jobs` and matches the one whose `description` carries the
  buyer's `request_tag` -- the recovery path when a crash lost the tx hash.

  ## Event signature (verified)

  The defaults below are verified against the deployed `AgenticCommerceV3`
  (Base `0x8e86FbEf...B77BC`, behind the ACP Core proxy): `JobCreated` carries
  six params, with `jobId` the first indexed one, so topic 0 is
  `keccak256("JobCreated(uint256,address,address,address,uint256,address)")`
  and `jobId` is `topics[1]`. Override via the resolver config only if the core
  is upgraded and the event changes:

      %{adapter: Raxol.ACP.JobIdResolver.Receipt,
        config: %{
          event_signature: "JobCreated(uint256,address,address,address,uint256,address)",
          topic_index: 1                            # 1-based; topic 0 is the hash
        }}

  `reconcile/4`'s recovery path depends on `createJob`'s `description` string
  round-tripping on-chain and being readable back through `get_active_jobs`.
  """

  @behaviour Raxol.ACP.JobIdResolver

  alias Raxol.ACP.{JobApi, Onchain.LogDecoder, ProviderAdapter}

  # Verified against the deployed AgenticCommerceV3 (see moduledoc).
  @default_event_signature "JobCreated(uint256,address,address,address,uint256,address)"
  @default_topic_index 1

  @impl Raxol.ACP.JobIdResolver
  def resolve(resolver, adapter, chain_id, tx_hash) do
    signature = cfg(resolver, :event_signature, @default_event_signature)
    topic_index = cfg(resolver, :topic_index, @default_topic_index)

    case ProviderAdapter.get_transaction_receipt(adapter, chain_id, tx_hash) do
      # No receipt yet: the tx is not mined. Let the caller poll / reconcile.
      {:ok, nil} ->
        :pending

      {:ok, receipt} ->
        decode_from_logs(logs_of(receipt), signature, topic_index)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Raxol.ACP.JobIdResolver
  def reconcile(_resolver, api, _chain_id, request_tag) do
    case JobApi.get_active_jobs(api) do
      {:ok, jobs} ->
        jobs
        |> Enum.find(&description_matches?(&1, request_tag))
        |> job_id_or_none()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Internals --

  # An event that isn't present is treated as "not ready yet" (:pending) rather
  # than a hard error, so the crash-recovery caller can fall through to
  # reconcile. A genuinely wrong signature therefore surfaces as a reconcile
  # `:none` -- which the buyer turns into a visible error -- instead of a silent
  # wrong id, honoring the fail-closed posture.
  defp decode_from_logs(logs, signature, topic_index) do
    case LogDecoder.extract(logs, signature, topic_index, :uint256) do
      {:ok, job_id} -> {:ok, job_id}
      {:error, {:event_not_found, _}} -> :pending
      {:error, {:topic_out_of_range, _}} -> :pending
      {:error, reason} -> {:error, reason}
    end
  end

  defp logs_of(receipt) when is_map(receipt) do
    receipt["logs"] || receipt[:logs] || []
  end

  defp logs_of(_), do: []

  defp description_matches?(job, request_tag) when is_map(job) do
    description = job["description"] || job[:description] || ""
    is_binary(description) and String.contains?(description, request_tag)
  end

  defp job_id_or_none(nil), do: :none

  defp job_id_or_none(job) do
    case job_id_of(job) do
      nil -> :none
      id -> {:ok, id}
    end
  end

  # Tolerant reader matching `Raxol.ACP.Agent.job_id_from/1`: the live SSE / API
  # shapes spell the id `onChainJobId` / `jobId` / `job_id`. Coerce to integer.
  defp job_id_of(job) do
    raw =
      job["onChainJobId"] || job[:onChainJobId] || job["jobId"] || job[:jobId] ||
        job["job_id"] || job[:job_id]

    coerce_id(raw)
  end

  defp coerce_id(id) when is_integer(id), do: id

  defp coerce_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp coerce_id(_), do: nil

  defp cfg(%{config: config}, key, default) when is_map(config),
    do: Map.get(config, key, default)

  defp cfg(_resolver, _key, default), do: default
end
