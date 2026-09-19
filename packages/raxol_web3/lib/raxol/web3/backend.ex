defmodule Raxol.Web3.Backend do
  @moduledoc """
  The chain-read contract: two required callbacks plus twelve optional ones.

  ADR-0033 decision 3. The shape follows what already exists in this repository
  rather than inventing a new one: a `{module, state}` handle as in
  `Raxol.Payments.ChainReader`, a capability-declaring callback as in
  `Raxol.Earn.ProviderAdapter`'s `supported_chain_ids/1`, and a self-identifying
  zero-arity callback as in `Raxol.Gateway.Adapter`'s `platform/0`.

  Eleven of the fourteen are optional, and the count got there in two steps.
  ADR-0033 demoted two of an original eight on evidence about CHAINS: Canton has
  no blocks (none of the Splice Scan API's 79 paths returns one) and on Solana an
  empty slot is a valid success rather than an error, so `get_block/2` is
  optional; outside EVM and TVM a token transfer is not an event but a parse,
  which is the operation Solana providers meter most heavily, so
  `list_token_transfers/3` is too.

  ADR-0039 demoted four more on evidence about SOURCES, which is the question
  the contract actually binds. A raw JSON-RPC node has no method that lists by
  account: the allowlist in `Raxol.Web3.RPC` is ten methods and none of them
  answers "the transactions of this address" or "the tokens this address holds".
  Probed 2026-09-14, Aztec's public surface has no account resource at all
  (`l2/accounts` is a 404) and its transactions carry a fee payer and no
  counterparties; SQD Portal's nearest account tool summarizes activity over a
  look-back window rather than reporting a current balance; and SQD's Solana
  surface has no transaction-by-signature lookup at all, since its query tools
  take a slot or timestamp range plus a cursor and the only id-shaped parameters
  in its 31 tools belong to the EVM and Tron families. So `account_info/2`,
  `get_transaction/2`, `list_transactions/3` and `token_balances/2` are declared
  rather than assumed.

  What survives as required is what a source knows about the CHAIN rather than
  about anything in it: which chain this is, and how far it has got. Every
  question about a thing on the chain needs an index over things of that kind,
  and an index is what a node does not have and an archive has only over ranges.

  ## Three shapes that are load-bearing

  Each is here because the naive version silently lies on a chain we target.

    * `block_height/1` returns a map, never a bare integer. Solana counts slots
      that skip, Canton has no height at all, and Tron ships 26 parallel
      `solidity*` tools purely to expose the irreversible view, so the unit and
      the finalized split are first-class. It is a map rather than ADR-0033's
      `{height, finalized_height, unit}` tuple for one reason: ADR-0038
      decision 7 requires the indexer's lag to be reported alongside, and a
      three-tuple has nowhere to put it. The tuple's point was that a bare
      integer lies; a named map keeps that and can grow.
    * `account_info/2` takes an opaque tagged reference, never a string.
      **Canton has no addresses**, it has party ids, which is why its explorer's
      tool is `get_party`. Tron has dual Base58 and hex encoding, and a Solana
      account may be a wallet, a token account, a PDA or a program.
    * Pagination is an opaque cursor in both directions, never an offset or a
      page number. Every surveyed upstream paginates differently and one caps
      `start + limit` at 10000, so an offset would leak a limit we cannot
      honour uniformly. See `Raxol.Web3.Cursor`.

  ## Optional callbacks are asked, not assumed

  `capabilities/1` declares what a backend answers, and the `supports?/2`
  wrapper checks `function_exported?/3` as well, so a backend that declares a
  capability it did not implement fails as `{:error, {:unsupported, callback}}`
  rather than as an `UndefinedFunctionError` inside a router.

  ## Read-only by construction

  Every callback here is a read. `raw_request/2` is the one that could escape
  that, so it is bounded by a per-backend compile-time allowlist of read
  methods: an unbounded passthrough to a JSON-RPC backend reaches
  `eth_sendRawTransaction`. A backend with nothing to pass through declines the
  callback, which is stronger than policing it.

  ## One error taxonomy, written down once

  `t:error/0` is the closed set, and its typedoc says which half of
  `Raxol.Web3.Router.failover?/1`'s split each reason is on. A backend that
  coins a reason outside it gets the wrong half by default, because an
  unrecognised term is treated as an answer about the question and is final.
  Reach for the list before naming a new one: two of the five backends had
  invented a second spelling of a reason another already had.
  """

  alias Raxol.Web3.Cursor

  @typedoc "A backend handle: the module plus its own state."
  @type t :: {module(), state :: term()}

  @typedoc "CAIP-2, as `Raxol.Payments.Assets.normalize_chain_id/1` already accepts."
  @type chain_ref :: String.t()

  @typedoc """
  An opaque, tagged account reference.

  `{:evm, "0x..."}` today. `{:tron, base58_or_hex}`, `{:party, "Alice::1220ab"}`
  and `{:solana, pubkey}` are the reason it is tagged rather than a string.
  """
  @type account_ref :: {atom(), String.t()}

  @type unit :: :block | :slot | :offset | :round

  @typedoc """
  How far behind the source's view is, or `nil` when it has nothing to report.

  `finished?` is the only field every source can answer. The three measures are
  optional because each upstream publishes a different one and none publishes
  all three: Blockscout reports `indexed_blocks_ratio`, and SQD Portal reports
  a finalized lag in blocks and in seconds and no ratio at all (measured
  2026-09-14: `finalized_lag_blocks` 31, `finalized_lag_seconds` 10). An absent
  key means this source does not publish that measure, which is a different
  fact from a zero, and it is the reason none of them is nilable: a computed
  `indexed_ratio` of `1.0` for a source that publishes no ratio would be a
  fabricated number in the one field that exists so lag is visible.
  """
  @type indexer :: %{
          required(:finished?) => boolean(),
          optional(:indexed_ratio) => float(),
          optional(:lag_blocks) => non_neg_integer(),
          optional(:lag_seconds) => non_neg_integer()
        }

  @type height :: %{
          height: non_neg_integer(),
          finalized_height: non_neg_integer() | nil,
          unit: unit(),
          indexer: indexer() | nil
        }

  @type chain_info :: %{
          chain_ref: chain_ref(),
          average_block_time_ms: number() | nil,
          total_blocks: non_neg_integer() | nil,
          total_transactions: non_neg_integer() | nil,
          total_addresses: non_neg_integer() | nil
        }

  @type transaction :: %{
          hash: String.t(),
          status: :success | :reverted | :pending,
          block: non_neg_integer() | nil,
          timestamp: DateTime.t() | nil,
          from: account_ref() | nil,
          to: account_ref() | nil,
          value: non_neg_integer() | nil,
          fee: non_neg_integer() | nil,
          method: String.t() | nil
        }

  @typedoc """
  What kind of thing an account is, where the chain distinguishes kinds that
  change how `balance` must be read.

  Solana is why this exists and is the shape to follow: measured 2026-09-14, a
  token account's lamport balance is its rent-exempt reserve (2,039,280 for a
  165-byte SPL account), which is a true number and a badly misleading one,
  since the holding a caller asked about is a token amount reachable only
  through `token_balances/2`. The kinds there are `:wallet`, `:program`,
  `:token_account` and `:data`, separated by the account's owner, its
  `executable` flag and its size.

  Open rather than enumerated, because the taxonomy belongs to the chain. A
  backend on a chain with no such notion omits the key: absent is not `nil`
  meaning unknown, it means the question does not apply here. `contract?`
  answers a different question (code presence) and stays.
  """
  @type account_kind :: atom()

  @type account :: %{
          required(:ref) => account_ref(),
          required(:balance) => non_neg_integer() | nil,
          required(:contract?) => boolean(),
          required(:verified?) => boolean(),
          required(:name) => String.t() | nil,
          required(:ens) => String.t() | nil,
          optional(:kind) => account_kind()
        }

  @type token :: %{
          address: String.t(),
          symbol: String.t() | nil,
          name: String.t() | nil,
          decimals: non_neg_integer() | nil,
          type: String.t() | nil
        }

  @type token_balance :: %{token: token(), amount: non_neg_integer(), token_id: String.t() | nil}

  @type token_transfer :: %{
          token: token(),
          amount: non_neg_integer() | nil,
          from: account_ref() | nil,
          to: account_ref() | nil,
          block: non_neg_integer() | nil,
          timestamp: DateTime.t() | nil,
          transaction: String.t() | nil
        }

  @type log :: %{
          address: String.t(),
          topics: [String.t()],
          data: String.t() | nil,
          block: non_neg_integer() | nil,
          transaction: String.t() | nil,
          index: non_neg_integer() | nil
        }

  @type nft :: %{
          token: token(),
          token_id: String.t() | nil,
          name: String.t() | nil,
          image_url: String.t() | nil
        }

  @type block :: %{
          height: non_neg_integer(),
          hash: String.t() | nil,
          timestamp: DateTime.t() | nil,
          transactions_count: non_neg_integer() | nil,
          miner: account_ref() | nil
        }

  @type contract_metadata :: %{
          name: String.t() | nil,
          verified?: boolean(),
          language: String.t() | nil,
          compiler_version: String.t() | nil,
          abi: list() | nil,
          proxy_type: String.t() | nil
        }

  @typedoc "A page of results plus the cursor for the next one, or `nil` at the end."
  @type page(item) :: %{items: [item], next: Cursor.t() | nil}

  @typedoc """
  The backend layer's errors: the closed set, and which half of the split each
  reason is on.

  A superset of `Raxol.Web3.HTTP`'s taxonomy: that module never inspects a
  status or a body, so `{:http, status}` (a status nobody can use),
  `{:upstream_refused, _}` (a refusal announced inside a 200, which is how
  Etherscan answers an unauthenticated call) and `{:decode_failed, _}` (a body
  that is not what its content type claimed) are decided here. None of them
  carries upstream text.

  The split that matters is `Raxol.Web3.Router.failover?/1`'s, and a backend
  that invents a reason outside this list gets the wrong half of it by
  default: an unrecognised term is treated as an answer about the QUESTION and
  is final. The list is here rather than in each backend so that the fifth one
  copies it instead of coining a synonym, which is how
  `{:unsupported_source, _}` and `{:unknown_source, _}` came to be the same
  fact under two names.

  About the SOURCE, so the router tries the next candidate:

    * `{:breaker_open, origin}`, `{:transport, reason}`, `{:timeout, stage}`,
      `{:dns_failed, origin}`, `{:rate_limited, ms}`, `{:too_large, limit}`,
      `{:decode_failed, tag}` - from `Raxol.Web3.HTTP` and the decoders.
    * `{:http, status}` for 403, 408, 429 and any 5xx.
    * `{:upstream_refused, :auth}` and `{:upstream_refused, :rate_limit}` -
      a credential this deployment does not hold, and a budget this origin
      has spent. Both are facts about the source, and a keyless sibling or a
      separate budget answers where this one will not.
    * `{:unsupported_chain, ref}` - this source does not serve this chain. It
      is a read error and not only a construction error because one upstream's
      network set is resolved at runtime: its README, documentation and
      changelog disagree about coverage, so a handle can declare a chain in
      `supported_chain_ids/1` and learn otherwise on the first read, or after
      a cached catalog goes stale.
    * `{:source_unavailable, detail}` - this source went away under us. An
      endpoint it serves unconditionally answered 404, so there is no
      credential to supply and no resource that could have been missing. It is
      separate from `:auth` because they call for different operator actions,
      and `Raxol.Web3.Backend.Aztec` is why: a withdrawn URL prefix was
      reported as `:auth` purely to buy the failover.
    * `{:blocked, :address}` - the target resolved into the reject set.

  About the QUESTION, so the router stops and answers:

    * `{:upstream_refused, :not_found}` - a definitive answer about a missing
      thing, which a sibling would repeat.
    * `{:upstream_refused, :unknown}` - a refusal we could not classify, which
      is not evidence that another source would do better.
    * `{:unsupported, callback}` - this handle does not answer this callback.
      Distinct from `{:unsupported_chain, _}`: the router has already filtered
      by capability, so reaching this means nothing on the chain answers it.
    * `{:invalid_cursor, reason}` - a cursor is pinned to the backend that
      minted it, so replaying it elsewhere would serve page one as page two.
    * `{:unsupported_account_ref, detail}` - the reference is not one this
      chain has.
    * `{:missing_argument, name}` and `{:invalid_argument, name}` - from
      `Raxol.Web3.MCP.Tools`, before any backend is reached.
    * `{:blocked, other}` - a URL we will not dial.

  Construction, from a backend's `new/2` and never from a read:
  `{:unsupported_source, source}`, `{:invalid_base_url, part}`.
  """
  @type error ::
          Raxol.Web3.HTTP.reason()
          | {:http, non_neg_integer()}
          | {:upstream_refused, :auth | :rate_limit | :not_found | :unknown}
          | {:decode_failed, atom()}
          | {:unsupported, atom()}
          | {:unsupported_chain, atom() | String.t()}
          | {:source_unavailable, atom()}
          | {:invalid_cursor, Cursor.reason()}
          | {:unsupported_account_ref, atom()}
          | {:missing_argument, String.t()}
          | {:invalid_argument, String.t()}

  @type list_opts :: [cursor: Cursor.t() | nil]

  # -- identity and capability -------------------------------------------------

  @doc "What this backend is, for logs, config and the router's failover order."
  @callback backend() :: atom()

  @doc """
  What this HANDLE is, when one module serves several upstreams.

  Optional, and `backend/0` is the answer when it is absent. It exists because
  a module is not a source: the Tron backend carries TronGrid, SQD Portal and
  TronScan, and the Solana backend carries an archive and a node, so
  `Raxol.Web3.Router.coverage/2` reported `[:tron, :tron, :tron]` and an
  operator could read the count of surviving sources but not which one dropped
  out. Coverage is the only place a chain's real shape is visible (ADR-0039
  decision 3), so it has to name what it is reporting on.

  A single-source backend declines this and is named by its module, which is
  ADR-0033 decision 3's `platform/0` precedent unchanged.
  """
  @callback backend(state :: term()) :: atom()

  @doc "The chains this handle can answer for."
  @callback supported_chain_ids(state :: term()) :: [chain_ref()]

  @doc "Which optional callbacks this handle answers."
  @callback capabilities(state :: term()) :: [atom()]

  @doc """
  The circuit-breaker key whose state describes this handle's health, or `nil`.

  Infrastructure rather than data, so it is not in `capabilities/1`: a router
  asks it to order candidates, never to answer a read. `nil` means there is no
  health to check, which is the honest answer for a backend that opens no
  socket (`Raxol.Web3.Backend.Stub`) and would be a lie for one that does.

  The key is read, not written. `Raxol.Web3.HTTP` is the only writer, on the
  request path, so a router that ordered by health and then also recorded it
  would double-count one failure.
  """
  @callback health_key(state :: term()) :: Raxol.MCP.CircuitBreaker.key() | nil

  # -- required ----------------------------------------------------------------

  @callback chain_info(state :: term()) :: {:ok, chain_info()} | {:error, error()}
  @callback block_height(state :: term()) :: {:ok, height()} | {:error, error()}

  # -- optional ----------------------------------------------------------------

  # The four reads about a thing on the chain rather than about the chain,
  # optional per ADR-0039. Each needs an index over things of its kind: over
  # accounts for three of them, over transaction ids for `get_transaction/2`.
  # A node has neither, and an archive has both only over block ranges, which
  # is why SQD Portal's Solana surface has no by-signature lookup at all
  # (measured 2026-09-14).
  @callback get_transaction(state :: term(), String.t()) ::
              {:ok, transaction()} | {:error, error()}
  @callback account_info(state :: term(), account_ref()) :: {:ok, account()} | {:error, error()}
  @callback list_transactions(state :: term(), account_ref(), list_opts()) ::
              {:ok, page(transaction())} | {:error, error()}
  # Paginated like the other list callbacks, and it was not until 2026-09-14.
  # It returned a `page()` while taking no `list_opts`, so a backend could MINT
  # a `next` cursor that no caller could hand back: `Blockscout` minted one for
  # `/tokens` and Canton's holdings page is the only paginated party-scoped
  # read that chain offers. A cursor nobody can use is the same class of
  # dishonesty as an empty page standing in for an unanswerable question.
  @callback token_balances(state :: term(), account_ref(), list_opts()) ::
              {:ok, page(token_balance())} | {:error, error()}

  @callback get_block(state :: term(), non_neg_integer() | String.t()) ::
              {:ok, block()} | {:error, error()}
  @callback list_token_transfers(state :: term(), account_ref(), list_opts()) ::
              {:ok, page(token_transfer())} | {:error, error()}
  @callback read_contract(state :: term(), map()) :: {:ok, String.t()} | {:error, error()}
  @callback contract_metadata(state :: term(), account_ref()) ::
              {:ok, contract_metadata()} | {:error, error()}
  @callback get_logs(state :: term(), account_ref(), list_opts()) ::
              {:ok, page(log())} | {:error, error()}
  @callback resolve_name(state :: term(), String.t()) :: {:ok, account_ref()} | {:error, error()}
  @callback list_nfts(state :: term(), account_ref(), list_opts()) ::
              {:ok, page(nft())} | {:error, error()}
  @callback raw_request(state :: term(), map()) :: {:ok, term()} | {:error, error()}

  @optional_callbacks backend: 1,
                      health_key: 1,
                      get_transaction: 2,
                      account_info: 2,
                      list_transactions: 3,
                      token_balances: 3,
                      get_block: 2,
                      list_token_transfers: 3,
                      read_contract: 2,
                      contract_metadata: 2,
                      get_logs: 3,
                      resolve_name: 2,
                      list_nfts: 3,
                      raw_request: 2

  @doc """
  What a handle is, by source where it says so and by module otherwise.

  Arity matters here rather than mere export, unlike `health_key/1`: every
  backend exports `backend/0`, so a name check would always find one and the
  per-handle answer would never be asked for.
  """
  @spec name(t()) :: atom()
  def name({module, state}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :backend, 1),
      do: module.backend(state),
      else: module.backend()
  end

  @doc """
  A handle's health key, or `nil` when it declines to have one.

  Absent rather than required because the callback is optional and a backend
  that never opens a socket has nothing to report.
  """
  @spec health_key(t()) :: Raxol.MCP.CircuitBreaker.key() | nil
  def health_key({module, state}) do
    if exported?(module, :health_key), do: module.health_key(state), else: nil
  end

  @doc """
  Whether a handle answers an optional callback.

  Both halves are checked. `capabilities/1` is the backend's declaration and
  `function_exported?/3` is what is actually there; a declaration without an
  implementation is a boot-time mistake that would otherwise surface as an
  `UndefinedFunctionError` from inside a router's failover.
  """
  @spec supports?(t(), atom()) :: boolean()
  def supports?({module, state}, callback) when is_atom(callback) do
    callback in module.capabilities(state) and exported?(module, callback)
  end

  @doc """
  Invoke a callback on a handle, refusing one it does not answer.

  The required two are always dispatched; an optional one that the handle does
  not support is `{:error, {:unsupported, callback}}`, which is a router's cue
  to try the next backend rather than to fail the whole read.
  """
  @spec call(t(), atom(), [term()]) :: {:ok, term()} | {:error, error()}
  def call({module, state} = handle, callback, args \\ []) do
    cond do
      required?(callback) -> apply(module, callback, [state | args])
      supports?(handle, callback) -> apply(module, callback, [state | args])
      true -> {:error, {:unsupported, callback}}
    end
  end

  @required [
    chain_info: 1,
    block_height: 1
  ]

  @doc "The two callbacks every backend implements, as `{name, arity}`."
  @spec required() :: keyword(non_neg_integer())
  def required, do: @required

  defp required?(callback), do: Keyword.has_key?(@required, callback)

  defp exported?(module, callback) do
    Code.ensure_loaded?(module) and
      Enum.any?(module.__info__(:functions), fn {name, _arity} -> name == callback end)
  end
end
