defmodule Raxol.Web3.Backend.JSONRPC do
  @moduledoc """
  The partial source: a backend whose upstream is a raw JSON-RPC node.

  ADR-0039 decision 4. A node has no index over accounts, so it cannot be asked
  what an address has done or what it holds, and before that amendment there was
  no contract this source could satisfy. What it can answer it answers well:
  `eth_call` and `eth_getLogs` are two reads a challenge-gated explorer cannot
  serve at all, so on part of the surface this fallback is stronger than the
  primary it stands behind.

  ## What is declared, and what is absent

  Required: `chain_info/1` and `block_height/1`. Declared:
  `get_transaction/2`, `account_info/2`, `get_block/2`, `get_logs/3`,
  `read_contract/2` and `raw_request/2`.

  Absent, and absent is the answer rather than an error shape:
  `list_transactions/3`, `token_balances/2`, `list_token_transfers/3`,
  `list_nfts/3`, `contract_metadata/2` and `resolve_name/2`. No method on
  `Raxol.Web3.RPC`'s allowlist answers any of them. A callback here that
  returned `{:error, {:unsupported, _}}` to satisfy the behaviour would be a
  stub with a behaviour attached, and `Raxol.Web3.Router.coverage/2` is what
  makes the absence legible to an operator.

  ## What a node does not know, reported as `nil`

  `chain_info/1` answers `total_blocks`, `total_transactions` and
  `total_addresses` as `nil`, because those are an indexer's counters and a node
  keeps none of them. `block_height/1` answers `indexer: nil` for the same
  reason: there is no indexer here to be behind, and a fabricated
  `%{finished?: true}` would claim a component exists and is healthy.
  `average_block_time_ms` is not decoration, though: it is derived from two real
  block timestamps 100 blocks apart.

  ## The identity check

  `chain_info/1` asks `eth_chainId` and compares it with the chain reference the
  handle was built for. A URL pointed at the wrong network is otherwise
  invisible: every callback here would answer, correctly, about a chain nobody
  asked about. A mismatch is `{:blocked, :chain_mismatch}`, which is this
  package's existing term for "we refused this target" rather than a new error
  variant. It is terminal at the router, which is deliberate: failing over would
  answer the caller from another source and leave the misconfigured handle
  answering wrongly forever.

  The check is `chain_info/1`'s alone, not every callback's. It is the identity
  callback, and running it on each read would double the round trips of the
  cheapest ones.

  ## `contract?` is code presence, not account type

  `account_info/2` reads `eth_getCode` and reports whether there is any. Since
  EIP-7702 that is no longer the same question as "this is not an externally
  owned account": a wallet that has signed a delegation carries code. A consumer
  deciding whether it is talking to a wallet or to a contract has to ask
  something else, and reinterpreting the field here would only move the wrong
  answer closer to the caller. `Raxol.Web3.Backend.Blockscout` says the same
  about the upstream field it passes through, for the same reason.

  ## A transaction that is known but unmined

  `get_transaction/2` reads the transaction and its receipt. A node that has the
  transaction in its pool answers the first and `null` for the second, and that
  is `:pending` with a `nil` block, which is the value the contract carries for
  exactly this case. A hash the node has never seen is
  `{:error, {:upstream_refused, :not_found}}`, because "no such transaction" is
  an answer about the question rather than about the source, and the router must
  not fail over on it.

  There is no timestamp. A node's transaction record carries none, and the block
  that does would be a third round trip for a field `get_block/2` already
  answers. `method` is the four-byte selector rather than a name: a node has no
  ABI, so `"0xa9059cbb"` is the whole of what it knows.

  ## Bounded log windows

  `eth_getLogs` over an unbounded range is how a public node refuses a query, so
  a request here covers at most 2,000 blocks and a walk
  pages forward with a cursor. The cursor carries the next `fromBlock` and the
  head the walk was pinned to when it started, so a walk terminates rather than
  chasing a head that keeps moving.

  ## Chains

  `@default_urls` is a dated table with one entry, and an entry is a claim:
  every other chain needs an explicit `:url`. ADR-0033 gap 2 records that chain
  4663 had no public RPC default anywhere in library code and that the only URL
  lived in a shell script. This is where that closes.
  """

  @behaviour Raxol.Web3.Backend

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Origin
  alias Raxol.Web3.RPC
  alias Raxol.Web3.TTL

  # Probed 2026-09-14: this endpoint answered `eth_chainId` with `0x1237`, which
  # is 4663, and `eth_blockNumber` with `0x3bd25de`. A table entry is a claim
  # about a live endpoint on a date, so the table carries only what was probed.
  @default_urls %{
    4663 => "https://rpc.mainnet.chain.robinhood.com"
  }

  # A guess, labelled as one per ADR-0038's mitigation list: no node in
  # `@default_urls` publishes a rate limit. The floor is set by the most
  # expensive callback rather than by taste, which is what makes it a figure
  # rather than a number: `chain_info/1` costs three calls, so a capacity below
  # that would refuse its own read. A deployment with a real figure passes
  # `:rate_limit` inside `:http_opts` and this is never consulted.
  @rate_limit [capacity: 10, refill_per_second: 4.0]

  # Both judgements, neither measured.
  #
  # The block-time span is wide enough that one slow block does not dominate and
  # narrow enough to cost one extra round trip rather than a walk. The log
  # window is the per-request block range: small enough that a public node will
  # serve it, large enough that a walk over a day of blocks is tens of pages and
  # not thousands. The lookback is how far back a walk starts when the caller
  # gives no cursor.
  @block_time_sample 100
  @log_window 2_000
  @log_lookback 10_000

  @enforce_keys [:chain_ref, :chain_id, :url]
  defstruct [
    :chain_ref,
    :chain_id,
    :url,
    http_opts: [],
    cache?: true,
    log_window: @log_window,
    log_lookback: @log_lookback
  ]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          chain_id: non_neg_integer(),
          url: String.t(),
          http_opts: keyword(),
          cache?: boolean(),
          log_window: pos_integer(),
          log_lookback: pos_integer()
        }

  # `get_transaction/2` leads the list because it is the one that moved: it was
  # required until 2026-09-14, and it is declared here rather than assumed
  # because an archive with no index over transaction ids cannot answer it. A
  # node can. The three that follow the reads a node simply does not have.
  @capabilities [
    :get_transaction,
    :account_info,
    :get_block,
    :get_logs,
    :read_contract,
    :raw_request
  ]

  @doc """
  Build a handle for a CAIP-2 chain reference.

  `:url` is the node. Without one, `@default_urls` answers for a chain that was
  probed, and every other chain is `{:error, :no_rpc_url}` rather than a guess.

  `:http_opts` is forwarded to `Raxol.Web3.HTTP` unchanged, except that a
  `:rate_limit` the caller did not set is seeded with this module's labelled
  figure. `:cache` defaults to `true`; a height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, chain_id} <- chain_id(chain_ref),
         {:ok, url} <- url(chain_id, Keyword.get(opts, :url)) do
      state = %__MODULE__{
        chain_ref: chain_ref,
        chain_id: chain_id,
        url: url,
        http_opts: Keyword.put_new(Keyword.get(opts, :http_opts, []), :rate_limit, @rate_limit),
        cache?: Keyword.get(opts, :cache, true),
        log_window: Keyword.get(opts, :log_window, @log_window),
        log_lookback: Keyword.get(opts, :log_lookback, @log_lookback)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The dated chain-to-URL table. Data, not behaviour."
  @spec default_urls() :: %{non_neg_integer() => String.t()}
  def default_urls, do: @default_urls

  @impl Backend
  def backend, do: :jsonrpc

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{}), do: @capabilities

  # The key `Raxol.Web3.HTTP` writes on every request to this node, so a router
  # ordering by it reads the verdict the outbound path already recorded.
  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, origin_id(state)}

  # -- required ----------------------------------------------------------------

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with :ok <- check_chain_id(state),
         {:ok, latest} <- head_block(state),
         {:ok, average} <- average_block_time_ms(state, latest) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: average,
         # A node keeps no aggregate counters. `nil` is what it knows.
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{} = state) do
    with {:ok, height} <- RPC.block_number(state.url, state.http_opts),
         {:ok, finalized} <- RPC.block_height_by_tag(state.url, "finalized", state.http_opts) do
      # Never cached, and `indexer: nil` because there is no indexer here.
      {:ok, %{height: height, finalized_height: finalized, unit: :block, indexer: nil}}
    end
  end

  # -- declared ----------------------------------------------------------------

  @impl Backend
  def get_transaction(%__MODULE__{} = state, hash) when is_binary(hash) do
    case RPC.transaction(state.url, hash, rpc_opts(state, {:transaction, hash}, :transaction)) do
      {:ok, nil} -> {:error, {:upstream_refused, :not_found}}
      {:ok, transaction} -> with_receipt(state, hash, transaction)
      {:error, _reason} = error -> error
    end
  end

  @impl Backend
  def account_info(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, balance} <- RPC.balance(state.url, address, "latest", account_opts(state, address)),
         {:ok, code} <- RPC.code(state.url, address, "latest", code_opts(state, address)) do
      {:ok,
       %{
         ref: {:evm, address},
         balance: balance,
         # Code presence, not account type. See the moduledoc: EIP-7702.
         # `Raxol.Web3.RPC.code/4` refuses a non-binary result as
         # `{:decode_failed, :code}`, so there is no nil to test for here.
         contract?: code != "0x",
         # A node has no source, so it can verify nothing and knows no names.
         verified?: false,
         name: nil,
         ens: nil
       }}
    end
  end

  @impl Backend
  def get_block(%__MODULE__{} = state, number_or_hash) do
    case fetch_block(state, number_or_hash) do
      {:ok, nil} -> {:error, {:upstream_refused, :not_found}}
      {:ok, body} -> block(body)
      {:error, _reason} = error -> error
    end
  end

  @impl Backend
  def get_logs(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, window} <- window(state, Keyword.get(opts, :cursor)),
         {:ok, logs} <-
           RPC.logs(state.url, filter(address, window), logs_opts(state, address, window)) do
      {:ok, %{items: Enum.map(logs, &log/1), next: next_cursor(state, window)}}
    end
  end

  @impl Backend
  def read_contract(%__MODULE__{} = state, %{to: _to, data: _data} = call) do
    # Uncached, like the REST backend's: a gate reading a balance through
    # `eth_call` is the caller least able to accept a stale answer.
    RPC.eth_call(state.url, call, Map.get(call, :block, "latest"), state.http_opts)
  end

  @doc """
  A JSON-RPC call for a method on `Raxol.Web3.RPC`'s compile-time allowlist.

  This is the callback ADR-0033 section 3 introduced the allowlist for, and this
  backend is its intended use: an unbounded passthrough to a node reaches
  `eth_sendRawTransaction`. `Raxol.Web3.RPC.call/4` refuses a method outside the
  allowlist before a request is built, so the refusal costs no outbound call.

  Nothing on the served surface takes a method name from a caller, so this is
  reachable from Elixir and from nowhere else.
  """
  @impl Backend
  def raw_request(%__MODULE__{} = state, %{method: method} = request) when is_binary(method) do
    RPC.call(state.url, method, Map.get(request, :params, []), state.http_opts)
  end

  def raw_request(%__MODULE__{}, _malformed), do: {:error, {:unsupported, :rpc_method}}

  # -- the outbound path -------------------------------------------------------

  # One place composes a cache class onto an RPC call, as the REST backend's
  # `get/4` does for a path. The key fragment is the method and its own
  # arguments, never the URL: a bring-your-own-node deployment carries its
  # credential in the host or the path, and ADR-0033 section 7 names cache keys
  # as one of the four places a credential leaks. `Raxol.Web3.HTTP` composes the
  # fragment with the origin id.
  defp rpc_opts(state, _fragment, nil), do: state.http_opts
  defp rpc_opts(%__MODULE__{cache?: false} = state, _fragment, _class), do: state.http_opts

  defp rpc_opts(state, fragment, class) do
    Keyword.put(state.http_opts, :cache, key: fragment, ttl_ms: TTL.for(class))
  end

  # Both halves of an account read share the `:account` class. Code gets the
  # short TTL rather than `:contract_metadata`'s hour for one reason: an
  # EIP-7702 delegation can appear and disappear between two transactions, so an
  # hour-old `contract?` is a stale answer to a question that moves.
  defp account_opts(state, address), do: rpc_opts(state, {:balance, address}, :account)
  defp code_opts(state, address), do: rpc_opts(state, {:code, address}, :account)

  defp logs_opts(state, address, %{from: from, to: to}) do
    rpc_opts(state, {:logs, address, from, to}, :list)
  end

  defp block_at(state, tag_or_number) do
    RPC.block_by_number(state.url, tag_or_number, block_opts(state, tag_or_number))
  end

  # A node with no head is a node that cannot answer anything, so `null` here is
  # a body that did not say what it claimed rather than a fact about a chain.
  defp head_block(state) do
    case block_at(state, "latest") do
      {:ok, nil} -> {:error, {:decode_failed, :block}}
      other -> other
    end
  end

  # A tag moves, a number does not, and only the second is worth a block TTL.
  defp block_opts(state, tag) when is_binary(tag), do: rpc_opts(state, nil, nil)
  defp block_opts(state, number), do: rpc_opts(state, {:block, number}, :block)

  defp fetch_block(state, number) when is_integer(number), do: block_at(state, number)

  defp fetch_block(state, "0x" <> rest = hash) when byte_size(rest) == 64 do
    RPC.block_by_hash(state.url, hash, rpc_opts(state, {:block, hash}, :block))
  end

  defp fetch_block(state, tag) when is_binary(tag), do: block_at(state, tag)

  defp with_receipt(state, hash, transaction) do
    with {:ok, receipt} <-
           RPC.receipt(state.url, hash, rpc_opts(state, {:receipt, hash}, :transaction)) do
      {:ok, transaction(transaction, receipt)}
    end
  end

  defp check_chain_id(%__MODULE__{chain_id: expected} = state) do
    with {:ok, hex} <-
           RPC.call(state.url, "eth_chainId", [], rpc_opts(state, :chain_id, :chain_stats)),
         {:ok, answered} <- RPC.decode_quantity(hex) do
      if answered == expected, do: :ok, else: {:error, {:blocked, :chain_mismatch}}
    end
  end

  # Advisory, like the REST backend's indexer lag: the block time is extra
  # information about a chain, not the chain's identity, so a node that has
  # pruned the earlier block or a chain younger than the sample answers `nil`
  # rather than failing the read. The head that this is derived from is not
  # advisory, and its failure is already `chain_info/1`'s failure.
  defp average_block_time_ms(state, latest) do
    with {:ok, height} <- RPC.decode_quantity(latest["number"]),
         true <- height > @block_time_sample,
         {:ok, newer} <- RPC.decode_quantity(latest["timestamp"]),
         {:ok, %{"timestamp" => hex}} <- block_at(state, height - @block_time_sample),
         {:ok, older} <- RPC.decode_quantity(hex) do
      {:ok, (newer - older) * 1000 / @block_time_sample}
    else
      _unavailable -> {:ok, nil}
    end
  end

  # -- the log walk ------------------------------------------------------------

  # Page one establishes the head and pins the walk to it. Every later page
  # takes both numbers from the cursor, so the walk terminates: a walk that
  # re-read the head each page would chase a chain that keeps producing blocks.
  defp window(state, nil) do
    with {:ok, head} <- RPC.block_number(state.url, state.http_opts) do
      {:ok, bounded(state, max(head - state.log_lookback + 1, 0), head)}
    end
  end

  defp window(state, cursor) do
    case Cursor.decode(cursor, origin_id(state), :rpc_logs) do
      {:ok, %{"from_block" => from, "to_block" => to}}
      when is_integer(from) and is_integer(to) ->
        {:ok, bounded(state, from, to)}

      {:ok, _incomplete} ->
        {:error, {:invalid_cursor, :malformed}}

      {:error, reason} ->
        {:error, {:invalid_cursor, reason}}
    end
  end

  defp bounded(state, from, walk_to) do
    %{from: from, to: min(from + state.log_window - 1, walk_to), walk_to: walk_to}
  end

  defp filter(address, %{from: from, to: to}) do
    %{
      "address" => address,
      "fromBlock" => RPC.encode_quantity(from),
      "toBlock" => RPC.encode_quantity(to)
    }
  end

  defp next_cursor(_state, %{to: to, walk_to: walk_to}) when to >= walk_to, do: nil

  defp next_cursor(state, %{to: to, walk_to: walk_to}) do
    Cursor.encode(
      %{"from_block" => to + 1, "to_block" => walk_to},
      origin_id(state),
      :rpc_logs
    )
  end

  defp origin_id(state), do: Origin.id(URI.new!(state.url))

  # -- normalization -----------------------------------------------------------

  defp transaction(item, receipt) do
    %{
      hash: item["hash"],
      status: status(receipt),
      block: quantity(item["blockNumber"]),
      # A node's transaction record carries no timestamp. See the moduledoc.
      timestamp: nil,
      from: address_ref(item["from"]),
      to: address_ref(item["to"]),
      value: quantity(item["value"]),
      fee: fee(receipt),
      method: selector(item["input"])
    }
  end

  defp block(body) do
    with {:ok, height} <- RPC.decode_quantity(body["number"]) do
      {:ok,
       %{
         height: height,
         hash: body["hash"],
         timestamp: timestamp(body["timestamp"]),
         transactions_count: length(Map.get(body, "transactions", [])),
         miner: address_ref(body["miner"])
       }}
    end
  end

  defp log(item) do
    %{
      address: item["address"],
      topics: item |> Map.get("topics", []) |> Enum.reject(&is_nil/1),
      data: item["data"],
      block: quantity(item["blockNumber"]),
      transaction: item["transactionHash"],
      index: quantity(item["logIndex"])
    }
  end

  # No receipt is a transaction the node holds but has not mined, which the
  # contract calls `:pending`. A mined receipt with no `status` field is
  # pre-Byzantium: none of the chains in `@default_urls` is, and `:pending` is
  # the only non-committal value the contract carries, with a non-nil `block`
  # to tell the two apart.
  defp status(nil), do: :pending
  defp status(%{"status" => "0x1"}), do: :success
  defp status(%{"status" => "0x0"}), do: :reverted
  defp status(_pre_byzantium), do: :pending

  defp fee(nil), do: nil

  defp fee(receipt) do
    with used when is_integer(used) <- quantity(receipt["gasUsed"]),
         price when is_integer(price) <- quantity(receipt["effectiveGasPrice"]) do
      used * price
    else
      _incomplete -> nil
    end
  end

  # The four-byte selector, because a node has no ABI to name it.
  defp selector("0x" <> rest) when byte_size(rest) >= 8, do: "0x" <> binary_part(rest, 0, 8)
  defp selector(_absent), do: nil

  defp address_ref(address) when is_binary(address), do: {:evm, address}
  defp address_ref(_absent), do: nil

  defp quantity(value) do
    case RPC.decode_quantity(value) do
      {:ok, number} -> number
      {:error, _reason} -> nil
    end
  end

  defp timestamp(value) do
    with {:ok, seconds} <- RPC.decode_quantity(value),
         {:ok, datetime} <- DateTime.from_unix(seconds) do
      datetime
    else
      _unusable -> nil
    end
  end

  defp chain_id("eip155:" <> id) do
    case Integer.parse(id) do
      {chain_id, ""} -> {:ok, chain_id}
      _unparseable -> {:error, {:unsupported_chain, id}}
    end
  end

  defp chain_id(other), do: {:error, {:unsupported_chain, other}}

  defp url(_chain_id, url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> {:ok, url}
      _unusable -> {:error, :invalid_rpc_url}
    end
  end

  defp url(chain_id, nil) do
    case Map.fetch(@default_urls, chain_id) do
      {:ok, url} -> {:ok, url}
      :error -> {:error, :no_rpc_url}
    end
  end

  defp evm_address({:evm, address}) when is_binary(address), do: {:ok, address}
  defp evm_address({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp evm_address(_other), do: {:error, {:unsupported_account_ref, :unknown}}
end
