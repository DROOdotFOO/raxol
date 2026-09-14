defmodule Raxol.Web3.Backend.Aztec do
  @moduledoc """
  The Aztec backend, against the Aztecscan (`chicmoz`) REST surface.

  **Public state only.** Aztec's private state is notes, and a note is
  unobservable by construction rather than by an indexer's choice. That is a
  property of the chain and not of this source, so it bounds what any Aztec
  backend can ever declare: every read below answers a question about the
  public half, and the questions that need the private half are absent from
  `capabilities/1` rather than answered emptily. ADR-0039 decision 3 is what
  makes absence the answer, and `Raxol.Web3.Router.coverage/2` is what makes it
  legible to an operator instead of surfacing as an error per call.

  Every path named here was probed on 2026-09-14 and the shapes are pinned by
  recorded responses in `test/fixtures/aztec`. The route table itself is
  published (`chicmoz` is Apache-2.0), but the responses are not specified
  anywhere, so the mapping is probe-derived and has to be re-probed on upgrade
  rather than read.

  ## The primary path is named temporary, so assume revocation

  `@sources` carries `https://api.aztecscan.xyz/v1/temporary-api-key` as data
  with a dated comment, exactly as `Raxol.Web3.Backend.Blockscout`'s
  chain-to-host table does. The path segment that stands where an API key would
  stand is literally named `temporary-api-key`, so the interesting question is
  not whether it is withdrawn but what happens on the day it is.

  What happens is a handled failure rather than a predicted one. Measured
  2026-09-14 by substituting a bogus key segment, a withdrawn prefix answers
  **404 `text/plain`** from the edge, not 403. That matters twice:
  `Raxol.Web3.HTTP` records a 404 as breaker *success*, because a definitive
  answer about a missing thing is a healthy upstream, so health alone would
  never fail a revoked prefix over. Classification is what does it, and the
  classification is structural rather than textual:

    * A 404 on a **parameterless** endpoint (`/l2/info`, `/l2/tips`,
      `/l2/stats/*`) cannot mean "that resource is absent", because there is no
      parameter for it to be absent for. Every endpoint under a withdrawn
      prefix answers 404, so a 404 here is a withdrawn credential:
      `{:upstream_refused, :auth}`.
    * A 404 on an **addressed** endpoint (a block, a transaction hash, a
      contract instance) is an answer: `{:upstream_refused, :not_found}`, which
      must not fail over, because the fallback would answer the same.

  A 403 is left as `{:http, 403}` rather than reclassified. It is already in
  the router's failover set and already records a breaker failure, and
  relabelling it would take both of those away from the one response shape that
  has them.

  The fallback is a self-hosted `chicmoz`, passed as `:base_url`. Apache-2.0
  permits self-hosting, which is why it is the fallback with a licence that
  allows being one. It runs the same routes, so it needs no second module.
  `chain_info/1` checks the instance's own `l2NetworkId` against the network
  this handle claims and refuses a mismatch, because the failure mode of a
  configured fallback is a URL pointing at a different network, and that one
  would otherwise answer confidently about the wrong chain.

  One module, two sources, so this backend implements `backend/1` beside
  `backend/0`: a handle names itself `:aztecscan` on the temporary path and
  `:chicmoz` on a configured instance, and `Raxol.Web3.Router.coverage/2`
  reports those two names rather than `[:aztec, :aztec]`. During a revocation
  that difference is the operator-visible half of the failover, since a count
  of surviving sources says that one of two is left and a name says which one.
  The label is read off the resolved URL's credential segment rather than off
  whether a `:base_url` was passed, because the segment is the revocable
  thing: a deployment that configures the hosted URL explicitly is on the
  temporary path however it got there.

  ## The unit is `:block`, and `l2/info` is not what decided it

  `l2/info` carries no unit: it answers `l2NetworkId`, `l1ChainId`,
  `rollupVersion` and the L1 contract addresses. A block is what decides it.
  Every block carries `header.globalVariables.blockNumber` and
  `header.globalVariables.slotNumber` side by side, and in the recorded
  `block.json` those read 83582 and 91350: Aztec counts both, and slots skip.
  `l2/latest-height` returned 83590 while `l2/blocks/latest` reported
  `blockNumber` 83590 and `slotNumber` 91360 on 2026-09-14, so the number this
  backend reports is a block count and `:block` is the honest unit. Reporting
  it as `:slot` would have overstated the height by the 7,770 slots that were
  skipped by then.

  ## The finalized half comes from `l2/tips`, in one request

  `l2/tips` returns the whole ladder at one instant. In the recorded
  `tips.json`, taken on 2026-09-14: `proposed` 83597, `checkpointed` 83597,
  `proven` 83589, `finalized` 83561, plus `observedAt`, `stale`,
  `stalenessMs`, `staleAfterMs` and `degraded`.
  So `block_height/1` takes both numbers from that one response and
  never composes two endpoints, which is the rule
  `Raxol.Web3.Backend.Blockscout` spends a paragraph on: a height from one
  moment beside a finalized height from another can report
  `finalized_height > height`, and a consumer computing confirmation depth from
  that pair reads a negative number. A ladder that arrives non-monotone is
  `{:decode_failed, :tips}` rather than a repaired pair.

  The per-block `nativeStatus` was the other candidate and it is not used, on
  evidence. It is a four-value ladder (`proposed`, `checkpointed`, `proven`,
  `finalized`) and it also emits `unknown` transiently. At 10:15Z on
  2026-09-14, heights 83567 to 83574 read `unknown` from `l2/ui/blocks-for-table`
  while 83575 and above read `checkpointed`, and `l2/blocks/83580` read
  `unknown` at the same moment that table said `checkpointed` for it. By 10:30Z
  all of them read `proven` or `finalized`. So it converges, but it is neither
  monotone in height nor consistent between two views of the same block at one
  moment, and "the highest block whose status says finalized" is therefore not
  a finalized height.

  `indexer` comes out of the same response. This source publishes a staleness
  window rather than a ratio of indexed blocks, so `finished?` is `stale`
  inverted and `lag_seconds` is `stalenessMs` (24,815 ms in the fixture), and
  `indexed_ratio` and `lag_blocks` are **omitted** rather than computed. An
  absent key says this source does not publish that measure, and a fabricated
  `1.0` in the one field that exists so lag is visible would be the worst
  available answer. `degraded`, which has no field at all in the height shape,
  is on `tips/1`.

  ## What a transaction does and does not say

  `l2/txs` is the **pending pool**, not a list of mined transactions: its one
  item on 2026-09-14 was 15 days older than the head block, and
  `l2/txs/{hash}` answers 404 once that hash is mined. The mined record lives
  at `l2/tx-effects/{hash}`. So `get_transaction/2` reads the effect first and
  falls back to the pool on a 404, which is also what makes `:pending` an
  observation rather than a guess.

  `from`, `to` and `value` are `nil`, and that is the whole point of this
  chain. The mined record carries `feePayer` and `initiator`; neither is a
  sender. A fee payer can be a paymaster, and `initiator` is undefined by the
  surface (it equalled the `contractAddress` of its own public call request in
  the one case probed). Promoting either into `from` would produce a field a
  caller cannot distinguish from a measured sender. ADR-0039 records that these
  records carry "a fee payer and no counterparties"; the `initiator` field is
  the part of that claim which needs qualifying, and the qualification is that
  its meaning is not established rather than that it is a sender.

  ## What is not declared, and why

  `token_balances/3` is **absent**, and it is the reason ADR-0039 exists. A
  private note is unobservable by design, so an empty page is a lie a caller
  cannot distinguish from an account holding nothing, and nothing about a
  balance is safe to get wrong. Probing made the refusal stronger rather than
  weaker: a balance resource does exist, at
  `l2/contract-instances/{address}/balance` and
  `l2/contract-instances/with-balance`, and it is fee juice only and contract
  instances only. It answered `null` for a deployed instance on 2026-09-14, so
  even within its own scope "no balance recorded" and "zero" are already
  indistinguishable at the source.

  `account_info/2` and `list_transactions/3` are absent because there is no
  account resource: `l2/accounts` and `l2/accounts/{address}` are both 404.
  `l2/public-call-requests?senderAddress={address}` is a real per-sender filter
  and returned 47,976 bytes for one mainnet address, but a page built from it
  omits every private-only transaction that address made, and an incomplete
  page is the same lie in a different shape.

  `get_logs/3` is absent for the same reason: `l2/search/public-logs` exists,
  private logs are unobservable, and a log page that silently covers half the
  logs is worse than no callback. `read_contract/2` is absent because this
  surface has no `eth_call` equivalent; answering it needs a PXE, which is a
  different seam and out of scope here. `resolve_name/2`, `list_nfts/3`,
  `list_token_transfers/3` and `raw_request/2` have no upstream at all here,
  and declining `raw_request/2` keeps this backend's read allowlist empty by
  construction rather than by policing.

  ## Endpoints deliberately not called

  `l2/contract-instances` answered 200 with 2,380,955 bytes unpaginated on
  2026-09-14, and `l2/contract-classes` with 2,277,917 bytes. No fixed byte
  ceiling bounds an unpaginated list, which is the same class of mistake as
  Blockscout's 3.1 MB `/token-balances` that ADR-0038 records, so the addressed
  form is used and the list form is not called. Nothing this backend declares
  is paginated, which is why it adds no `Raxol.Web3.Cursor` entry: a cursor key
  allowlist has to be measured from a live paged response, and there is no
  paged response here to measure.
  """

  @behaviour Raxol.Web3.Backend

  alias Raxol.Web3.Backend
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Origin
  alias Raxol.Web3.TTL

  @enforce_keys [:chain_ref, :base_url, :network, :source]
  defstruct [:chain_ref, :base_url, :network, :source, http_opts: [], cache?: true]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          base_url: String.t(),
          network: String.t(),
          source: :aztecscan | :chicmoz,
          http_opts: keyword(),
          cache?: boolean()
        }

  @typedoc "The finality ladder, plus the freshness of the view that reported it."
  @type tips :: %{
          proposed: non_neg_integer() | nil,
          checkpointed: non_neg_integer() | nil,
          proven: non_neg_integer() | nil,
          finalized: non_neg_integer() | nil,
          stale?: boolean(),
          staleness_ms: non_neg_integer() | nil,
          degraded?: boolean()
        }

  @typedoc "What identifies an L2: its own network, and its anchor on L1."
  @type rollup :: %{
          network: String.t() | nil,
          l1_chain_id: non_neg_integer() | nil,
          rollup_version: String.t() | nil,
          l1_rollup: Backend.account_ref() | nil,
          l1_registry: Backend.account_ref() | nil
        }

  # Probed 2026-09-14. The key segment is named `temporary-api-key` upstream,
  # so `:temporary_path` is a dated note for a human rather than a gate: the
  # breaker and the 404 classification are what decide reachability at runtime,
  # and a withdrawn prefix has to fail over rather than fail.
  @aztecscan "https://api.aztecscan.xyz/v1/temporary-api-key"

  # The same segment on its own, because `backend/1` reads it off a handle's
  # resolved URL to name the source.
  @temporary_key "temporary-api-key"

  # The network id is the second half of each row because it is checked against
  # the instance's own `l2/info`. A self-hosted fallback aimed at a different
  # network is the failure this catches, and it is the one failure a fallback
  # can have that looks like success.
  @sources %{
    "aztec:mainnet" => {@aztecscan, "MAINNET", :temporary_path}
  }

  # A guess, and labelled as one. Neither Aztecscan nor `chicmoz` publishes a
  # figure, and probing for one would mean deliberately exceeding it on a free
  # path whose name already says it is a favour. It is under the package
  # default (10 at 2/s) rather than over it for that reason.
  @rate_limit [capacity: 5, refill_per_second: 1.0]

  @optional [:get_transaction, :get_block, :contract_metadata]

  @doc """
  Build a handle for an Aztec chain reference.

  `:base_url` points at a self-hosted `chicmoz` instance, scheme and prefix
  included (`"https://chicmoz.example.org/v1/local"`). Omitted, the handle
  talks to the hosted Aztecscan instance on the temporary path. The two are the
  primary and the fallback of the same chain and are built from the same
  module, so a router takes `[primary, fallback]` and needs nothing else.

  `:cache` defaults to `true`; `false` turns the response cache off for this
  handle. A height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, {default_url, network, _status}} <-
           Map.fetch(@sources, chain_ref) |> ok_or({:unsupported_chain, chain_ref}),
         {:ok, base_url, source} <- resolve(default_url, Keyword.get(opts, :base_url)) do
      state = %__MODULE__{
        chain_ref: chain_ref,
        base_url: base_url,
        network: network,
        source: source,
        http_opts: Keyword.put_new(Keyword.get(opts, :http_opts, []), :rate_limit, @rate_limit),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The chain-to-source table, with its network id and dated status. Data, not behaviour."
  @spec sources() :: %{
          Backend.chain_ref() => {String.t(), String.t(), :temporary_path}
        }
  def sources, do: @sources

  @doc "The rate limit seeded per origin, and a reminder that it is a guess."
  @spec rate_limit() :: keyword()
  def rate_limit, do: @rate_limit

  @impl Backend
  def backend, do: :aztec

  # The per-handle name, because one module carries both sources. `coverage/2`
  # reporting `[:aztec, :aztec]` tells an operator that two sources are
  # believed healthy and not which of them is the temporary path, and during a
  # revocation that is the only question. `backend/0` stays the chain-level
  # name that config and a router's failover order are written against.
  @impl Backend
  def backend(%__MODULE__{source: source}), do: source

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{}), do: @optional

  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, origin_id(state)}

  # -- required ----------------------------------------------------------------

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with {:ok, info} <- object(get(state, "/l2/info", :chain_stats, :fixed)),
         :ok <- same_network(state, info),
         {:ok, block_time} <- get(state, "/l2/stats/average-block-time", :chain_stats, :fixed),
         {:ok, transactions} <- get(state, "/l2/stats/total-tx-effects", :chain_stats, :fixed) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: int(block_time),
         # No counter of blocks exists on this surface, and `l2/tips` reports a
         # height. Reading a height as a count is the mistake ADR-0038
         # records, so this stays nil rather than borrowing that number.
         total_blocks: nil,
         # One tx effect per mined transaction, which is the count a caller
         # means. `l2/stats/total-txs` is a 404; the plural that exists is
         # `total-tx-effects`.
         total_transactions: int(transactions),
         # No account resource exists, so no count of accounts does either.
         # `total-contract-instances` (205 on 2026-09-14) counts deployments
         # rather than addresses.
         total_addresses: nil
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{} = state) do
    with {:ok, body} <- object(get(state, "/l2/tips", nil, :fixed)),
         {:ok, height, finalized} <- ladder(body) do
      {:ok,
       %{
         height: height,
         finalized_height: finalized,
         unit: :block,
         indexer: indexer(body)
       }}
    end
  end

  # -- optional ----------------------------------------------------------------

  @impl Backend
  def get_transaction(%__MODULE__{} = state, hash) when is_binary(hash) do
    case object(get(state, "/l2/tx-effects/#{segment(hash)}", :transaction, :addressed)) do
      {:ok, body} -> mined(body)
      {:error, {:upstream_refused, :not_found}} -> pooled(state, hash)
      {:error, _reason} = error -> error
    end
  end

  @impl Backend
  def get_block(%__MODULE__{} = state, number) do
    with {:ok, body} <- object(get(state, "/l2/blocks/#{segment(number)}", :block, :addressed)),
         {:ok, height} <- block_number(body) do
      variables = get_in(body, ["header", "globalVariables"]) || %{}

      {:ok,
       %{
         height: height,
         hash: body["hash"],
         timestamp: timestamp(variables["timestamp"]),
         transactions_count: effect_count(body),
         # An L1 address, 20 bytes, so the EVM tag is the accurate one even
         # inside an Aztec block: the coinbase is who gets paid on L1.
         miner: evm_ref(variables["coinbase"])
       }}
    end
  end

  @impl Backend
  def contract_metadata(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- aztec_address(account_ref),
         {:ok, body} <-
           object(
             get(
               state,
               "/l2/contract-instances/#{segment(address)}",
               :contract_metadata,
               :addressed
             )
           ) do
      {:ok,
       %{
         name: body["artifactContractName"],
         # Verification is a real concept here (`chicmoz` serves
         # `verify-source` and a `verifiedSourceOnly` filter), and on
         # 2026-09-14 `l2/contract-classes?verifiedSourceOnly=true` answered
         # `[]` and all 23 mainnet instances carried a null `sourceCodeUrl`.
         # So `false` is measured rather than defaulted: it means no source is
         # registered, not that a verification failed.
         verified?: is_binary(body["sourceCodeUrl"]),
         # Not carried. Noir is the only language an Aztec contract is written
         # in, which is exactly why putting it here would be a guess dressed as
         # a reading.
         language: nil,
         compiler_version: nil,
         # `selectorMap` is a selector-to-name map and carries no argument
         # types, so it is not an ABI. An artifact can be requested with
         # `?includeArtifactJson=true`, and no mainnet instance has one to
         # record, so no mapping is written against an unmeasured shape.
         abi: nil,
         proxy_type: nil
       }}
    end
  end

  # -- beyond the contract -----------------------------------------------------

  @doc """
  The finality ladder and the freshness of the view that reported it.

  Outside the contract because `Raxol.Web3.Backend`'s height shape carries one
  finalized number and this chain distinguishes four, and because the staleness
  window `l2/tips` reports is not the indexed-block ratio the `indexer` field
  means. Widening a shape shared by every chain for one chain's ladder is what
  ADR-0033 section 7's "serve a normalized contract" refuses; a named function
  on the backend that has the ladder is the alternative.
  """
  @spec tips(t()) :: {:ok, tips()} | {:error, Backend.error()}
  def tips(%__MODULE__{} = state) do
    with {:ok, body} <- object(get(state, "/l2/tips", nil, :fixed)) do
      ladder = Map.get(body, "tips", %{})

      {:ok,
       %{
         proposed: rung(ladder, "proposed"),
         checkpointed: rung(ladder, "checkpointed"),
         proven: rung(ladder, "proven"),
         finalized: rung(ladder, "finalized"),
         stale?: body["stale"] == true,
         staleness_ms: int(body["stalenessMs"]),
         degraded?: body["degraded"] == true
       }}
    end
  end

  @doc """
  What identifies this L2: its own network, and its anchor on L1.

  Outside the contract for the same reason as `tips/1`:
  `Raxol.Web3.Backend`'s `chain_info` shape has no field for an L1 chain id or
  a rollup version, and on an L2 those two are what identify the chain. The
  L1 contract addresses are normalized down to the rollup and the registry
  rather than passed through, because pass-through is what section 7 refuses
  and the other nine addresses identify nothing.
  """
  @spec rollup(t()) :: {:ok, rollup()} | {:error, Backend.error()}
  def rollup(%__MODULE__{} = state) do
    with {:ok, info} <- object(get(state, "/l2/info", :chain_stats, :fixed)) do
      contracts = Map.get(info, "l1ContractAddresses", %{})

      {:ok,
       %{
         network: info["l2NetworkId"],
         l1_chain_id: int(info["l1ChainId"]),
         rollup_version: info["rollupVersion"],
         l1_rollup: evm_ref(contracts["rollupAddress"]),
         l1_registry: evm_ref(contracts["registryAddress"])
       }}
    end
  end

  # -- the outbound path -------------------------------------------------------

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. `resource` decides what a 404 means, and it is the endpoint's own
  # shape rather than the response's text that decides it: see the moduledoc.
  #
  # The cache key fragment is the endpoint path, never the assembled URL. On
  # this upstream the credential is a PATH SEGMENT rather than a query
  # parameter, so the prefix is what has to stay out of the key, and building
  # the key from the suffix is what keeps it out by construction.
  defp get(state, path, class, resource) do
    url = state.base_url <> path

    url
    |> HTTP.get(cache_opts(state, path, class))
    |> decode(resource)
  end

  # Most endpoints answer an object, and the two stats reads answer a bare
  # number or string (`l2/latest-height` does too). Guarding here rather than
  # inside `decode/2` is what lets both kinds share one outbound path.
  defp object({:ok, body}) when is_map(body), do: {:ok, body}
  defp object({:ok, _other}), do: {:error, {:decode_failed, :not_an_object}}
  defp object({:error, _reason} = error), do: error

  defp cache_opts(state, _path, nil), do: state.http_opts
  defp cache_opts(%{cache?: false} = state, _path, _class), do: state.http_opts

  defp cache_opts(state, path, class) do
    Keyword.put(state.http_opts, :cache, key: path, ttl_ms: TTL.for(class))
  end

  # Any JSON term, not only an object: `l2/latest-height` answers a bare
  # number and `l2/stats/average-block-time` a bare string, so requiring an
  # object here would refuse two endpoints for having no wrapper.
  #
  # A non-2xx carries no body onward. ADR-0038 decision 6 keeps upstream text
  # out of an error term, and the 404 classification below needs the endpoint's
  # shape rather than the body: the withdrawn-prefix body is nine bytes of
  # someone else's plain text.
  defp decode({:ok, %{status: status, body: body}}, _resource) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  # `:fixed` is every parameterless endpoint this backend calls, and the list
  # is exhaustive: `/l2/info`, `/l2/tips`, `/l2/stats/average-block-time` and
  # `/l2/stats/total-tx-effects`. None of them takes a parameter, so none of
  # them has a resource that can be absent, so a 404 on one is the prefix
  # being gone rather than the resource. `:addressed` is the other four, which
  # name a block, a transaction hash twice, or a contract instance, and a 404
  # there is an answer. Since ADR-0039's amendment the router fails over on
  # `{:upstream_refused, :auth}` and never on `:not_found`, so this split is a
  # routing decision rather than a taste one.
  defp decode({:ok, %{status: 404}}, :fixed), do: {:error, {:upstream_refused, :auth}}
  defp decode({:ok, %{status: 404}}, :addressed), do: {:error, {:upstream_refused, :not_found}}
  defp decode({:ok, %{status: status}}, _resource), do: {:error, {:http, status}}
  defp decode({:error, _reason} = error, _resource), do: error

  defp origin_id(state), do: Origin.id(URI.new!(state.base_url))

  # Percent-encodes everything outside the unreserved set, so a caller-supplied
  # hash or address cannot carry a `/` or a `?` and reshape the path it is
  # interpolated into. There is no error variant for a malformed id, and there
  # should not be: the upstream is what decides whether an id exists, and an
  # encoded id that does not exist is a clean 404.
  defp segment(value) when is_integer(value), do: Integer.to_string(value)
  defp segment(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp resolve(default_url, nil), do: {:ok, default_url, source(default_url)}

  defp resolve(_default_url, base_url) when is_binary(base_url) do
    url = String.trim_trailing(base_url, "/")
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, {:invalid_base_url, :scheme}}
      is_nil(uri.host) or uri.host == "" -> {:error, {:invalid_base_url, :host}}
      true -> {:ok, url, source(url)}
    end
  end

  defp resolve(_default_url, _other), do: {:error, {:invalid_base_url, :type}}

  # What names a handle is the credential it presents, not the option it was
  # built from: the segment standing where an API key stands is the withdrawable
  # thing, and a deployment that configures the hosted URL by hand is on the
  # temporary path however it arrived there. `chicmoz` puts its own key in the
  # same position (`/v1/local` on a self-hosted instance), so the two sources
  # are distinguishable by that segment alone.
  defp source(url) do
    path = URI.parse(url).path || ""

    if Path.basename(path) == @temporary_key, do: :aztecscan, else: :chicmoz
  end

  # A self-hosted instance aimed at the wrong network is the one fallback
  # misconfiguration that answers confidently, so it is refused here rather
  # than trusted. `:decode_failed` because the body is not what it claimed to
  # be, and because the router fails over on it: the other source may be
  # pointed at the right chain.
  defp same_network(%__MODULE__{network: network}, %{"l2NetworkId" => network}), do: :ok
  defp same_network(_state, _info), do: {:error, {:decode_failed, :network_mismatch}}

  # -- normalization -----------------------------------------------------------

  defp ladder(%{"tips" => %{"proposed" => %{"number" => height}} = tips})
       when is_integer(height) do
    case rung(tips, "finalized") do
      nil -> {:ok, height, nil}
      finalized when finalized <= height -> {:ok, height, finalized}
      _above_the_head -> {:error, {:decode_failed, :tips}}
    end
  end

  defp ladder(_body), do: {:error, {:decode_failed, :tips}}

  # `stalenessMs` is the age of the tips observation, so it is how far behind
  # now this source's view is, in seconds. An indexer that stopped observing
  # shows it growing, which is what makes it a lag rather than a constant.
  defp indexer(body) do
    reported = %{finished?: body["stale"] != true}

    case int(body["stalenessMs"]) do
      ms when is_integer(ms) and ms >= 0 -> Map.put(reported, :lag_seconds, div(ms, 1000))
      _unpublished -> reported
    end
  end

  # `proposed` reports a number directly; the three settled rungs each report a
  # block and the L1 checkpoint that settled it, and it is the block number
  # that is comparable with a height.
  defp rung(%{"proposed" => %{"number" => number}}, "proposed") when is_integer(number),
    do: number

  defp rung(ladder, name) do
    case get_in(ladder, [name, "block", "number"]) do
      number when is_integer(number) -> number
      _absent -> nil
    end
  end

  defp mined(body) do
    with {:ok, status} <- revert_status(body["revertCode"]) do
      {:ok,
       %{
         hash: body["txHash"],
         status: status,
         block: int(body["blockHeight"]),
         timestamp: timestamp(body["timestamp"]),
         from: nil,
         to: nil,
         value: nil,
         fee: int(body["transactionFee"]),
         # A private function call is not observable, and the public call
         # requests a transaction made are a separate resource rather than a
         # name on this record.
         method: nil
       }}
    end
  end

  defp pooled(state, hash) do
    with {:ok, body} <- object(get(state, "/l2/txs/#{segment(hash)}", :transaction, :addressed)) do
      {:ok,
       %{
         hash: body["txHash"],
         status: :pending,
         block: nil,
         timestamp: timestamp(body["birthTimestamp"]),
         from: nil,
         to: nil,
         value: nil,
         # The pool record carries gas limits and max fees, which are bounds
         # rather than a fee. What was paid is known once it is mined.
         fee: nil,
         method: nil
       }}
    end
  end

  # A mined effect whose revert code cannot be read is not a transaction whose
  # status is unknown, because the contract has no such status. It is a body
  # that is not what it claimed, and the other source may parse it.
  defp revert_status(%{"code" => code}) do
    case int(code) do
      0 -> {:ok, :success}
      other when is_integer(other) -> {:ok, :reverted}
      nil -> {:error, {:decode_failed, :revert_code}}
    end
  end

  defp revert_status(_absent), do: {:error, {:decode_failed, :revert_code}}

  defp block_number(body) do
    case int(body["height"]) do
      height when is_integer(height) -> {:ok, height}
      nil -> {:error, {:decode_failed, :block}}
    end
  end

  defp effect_count(body) do
    case get_in(body, ["body", "txEffects"]) do
      effects when is_list(effects) -> length(effects)
      _absent -> nil
    end
  end

  defp aztec_address({:aztec, address}) when is_binary(address), do: {:ok, address}
  defp aztec_address({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp aztec_address(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  defp evm_ref(address) when is_binary(address), do: {:evm, address}
  defp evm_ref(_absent), do: nil

  defp ok_or({:ok, _value} = ok, _reason), do: ok
  defp ok_or(:error, reason), do: {:error, reason}

  defp int(nil), do: nil
  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp int(_other), do: nil

  # Milliseconds since the epoch, which is what every timestamp on this
  # surface is: a block's `globalVariables.timestamp` and a transaction's
  # `birthTimestamp` both read 1789380527000-scale on 2026-09-14.
  defp timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_other), do: nil
end
