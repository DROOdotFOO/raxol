defmodule Raxol.Web3.Backend.Blockscout do
  @moduledoc """
  The EVM backend, against a Blockscout instance's `/api/v2/*` surface.

  ADR-0038 decision 7. Every path below returned 200 on 2026-09-13 and the
  shapes are pinned by recorded responses in `test/fixtures/blockscout`, because
  the vendor publishes no spec for this surface: `/api-docs` is a 404 on every
  instance probed, so the mapping is probe-derived and has to be re-probed on
  upgrade rather than read.

  Consuming the REST API rather than forking the server is the whole point.
  ADR-0033 records that the Blockscout stack was relicensed in April and May
  2026 under revocable terms that forbid distributing derivative works, so a
  public fork is unavailable; calling a public HTTP API carries no licence
  obligation at all.

  ## Two structural points

  `raw_request/2` is **not implemented**, so this backend's read allowlist is
  empty. ADR-0033 §3 introduced that allowlist because an unbounded passthrough
  to a JSON-RPC backend reaches `eth_sendRawTransaction`. A REST backend has no
  method parameter to abuse, so declining the callback keeps §4's "read-only by
  construction" claim structural rather than policed.

  `block_height/1` never mixes sources. With an RPC URL configured, both
  numbers come from the node (`eth_blockNumber` and
  `eth_getBlockByNumber("finalized")`); without one, the height comes from REST
  and `finalized_height` is `nil`. The obvious third option, a REST height
  composed with an RPC finality, is the one that is wrong: they are different
  systems, the REST one is an indexer view and is cacheable, and an indexer
  that is behind yields `finalized_height` above `height`, which is the one
  invariant the shape exists to express. A consumer using the pair for
  confirmation depth would read a negative depth. The lag that composition
  would have hidden is reported instead, from `/api/v2/main-page/indexing-status`.

  ## Chains

  Final hosts only, because §7 refuses redirects: `optimism.blockscout.com`
  answers 301 to `explorer.optimism.io`, so the table carries the destination
  or Optimism simply fails.

  Chain 4663 is present and marked `challenge_gated`. Its API paths answered
  403 with `cf-mitigated: challenge` on 2026-09-13 while `/` returned 200 and
  the chain registry still listed the instance, so this is a dated WAF state
  rather than a structural fact. Carrying it as health means the circuit
  breaker trips, the router fails over to raw RPC, and coverage returns on its
  own if the rule lifts. Excluding it from the table would have needed a code
  change to get back.

  ## `contract?` is code presence, not account type

  `account_info/2` passes the upstream's `is_contract` through unchanged, and
  that field means "this address has code", which since EIP-7702 is no longer
  the same question as "this is not an externally owned account". The recorded
  fixture makes the point: `vitalik.eth` comes back `is_contract: true`,
  because the address carries a delegation designator. A consumer deciding
  whether it is talking to a wallet or a contract has to ask something else,
  and reinterpreting the field here would only move the wrong answer closer to
  the caller.

  ## Token balances

  `token_balances/2` reads `/api/v2/addresses/{hash}/tokens`, **not**
  `/token-balances`. The latter is unpaginated and scales with holdings:
  measured on 2026-09-13 it returned 3,289,596 bytes carrying 8,009 items for
  one well-known wallet, against 26,160 bytes for a 50-item page from `/tokens`.
  No fixed byte ceiling bounds an unpaginated list, so the answer is a
  different endpoint rather than a bigger ceiling.
  """

  @behaviour Raxol.Web3.Backend

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Origin
  alias Raxol.Web3.RPC
  alias Raxol.Web3.TTL

  # `:http_opts` is an operator's own keyword list and may carry an
  # authorization header, so it is not something `inspect/1` may render: a
  # handle reaches an operator through `Raxol.Web3.Router.candidates/3`, and a
  # crash anywhere below formats the struct whole into a log line.
  @derive {Inspect, except: [:http_opts]}
  @enforce_keys [:chain_ref, :host]
  defstruct [:chain_ref, :host, :rpc_url, http_opts: [], cache?: true]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          host: String.t(),
          rpc_url: String.t() | nil,
          http_opts: keyword(),
          cache?: boolean()
        }

  # Probed 2026-09-13. `:serving` and `:challenge_gated` are both admitted; the
  # status is a dated note for a human, not a gate, because the breaker is what
  # decides reachability at runtime.
  @hosts %{
    1 => {"eth.blockscout.com", :serving},
    10 => {"explorer.optimism.io", :serving},
    137 => {"polygon.blockscout.com", :serving},
    8453 => {"base.blockscout.com", :serving},
    42_161 => {"arbitrum.blockscout.com", :serving},
    4663 => {"robinhoodchain.blockscout.com", :challenge_gated}
  }

  # Every optional callback this handle answers over REST alone. The four reads
  # about a thing on the chain lead the list because they were required until
  # ADR-0039: an explorer has the indexes they need, over accounts and over
  # transaction ids alike, so a Blockscout handle declares all four and nothing
  # that was answerable before that amendment stopped being answerable.
  @optional_with_rest [
    :get_transaction,
    :account_info,
    :list_transactions,
    :token_balances,
    :get_block,
    :list_token_transfers,
    :contract_metadata,
    :get_logs,
    :resolve_name,
    :list_nfts
  ]

  @hex_digits Enum.concat([?0..?9, ?a..?f, ?A..?F])

  @doc """
  Build a handle for a CAIP-2 chain reference.

  `:rpc_url` unlocks `read_contract/2` and the finalized half of
  `block_height/1`; without it both degrade honestly rather than guessing.
  `:http_opts` is forwarded to `Raxol.Web3.HTTP` unchanged.

  `:cache` defaults to `true`. Setting it to `false` turns off the response
  cache for this handle, which a caller that must see the head on every read
  needs and which nothing else can express: the TTLs in `Raxol.Web3.TTL` are
  short, but "short" is not "none". A height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, chain_id} <- chain_id(chain_ref),
         {:ok, {host, _status}} <-
           Map.fetch(@hosts, chain_id) |> ok_or({:unsupported_chain, chain_ref}) do
      state = %__MODULE__{
        chain_ref: chain_ref,
        host: host,
        rpc_url: Keyword.get(opts, :rpc_url),
        http_opts: Keyword.get(opts, :http_opts, []),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The chain-to-host table, with its dated status. Data, not behaviour."
  @spec hosts() :: %{non_neg_integer() => {String.t(), :serving | :challenge_gated}}
  def hosts, do: @hosts

  @impl Backend
  def backend, do: :blockscout

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{rpc_url: nil}), do: @optional_with_rest
  def capabilities(%__MODULE__{}), do: [:read_contract | @optional_with_rest]

  # The same key `Raxol.Web3.HTTP` writes on every request through this host,
  # so a router ordering by it sees the verdict the outbound path already
  # recorded rather than keeping a second opinion. `origin_id/1` registers the
  # origin as a side effect, which is what makes the key resolvable back to a
  # host by an operator.
  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, origin_id(state)}

  # -- required ----------------------------------------------------------------

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with {:ok, body} <- get(state, "/api/v2/stats", %{}, :chain_stats) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: body["average_block_time"],
         # A count of indexed blocks, not a height. Reading it as one is the
         # mistake ADR-0038 records: use `block_height/1`.
         total_blocks: int(body["total_blocks"]),
         total_transactions: int(body["total_transactions"]),
         total_addresses: int(body["total_addresses"])
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{rpc_url: nil} = state) do
    with {:ok, body} <- get(state, "/api/v2/blocks", %{"type" => "block"}),
         {:ok, height} <- latest_height(body) do
      {:ok, %{height: height, finalized_height: nil, unit: :block, indexer: indexer(state)}}
    end
  end

  def block_height(%__MODULE__{rpc_url: url} = state) do
    with {:ok, height} <- RPC.block_number(url, state.http_opts),
         {:ok, finalized} <- RPC.block_height_by_tag(url, "finalized", state.http_opts) do
      {:ok, %{height: height, finalized_height: finalized, unit: :block, indexer: indexer(state)}}
    end
  end

  @impl Backend
  def get_transaction(%__MODULE__{} = state, hash) when is_binary(hash) do
    with {:ok, body} <- get(state, "/api/v2/transactions/#{segment(hash)}", %{}, :transaction) do
      transaction(body)
    end
  end

  @impl Backend
  def account_info(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, body} <- get(state, "/api/v2/addresses/#{segment(address)}", %{}, :account),
         {:ok, balance} <- Backend.money(body["coin_balance"], :balance) do
      {:ok,
       %{
         ref: {:evm, body["hash"] || address},
         balance: balance,
         contract?: body["is_contract"] == true,
         verified?: body["is_verified"] == true,
         name: body["name"],
         ens: body["ens_domain_name"]
       }}
    end
  end

  @impl Backend
  def list_transactions(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(
        state,
        "/api/v2/addresses/#{segment(address)}/transactions",
        :address_transactions,
        opts,
        &transaction/1
      )
    end
  end

  # The cursor this minted was unusable until 2026-09-14: the callback took no
  # `list_opts`, so `/tokens` handed back a `next` that no caller could feed in.
  @impl Backend
  def token_balances(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(
        state,
        "/api/v2/addresses/#{segment(address)}/tokens",
        :address_tokens,
        opts,
        &token_balance/1
      )
    end
  end

  # -- optional ----------------------------------------------------------------

  @impl Backend
  def get_block(%__MODULE__{} = state, number) do
    with {:ok, body} <- get(state, "/api/v2/blocks/#{segment(number)}", %{}, :block) do
      {:ok,
       %{
         height: int(body["height"]),
         hash: body["hash"],
         timestamp: timestamp(body["timestamp"]),
         transactions_count: int(body["transactions_count"]),
         miner: address_ref(body["miner"])
       }}
    end
  end

  @impl Backend
  def list_token_transfers(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(
        state,
        "/api/v2/addresses/#{segment(address)}/token-transfers",
        :address_token_transfers,
        opts,
        &token_transfer/1
      )
    end
  end

  @impl Backend
  def get_logs(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(state, "/api/v2/addresses/#{segment(address)}/logs", :address_logs, opts, &log/1)
    end
  end

  @impl Backend
  def list_nfts(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(state, "/api/v2/addresses/#{segment(address)}/nft", :address_nft, opts, &nft/1)
    end
  end

  @impl Backend
  def contract_metadata(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, body} <-
           get(state, "/api/v2/smart-contracts/#{segment(address)}", %{}, :contract_metadata) do
      {:ok,
       %{
         name: body["name"],
         verified?: body["is_verified"] == true,
         language: body["language"],
         compiler_version: body["compiler_version"],
         abi: body["abi"],
         proxy_type: body["proxy_type"]
       }}
    end
  end

  @impl Backend
  def resolve_name(%__MODULE__{} = state, name) when is_binary(name) do
    with {:ok, body} <- get(state, "/api/v2/search", %{"q" => name}, :account),
         {:ok, rows} <- page_rows(body["items"]) do
      case Enum.find_value(rows, &match_name(&1, name)) do
        nil -> {:error, {:upstream_refused, :not_found}}
        ref -> {:ok, ref}
      end
    end
  end

  @impl Backend
  def read_contract(%__MODULE__{rpc_url: nil}, _call),
    do: {:error, {:unsupported, :read_contract}}

  def read_contract(%__MODULE__{rpc_url: url} = state, %{to: _to, data: _data} = call) do
    RPC.eth_call(url, call, Map.get(call, :block, "latest"), state.http_opts)
  end

  # -- the outbound path -------------------------------------------------------

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. The key fragment is built here, from the endpoint's own path and
  # its own query map, and never from the assembled URI: that is what keeps a
  # credential-bearing query parameter out of a cache key by construction
  # rather than by review. `Raxol.Web3.HTTP` composes it with the origin id.
  defp get(state, path, query \\ %{}, class \\ nil) do
    state
    |> url(path, query)
    |> HTTP.get(cache_opts(state, path, query, class))
    |> decode()
  end

  defp cache_opts(state, _path, _query, nil), do: state.http_opts
  defp cache_opts(%{cache?: false} = state, _path, _query, _class), do: state.http_opts

  defp cache_opts(state, path, query, class) do
    Keyword.put(state.http_opts, :cache, key: {path, query}, ttl_ms: TTL.for(class))
  end

  defp url(state, path, query) when map_size(query) == 0, do: "https://#{state.host}#{path}"

  defp url(state, path, query) do
    "https://#{state.host}#{path}?#{URI.encode_query(query)}"
  end

  # Percent-encodes everything outside the unreserved set, so a caller-supplied
  # hash, address or block identifier cannot carry a `/`, a `?` or a `#` and
  # reshape the path it is interpolated into. `URI.encode/1`'s default
  # predicate leaves all three alone and would be no defence at all.
  # `Raxol.Web3.Backend.Aztec` encodes its own path parameters the same way.
  defp segment(value) when is_integer(value), do: Integer.to_string(value)
  defp segment(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # A non-2xx carries no body onward: a 403 challenge page is HTML written by
  # someone else, and ADR-0038 decision 6 keeps upstream text out of an error
  # term. The status is what the router classifies on.
  defp decode({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, :not_an_object}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  defp decode({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp decode({:error, _reason} = error), do: error

  # Every list shares the `:list` class, and the cursor's decoded parameters are
  # part of the key: page two of a walk is a different cache entry from page
  # one, which is the only way a cached page and a cursor can coexist without
  # one serving the other's contents.
  defp page(state, path, endpoint, opts, mapper) do
    with {:ok, query} <- cursor_query(state, endpoint, Keyword.get(opts, :cursor)),
         {:ok, body} <- get(state, path, query, :list),
         {:ok, rows} <- page_rows(body["items"]),
         {:ok, items} <- Backend.map_rows(rows, mapper, endpoint) do
      {:ok,
       %{
         items: items,
         next: next_cursor(state, body["next_page_params"], endpoint)
       }}
    end
  end

  # An absent list is an empty page, and a list-shaped key holding something
  # else is a body that is not what it claimed rather than a page with no
  # rows: an empty page would report an account as holding nothing.
  defp page_rows(nil), do: {:ok, []}
  defp page_rows(rows) when is_list(rows), do: {:ok, rows}
  defp page_rows(_other), do: {:error, {:decode_failed, :page}}

  # `Raxol.Web3.Cursor.encode/3` takes a map or `nil`, and `next_page_params`
  # is whatever the upstream put under that key: anything else is the last
  # page rather than a `FunctionClauseError` on the way out of a successful
  # read.
  defp next_cursor(state, params, endpoint) when is_map(params) do
    Cursor.encode(params, origin_id(state), endpoint)
  end

  defp next_cursor(_state, _absent, _endpoint), do: nil

  defp cursor_query(_state, _endpoint, nil), do: {:ok, %{}}

  defp cursor_query(state, endpoint, cursor) do
    case Cursor.decode(cursor, origin_id(state), endpoint) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:error, {:invalid_cursor, reason}}
    end
  end

  defp origin_id(state), do: Origin.id(URI.new!("https://#{state.host}/"))

  # -- normalization -----------------------------------------------------------

  defp transaction(item) when is_map(item) do
    fee = item |> field("fee") |> object()

    with {:ok, value} <- Backend.money(item["value"], :value),
         {:ok, paid} <- Backend.money(fee["value"], :fee) do
      {:ok, normalized_transaction(item, value, paid)}
    end
  end

  defp transaction(_item), do: {:error, {:decode_failed, :transaction}}

  defp normalized_transaction(item, value, paid) do
    %{
      hash: item["hash"],
      status: status(item["status"]),
      block: int(item["block_number"]),
      timestamp: timestamp(item["timestamp"]),
      from: address_ref(item["from"]),
      to: address_ref(item["to"]),
      value: value,
      fee: paid,
      method: item["method"]
    }
  end

  defp token_balance(item) when is_map(item) do
    with {:ok, amount} <- Backend.money(item["value"], :amount) do
      {:ok, %{token: token(item["token"]), amount: amount, token_id: item["token_id"]}}
    end
  end

  defp token_balance(_item), do: {:error, {:decode_failed, :token_balance_row}}

  defp token_transfer(item) when is_map(item) do
    total = item |> field("total") |> object()

    with {:ok, amount} <- Backend.money(total["value"], :amount) do
      {:ok,
       %{
         token: token(item["token"]),
         amount: amount,
         from: address_ref(item["from"]),
         to: address_ref(item["to"]),
         block: int(item["block_number"]),
         timestamp: timestamp(item["timestamp"]),
         transaction: item["transaction_hash"]
       }}
    end
  end

  defp token_transfer(_item), do: {:error, {:decode_failed, :token_transfer_row}}

  defp log(item) when is_map(item) do
    {:ok,
     %{
       address: item |> field("address") |> field("hash"),
       topics: item |> field("topics") |> rows_of() |> Enum.reject(&is_nil/1),
       data: item["data"],
       block: int(item["block_number"]),
       transaction: item["transaction_hash"],
       index: int(item["index"])
     }}
  end

  defp log(_item), do: {:error, {:decode_failed, :log_row}}

  defp nft(item) when is_map(item) do
    {:ok,
     %{
       token: token(item["token"]),
       token_id: item["id"],
       name: item |> field("metadata") |> field("name"),
       image_url: item["image_url"]
     }}
  end

  defp nft(_item), do: {:error, {:decode_failed, :nft_row}}

  defp token(token) when is_map(token) do
    %{
      address: token["address_hash"] || token["address"],
      symbol: token["symbol"],
      name: token["name"],
      decimals: int(token["decimals"]),
      type: token["type"]
    }
  end

  defp token(_absent), do: %{address: nil, symbol: nil, name: nil, decimals: nil, type: nil}

  defp match_name(%{"ens_info" => %{"name" => name}, "address_hash" => hash}, name)
       when is_binary(hash),
       do: {:evm, hash}

  defp match_name(_item, _name), do: nil

  defp address_ref(%{"hash" => hash}) when is_binary(hash), do: {:evm, hash}
  defp address_ref(_absent), do: nil

  defp status("ok"), do: :success
  defp status("error"), do: :reverted
  defp status(_pending), do: :pending

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_other, _key), do: nil

  defp object(value) when is_map(value), do: value
  defp object(_other), do: %{}

  defp rows_of(value) when is_list(value), do: value
  defp rows_of(_other), do: []

  # Advisory, so a failure here is `nil` rather than a failed read: the lag is
  # extra information about a height, not the height.
  defp indexer(state) do
    case get(state, "/api/v2/main-page/indexing-status") do
      {:ok, body} ->
        %{
          finished?: body["finished_indexing_blocks"] == true,
          indexed_ratio: float(body["indexed_blocks_ratio"])
        }

      {:error, _reason} ->
        nil
    end
  end

  defp latest_height(%{"items" => [%{"height" => height} | _rest]}), do: {:ok, int(height)}
  defp latest_height(_body), do: {:error, {:decode_failed, :blocks}}

  defp chain_id("eip155:" <> id) do
    case Integer.parse(id) do
      {chain_id, ""} -> {:ok, chain_id}
      _unparseable -> {:error, {:unsupported_chain, id}}
    end
  end

  defp chain_id(other), do: {:error, {:unsupported_chain, other}}

  defp ok_or({:ok, _value} = ok, _reason), do: ok
  defp ok_or(:error, reason), do: {:error, reason}

  # The one place a caller's account reference becomes a path segment, so the
  # FORMAT is checked here rather than at the tool boundary: validation sits on
  # the function that performs the side effect. `is_binary/1` alone was not a
  # check -- `Raxol.Web3.Serialize.account_ref/1` builds `{:evm, value}` out of
  # anything a tool argument prefixes with `"evm:"`, so `"evm:../../admin?x=1"`
  # reached an arbitrary path and query on this host and handed the body back
  # to the model.
  #
  # Rejecting beats encoding for this one: this upstream has exactly one
  # address shape, and a percent-encoded traversal is a 404 a caller cannot act
  # on. `segment/1` still wraps every interpolation, so a path parameter added
  # later cannot reopen the hole.
  #
  # Case is carried through rather than normalized: an EIP-55 checksum is the
  # caller's own typo protection, and downcasing it would throw that away.
  defp evm_address({:evm, address}) when is_binary(address) do
    if evm_address?(address),
      do: {:ok, address},
      else: {:error, {:unsupported_account_ref, :not_an_address}}
  end

  defp evm_address({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp evm_address(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  # `0x` plus twenty bytes of hex, either case. A byte walk rather than a
  # regex: the check runs on every read and a compiled pattern buys nothing at
  # 42 characters. Bytes rather than codepoints because `to_charlist/1` RAISES
  # on a binary that is not valid UTF-8, and this one is a tool argument; a
  # byte outside `@hex_digits` is refused either way.
  defp evm_address?("0x" <> hex) when byte_size(hex) == 40 do
    hex |> :binary.bin_to_list() |> Enum.all?(&(&1 in @hex_digits))
  end

  defp evm_address?(_other), do: false

  defp int(nil), do: nil
  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp int(_other), do: nil

  defp float(value) when is_number(value), do: value * 1.0

  defp float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp float(_other), do: nil

  defp timestamp(nil), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_other), do: nil
end
