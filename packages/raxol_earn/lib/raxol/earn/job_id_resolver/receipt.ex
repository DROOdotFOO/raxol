defmodule Raxol.Earn.JobIdResolver.Receipt do
  @moduledoc """
  Default `Raxol.Earn.JobIdResolver`: decode the `jobId` from the `createJob`
  transaction receipt, and reconcile a lost `createJob` via the discovery API.

  `resolve/4` reads the receipt through `ProviderAdapter.get_transaction_receipt`
  and decodes the `JobCreated` event's indexed `uint256 jobId` from its topics
  with `Raxol.Earn.Onchain.LogDecoder`. `reconcile/4` lists active jobs via
  `JobApi.get_active_jobs` and matches the one whose `description` carries the
  buyer's `request_tag` -- the recovery path when a crash lost the tx hash.

  ## Event signature (verified)

  The defaults below are verified against the deployed `AgenticCommerceV3`
  (Base `0x8e86FbEf...B77BC`, behind the ACP Core proxy): `JobCreated` carries
  six params, with `jobId`, `client` and `provider` the indexed ones, so topic 0
  is `keccak256("JobCreated(uint256,address,address,address,uint256,address)")`,
  `jobId` is `topics[1]` and `client` is `topics[2]`. Override via the resolver
  config only if the core is upgraded and the event changes:

      %{adapter: Raxol.Earn.JobIdResolver.Receipt,
        config: %{
          event_signature: "JobCreated(uint256,address,address,address,uint256,address)",
          topic_index: 1,                           # 1-based; topic 0 is the hash
          client_topic_index: 2,
          emitter: "0x...",                         # the ACP core that must have emitted it
          client: "0x..."                           # our buyer address
        }}

  ## Scoping (why `:client` and `:emitter` matter)

  The receipt read here is not always this buyer's own transaction's. On the
  ERC-4337 path `Raxol.Earn.ProviderAdapter.SCA` reports the BUNDLE's
  `transactionHash`, and that receipt's `logs` carry every co-bundled UserOp's
  logs -- including another buyer's genuine `JobCreated` from the same ACP core,
  which a topic-0-only search would take if it came first. `:client` is the
  discriminator that actually separates them (the deployed event indexes it);
  `:emitter` is defence in depth against a look-alike event from another
  contract.

  Both are unset by default here, which matches ANY log, because this is a
  public injectable seam whose `resolve/4` contract is fail-soft. The buyer does
  not opt in: `Raxol.Earn.JobSession.Client.new/1` fills both from the
  `:acp_core_address` and `:buyer` it already holds. Pass either explicitly as
  `nil` to opt back out.

  `reconcile/4`'s recovery path depends on `createJob`'s `description` string
  round-tripping on-chain and being readable back through `get_active_jobs`.
  """

  @behaviour Raxol.Earn.JobIdResolver

  alias Raxol.Earn.{JobApi, Onchain.LogDecoder, ProviderAdapter}

  # Verified against the deployed AgenticCommerceV3 (see moduledoc).
  @default_event_signature "JobCreated(uint256,address,address,address,uint256,address)"
  @default_topic_index 1
  @default_client_topic_index 2

  @impl Raxol.Earn.JobIdResolver
  def resolve(resolver, adapter, chain_id, tx_hash) do
    signature = cfg(resolver, :event_signature, @default_event_signature)
    topic_index = cfg(resolver, :topic_index, @default_topic_index)
    match_opts = match_opts(resolver)

    case ProviderAdapter.get_transaction_receipt(adapter, chain_id, tx_hash) do
      # No receipt yet: the tx is not mined. Let the caller poll / reconcile.
      {:ok, nil} ->
        :pending

      {:ok, receipt} ->
        decode_from_logs(logs_of(receipt), signature, topic_index, match_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Raxol.Earn.JobIdResolver
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

  # Narrow the search to the JobCreated this buyer caused: an ERC-4337 bundle
  # receipt also carries the logs of every other UserOp in the bundle.
  defp match_opts(resolver) do
    client_topic_index = cfg(resolver, :client_topic_index, @default_client_topic_index)

    [
      emitter: cfg(resolver, :emitter, nil),
      topics: client_topics(cfg(resolver, :client, nil), client_topic_index)
    ]
  end

  # A configured-but-malformed client address raises out of LogDecoder rather
  # than quietly matching nothing, which would be indistinguishable from an
  # unmined receipt.
  defp client_topics(nil, _index), do: %{}
  defp client_topics(client, index), do: %{index => client}

  # An event that isn't present is treated as "not ready yet" (:pending) rather
  # than a hard error, so the crash-recovery caller can fall through to
  # reconcile. A genuinely wrong signature -- or a bundle that carries only
  # other buyers' jobs -- therefore surfaces as a reconcile `:none`, which the
  # buyer turns into a visible error, instead of a silent wrong id.
  defp decode_from_logs(logs, signature, topic_index, match_opts) do
    case LogDecoder.extract(logs, signature, topic_index, :uint256, match_opts) do
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

    is_binary(description) and
      (String.contains?(description, request_tag) or
         String.contains?(description, legacy_request_tag(request_tag)))
  end

  # Jobs created before the raxol_acp -> raxol_earn rename stamped their
  # description with the old "raxol-acp:" prefix. Match those too so a rename
  # deploy does not strand in-flight jobs on the reconcile-by-tag recovery path.
  # Retire once no legacy-tagged jobs remain in flight.
  defp legacy_request_tag("raxol-earn:" <> rest), do: "raxol-acp:" <> rest
  defp legacy_request_tag(tag), do: tag

  defp job_id_or_none(nil), do: :none

  defp job_id_or_none(job) do
    case job_id_of(job) do
      nil -> :none
      id -> {:ok, id}
    end
  end

  # Tolerant reader matching `Raxol.Earn.Agent.job_id_from/1`: the live SSE / API
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
