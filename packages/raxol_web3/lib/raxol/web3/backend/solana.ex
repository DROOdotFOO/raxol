defmodule Raxol.Web3.Backend.Solana do
  @moduledoc """
  The Solana backend, over two sources that answer different questions.

  Issue #1028. `new/2` takes a `:source` of `:sqd` or `:rpc` and builds one
  handle for one source, because a handle must declare honestly what its own
  source answers and these two do not answer the same set. The caller assembles
  the router, `Raxol.Web3.Router.new([sqd, rpc])`, and the asymmetry below is
  the whole point of the backend rather than an accident of it.

  | Callback | SQD Portal | Public RPC |
  | -------- | ---------- | ---------- |
  | `chain_info/1` | `portal_get_network_info` | `getEpochInfo` |
  | `block_height/1` | `portal_get_head` twice | `getSlot` twice |
  | `get_transaction/2` | no | `getTransaction` |
  | `account_info/2` | no | `getAccountInfo` |
  | `token_balances/3` | no | `getTokenAccountsByOwner` |
  | `list_transactions/3` | no | `getSignaturesForAddress` |
  | `get_block/2` | no | `getBlock` |

  Every "no" is a measurement, taken 2026-09-14 against the live surfaces with
  the honest User-Agent ADR-0033 §7 mandates, and each one is an absent
  capability rather than a callback that returns an error to satisfy the
  behaviour, per ADR-0039 decision 3.

  ## A handle names its source, and the module still names itself

  One module, two upstreams, so `backend/1` answers per handle: `:solana_sqd`
  for the archive and `:solana_rpc` for the node. It is the optional callback
  ADR-0039 added for exactly this, because `Raxol.Web3.Router.coverage/2` read
  `[:solana, :solana]` for the required two and an operator could count the
  sources that survived without seeing which one dropped out. `backend/0` is
  still `:solana`, which is what logs, config and the `:source` option are
  keyed on.

  ## Why the archive answers nothing account-shaped or id-shaped

  SQD Portal's Solana surface has **no lookup by signature at all**. Its 31
  tools carry an id-shaped parameter in three places and all three are EVM or
  Tron (`portal_evm_query_transactions.sighash`,
  `portal_evm_query_traces.transaction_hash`,
  `portal_tron_query_transactions.sighash`);
  `portal_solana_query_transactions` filters on a network, a slot or timestamp
  range, `finalized_only`, `fee_payer`, `mentions_account` and a limit capped at
  25. A scan is not an implementation: mainnet carries thousands of
  transactions per slot. That measurement is what demoted `get_transaction/2`
  to optional in ADR-0039's same-day revision, so this backend is the reason
  the required set is two rather than three.

  The same tool refuses an account-scoped query outright without a window:
  network plus `mentions_account` plus a limit answers HTTP 200 carrying
  `error.code == "invalid_request"` and "Provide timeframe, from_block, or
  from_timestamp/to_timestamp to define the query window."
  `Raxol.Web3.Backend.list_opts()` is `[cursor: _]`, so a caller cannot supply
  a window, any window chosen here would be this module's invention, and an
  empty page from a window that was too narrow is indistinguishable from an
  account with no activity. So `list_transactions/3` is not declared on SQD.

  And the nearest thing to an account read, `portal_get_wallet_summary`, takes
  an address plus a look-back `timeframe` and reports activity and fund flow
  over that window. "The current native balance of this account" is not a range
  query, which is the second of the two measurements ADR-0039 rests on, so
  `account_info/2` is not declared on SQD either.

  ## A height here is a slot, and that is not a detail

  Both sources report `unit: :slot`. Measured 2026-09-14 in one `getEpochInfo`
  response: `absoluteSlot` was 446,951,753 and `blockHeight` was 424,994,262 at
  the same instant, a gap of **21,957,491**. A consumer that read this chain's
  height as a block height would be wrong by twenty-two million, which is the
  concrete reason ADR-0033 made the height a named map instead of an integer.

  Slots also skip, and the two sources report the finalized split differently:

    * SQD answers `portal_get_head` with `type: latest` and again with
      `type: finalized`, and the lag between them is reported in the height's
      `indexer` field as `lag_blocks`. It is computed from the two numbers
      already in hand rather than from a third call to
      `portal_get_network_info`, and it is clamped at zero because the two
      calls are not one snapshot and a momentary inversion is a fact about the
      pair of requests, not about the chain. `finished?` comes from the
      catalog's `real_time` flag, so it is a fact the source published.
    * Public RPC answers `getSlot` with `commitment: "processed"` for the head
      and `"finalized"` for the finalized half. `"confirmed"` is the middle
      state and the shape has two slots for numbers, so the extremes are taken.
      `indexer` is `nil`: a validator is not an indexer and has no lag to
      report, and inventing a ratio for it would put a fabricated number in the
      one field that exists so lag is visible.

  ## `get_block/2` is declared, and a skipped slot is a success

  ADR-0033 demoted this callback because on Solana an empty or skipped slot is
  a valid success rather than an error. The upstream separates the three
  outcomes by itself, measured 2026-09-14:

    * A produced slot answers a block. Slot 446,800,611 returned a `blockhash`,
      a `blockTime` and a `parentSlot`.
    * A skipped slot answers JSON-RPC error **-32009**, "Slot N was skipped, or
      missing in long-term storage". Slots 446,800,612 through 446,800,615 were
      a real gap in `getBlocks` over that range.
    * A slot above the head answers **-32004**, "Block not available for slot".

  So: a produced slot is `{:ok, block}` with a binary `hash`; a skipped slot is
  `{:ok, block}` with `hash: nil`, `timestamp: nil` and
  `transactions_count: nil`; an empty-but-produced slot is `{:ok, block}` with a
  binary `hash` and `transactions_count: 0`; and a failed read is
  `{:error, _}`. The hash is the discriminator because a produced block always
  carries one, including slot 1000, whose `blockHeight` is `null`.

  `height` is **the slot that was asked for**, always, and never the upstream's
  `blockHeight`. Slot 446,800,611 reports `blockHeight` 424,843,204, so putting
  that number in `height` would make `get_block/2` and `block_height/1`
  disagree by about 21.96 million while both claim `unit: :slot`. The contract's
  `block()` has nowhere to put a second counter, so `blockHeight` is dropped
  rather than reported under a name that would make two callbacks contradict
  each other. `miner` is `nil`: `getBlock` exposes no leader identity.

  `transactionDetails: "signatures"` is what makes `transactions_count` a real
  number rather than a `nil`. It cost 121,298 bytes for one mainnet slot on
  2026-09-14, well inside the 2 MiB read ceiling, and the alternative
  (`"none"`) would leave the empty-versus-populated distinction unanswerable.

  ## An account may be four things, so it says which

  `account()` carries `kind`, added to the shared type for this backend. The
  four values below are each measured, 2026-09-14, from `getAccountInfo` with
  `dataSlice: {offset: 0, length: 0}`, which returns `owner`, `executable`,
  `lamports` and `space` for 250 bytes and no data payload:

  | Owner and shape | `kind` | Measured on |
  | --------------- | ------ | ----------- |
  | `executable: true` | `:program` | the SPL token program, owner `BPFLoaderUpgradeab1e...` |
  | owner is the system program | `:wallet` | an account holding 38,298,783,833 lamports |
  | owner is the SPL token program, `space` 165 | `:token_account` | an account holding 2,039,280 lamports |
  | owner is the SPL token program, `space` 82 | `:mint` | an account holding 1,461,600 lamports |
  | anything else | `:data` | a sysvar, owner `Sysvar111...`, `space` 40 |

  The reason it is not a nicety: a token account's `balance` is 2,039,280
  lamports, which is its rent-exempt reserve. That number is true, so this was
  never a wrong answer, but a caller who cannot tell a token account from a
  wallet reads "this account holds 0.002 SOL" for an account whose actual
  holding is reachable only through `token_balances/3`. `:data` means
  "program-owned, and this table does not name its kind"; Token-2022 accounts
  land there because their space is variable and none was measured.

  `contract?` stays code presence, from `executable`, which is a different
  question. `verified?` is always `false`: a validator has no notion of source
  verification, the field is a boolean with no room for "unknown", and `false`
  reads as "no evidence of verification", which is the truth. `name` and `ens`
  are `nil` for the same kind of reason.

  An account with no lamports and a `null` `getAccountInfo` value is
  `{:upstream_refused, :not_found}` rather than a zero balance: on this chain an
  account that holds nothing does not exist, and reporting zero would answer a
  question about an account that is not there.

  ## Paging, and the two lists that page differently

  `list_transactions/3` walks `getSignaturesForAddress` on its `before`
  parameter, and the cursor is a `Raxol.Web3.Cursor` entry
  (`:solana_address_signatures`) whose allowlist is the single key `before`,
  measured from a live response: `before` takes a signature and a signature is
  what every item carries. Two pages of two for one mainnet account returned
  disjoint signatures on 2026-09-14.

  There is no `next_page_params` and no end-of-list flag, so **a non-empty page
  always mints a cursor and only an empty page ends the walk**. That costs one
  extra round trip at the end of a walk and never truncates one, which is the
  right way round: a cursor withheld early would silently shorten a caller's
  view of an account's history.

  The rows are thin, deliberately. A signature listing carries `signature`,
  `slot`, `blockTime`, `err`, `memo` and `transactionIndex` and no
  counterparties at all, so `from`, `to`, `value`, `fee` and `method` are `nil`
  and a caller that needs them calls `get_transaction/2` per signature. Filling
  `from` with the queried address would be a guess: an address that is merely
  mentioned by a transaction is not its fee payer.

  `token_balances/3` takes the cursor option and its `next` is always `nil`,
  which is what taking the option lets it say honestly.
  `getTokenAccountsByOwner`'s config object accepts `commitment`,
  `minContextSlot`, `dataSlice` and `encoding` and nothing that offsets,
  limits or resumes, so one response is the whole set of a wallet's token
  accounts and there is no second page to name. A cursor handed back to this
  callback therefore did not come from it, and it is refused as
  `{:invalid_cursor, :wrong_scope}` rather than served a first page: answering
  page one to a caller who asked for page two would answer a different
  question, silently. This is structurally the problem ADR-0038 records
  against Blockscout's `/token-balances`, and there is no paginated
  alternative here to switch to, so the bound is the read ceiling: one mainnet
  wallet's 58 token accounts were 30,800 bytes on 2026-09-14, against a 2 MiB
  ceiling.

  A transaction has no single recipient and no single value on this chain: it
  has instructions over a list of account keys, and balance deltas per account.
  So `get_transaction/2` reports `from` (the fee payer, `accountKeys[0]`), the
  fee and the status, and leaves `to`, `value` and `method` `nil` rather than
  picking one account key and calling it the counterparty. `:pending` is never
  returned: a transaction the node has not confirmed is indistinguishable from
  one that never existed, and both are `{:upstream_refused, :not_found}`.

  ## Networks are resolved at runtime, never hardcoded

  The survey records SQD's README, docs and changelog disagreeing about
  coverage, so the supported set is read from `portal_list_networks` and cached
  under `Raxol.Web3.TTL`'s `:catalog` class. A network the catalog does not
  list is `{:error, {:unsupported_chain, network}}`, which the router treats as
  a source error and fails over on, rather than a request that fails. The same
  term covers the case where the cached catalog has gone stale inside its hour
  and the tool itself answers `error.code == "unknown_network"`.

  Measured 2026-09-14: `vm: "solana"` returned 7 networks of the catalog's 139,
  `has_more: false`, and `solana-mainnet` carries the aliases `solana-beta`,
  `solana` and `sol`. Those aliases are matched from the live response, so they
  are not a table here that could drift from it.

  `error.code == "invalid_request"` is `{:upstream_refused, :unknown}`, which
  the router treats as final: our own arguments were wrong and a sibling source
  would answer the same way.

  ## Chain references

  Canonical CAIP-2 for mainnet is `solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp`,
  the first 32 characters of the genesis hash. Measured 2026-09-14:
  `getGenesisHash` on `api.mainnet-beta.solana.com` returned
  `5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d`. `solana:mainnet` is accepted
  as an alias and canonicalized on ingest, so a handle always reports the
  canonical reference. The table is dated data and carries mainnet only:
  devnet's genesis hash was not measured, and a CAIP-2 reference copied from
  documentation is exactly the kind of claim this package refuses to make
  without probing it.

  ## Rate limits, and which figures are guesses

  Public RPC's documented limit is **100 requests per 10 seconds per IP** and 40
  per method (documentation read 2026-09-14, not measured against), so the
  bucket is seeded at a capacity of 100 refilling at 10 per second. The
  per-method half is **not enforceable here**: the bucket is keyed per origin,
  so a caller that spends the whole budget on one method will be refused by the
  upstream rather than by us. That is a known gap, stated rather than hidden.

  SQD publishes no rate limit at all, so its seed is **a guess**: a capacity of
  10 refilling at 2 per second, which is conservative enough that a height read
  still fits: three requests on a cold catalog and two once it is cached.

  `@page_limit` is a judgement, not a measurement: 100 signatures per page,
  against an upstream maximum of 1000, chosen to keep one page small.

  ## Two things this backend declines, and why declining is stronger

  `raw_request/2` is not implemented, so there is no method allowlist in this
  module and no need for one. ADR-0033 §3's allowlist exists because an
  unbounded passthrough to a JSON-RPC backend reaches a write method; with the
  callback declined, no method parameter crosses the served surface at all, and
  an allowlist over this module's own literals would police the author rather
  than the caller.

  `list_token_transfers/3` is not declared on either source, which is the
  callback ADR-0033 demoted on cost. Outside EVM and TVM a transfer is not an
  event but a parse: it is an instruction inside a transaction, and recovering
  it needs an instruction decoder. Public RPC has no method for it at all, and
  on SQD it would be `portal_solana_query_instructions`, which needs the same
  query window `list_transactions/3` cannot supply. So the cost never arises
  here and no rate-limit weighting is needed for it; the day a source can
  answer it, the weight has to be visible in a heavier `:rate_limit` for that
  endpoint rather than hidden behind this module's uniform bucket.

  `read_contract/2`, `contract_metadata/2`, `get_logs/3`, `resolve_name/2` and
  `list_nfts/3` are absent for the same shape of reason: the first three have no
  Solana analogue over these two surfaces, name resolution needs a program read
  neither source exposes, and an NFT here is an SPL token whose metadata lives
  in a program account that neither source parses.

  ## No upstream prose reaches anything

  SQD's payloads carry model-facing text beside their structured fields:
  `portal_get_head` returns `answer: "Current value: 446,951,484."` next to
  `number`, and `portal_get_network_info` returns a
  `_tool_contract.untrusted_fields` list that names `display_name` among the
  fields a client must not trust. Nothing in this module reads `answer`,
  `display`, `display_name`, `freshness_summary`, `_summary` or `next_steps`.
  Upstream text travels only inside a result payload, never into a normalized
  field, a served tool definition or an annotation.
  """

  @behaviour Raxol.Web3.Backend

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.MCPCall
  alias Raxol.Web3.Origin
  alias Raxol.Web3.TTL

  @enforce_keys [:chain_ref, :source, :url, :network]
  defstruct [:chain_ref, :source, :url, :network, http_opts: [], cache?: true]

  @type source :: :sqd | :rpc

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          source: source(),
          url: String.t(),
          network: String.t(),
          http_opts: keyword(),
          cache?: boolean()
        }

  @mainnet "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"

  # Dated data, 2026-09-14. A compile-time map rather than a parse plus
  # `String.to_existing_atom/1`, which would depend on an atom having been
  # interned somewhere else.
  @chain_aliases %{
    @mainnet => @mainnet,
    "solana:mainnet" => @mainnet
  }

  @chains %{
    @mainnet => %{
      network: "solana-mainnet",
      rpc_url: "https://api.mainnet-beta.solana.com",
      sqd_url: "https://portal.sqd.dev/mcp"
    }
  }

  @sources [:sqd, :rpc]

  # SQD declares nothing optional, which is the asymmetry this backend exists
  # to express, and every entry in the RPC list is measured in the moduledoc.
  @rpc_capabilities [
    :get_transaction,
    :account_info,
    :token_balances,
    :list_transactions,
    :get_block
  ]

  @system_program "11111111111111111111111111111111"
  @token_program "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  @token_account_space 165
  @mint_space 82

  # Documented, not measured: the public endpoint's published limit is 100
  # requests per 10 seconds per IP (read 2026-09-14).
  @rpc_rate_limit [capacity: 100, refill_per_second: 10.0]

  # A guess. SQD publishes no rate limit anywhere, and the survey records that.
  @sqd_rate_limit [capacity: 10, refill_per_second: 2.0]

  # A judgement: the upstream maximum is 1000 and one page should stay small.
  @page_limit 100

  # The catalog's Solana family was 7 of 139 networks with `has_more: false` on
  # 2026-09-14, so one page of 100 covers it. If it ever outgrows a page, an
  # unlisted network is `{:unsupported_chain, _}`, which is a refusal rather
  # than a wrong answer.
  @catalog_limit 100

  @finalized %{"commitment" => "finalized"}

  # `dataSlice` with a zero length is what keeps an account read at 250 bytes:
  # the fields that classify an account are in the envelope, never in its data.
  @account_config %{
    "encoding" => "base64",
    "commitment" => "finalized",
    "dataSlice" => %{"offset" => 0, "length" => 0}
  }

  @parsed_config %{"encoding" => "jsonParsed", "commitment" => "finalized"}

  @transaction_config %{
    "encoding" => "json",
    "commitment" => "confirmed",
    "maxSupportedTransactionVersion" => 0
  }

  @block_config %{
    "encoding" => "json",
    "transactionDetails" => "signatures",
    "rewards" => false,
    "maxSupportedTransactionVersion" => 0
  }

  # The Bitcoin alphabet, which omits 0, O, I and l. Input hygiene, not
  # authentication: it keeps a junk reference out of an upstream request.
  @base58 ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc """
  Build a handle for a chain reference and one source.

  Options:

    * `:source` - `:sqd` (the archive) or `:rpc` (a validator). Defaults to
      `:sqd`, the primary. One handle is one source, so a router assembled as
      `[sqd, rpc]` orders them.
    * `:url` - overrides the source's endpoint, for an operator running their
      own RPC node or portal.
    * `:network` - names the SQD network directly, for one this dated table does
      not carry yet. It is validated against the live catalog on the first read,
      so a wrong value is `{:unsupported_chain, _}` rather than a bad request.
    * `:http_opts` - forwarded to `Raxol.Web3.HTTP` unchanged.
    * `:cache` - defaults to `true`. `false` turns off the response cache for
      this handle, which a caller that must see the head needs. A height is
      never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, canonical} <- canonical(chain_ref),
         {:ok, chain} <- Map.fetch(@chains, canonical) |> ok_or({:unsupported_chain, chain_ref}),
         {:ok, source} <- source(Keyword.get(opts, :source, :sqd)) do
      state = %__MODULE__{
        chain_ref: canonical,
        source: source,
        url: Keyword.get(opts, :url, endpoint(source, chain)),
        network: Keyword.get(opts, :network, chain.network),
        http_opts: Keyword.get(opts, :http_opts, []),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The chain references this backend accepts, and what each canonicalizes to."
  @spec chain_aliases() :: %{String.t() => String.t()}
  def chain_aliases, do: @chain_aliases

  @impl Backend
  def backend, do: :solana

  @impl Backend
  def backend(%__MODULE__{source: :sqd}), do: :solana_sqd
  def backend(%__MODULE__{source: :rpc}), do: :solana_rpc

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{source: :sqd}), do: []
  def capabilities(%__MODULE__{source: :rpc}), do: @rpc_capabilities

  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, origin_id(state)}

  # -- required ----------------------------------------------------------------

  @impl Backend
  def chain_info(%__MODULE__{source: :sqd} = state) do
    with {:ok, network} <- resolve(state),
         {:ok, payload} <-
           sqd(state, "portal_get_network_info", %{"network" => network.network}, :chain_stats) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         # No tool reports one, and deriving a figure from the 31-slot
         # finality lag would have the precision of a guess.
         average_block_time_ms: nil,
         # A count of indexed blocks, as Blockscout's `total_blocks` is, and
         # not a height: `block_height/1` is the height.
         total_blocks: indexed_blocks(payload),
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  def chain_info(%__MODULE__{source: :rpc} = state) do
    with {:ok, body} <- rpc(state, "getEpochInfo", [@finalized], :chain_stats) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: nil,
         # `blockHeight` is a count of blocks produced, which is what this
         # field means. The slot count is `block_height/1`'s answer.
         total_blocks: body["blockHeight"],
         total_transactions: body["transactionCount"],
         total_addresses: nil
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{source: :sqd} = state) do
    with {:ok, network} <- resolve(state),
         {:ok, latest} <- sqd_head(state, network.network, "latest"),
         {:ok, finalized} <- sqd_head(state, network.network, "finalized") do
      {:ok,
       %{
         height: latest,
         finalized_height: finalized,
         unit: :slot,
         indexer: %{finished?: network.real_time?, lag_blocks: max(latest - finalized, 0)}
       }}
    end
  end

  def block_height(%__MODULE__{source: :rpc} = state) do
    with {:ok, height} <- slot(state, "processed"),
         {:ok, finalized} <- slot(state, "finalized") do
      {:ok, %{height: height, finalized_height: finalized, unit: :slot, indexer: nil}}
    end
  end

  # -- optional, on the RPC source only ----------------------------------------

  @impl Backend
  def get_transaction(%__MODULE__{source: :rpc} = state, signature) when is_binary(signature) do
    with {:ok, checked} <- base58(signature, 43, 90),
         {:ok, body} <- rpc(state, "getTransaction", [checked, @transaction_config], :transaction) do
      case body do
        nil -> {:error, {:upstream_refused, :not_found}}
        body -> {:ok, transaction(body)}
      end
    end
  end

  # One request, not two. `getBalance` and `getAccountInfo` return the same
  # number: measured 2026-09-14, both answered 38,298,783,833 lamports for the
  # same wallet, and the account envelope carries `lamports` beside the `owner`,
  # `executable` and `space` that classify the account. Asking twice would
  # spend two of a hundred requests per ten seconds for one number.
  @impl Backend
  def account_info(%__MODULE__{source: :rpc} = state, account_ref) do
    with {:ok, pubkey} <- pubkey(account_ref),
         {:ok, account} <- rpc(state, "getAccountInfo", [pubkey, @account_config], :account) do
      case value(account) do
        nil ->
          {:error, {:upstream_refused, :not_found}}

        info ->
          {:ok,
           %{
             ref: {:solana, pubkey},
             balance: info["lamports"],
             contract?: info["executable"] == true,
             verified?: false,
             name: nil,
             ens: nil,
             kind: kind(info)
           }}
      end
    end
  end

  @impl Backend
  def token_balances(%__MODULE__{source: :rpc} = state, account_ref, opts \\ []) do
    with {:ok, pubkey} <- pubkey(account_ref),
         :ok <- unpaginated(Keyword.get(opts, :cursor)),
         {:ok, body} <-
           rpc(
             state,
             "getTokenAccountsByOwner",
             [pubkey, %{"programId" => @token_program}, @parsed_config],
             :list
           ) do
      items = body |> value() |> List.wrap() |> Enum.map(&token_balance/1)

      {:ok, %{items: items, next: nil}}
    end
  end

  @impl Backend
  def list_transactions(%__MODULE__{source: :rpc} = state, account_ref, opts \\ []) do
    with {:ok, pubkey} <- pubkey(account_ref),
         {:ok, params} <- cursor_params(state, Keyword.get(opts, :cursor)),
         {:ok, body} <-
           rpc(state, "getSignaturesForAddress", [pubkey, page_config(params)], :list) do
      items = List.wrap(body)

      {:ok, %{items: Enum.map(items, &signature_row/1), next: next_cursor(state, items)}}
    end
  end

  @impl Backend
  def get_block(%__MODULE__{source: :rpc} = state, slot) do
    with {:ok, number} <- slot_number(slot) do
      state
      |> rpc_raw("getBlock", [number, @block_config], :block)
      |> block_result(number)
    end
  end

  # -- SQD ---------------------------------------------------------------------

  defp resolve(state) do
    arguments = %{"vm" => "solana", "limit" => @catalog_limit}

    with {:ok, payload} <- sqd(state, "portal_list_networks", arguments, :catalog) do
      payload
      |> Map.get("items", [])
      |> Enum.find_value(&match_network(&1, state.network))
      |> case do
        nil -> {:error, {:unsupported_chain, state.network}}
        network -> {:ok, network}
      end
    end
  end

  # The aliases come from the live response rather than from a table here, so
  # `solana`, `sol` and `solana-beta` resolve without this module tracking them.
  defp match_network(%{"network" => name} = item, wanted) when is_binary(name) do
    if name == wanted or wanted in Map.get(item, "aliases", []) do
      %{network: name, real_time?: item["real_time"] == true}
    end
  end

  defp match_network(_item, _wanted), do: nil

  defp sqd_head(state, network, type) do
    arguments = %{"network" => network, "type" => type}

    with {:ok, payload} <- sqd(state, "portal_get_head", arguments, nil) do
      case payload["number"] do
        number when is_integer(number) -> {:ok, number}
        _absent -> {:error, {:decode_failed, :head}}
      end
    end
  end

  defp indexed_blocks(%{"head" => %{"number" => head}, "start_block" => start})
       when is_integer(head) and is_integer(start),
       do: head - start + 1

  defp indexed_blocks(_payload), do: nil

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. The key fragment is the tool and its own arguments, never an
  # assembled URI, which is what keeps a credential out of a cache key by
  # construction rather than by review.
  defp sqd(state, tool, arguments, class) do
    opts =
      state.http_opts
      |> Keyword.put_new(:rate_limit, @sqd_rate_limit)
      |> cache_opts(state, {tool, arguments}, class)

    case MCPCall.call(state.url, tool, arguments, opts) do
      {:ok, payload} -> {:ok, payload}
      {:tool_error, payload} -> {:error, sqd_refusal(payload, state)}
      {:error, _reason} = error -> error
    end
  end

  # The payload's error code, never its prose. `unknown_network` is a source
  # error the router fails over on; anything else is our own request being
  # wrong, which a sibling source would answer the same way, so it is final.
  defp sqd_refusal(payload, state) do
    case get_in(payload, ["error", "code"]) do
      "unknown_network" -> {:unsupported_chain, state.network}
      _ours -> {:upstream_refused, :unknown}
    end
  end

  # -- JSON-RPC ----------------------------------------------------------------

  defp slot(state, commitment) do
    case rpc(state, "getSlot", [%{"commitment" => commitment}], nil) do
      {:ok, number} when is_integer(number) -> {:ok, number}
      {:ok, _other} -> {:error, {:decode_failed, :slot}}
      {:error, _reason} = error -> error
    end
  end

  defp rpc(state, method, params, class) do
    case rpc_raw(state, method, params, class) do
      {:rpc_error, code} -> {:error, {:upstream_refused, rpc_class(code)}}
      result -> result
    end
  end

  # `{:rpc_error, code}` never leaves this module: `rpc/4` collapses it into
  # the closed taxonomy and `get_block/2` is the one caller that needs the code
  # itself, because -32009 is a success on this chain.
  defp rpc_raw(state, method, params, class) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    opts =
      state.http_opts
      |> Keyword.put_new(:rate_limit, @rpc_rate_limit)
      |> Keyword.put(:headers, [{"content-type", "application/json"}])
      |> cache_opts(state, {method, params}, class)

    state.url
    |> HTTP.post(body, opts)
    |> rpc_response()
  end

  defp rpc_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => %{"code" => code}}} -> {:rpc_error, code}
      {:ok, _other} -> {:error, {:decode_failed, :jsonrpc}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  defp rpc_response({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp rpc_response({:error, _reason} = error), do: error

  defp rpc_class(code) when code in [-32_601, -32_602, -32_004], do: :not_found
  defp rpc_class(code) when code in [401, -32_001], do: :auth
  defp rpc_class(code) when code in [429, -32_005], do: :rate_limit
  defp rpc_class(_code), do: :unknown

  defp cache_opts(opts, _state, _fragment, nil), do: opts
  defp cache_opts(opts, %__MODULE__{cache?: false}, _fragment, _class), do: opts

  defp cache_opts(opts, _state, fragment, class) do
    Keyword.put(opts, :cache, key: fragment, ttl_ms: TTL.for(class))
  end

  defp origin_id(state), do: Origin.id(URI.new!(state.url))

  # -- paging ------------------------------------------------------------------

  defp page_config(params) do
    Map.merge(%{"limit" => @page_limit, "commitment" => "confirmed"}, params)
  end

  # `token_balances/3` mints no cursor, because `getTokenAccountsByOwner` has
  # no parameter to resume on, so a cursor handed back to it came from
  # somewhere else. `:wrong_scope` is what that is: no cursor is in this
  # callback's scope, and serving the first page instead would answer a
  # different question than the caller asked.
  defp unpaginated(nil), do: :ok
  defp unpaginated(_cursor), do: {:error, {:invalid_cursor, :wrong_scope}}

  defp cursor_params(_state, nil), do: {:ok, %{}}

  defp cursor_params(state, cursor) do
    case Cursor.decode(cursor, origin_id(state), :solana_address_signatures) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:error, {:invalid_cursor, reason}}
    end
  end

  defp next_cursor(state, items) do
    case items |> List.last() |> signature() do
      nil ->
        nil

      signature ->
        Cursor.encode(
          %{"before" => signature},
          origin_id(state),
          :solana_address_signatures
        )
    end
  end

  defp signature(%{"signature" => signature}) when is_binary(signature), do: signature
  defp signature(_absent), do: nil

  # -- normalization -----------------------------------------------------------

  defp transaction(body) do
    meta = Map.get(body, "meta") || %{}
    message = get_in(body, ["transaction", "message"]) || %{}

    %{
      hash: body |> get_in(["transaction", "signatures"]) |> first(),
      status: status(meta["err"]),
      block: body["slot"],
      timestamp: unix(body["blockTime"]),
      from: message |> Map.get("accountKeys") |> first() |> account_ref(),
      to: nil,
      value: nil,
      fee: meta["fee"],
      method: nil
    }
  end

  defp signature_row(item) do
    %{
      hash: item["signature"],
      status: status(item["err"]),
      block: item["slot"],
      timestamp: unix(item["blockTime"]),
      from: nil,
      to: nil,
      value: nil,
      fee: nil,
      method: nil
    }
  end

  defp token_balance(item) do
    info = get_in(item, ["account", "data", "parsed", "info"]) || %{}
    amount = Map.get(info, "tokenAmount") || %{}

    %{
      token: %{
        address: info["mint"],
        # A validator serves no token registry, so a symbol and a name are
        # absent rather than guessed from a mint address.
        symbol: nil,
        name: nil,
        decimals: amount["decimals"],
        type: get_in(item, ["account", "data", "program"])
      },
      amount: int(amount["amount"]),
      token_id: nil
    }
  end

  defp block_result({:ok, body}, slot) when is_map(body) do
    {:ok,
     %{
       height: slot,
       hash: body["blockhash"],
       timestamp: unix(body["blockTime"]),
       transactions_count: body |> Map.get("signatures") |> count(),
       miner: nil
     }}
  end

  # A skipped slot is a success with no block in it, and the nil hash is what
  # says so: a produced block always carries a blockhash.
  defp block_result({:ok, nil}, slot), do: {:ok, skipped(slot)}
  defp block_result({:rpc_error, -32_009}, slot), do: {:ok, skipped(slot)}
  defp block_result({:rpc_error, code}, _slot), do: {:error, {:upstream_refused, rpc_class(code)}}
  defp block_result({:error, _reason} = error, _slot), do: error

  defp skipped(slot) do
    %{height: slot, hash: nil, timestamp: nil, transactions_count: nil, miner: nil}
  end

  defp kind(%{"executable" => true}), do: :program
  defp kind(%{"owner" => @system_program}), do: :wallet

  defp kind(%{"owner" => @token_program, "space" => @token_account_space}),
    do: :token_account

  defp kind(%{"owner" => @token_program, "space" => @mint_space}), do: :mint
  defp kind(_info), do: :data

  defp status(nil), do: :success
  defp status(_error), do: :reverted

  defp value(%{"value" => value}), do: value
  defp value(_other), do: nil

  defp account_ref(pubkey) when is_binary(pubkey), do: {:solana, pubkey}
  defp account_ref(_absent), do: nil

  defp first([head | _rest]), do: head
  defp first(_other), do: nil

  defp count(list) when is_list(list), do: length(list)
  defp count(_other), do: nil

  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp int(_other), do: nil

  defp unix(seconds) when is_integer(seconds), do: DateTime.from_unix!(seconds)
  defp unix(_other), do: nil

  # -- ingest ------------------------------------------------------------------

  defp canonical(chain_ref) when is_binary(chain_ref) do
    Map.fetch(@chain_aliases, chain_ref) |> ok_or({:unsupported_chain, chain_ref})
  end

  defp canonical(other), do: {:error, {:unsupported_chain, other}}

  defp source(source) when source in @sources, do: {:ok, source}
  defp source(other), do: {:error, {:unknown_source, other}}

  defp endpoint(:sqd, chain), do: chain.sqd_url
  defp endpoint(:rpc, chain), do: chain.rpc_url

  defp pubkey({:solana, value}), do: base58(value, 32, 44)
  defp pubkey({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp pubkey(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  defp base58(value, min, max) when is_binary(value) do
    characters = to_charlist(value)

    if length(characters) in min..max and Enum.all?(characters, &(&1 in @base58)) do
      {:ok, value}
    else
      {:error, {:unsupported_account_ref, :not_base58}}
    end
  end

  defp base58(_value, _min, _max), do: {:error, {:unsupported_account_ref, :unknown}}

  defp slot_number(slot) when is_integer(slot) and slot >= 0, do: {:ok, slot}

  defp slot_number(slot) when is_binary(slot) do
    case Integer.parse(slot) do
      {number, ""} when number >= 0 -> {:ok, number}
      _unparseable -> {:error, {:decode_failed, :slot}}
    end
  end

  defp slot_number(_other), do: {:error, {:decode_failed, :slot}}

  defp ok_or({:ok, _value} = ok, _reason), do: ok
  defp ok_or(:error, reason), do: {:error, reason}
end
