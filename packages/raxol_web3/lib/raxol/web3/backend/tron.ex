defmodule Raxol.Web3.Backend.Tron do
  @moduledoc """
  The Tron backend, over three MCP upstreams with three different session models.

  ADR-0033 decision 3 and ADR-0039 for the contract, ADR-0037 for the client
  that reaches a stateful MCP origin. Every figure below was measured on
  2026-09-14 unless it says otherwise, and the ones that are guesses say so.

  Tron matters more here than its position in the survey suggests: ADR-0033's
  motivating case is an FX venue, and Tron carries a disproportionate share of
  the stablecoin supply that venue settles in.

  ## Three sources, three session models, one contract

  | Source | Session | Concurrency | Tools |
  | ------ | ------- | ----------- | ----- |
  | TronGrid (`mcp.trongrid.io/mcp`) | legacy, `mcp-session-id` | `:pooled` | 149 |
  | SQD Portal (`portal.sqd.dev/mcp`) | none | `:stateless` | 31 |
  | TronScan (`mcp.tronscan.org/mcp`) | legacy, `mcp-session-id` | `:serialized` | 119 |

  The concurrency policy is passed to `Raxol.MCP.Client` rather than
  reimplemented here (ADR-0037 decision 6). TronScan is the reason the policy
  exists: two parallel calls on one session answered 500 for both, reproducibly,
  while sequential calls immediately after succeeded and the session survived.

  149 plus 119 is 268 third-party tool descriptions for one chain, and
  TronGrid's `tools/list` alone was 269,860 bytes on 2026-09-14. None of that
  text reaches a served tool definition or an annotation: upstream names appear
  only as arguments this module chooses, and upstream prose travels only inside
  a result payload that the normalizers below take structured fields out of.

  ## Two encodings for one account

  The reference is `{:tron, value}` and accepts Base58Check or hex for the same
  account. `Raxol.Web3.Tron.Address.canonical/1` collapses them, and it is
  applied ONCE, at the edge, in `account/1`. Everything below that point holds
  Base58, so a cache key, a cursor scope and a rate-limit spend cannot differ
  by encoding for one account. The upstreams make the point themselves: a
  single `getTransactionById` response carried `owner_address` in Base58 and
  `contract_address` in hex, so normalization canonicalizes on the way out too.

  ## Three token standards, and TRC-10 has no address

  `Backend.token()`'s `address` is the TRC-20 contract. A TRC-10 asset is keyed
  by a numeric id, so `address` is `nil`, `type` is `"TRC-10"` and the id lands
  in `token_balance()`'s `token_id`, which is exactly the field a standard with
  a non-address identifier needs. A TRC-10 and a TRC-20 balance therefore come
  back from one `token_balances/3` page and are told apart by `type` without
  either of them carrying a field it does not have. The native asset is neither:
  TronScan reports it as `tokenType: "trc10"` with `tokenId: "_"`, and it is
  normalized to `type: "TRX"` with no address and no id.

  Token metadata is absent on the TronGrid source, and that is a measurement
  rather than an omission. `getTrc20Info` is the only batch metadata tool, its
  `contractList` is a comma-separated string despite an array schema, and asked
  for the 493 contracts one account held it answered with 20 records and no
  indication that it had truncated. Enriching from it would have produced
  metadata for 20 tokens out of 493 and silence about the rest. The TronScan
  source answers `token_balances/3` with `tokenDecimal` and `tokenAbbr`
  included, so a caller that needs the scale has a source that publishes it and
  a nil rather than a fabricated 18 from one that does not.

  ## The finalized split, from the irreversible view

  `block_height/1` never reports the head twice, and each source has its own
  irreversible view:

    * TronGrid: `getBlock` for the head, `solidityGetBlock` for the
      irreversible one. The 25 `solidity*` tools exist for no other reason, and
      the two numbers were 86,236,608 and 86,236,590 when measured.
    * TronScan: one descending `getBlocks` page. The head is the first row and
      the irreversible height is the highest row carrying `confirmed: true`,
      which sat 18 blocks back at 19 confirmations, matching Tron's
      two-thirds-of-27 rule.
    * SQD Portal: `portal_get_network_info` carries `head`, `finalized_head`
      and the lag in blocks and seconds, so one call answers the height and the
      indexer shape.

  `getNodeInfo` carries both numbers in one call and is deliberately not used:
  it delivers them as `"Num:N,ID:hash"` strings beside a peer list, 30,366
  bytes on 2026-09-14, against roughly 800 bytes for each structured block.

  ## What each source declares

  SQD Portal declares no optional callback at all, on the same measurement
  ADR-0039 rests on. `portal_tron_query_transactions` takes a `sighash`, which
  is a method selector and not a transaction id, so there is no by-hash lookup;
  and asked for an account's transactions with no window it answers 200
  carrying `error.code "invalid_request"` and "Provide timeframe, from_block, or
  from_timestamp/to_timestamp to define the query window". `Backend.list_opts()`
  is `[cursor: _]`, so a caller cannot supply that window and a window this
  module invented would be its own number. An archive answers ranges; the two
  required callbacks are what it knows about the chain.

  TronGrid declines `get_block/2`'s siblings it has no index for and declares
  the six reads its named tools answer. `getTransactionInfoById` is not among
  them: on 2026-09-14 it answered `isError: true` with its own output-schema
  validation failure (`/fee_major: string found, number expected`), so a
  TronGrid transaction carries a `nil` block and fee, and TronScan is the source
  in the chain that answers those.

  ## Pagination, and a ceiling the caller never sees

  TronGrid pages by an opaque `fingerprint`; TronScan pages by `start` and
  `limit` with a hard `start + limit <= 10000`. Both live behind
  `Raxol.Web3.Cursor`, so neither an offset nor a fingerprint is exposed.
  Crossing TronScan's ceiling fails rather than rewinding: the cursor is still
  minted while the upstream reports more rows, and presenting one whose page
  would cross the ceiling answers `{:upstream_refused, :unknown}` without
  spending the upstream's budget on a request its own rule refuses. The
  recorded refusal is pinned as a fixture and maps to the same error, so the
  local check and the upstream agree.
  """

  @behaviour Raxol.Web3.Backend

  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.Era
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Cache
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.MCPCall
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Tables
  alias Raxol.Web3.Tron.Address
  alias Raxol.Web3.TTL

  @enforce_keys [:source, :chain_ref]
  defstruct [:source, :chain_ref, :client, http_opts: [], cache?: true]

  @type source :: :trongrid | :sqd | :tronscan

  @type t :: %__MODULE__{
          source: source(),
          chain_ref: Backend.chain_ref(),
          client: GenServer.server() | nil,
          http_opts: keyword(),
          cache?: boolean()
        }

  # The registered CAIP-2 form for Tron mainnet is the genesis-block prefix.
  @chain_ref "tron:0x2b6653dc"

  # Dated 2026-09-14. `tron:mainnet` is the spelling operators and upstreams
  # reach for, so it is accepted on ingest and collapsed here rather than in
  # three source-specific places. Data, so a new alias is a table row.
  @chain_aliases %{
    "tron:mainnet" => @chain_ref,
    @chain_ref => @chain_ref
  }

  # Probed 2026-09-14. `network` is the upstream's own name for this chain and
  # is an argument this module chooses, never a name it forwards.
  @sources %{
    trongrid: %{
      url: "https://mcp.trongrid.io/mcp",
      stateful?: true,
      concurrency: :pooled,
      tools: 149,
      network: nil
    },
    sqd: %{
      url: "https://portal.sqd.dev/mcp",
      stateful?: false,
      concurrency: :stateless,
      tools: 31,
      network: "tron-mainnet"
    },
    tronscan: %{
      url: "https://mcp.tronscan.org/mcp",
      stateful?: true,
      concurrency: :serialized,
      tools: 119,
      network: nil
    }
  }

  # A GUESS, and labelled one because Tron's documentation refuses to publish a
  # free-tier figure and warns against hardcoding the commonly cited ones. It
  # is set below every historical number rather than at one of them. A token
  # bucket rather than a window counter because TronGrid answers a burst with a
  # 30-second penalty, which a window counter forgets at its boundary.
  @rate_limit [capacity: 5, refill_per_second: 1.0]

  # A judgement, not a measurement. Small enough that one page is cheap on a
  # budget nobody publishes, large enough that a walk is not mostly round
  # trips. TronGrid accepts up to 200 and TronScan is bounded by its ceiling.
  @page_limit 25

  # Measured 2026-09-14: `start + limit` above this answers a refusal inside a
  # successful tool result. It is the offset the contract refuses to expose, so
  # it lives in a cursor and never in a return value.
  @tronscan_ceiling 10_000

  # Mirrors `Raxol.Web3.Backend.JSONRPC`: an average block time derived from
  # two real timestamps this many blocks apart, rather than the protocol
  # constant, which would be a number we asserted instead of read.
  @block_time_sample 100

  @trongrid_capabilities [
    :get_transaction,
    :account_info,
    :list_transactions,
    :token_balances,
    :list_token_transfers,
    :get_block
  ]

  # No `list_transactions/3`: the only account-scoped transaction tools take a
  # single `fromAddress` or `toAddress`, so "the transactions of this address"
  # would be two half-answers stitched together. `getTransferList` answers
  # transfers in both directions and is `list_token_transfers/3`.
  @tronscan_capabilities [
    :get_transaction,
    :account_info,
    :token_balances,
    :list_token_transfers
  ]

  @doc """
  Build a handle for one source.

  `:client` is required for `:trongrid` and `:tronscan` and must be a running
  `Raxol.MCP.Client`; `client_spec/2` builds the child spec for one. The handle
  is data and starts no process, which is what lets a router hold three of them
  and a test hold one with a recorded transport.

  `:chain_ref` accepts `tron:0x2b6653dc` or `tron:mainnet` and is canonicalized.
  `:cache` defaults to `true`; `false` turns off the response cache for this
  handle, which a caller that must see the head on every read needs. A height is
  never cached either way.
  """
  @spec new(source(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(source, opts \\ []) when is_atom(source) do
    with {:ok, config} <- Map.fetch(@sources, source) |> ok_or({:unsupported_source, source}),
         {:ok, chain_ref} <- canonical_chain_ref(Keyword.get(opts, :chain_ref, @chain_ref)),
         {:ok, client} <- client(config, opts) do
      state = %__MODULE__{
        source: source,
        chain_ref: chain_ref,
        client: client,
        http_opts: Keyword.get(opts, :http_opts, []),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc """
  A child spec for the `Raxol.MCP.Client` a stateful source needs.

  The breaker table is this package's, so the health the transport records on
  the request path is the health `Raxol.Web3.Router` orders candidates by. The
  era table stays the client's, because an era verdict is the client's own
  cached decision about a protocol revision and means nothing here.

  `:concurrency` is the policy, not a suggestion: TronGrid is `:pooled` because
  six parallel calls on one session all returned 200, and TronScan is
  `:serialized` because two returned 500. A legacy origin defaults to
  `:serialized` on its own, so the second one is passed for the record rather
  than to change behaviour.

  `Raxol.MCP.Client` registers a process only when a `:registry` is supplied,
  so `:name` here labels log lines rather than the process. A handle therefore
  takes the pid the supervisor returned, or a via-tuple when a registry is in
  use, and `new/2` accepts either because both are a `GenServer.server()`.
  """
  @spec client_spec(source(), keyword()) :: Supervisor.child_spec()
  def client_spec(source, opts \\ []) when is_atom(source) do
    config = Map.fetch!(@sources, source)
    name = Keyword.get(opts, :name, default_client_name(source))

    spec =
      opts
      |> Keyword.take([
        :exchange,
        :tables,
        :resolver,
        :registry,
        :era_ttl_ms,
        :max_bytes,
        :deadline_ms,
        :chunk_timeout_ms,
        :connect_timeout_ms
      ])
      |> Keyword.put_new_lazy(:tables, &default_tables/0)
      |> Keyword.merge(
        name: name,
        url: config.url,
        concurrency: config.concurrency
      )

    %{id: {Client, name}, start: {Client, :start_link, [spec]}}
  end

  # The era verdict belongs to the client, because it is the client's cached
  # decision about a protocol revision and means nothing here. The breaker is
  # this package's, so the health the transport records on the request path is
  # the health `Raxol.Web3.Router` orders candidates by; two tables would give
  # the router a second opinion it could not see the first of.
  defp default_tables do
    %{eras: Raxol.MCP.Client.Tables.ensure_started().eras, breakers: Tables.breakers()}
  end

  @doc "The name `client_spec/2` labels a source's client with by default."
  @spec default_client_name(source()) :: atom()
  def default_client_name(source) when is_atom(source), do: :"raxol_web3_tron_#{source}"

  @doc "The source table, with its dated session and concurrency facts. Data, not behaviour."
  @spec sources() :: %{source() => map()}
  def sources, do: @sources

  @doc "The accepted chain references and what each one canonicalizes to. Dated 2026-09-14."
  @spec chain_aliases() :: %{String.t() => String.t()}
  def chain_aliases, do: @chain_aliases

  @impl Backend
  def backend, do: :tron

  # The module is not the source. Three upstreams answer for this chain and
  # `backend/0` is `:tron` for all three, so `Raxol.Web3.Router.coverage/2`
  # reported `[:tron, :tron, :tron]` and an operator could read how many
  # sources survived a failover but not which one dropped out. The handle
  # already carries the source, which is the answer the coverage map wants,
  # and it is the same atom as `sources/0`'s key and `health_key/1`'s subject
  # so all three name one thing.
  @impl Backend
  def backend(%__MODULE__{source: source}), do: source

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{source: :trongrid}), do: @trongrid_capabilities
  def capabilities(%__MODULE__{source: :tronscan}), do: @tronscan_capabilities
  def capabilities(%__MODULE__{source: :sqd}), do: []

  # Two writers, so two key shapes, and each handle names the one its own
  # outbound path records. `Raxol.Web3.HTTP` keys on a hashed origin id;
  # `Raxol.MCP.Client`'s transport keys on the plain origin string. The origin
  # comes from the dated table above and never from a caller, so no per-account
  # hostname can reach either key.
  @impl Backend
  def health_key(%__MODULE__{source: :sqd} = state), do: {:origin, origin_id(state)}
  def health_key(%__MODULE__{} = state), do: {:origin, Era.origin(uri(state))}

  # -- required ----------------------------------------------------------------

  @impl Backend
  def chain_info(%__MODULE__{source: :sqd} = state) do
    with {:ok, body} <- call(state, "portal_get_network_info", network(state), :chain_stats),
         :ok <- confirm_network(body) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         # An archive publishes freshness and coverage, not aggregate counters,
         # so the four totals are absent facts rather than zeros. The call is
         # still made: chain identity is confirmed against the upstream here
         # rather than asserted from the handle.
         average_block_time_ms: nil,
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  def chain_info(%__MODULE__{source: :trongrid} = state) do
    with {:ok, head} <- call(state, "getBlock", %{"detail" => false}, :chain_stats),
         {:ok, height} <- block_number(head),
         {:ok, earlier} <- sample_block(state, height - @block_time_sample) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: average_block_time_ms(head, earlier),
         # A node keeps no aggregate counters, and a fabricated total would be
         # read as a fact about the chain.
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  def chain_info(%__MODULE__{source: :tronscan} = state) do
    with {:ok, body} <- call(state, "getStatsOverview", %{}, :chain_stats),
         {:ok, stats} <- first_row(body, :stats_overview) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: seconds_to_ms(stats["avgBlockTime"]),
         total_blocks: int(stats["totalBlockCount"]),
         total_transactions: int(stats["totalTransaction"]),
         total_addresses: int(stats["totalAddress"])
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{source: :sqd} = state) do
    with {:ok, body} <- call(state, "portal_get_network_info", network(state)),
         {:ok, height} <- dig_int(body, ["head", "number"], :sqd_head) do
      {:ok,
       %{
         height: height,
         finalized_height: int(get_in(body, ["finalized_head", "number"])),
         unit: :block,
         indexer: sqd_indexer(body)
       }}
    end
  end

  def block_height(%__MODULE__{source: :trongrid} = state) do
    with {:ok, head} <- call(state, "getBlock", %{"detail" => false}),
         {:ok, height} <- block_number(head),
         {:ok, irreversible} <- call(state, "solidityGetBlock", %{"detail" => false}),
         {:ok, finalized} <- block_number(irreversible) do
      # `indexer: nil` rather than a cheerful `%{finished?: true}`: this
      # upstream publishes no indexing status, and claiming a component is
      # healthy is worse than saying nothing about it.
      {:ok, %{height: height, finalized_height: finalized, unit: :block, indexer: nil}}
    end
  end

  def block_height(%__MODULE__{source: :tronscan} = state) do
    query = %{"limit" => @page_limit, "sort" => "-number"}

    with {:ok, body} <- call(state, "getBlocks", query),
         {:ok, rows} <- rows(body, :blocks),
         {:ok, height} <- first_block_number(rows) do
      {:ok,
       %{
         height: height,
         finalized_height: highest_confirmed(rows),
         unit: :block,
         indexer: nil
       }}
    end
  end

  # -- optional ----------------------------------------------------------------

  @impl Backend
  def get_transaction(%__MODULE__{source: :trongrid} = state, hash) when is_binary(hash) do
    with {:ok, body} <- call(state, "getTransactionById", %{"value" => hash}, :transaction),
         {:ok, transaction} <- trongrid_transaction(body) do
      {:ok, transaction}
    end
  end

  def get_transaction(%__MODULE__{source: :tronscan} = state, hash) when is_binary(hash) do
    with {:ok, body} <- call(state, "getTransactionDetail", %{"hash" => hash}, :transaction),
         {:ok, transaction} <- tronscan_transaction(body) do
      {:ok, transaction}
    end
  end

  @impl Backend
  def account_info(%__MODULE__{source: :trongrid} = state, account_ref) do
    with {:ok, address} <- account(account_ref),
         {:ok, body} <- call(state, "getAccountInfo", %{"address" => address}, :account),
         {:ok, record} <- first_row(body, :account),
         {:ok, balance} <- money(record["balance"], :balance) do
      {:ok,
       %{
         ref: {:tron, canonical!(record["address"], address)},
         balance: balance,
         # Code presence, from the account record's own account type. No
         # `:kind`: Tron draws no distinction that changes how `balance` is
         # read, and `contract?` already answers the only one it draws.
         contract?: record["type"] == "Contract",
         verified?: false,
         name: nil,
         ens: nil
       }}
    end
  end

  def account_info(%__MODULE__{source: :tronscan} = state, account_ref) do
    with {:ok, address} <- account(account_ref),
         {:ok, body} <- call(state, "getAccountDetail", %{"address" => address}, :account),
         {:ok, balance} <- money(body["balance"], :balance) do
      {:ok,
       %{
         ref: {:tron, canonical!(body["address"], address)},
         balance: balance,
         contract?: is_map(body["contractInfo"]) or body["accountType"] == 2,
         verified?: false,
         # The explorer's own label for the address, which is data in a result
         # payload rather than a tool description, and `nil` when unlabelled.
         name: presence(body["addressTag"]),
         ens: nil
       }}
    end
  end

  @impl Backend
  def list_transactions(%__MODULE__{source: :trongrid} = state, account_ref, opts \\ []) do
    with {:ok, address} <- account(account_ref) do
      fingerprint_page(
        state,
        "getAccountTransactions",
        %{"address" => address},
        :tron_account_transactions,
        opts,
        &trongrid_list_transaction/1
      )
    end
  end

  @impl Backend
  def token_balances(state, account_ref, opts \\ [])

  def token_balances(%__MODULE__{source: :trongrid} = state, account_ref, opts) do
    with :ok <- no_cursor(opts),
         {:ok, address} <- account(account_ref),
         {:ok, body} <- call(state, "getAccountInfo", %{"address" => address}, :account),
         {:ok, record} <- first_row(body, :account),
         {:ok, items} <- trongrid_token_balances(record) do
      # One call and no cursor: the account record is one object rather than a
      # page, so `next` is `nil` because there is no second page and not
      # because paging was declined. Measured 2026-09-14, the widest holder
      # probed returned 493 TRC-20 and 331 TRC-10 entries in 26,795 bytes.
      {:ok, %{items: items, next: nil}}
    end
  end

  def token_balances(%__MODULE__{source: :tronscan} = state, account_ref, opts) do
    with {:ok, address} <- account(account_ref) do
      offset_page(
        state,
        "getAccountTokens",
        %{"address" => address},
        :tronscan_account_tokens,
        opts,
        &tronscan_token_balance/1
      )
    end
  end

  # This read mints no cursor, so it accepts none. Answering page one again for
  # a cursor nobody minted is the silent rewind the opaque-cursor rule exists
  # to prevent, and it is indistinguishable from a walk that ended.
  defp no_cursor(opts) do
    case Keyword.get(opts, :cursor) do
      nil -> :ok
      _held -> {:error, {:invalid_cursor, {:unknown_endpoint, :tron_account_info}}}
    end
  end

  @impl Backend
  def list_token_transfers(state, account_ref, opts \\ [])

  def list_token_transfers(%__MODULE__{source: :trongrid} = state, account_ref, opts) do
    with {:ok, address} <- account(account_ref) do
      fingerprint_page(
        state,
        "getAccountTrc20Transactions",
        %{"address" => address},
        :tron_account_trc20_transfers,
        opts,
        &trongrid_token_transfer/1
      )
    end
  end

  def list_token_transfers(%__MODULE__{source: :tronscan} = state, account_ref, opts) do
    with {:ok, address} <- account(account_ref) do
      offset_page(
        state,
        "getTransferList",
        %{"address" => address},
        :tronscan_transfer_list,
        opts,
        &tronscan_token_transfer/1
      )
    end
  end

  @impl Backend
  def get_block(%__MODULE__{source: :trongrid} = state, number) do
    query = %{"detail" => false, "id_or_num" => to_string(number)}

    with {:ok, body} <- call(state, "getBlock", query, :block) do
      {:ok, trongrid_block(body)}
    end
  end

  # -- the outbound path -------------------------------------------------------

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. The key fragment is built from the tool name and the argument map
  # this module composed, never from an assembled URI, so a credential cannot
  # reach a cache key by construction rather than by review.
  defp call(state, tool, arguments, class \\ nil) do
    case cache_key(state, tool, arguments, class) do
      nil -> dispatch(state, tool, arguments, [])
      key -> through_cache(state, tool, arguments, key, class)
    end
  end

  # The stateless source caches inside `Raxol.Web3.HTTP`, which is where
  # ADR-0038 decision 2 puts the stage: after the vet, so a hit cannot answer
  # for a target that has since resolved into the reject set, and before the
  # token bucket, so a hit spends nobody's budget. A stateful source cannot
  # reach that stage, because its outbound path is `Raxol.MCP.Client`, so the
  # same table and the same TTL class are applied one layer up with the same
  # `{origin_id, fragment}` key shape.
  defp through_cache(%__MODULE__{source: :sqd} = state, tool, arguments, key, class) do
    dispatch(state, tool, arguments, cache: [key: key, ttl_ms: TTL.for(class)])
  end

  defp through_cache(%__MODULE__{} = state, tool, arguments, key, class) do
    full_key = {origin_id(state), key}

    case Cache.get(full_key) do
      {:ok, payload} ->
        {:ok, payload}

      :miss ->
        with {:ok, payload} = ok <- dispatch(state, tool, arguments, []) do
          Cache.put(full_key, payload, TTL.for(class))
          ok
        end
    end
  end

  defp cache_key(%__MODULE__{cache?: false}, _tool, _arguments, _class), do: nil
  defp cache_key(_state, _tool, _arguments, nil), do: nil
  defp cache_key(_state, tool, arguments, _class), do: {tool, arguments}

  defp dispatch(%__MODULE__{source: :sqd} = state, tool, arguments, extra) do
    case MCPCall.call(url(state), tool, arguments, http_opts(state, extra)) do
      {:ok, payload} -> payload_result(payload)
      {:tool_error, _payload} -> {:error, {:upstream_refused, :unknown}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(%__MODULE__{client: nil}, _tool, _arguments, _extra) do
    {:error, {:transport, :no_client}}
  end

  defp dispatch(%__MODULE__{client: client}, tool, arguments, _extra) do
    case Client.call_tool(client, tool, arguments) do
      {:ok, %{content: content, is_error: false}} -> content_payload(content)
      {:ok, %{is_error: true}} -> {:error, {:upstream_refused, :unknown}}
      {:error, reason} -> {:error, client_error(reason)}
    end
  end

  defp http_opts(state, extra) do
    state.http_opts
    |> Keyword.put_new(:rate_limit, @rate_limit)
    |> Keyword.merge(extra)
  end

  # `result.content[0].text` holds a JSON string, so there are two decodes:
  # `Raxol.MCP.Client` did the envelope and this does the text.
  defp content_payload([%{"text" => text} | _rest]) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, payload} when is_map(payload) -> payload_result(payload)
      {:ok, _other} -> {:error, {:decode_failed, :not_an_object}}
      {:error, _reason} -> {:error, {:decode_failed, :mcp_content}}
    end
  end

  defp content_payload(_other), do: {:error, {:decode_failed, :mcp_content}}

  # The one recognised refusal shape inside a successful tool result: a payload
  # whose `error` is a string and which carries nothing else to read. Measured
  # 2026-09-14, that is how TronScan announces its pagination ceiling, and the
  # announcement is prose in a language this repository's own lint would refuse,
  # so the class is `:unknown` rather than a reading of the words.
  defp payload_result(%{"error" => reason} = payload) when is_binary(reason) do
    if map_size(payload) == 1, do: {:error, {:upstream_refused, :unknown}}, else: {:ok, payload}
  end

  # SQD announces a refusal as a nested object with a machine-readable code, and
  # those two we do classify, because the code is a value rather than prose.
  defp payload_result(%{"error" => %{"code" => code}}) when is_binary(code) do
    {:error, {:upstream_refused, sqd_class(code)}}
  end

  defp payload_result(payload), do: {:ok, payload}

  defp sqd_class("unauthorized"), do: :auth
  defp sqd_class("rate_limited"), do: :rate_limit
  defp sqd_class("unknown_network"), do: :not_found
  defp sqd_class(_other), do: :unknown

  # Every reason `Raxol.MCP.Client` produces, mapped onto the closed taxonomy in
  # `Raxol.Web3.Backend`. Nothing upstream travels: a JSON-RPC error contributes
  # its numeric code and never its message.
  defp client_error({:http, status}), do: {:http, status}
  defp client_error({:redirect_refused, status}), do: {:http, status}
  defp client_error({:too_large, limit}), do: {:too_large, limit}
  defp client_error({:timeout, stage}), do: {:timeout, stage}
  defp client_error(:timeout), do: {:timeout, :deadline}
  defp client_error({:transport, reason}), do: {:transport, reason}
  defp client_error({:blocked, reason}), do: {:blocked, reason}
  defp client_error({:not_ready, _status}), do: {:transport, :not_ready}
  # Retryable, and a source error rather than an answer, so the router fails
  # over to the next candidate instead of returning a saturated queue.
  defp client_error(:busy), do: {:transport, :busy}
  defp client_error(:session_rejected), do: {:transport, :session_rejected}
  defp client_error(:breaker_open), do: {:breaker_open, :unknown}
  defp client_error(:dns_failed), do: {:dns_failed, :unknown}

  defp client_error(%{"code" => code}) when is_integer(code) do
    {:upstream_refused, code_class(code)}
  end

  defp client_error(_other), do: {:transport, :unknown}

  defp code_class(-32_601), do: :not_found
  defp code_class(-32_602), do: :not_found
  defp code_class(code) when code in [401, -32_001], do: :auth
  defp code_class(code) when code in [429, -32_005], do: :rate_limit
  defp code_class(_code), do: :unknown

  defp origin_id(state), do: Origin.id(uri(state))

  defp uri(%__MODULE__{} = state), do: URI.new!(url(state))

  defp url(%__MODULE__{source: source}), do: Map.fetch!(@sources, source).url

  defp network(%__MODULE__{source: source}) do
    %{"network" => Map.fetch!(@sources, source).network}
  end

  # Chain identity, confirmed rather than asserted. The upstream names the
  # network and the VM family it indexed, and a handle that asked for Tron and
  # was answered about something else is a misconfiguration worth failing on.
  defp confirm_network(%{"vm" => "tron", "network_type" => "mainnet"}), do: :ok
  defp confirm_network(_body), do: {:error, {:decode_failed, :network_identity}}

  # -- pagination --------------------------------------------------------------

  # TronGrid pages on an opaque `fingerprint`. `meta.links.next` is a full
  # upstream URL carrying that fingerprint, and it is read only as the signal
  # that another page exists: the next request is composed here from the tool
  # and the argument map, never by following somebody else's URL.
  defp fingerprint_page(state, tool, base, endpoint, opts, mapper) do
    with {:ok, params} <- cursor_params(state, endpoint, Keyword.get(opts, :cursor)),
         arguments = Map.merge(base, Map.put(params, "limit", @page_limit)),
         {:ok, body} <- call(state, tool, arguments, :list),
         {:ok, rows} <- rows(body, :page),
         {:ok, items} <- map_items(rows, mapper) do
      {:ok,
       %{
         items: items,
         next: mint(state, endpoint, next_fingerprint(body))
       }}
    end
  end

  # TronScan pages on `start` and `limit`. The ceiling is checked before the
  # request rather than after it, so a walk that would cross it fails without
  # spending a token on a request the upstream documents as refused, and the
  # error is the same one the upstream's own refusal maps to.
  defp offset_page(state, tool, base, endpoint, opts, mapper) do
    with {:ok, params} <- cursor_params(state, endpoint, Keyword.get(opts, :cursor)),
         start = int(params["start"]) || 0,
         :ok <- within_ceiling(start),
         arguments = Map.merge(base, %{"start" => start, "limit" => @page_limit}),
         {:ok, body} <- call(state, tool, arguments, :list),
         {:ok, rows} <- rows(body, :page),
         {:ok, items} <- map_items(rows, mapper) do
      {:ok,
       %{
         items: items,
         next: mint(state, endpoint, next_offset(body, start))
       }}
    end
  end

  defp within_ceiling(start) when start + @page_limit <= @tronscan_ceiling, do: :ok
  defp within_ceiling(_start), do: {:error, {:upstream_refused, :unknown}}

  defp next_fingerprint(body) do
    with %{"meta" => %{"fingerprint" => fingerprint} = meta} <- body,
         true <- is_binary(get_in(meta, ["links", "next"])) do
      %{"fingerprint" => fingerprint}
    else
      _last_page -> nil
    end
  end

  # `total` is the upstream's own row count, so "there is another page" is read
  # from it rather than guessed from a full page.
  defp next_offset(body, start) do
    next = start + @page_limit

    case int(body["total"]) do
      total when is_integer(total) and next < total ->
        %{"start" => next, "limit" => @page_limit}

      _end_of_walk ->
        nil
    end
  end

  defp mint(_state, _endpoint, nil), do: nil
  defp mint(state, endpoint, params), do: Cursor.encode(params, origin_id(state), endpoint)

  defp cursor_params(_state, _endpoint, nil), do: {:ok, %{}}

  defp cursor_params(state, endpoint, cursor) do
    case Cursor.decode(cursor, origin_id(state), endpoint) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:error, {:invalid_cursor, reason}}
    end
  end

  # -- normalization -----------------------------------------------------------

  defp trongrid_transaction(body) do
    contract = contract_call(body)

    with {:ok, value} <- money(contract["amount"] || contract["call_value"], :value) do
      {:ok,
       %{
         hash: body["txID"],
         status: contract_status(body),
         # `getTransactionInfoById` is the tool that carries a block and a fee,
         # and it currently refuses its own output. TronScan is the source that
         # answers those fields.
         block: nil,
         timestamp: epoch_ms(get_in(body, ["raw_data", "timestamp"])),
         from: ref(contract["owner_address"]),
         to: ref(counterparty(contract)),
         value: value,
         fee: nil,
         method: get_in(body, ["raw_data", "contract"]) |> contract_type()
       }}
    end
  end

  defp trongrid_list_transaction(item) do
    contract = contract_call(item)
    raw_fee = item |> Map.get("ret", []) |> List.first(%{}) |> Map.get("fee")

    with {:ok, value} <- money(contract["amount"] || contract["call_value"], :value),
         {:ok, fee} <- money(raw_fee, :fee) do
      {:ok,
       %{
         hash: item["txID"],
         status: contract_status(item),
         block: int(item["blockNumber"]),
         timestamp: epoch_ms(item["block_timestamp"]),
         from: ref(contract["owner_address"]),
         to: ref(counterparty(contract)),
         value: value,
         fee: fee,
         method: item |> Map.get("raw_data", %{}) |> Map.get("contract") |> contract_type()
       }}
    end
  end

  defp tronscan_transaction(body) do
    with {:ok, fee} <- money(get_in(body, ["cost", "fee"]), :fee) do
      {:ok,
       %{
         hash: body["hash"],
         status: ret_status(body["contractRet"]),
         block: int(body["block"]),
         timestamp: epoch_ms(body["timestamp"]),
         from: ref(body["ownerAddress"]),
         to: ref(body["toAddress"]),
         value: nil,
         fee: fee,
         method: presence(body["contractType"] && to_string(body["contractType"]))
       }}
    end
  end

  defp trongrid_block(body) do
    raw = get_in(body, ["block_header", "raw_data"]) || %{}

    %{
      height: int(raw["number"]),
      hash: body["blockID"],
      timestamp: epoch_ms(raw["timestamp"]),
      transactions_count: body |> Map.get("transactions", []) |> length_or_nil(),
      miner: ref(raw["witness_address"])
    }
  end

  # Both standards out of one account record. TRC-20 arrives as a list of
  # single-key maps from contract address to an amount string; TRC-10 as a list
  # of `key`/`value` pairs whose key is the numeric asset id.
  defp trongrid_token_balances(record) do
    trc10 =
      record
      |> Map.get("assetV2", [])
      |> Enum.map(fn %{"key" => id, "value" => amount} -> {:trc10, id, amount} end)

    trc20 =
      record
      |> Map.get("trc20", [])
      |> Enum.flat_map(fn entry ->
        Enum.map(entry, fn {contract, amount} -> {:trc20, contract, amount} end)
      end)

    map_items(trc20 ++ trc10, fn
      {:trc10, id, amount} ->
        with {:ok, parsed} <- money(amount, :amount) do
          {:ok, %{token: token(nil, "TRC-10"), amount: parsed, token_id: to_string(id)}}
        end

      {:trc20, contract, amount} ->
        with {:ok, parsed} <- money(amount, :amount) do
          {:ok, %{token: token(canonical(contract), "TRC-20"), amount: parsed, token_id: nil}}
        end
    end)
  end

  defp tronscan_token_balance(item) do
    {address, token_id} = token_identity(item["tokenId"])

    with {:ok, amount} <- money(item["balance"], :amount) do
      {:ok,
       %{
         token: %{
           address: address,
           symbol: presence(item["tokenAbbr"]),
           name: presence(item["tokenName"]),
           decimals: int(item["tokenDecimal"]),
           type: token_type(item["tokenType"], item["tokenId"])
         },
         amount: amount,
         token_id: token_id
       }}
    end
  end

  defp trongrid_token_transfer(item) do
    info = Map.get(item, "token_info", %{})

    with {:ok, amount} <- money(item["value"], :amount) do
      {:ok,
       %{
         token: %{
           address: canonical(info["address"]),
           symbol: presence(info["symbol"]),
           name: presence(info["name"]),
           decimals: int(info["decimals"]),
           type: "TRC-20"
         },
         amount: amount,
         from: ref(item["from"]),
         to: ref(item["to"]),
         block: nil,
         timestamp: epoch_ms(item["block_timestamp"]),
         transaction: item["transaction_id"]
       }}
    end
  end

  defp tronscan_token_transfer(item) do
    info = Map.get(item, "tokenInfo", %{})
    {address, _token_id} = token_identity(info["tokenId"])

    with {:ok, amount} <- money(item["amount"], :amount) do
      {:ok,
       %{
         token: %{
           address: address,
           symbol: presence(info["tokenAbbr"]),
           name: presence(info["tokenName"]),
           decimals: int(info["tokenDecimal"]),
           type: token_type(info["tokenType"], info["tokenId"])
         },
         amount: amount,
         from: ref(item["transferFromAddress"]),
         to: ref(item["transferToAddress"]),
         block: int(item["block"]),
         timestamp: epoch_ms(item["timestamp"]),
         transaction: item["transactionHash"]
       }}
    end
  end

  defp map_items(items, mapper) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case mapper.(item) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      {:error, _reason} = error -> error
    end
  end

  # The native asset has neither an address nor an asset id, a TRC-10 has an id
  # and no address, and a TRC-20 has an address and no id. One function so the
  # three cases cannot drift apart between the balance and the transfer mapper.
  defp token_identity("_"), do: {nil, nil}

  defp token_identity(id) when is_binary(id) do
    if numeric?(id), do: {nil, id}, else: {canonical(id), nil}
  end

  defp token_identity(_absent), do: {nil, nil}

  defp token_type(_upstream, "_"), do: "TRX"
  defp token_type("trc10", _id), do: "TRC-10"
  defp token_type("trc20", _id), do: "TRC-20"
  defp token_type("trc721", _id), do: "TRC-721"
  defp token_type("trc1155", _id), do: "TRC-1155"
  defp token_type(_other, _id), do: nil

  defp token(address, type) do
    %{address: address, symbol: nil, name: nil, decimals: nil, type: type}
  end

  defp contract_call(body) do
    body
    |> Map.get("raw_data", %{})
    |> Map.get("contract", [])
    |> List.first(%{})
    |> Map.get("parameter", %{})
    |> Map.get("value", %{})
  end

  defp contract_type([%{"type" => type} | _rest]) when is_binary(type), do: type
  defp contract_type(_absent), do: nil

  # The recipient is named differently per contract type, and none of the three
  # is a fallback for the others: a transfer names `to_address`, a contract call
  # names the contract it calls, and a resource delegation names the receiver.
  defp counterparty(contract) do
    contract["to_address"] || contract["contract_address"] || contract["receiver_address"]
  end

  defp contract_status(body) do
    body |> Map.get("ret", []) |> List.first(%{}) |> Map.get("contractRet") |> ret_status()
  end

  defp ret_status("SUCCESS"), do: :success
  defp ret_status(nil), do: :pending
  defp ret_status(_reverted), do: :reverted

  defp sqd_indexer(body) do
    indexing = Map.get(body, "indexing", %{})

    # `:indexed_ratio` is absent rather than computed: this upstream publishes
    # a lag in blocks and in seconds and no ratio at all, and a 1.0 here would
    # be a fabricated number in the one field that exists so lag is visible.
    %{finished?: body["real_time"] == true}
    |> put_measure(:lag_blocks, int(indexing["finalized_lag_blocks"]))
    |> put_measure(:lag_seconds, int(indexing["finalized_lag_seconds"]))
  end

  defp put_measure(indexer, _key, nil), do: indexer
  defp put_measure(indexer, key, value), do: Map.put(indexer, key, value)

  # -- reading the upstream shapes ---------------------------------------------

  defp block_number(body) do
    case int(get_in(body, ["block_header", "raw_data", "number"])) do
      number when is_integer(number) -> {:ok, number}
      nil -> {:error, {:decode_failed, :block}}
    end
  end

  defp sample_block(state, height) when height > 0 do
    call(state, "getBlock", %{"detail" => false, "id_or_num" => to_string(height)}, :block)
  end

  defp sample_block(_state, _height), do: {:error, {:decode_failed, :block}}

  defp average_block_time_ms(head, earlier) do
    newer = int(get_in(head, ["block_header", "raw_data", "timestamp"]))
    older = int(get_in(earlier, ["block_header", "raw_data", "timestamp"]))

    if is_integer(newer) and is_integer(older) and newer > older do
      (newer - older) / @block_time_sample
    end
  end

  defp first_block_number([%{"number" => number} | _rest]), do: {:ok, int(number)}
  defp first_block_number(_rows), do: {:error, {:decode_failed, :blocks}}

  # The irreversible view, from the flag the explorer publishes per block. A
  # page with no confirmed row is `nil` rather than the head: the shape exists
  # so a consumer can compute a confirmation depth, and reporting the head
  # twice would make that depth zero.
  defp highest_confirmed(rows) do
    rows
    |> Enum.filter(&(&1["confirmed"] == true))
    |> Enum.map(&int(&1["number"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp rows(%{"data" => rows}, _tag) when is_list(rows), do: {:ok, rows}
  defp rows(_body, tag), do: {:error, {:decode_failed, tag}}

  defp first_row(body, tag) do
    case rows(body, tag) do
      {:ok, [row | _rest]} when is_map(row) -> {:ok, row}
      {:ok, _empty} -> {:error, {:upstream_refused, :not_found}}
      error -> error
    end
  end

  defp dig_int(body, path, tag) do
    case int(get_in(body, path)) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:error, {:decode_failed, tag}}
    end
  end

  # -- the account reference ---------------------------------------------------

  # The one place either encoding is accepted, and the one place it collapses.
  # Everything below holds Base58, so nothing downstream can key a cache, a
  # cursor scope or a rate-limit spend on the spelling a caller happened to use.
  defp account({:tron, value}) when is_binary(value) do
    case Address.canonical(value) do
      {:ok, base58} -> {:ok, base58}
      {:error, :invalid_address} -> {:error, {:unsupported_account_ref, :tron}}
    end
  end

  defp account({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp account(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  defp ref(nil), do: nil

  defp ref(value) when is_binary(value) do
    case Address.canonical(value) do
      {:ok, base58} -> {:tron, base58}
      {:error, :invalid_address} -> nil
    end
  end

  defp ref(_other), do: nil

  defp canonical(nil), do: nil

  defp canonical(value) when is_binary(value) do
    case Address.canonical(value) do
      {:ok, base58} -> base58
      {:error, :invalid_address} -> nil
    end
  end

  defp canonical(_other), do: nil

  # The address we asked about is the fallback, because a response that echoes
  # nothing back still describes the account that was requested.
  defp canonical!(value, requested), do: canonical(value) || requested

  defp canonical_chain_ref(chain_ref) when is_binary(chain_ref) do
    case Map.fetch(@chain_aliases, chain_ref) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, {:unsupported_chain, chain_ref}}
    end
  end

  defp canonical_chain_ref(other), do: {:error, {:unsupported_chain, other}}

  defp client(%{stateful?: false}, _opts), do: {:ok, nil}

  defp client(%{stateful?: true}, opts) do
    case Keyword.get(opts, :client) do
      nil -> {:error, :client_required}
      client -> {:ok, client}
    end
  end

  # -- scalars -----------------------------------------------------------------

  defp ok_or({:ok, _value} = ok, _reason), do: ok
  defp ok_or(:error, reason), do: {:error, reason}

  defp numeric?(value) when is_binary(value) do
    match?({_number, ""}, Integer.parse(value))
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_other), do: nil

  defp length_or_nil([]), do: nil
  defp length_or_nil(list) when is_list(list), do: length(list)
  defp length_or_nil(_other), do: nil

  defp seconds_to_ms(value) when is_number(value), do: value * 1000
  defp seconds_to_ms(_other), do: nil

  defp epoch_ms(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp epoch_ms(_other), do: nil

  defp money(nil, _field), do: {:ok, nil}
  defp money(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp money(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _invalid -> {:error, {:decode_failed, field}}
    end
  end

  defp money(_value, field), do: {:error, {:decode_failed, field}}

  defp int(nil), do: nil
  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _invalid -> nil
    end
  end

  defp int(_other), do: nil
end
