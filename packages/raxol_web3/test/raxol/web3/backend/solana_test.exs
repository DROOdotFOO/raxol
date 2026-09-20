defmodule Raxol.Web3.Backend.SolanaTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Solana
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Router

  @fixtures Path.expand("../../../fixtures/solana", __DIR__)

  @mainnet "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"

  # A real mainnet wallet, its fee-payer transaction, one of its token accounts,
  # a mint, a program and a sysvar. Every one was read live on 2026-09-14 and
  # every fixture below is that read, trimmed to two items per page.
  @wallet {:solana, "9RAufBfjGQjDfrwxeyKmZWPADHSb8HcoqCdrmpqvCr1g"}
  @token_account {:solana, "C9VyXs6MPM8RgwouCH8qXih423VnraZBgzCNUepvC3xA"}
  @mint {:solana, "NkfbyG7feH9aJhdnSs4d7D7kWCEnxrmNUbM7dbpC6MM"}
  @program {:solana, "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"}
  @sysvar {:solana, "SysvarC1ock11111111111111111111111111111111"}

  @signature "47H9XKQW8LTEhRUdEWXPPS1ZKHjoyfbUaFkF8PpmBVLKsFucVMMAmG39Vaw2XiktFL7swbNZxJ6ze4aCrAztM9F5"

  # Recorded from the live APIs on 2026-09-14. A fixture is not a mock: it is
  # what the upstream actually said, replayed through the `:exchange` seam
  # because the vet refuses loopback and no local endpoint is reachable through
  # the pipeline. It is the only thing that makes "the shape changed" a red test
  # rather than a production surprise, and neither upstream publishes a spec for
  # what these calls return.
  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Both limiters are given room on purpose: every test here talks to one
  # origin per source, so the shared bucket and breaker would couple unrelated
  # tests through it. They are `Raxol.Web3.HTTPTest`'s subject.
  defp unmetered do
    [
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end
    ]
  end

  # An SSE body in the framing SQD actually uses: one `event: message` line,
  # then `data:` with the space, then a blank line.
  defp sse(payload) do
    envelope = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{"content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]}
    }

    "event: message\ndata: " <> Jason.encode!(envelope) <> "\n\n"
  end

  defp sse_error(payload) do
    envelope = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
        "isError" => true
      }
    }

    "event: message\ndata: " <> Jason.encode!(envelope) <> "\n\n"
  end

  # Routes an MCP `tools/call` by tool name and a JSON-RPC call by method, so
  # one arrangement exercises either source. `getSlot` is routed by its
  # commitment as well, because the whole point of that call is that the two
  # commitments answer different numbers.
  defp serving(responses) do
    fn _vetted, request, _opts ->
      send(self(), {:request, request})
      body = Jason.decode!(request.body)

      case Map.fetch(responses, route(body)) do
        {:ok, {status, payload}} -> {:ok, %{status: status, headers: [], body: payload}}
        {:ok, payload} -> {:ok, %{status: 200, headers: [], body: payload}}
        :error -> {:ok, %{status: 404, headers: [], body: ~s({"unrouted":true})}}
      end
    end
  end

  # `portal_get_head`, `getSlot` and `getSignaturesForAddress` are routed by
  # their one distinguishing argument, because the whole point of each is that
  # two calls answer two different things and a router keyed on the name alone
  # would hide that.
  defp route(%{"method" => "tools/call", "params" => %{"name" => "portal_get_head"} = params}),
    do: "portal_get_head:" <> get_in(params, ["arguments", "type"])

  defp route(%{"method" => "tools/call", "params" => %{"name" => name}}), do: name
  defp route(%{"method" => "getSlot", "params" => [%{"commitment" => c}]}), do: "getSlot:" <> c

  defp route(%{
         "method" => "getSignaturesForAddress",
         "params" => [_pubkey, %{"before" => _sig}]
       }),
       do: "getSignaturesForAddress:before"

  defp route(%{"method" => method}), do: method

  # The catalog resolution runs before every SQD read, so it is merged in unless
  # a test is about it.
  defp catalog, do: %{"portal_list_networks" => fixture("sqd_list_networks.sse")}

  defp handle(source, responses, opts) do
    http_opts = [{:exchange, serving(responses)} | unmetered()] ++ Keyword.take(opts, [:headers])

    {:ok, handle} =
      Solana.new(
        Keyword.get(opts, :chain_ref, "solana:mainnet"),
        [
          source: source,
          http_opts: http_opts,
          # Off by default, and not for convenience. The cache is per node and
          # keyed by origin plus fragment, so every test asking the same source
          # the same question would share one entry and the first to run would
          # answer for the rest. The cache tests below use their own origins.
          cache: Keyword.get(opts, :cache, false)
        ] ++ Keyword.take(opts, [:network, :url])
      )

    handle
  end

  defp sqd(responses, opts \\ []),
    do: handle(:sqd, Map.merge(catalog(), responses), opts)

  defp rpc(responses, opts \\ []), do: handle(:rpc, responses, opts)

  defp state(handle), do: elem(handle, 1)

  defp drain(acc \\ []) do
    receive do
      {:request, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp requested_tools do
    Enum.map(drain(), fn request ->
      request.body |> Jason.decode!() |> route()
    end)
  end

  defp requested_bodies do
    Enum.map(drain(), &Jason.decode!(&1.body))
  end

  describe "chain references" do
    test "the alias canonicalizes on ingest, so a handle reports one reference" do
      # The survey's naming section: `solana:mainnet` is what a caller writes
      # and the truncated genesis hash is what CAIP-2 says. Measured
      # 2026-09-14, getGenesisHash returned
      # 5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d.
      assert {:ok, {Solana, %{chain_ref: @mainnet}}} = Solana.new("solana:mainnet")
      assert {:ok, {Solana, %{chain_ref: @mainnet}}} = Solana.new(@mainnet)
      assert Solana.chain_aliases()["solana:mainnet"] == @mainnet
    end

    test "a chain this table does not carry is refused rather than guessed at" do
      assert {:error, {:unsupported_chain, "eip155:1"}} = Solana.new("eip155:1")
      assert {:error, {:unsupported_chain, "solana:devnet"}} = Solana.new("solana:devnet")
    end

    test "each source gets its own endpoint, which is what makes them two handles" do
      assert {:ok, {Solana, %{source: :sqd, url: sqd_url}}} =
               Solana.new(@mainnet, source: :sqd)

      assert {:ok, {Solana, %{source: :rpc, url: rpc_url}}} =
               Solana.new(@mainnet, source: :rpc)

      assert sqd_url == "https://portal.sqd.dev/mcp"
      assert rpc_url == "https://api.mainnet-beta.solana.com"
    end

    test "an unknown source is refused at construction" do
      # `:unsupported_source`, the name `Raxol.Web3.Backend.Tron` already
      # used for the same fact. Two spellings of one reason is how a caller
      # ends up matching on one of them.
      assert {:error, {:unsupported_source, :helius}} = Solana.new(@mainnet, source: :helius)
    end
  end

  describe "capabilities" do
    test "the archive declares nothing optional, and that is the asymmetry" do
      # Measured 2026-09-14: no tool in SQD's 31 takes a Solana signature, and
      # its account tool is a look-back summary rather than a balance. So four
      # callbacks are absent rather than stubbed, per ADR-0039 decision 3.
      handle = sqd(%{})

      assert Solana.capabilities(state(handle)) == []

      for callback <- [:get_transaction, :account_info, :token_balances, :list_transactions] do
        refute Backend.supports?(handle, callback), "#{callback} must not be declared on SQD"
      end

      assert {:error, {:unsupported, :get_transaction}} =
               Backend.call(handle, :get_transaction, [@signature])

      assert {:error, {:unsupported, :account_info}} =
               Backend.call(handle, :account_info, [@wallet])
    end

    test "the node declares the five reads it can answer" do
      handle = rpc(%{})

      for callback <- [
            :get_transaction,
            :account_info,
            :token_balances,
            :list_transactions,
            :get_block
          ] do
        assert Backend.supports?(handle, callback), "#{callback} is not declared on RPC"
      end
    end

    test "raw_request and list_token_transfers are declined on both sources" do
      # raw_request keeps read-only structural rather than policed: with no
      # method parameter crossing the surface there is no allowlist to get
      # wrong. list_token_transfers is the cost demotion: a transfer here is an
      # instruction inside a transaction and neither source parses one.
      for handle <- [sqd(%{}), rpc(%{})] do
        refute Backend.supports?(handle, :raw_request)
        refute Backend.supports?(handle, :list_token_transfers)

        assert {:error, {:unsupported, :list_token_transfers}} =
                 Backend.call(handle, :list_token_transfers, [@wallet, []])
      end
    end
  end

  describe "network resolution" do
    test "the supported set is read at runtime, never hardcoded" do
      handle = sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")})

      assert {:ok, _info} = Backend.call(handle, :chain_info)

      assert ["portal_list_networks", "portal_get_network_info"] = requested_tools()
    end

    test "an alias in the live catalog resolves without a table here to drift" do
      # The catalog reports solana-mainnet's aliases as solana-beta, solana and
      # sol, measured 2026-09-14. A handle pointed at the alias resolves to the
      # canonical network name and queries that.
      handle =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")}, network: "solana")

      assert {:ok, _info} = Backend.call(handle, :chain_info)

      assert [_catalog, %{"params" => %{"arguments" => %{"network" => "solana-mainnet"}}}] =
               requested_bodies()
    end

    test "a network the catalog does not list is unsupported_chain, not a failed request" do
      handle =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          network: "solana-unlisted"
        )

      assert {:error, {:unsupported_chain, "solana-unlisted"}} = Backend.call(handle, :chain_info)

      # The catalog was asked and the tool was not: the refusal is decided
      # against the resolved set rather than by letting the request fail.
      assert ["portal_list_networks"] = requested_tools()
    end

    test "a stale catalog is caught by the tool's own refusal, with the same term" do
      # The catalog is cached for an hour, so a network withdrawn inside that
      # hour answers 200 with error.code unknown_network. Measured 2026-09-14.
      handle = sqd(%{"portal_get_network_info" => fixture("sqd_unknown_network.sse")})

      assert {:error, {:unsupported_chain, "solana-mainnet"}} = Backend.call(handle, :chain_info)
    end

    test "a refusal about our own arguments is final rather than a chain fact" do
      # error.code invalid_request is the windowless account query, measured
      # 2026-09-14. A sibling source would answer the same way, so the router
      # must not walk on: {:upstream_refused, :unknown} is not a source error.
      payload = %{
        "error" => %{
          "code" => "invalid_request",
          "origin" => "client_input",
          "summary" => "Provide timeframe, from_block, or from_timestamp/to_timestamp"
        }
      }

      handle = sqd(%{"portal_get_network_info" => sse_error(payload)})

      assert {:error, {:upstream_refused, :unknown}} = Backend.call(handle, :chain_info)
    end
  end

  describe "block_height/1" do
    test "the archive asks both heads, and the lag between them is the indexer's" do
      # The recorded pair was taken back to back on 2026-09-14: latest
      # 446,956,167 against finalized 446,956,136, a lag of 31 slots, which is
      # the same figure portal_get_network_info reports as
      # finalized_lag_blocks. The lag is computed from these two numbers rather
      # than from a third call for it.
      handle =
        sqd(%{
          "portal_get_head:latest" => fixture("sqd_head_latest.sse"),
          "portal_get_head:finalized" => fixture("sqd_head_finalized.sse")
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.height == 446_956_167
      assert height.finalized_height == 446_956_136
      assert height.finalized_height < height.height
      assert height.indexer.finished? == true
      assert height.indexer.lag_blocks == 31

      # SQD publishes no indexing ratio, and the key is absent rather than a
      # computed 1.0, which would be a fabricated number in the one field that
      # exists so lag is visible.
      refute Map.has_key?(height.indexer, :indexed_ratio)

      assert ["portal_list_networks", "portal_get_head:latest", "portal_get_head:finalized"] =
               requested_tools()
    end

    test "an inversion between two calls is clamped, because it is not a chain fact" do
      # The two heads are two requests, not one snapshot, so finalized can come
      # back above latest. A negative lag would be a lie about the chain; zero
      # is the truth about the pair.
      handle =
        sqd(%{
          "portal_get_head:latest" => sse(%{"number" => 100}),
          "portal_get_head:finalized" => sse(%{"number" => 140})
        })

      assert {:ok, %{indexer: %{lag_blocks: 0}}} = Backend.call(handle, :block_height)
    end

    test "the node reports slots too, and has no indexer to report" do
      handle =
        rpc(%{
          "getSlot:processed" => fixture("rpc_slot_processed.json"),
          "getSlot:finalized" => fixture("rpc_slot_finalized.json")
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.height == 446_951_790
      assert height.finalized_height == 446_951_756
      assert height.finalized_height < height.height
      # A validator is not an indexer. Inventing a ratio would put a fabricated
      # number in the field that exists so lag is visible.
      assert height.indexer == nil
    end
  end

  describe "chain_info/1" do
    test "the archive reports a count of indexed blocks, not a height" do
      handle = sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")})

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == @mainnet
      # head 446,951,619 from start_block 0.
      assert info.total_blocks == 446_951_620
      assert info.average_block_time_ms == nil
      refute Map.has_key?(info, :height)
    end

    test "the node's block count and its slot count are different numbers" do
      # The measurement the height shape exists for: 2026-09-14, one
      # getEpochInfo response carried absoluteSlot 446,951,753 and blockHeight
      # 424,994,262, a gap of 21,957,491. A caller that read the slot as a
      # block height would be wrong by twenty-two million.
      handle =
        rpc(%{
          "getEpochInfo" => fixture("rpc_epoch_info.json"),
          "getSlot:processed" => fixture("rpc_slot_processed.json"),
          "getSlot:finalized" => fixture("rpc_slot_finalized.json")
        })

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert {:ok, height} = Backend.call(handle, :block_height)

      assert info.total_blocks == 424_994_262
      assert info.total_transactions == 548_325_347_180
      assert height.height - info.total_blocks > 21_000_000
      assert height.unit == :slot
    end
  end

  describe "get_transaction/2" do
    test "carries the fee payer, the fee and the status, and invents no counterparty" do
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction.json")})

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [@signature])
      assert transaction.hash == @signature
      assert transaction.status == :success
      assert transaction.block == 446_951_766
      assert transaction.fee == 125_300
      assert transaction.from == @wallet
      assert %DateTime{} = transaction.timestamp

      # No single recipient, no single value, no single method: a transaction
      # here is instructions over a list of account keys.
      assert transaction.to == nil
      assert transaction.value == nil
      assert transaction.method == nil
    end

    test "a signature the node does not know is a refusal, not an empty transaction" do
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction_absent.json")})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_transaction, [@signature])
    end

    test "a signature that is not base58 is refused before any request" do
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction.json")})

      assert {:error, {:unsupported_account_ref, :not_base58}} =
               Backend.call(handle, :get_transaction, ["0xdeadbeef" <> String.duplicate("0", 60)])

      assert [] == requested_tools()
    end

    test "an operator's own header survives the RPC POST, beside the content type" do
      # `:http_opts` is documented as forwarded unchanged, and this path
      # replaced the header list rather than merging into it, so a deployment
      # pointing this handle at its own gated node lost the credential it
      # carries in a header. `Raxol.Web3.Backend.CantonTest` asserts the same
      # property on the other backend that composes a header.
      operator = {"x-node-authorization", "operator-value"}
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction.json")}, headers: [operator])

      assert {:ok, _transaction} = Backend.call(handle, :get_transaction, [@signature])

      assert [request] = drain()
      assert operator in request.headers
      assert {"content-type", "application/json"} in request.headers
    end
  end

  describe "account_info/2 and the four kinds" do
    defp account_handle(account_fixture) do
      rpc(%{"getAccountInfo" => fixture(account_fixture)})
    end

    test "a wallet says so, and carries its lamports" do
      handle = account_handle("rpc_account_info_wallet.json")

      assert {:ok, account} = Backend.call(handle, :account_info, [@wallet])
      assert account.ref == @wallet
      assert account.kind == :wallet
      assert account.contract? == false
      assert account.balance == 38_298_783_833
      assert account.verified? == false
      assert account.name == nil
    end

    test "a token account says so, and its balance is a rent reserve" do
      # The case that earned `kind` a place in the shared shape. 2,039,280
      # lamports is true and badly misleading: this account's actual holding is
      # reachable only through token_balances/2.
      handle = account_handle("rpc_account_info_token_account.json")

      assert {:ok, account} = Backend.call(handle, :account_info, [@token_account])
      assert account.kind == :token_account
      assert account.balance == 2_039_280
      assert account.contract? == false
    end

    test "a program is executable, and contract? answers code presence" do
      handle = account_handle("rpc_account_info_program.json")

      assert {:ok, account} = Backend.call(handle, :account_info, [@program])
      assert account.kind == :program
      assert account.contract? == true
    end

    test "a mint is not a token account, even though one program owns both" do
      handle = account_handle("rpc_account_info_mint.json")

      assert {:ok, %{kind: :mint}} = Backend.call(handle, :account_info, [@mint])
    end

    test "a program-owned account this table cannot name is :data, not a guess" do
      handle = account_handle("rpc_account_info_data.json")

      assert {:ok, %{kind: :data}} = Backend.call(handle, :account_info, [@sysvar])
    end

    test "an account that does not exist is a refusal, not a zero balance" do
      # On this chain an account holding nothing does not exist. Reporting zero
      # would answer a question about an account that is not there.
      handle = account_handle("rpc_account_info_absent.json")

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :account_info, [@wallet])
    end

    test "a reference from another chain is refused by tag, before any request" do
      handle = account_handle("rpc_account_info_wallet.json")

      assert {:error, {:unsupported_account_ref, :evm}} =
               Backend.call(handle, :account_info, [
                 {:evm, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"}
               ])

      assert {:error, {:unsupported_account_ref, :party}} =
               Backend.call(handle, :account_info, [{:party, "Alice::1220abcd"}])

      assert [] == requested_tools()
    end
  end

  describe "token_balances/3" do
    test "maps the parsed token accounts, and mints no cursor it cannot honour" do
      handle = rpc(%{"getTokenAccountsByOwner" => fixture("rpc_token_accounts.json")})

      assert {:ok, page} = Backend.call(handle, :token_balances, [@wallet, []])
      assert length(page.items) == 2

      # getTokenAccountsByOwner's config object takes commitment,
      # minContextSlot, dataSlice and encoding and nothing that offsets,
      # limits or resumes, so the page is always complete and a cursor would
      # be a promise we cannot keep.
      assert page.next == nil

      assert [%{token: token, amount: amount} | _rest] = page.items
      assert token.address == "NkfbyG7feH9aJhdnSs4d7D7kWCEnxrmNUbM7dbpC6MM"
      assert token.type == "spl-token"
      assert token.decimals == 0
      assert amount == 85_000_221
      # A validator serves no token registry, so these are absent rather than
      # guessed from a mint address.
      assert token.symbol == nil
      assert token.name == nil
    end

    test "a cursor cannot have come from here, so one handed back is refused" do
      # The callback takes the option, and what the option lets it say is that
      # `next` is always nil. The nearest thing a caller could hold is this
      # same handle's signatures cursor, and answering the first page of token
      # accounts to it would answer a different question, silently. So it is
      # refused, before any request.
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      assert {:ok, %{next: cursor}} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert is_binary(cursor)
      _signatures = drain()

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Backend.call(handle, :token_balances, [@wallet, [cursor: cursor]])

      assert [] == requested_tools()
    end
  end

  describe "list_transactions/3 and the signature cursor" do
    test "a page mints a cursor that decodes to the upstream's own parameter" do
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      assert {:ok, page} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert length(page.items) == 2
      assert is_binary(page.next)

      origin = Origin.id(URI.new!("https://api.mainnet-beta.solana.com/"))
      assert {:ok, params} = Cursor.decode(page.next, origin, :solana_address_signatures)

      # The last signature of the page, which is what `before` takes.
      assert params["before"] ==
               "38gvbbjChiHatnNaUhYxoma7gHuwLiKkUCPmFpDWQQuB9MsN7h52LgJr452FDAbcHvNvZUkFtrmuoiHB86B17gCS"

      assert Map.keys(params) == ["before"]
    end

    test "a cursor becomes the before parameter on the next request" do
      handle =
        rpc(%{
          "getSignaturesForAddress" => fixture("rpc_signatures.json"),
          "getSignaturesForAddress:before" => fixture("rpc_signatures_page2.json")
        })

      assert {:ok, %{next: cursor}} = Backend.call(handle, :list_transactions, [@wallet, []])
      _first = drain()

      assert {:ok, _page} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: cursor]])

      assert [%{"params" => [_pubkey, config]}] = requested_bodies()

      assert config["before"] ==
               "38gvbbjChiHatnNaUhYxoma7gHuwLiKkUCPmFpDWQQuB9MsN7h52LgJr452FDAbcHvNvZUkFtrmuoiHB86B17gCS"

      assert config["limit"] == 100
    end

    test "the second page is the upstream's own next page, and the two are disjoint" do
      # Both pages were recorded live on 2026-09-14, the second by handing the
      # first page's last signature back as `before`. Two pages of two for one
      # mainnet account returned four distinct signatures, which is what makes
      # the single-key allowlist sufficient.
      handle =
        rpc(%{
          "getSignaturesForAddress" => fixture("rpc_signatures.json"),
          "getSignaturesForAddress:before" => fixture("rpc_signatures_page2.json")
        })

      assert {:ok, first} = Backend.call(handle, :list_transactions, [@wallet, []])

      assert {:ok, second} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: first.next]])

      hashes = fn page -> page.items |> Enum.map(& &1.hash) |> MapSet.new() end

      assert MapSet.size(hashes.(first)) == 2
      assert MapSet.disjoint?(hashes.(first), hashes.(second))

      # The walk moves: a second page mints a different cursor from the first.
      assert second.next != first.next
    end

    test "the rows are thin, because a signature listing carries no counterparties" do
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      assert {:ok, page} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert [row | _rest] = page.items

      assert row.status == :success
      assert row.block == 446_951_768
      assert %DateTime{} = row.timestamp
      # Filling `from` with the queried address would be a guess: an address a
      # transaction merely mentions is not its fee payer.
      assert row.from == nil
      assert row.to == nil
      assert row.fee == nil
    end

    test "only an empty page ends the walk, because the upstream flags no end" do
      handle = rpc(%{"getSignaturesForAddress" => ~s({"jsonrpc":"2.0","id":1,"result":[]})})

      assert {:ok, %{items: [], next: nil}} =
               Backend.call(handle, :list_transactions, [@wallet, []])
    end

    test "a cursor minted for another endpoint is refused before the request is built" do
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      origin = Origin.id(URI.new!("https://api.mainnet-beta.solana.com/"))
      foreign = Cursor.encode(%{"block_number" => 1}, origin, :address_transactions)

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: foreign]])

      assert [] == requested_tools()
    end
  end

  describe "get_block/2, where a skipped slot is a success" do
    test "a produced slot carries its hash and its transaction count" do
      handle = rpc(%{"getBlock" => fixture("rpc_block.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [446_800_611])
      assert block.hash == "8kLEYsgop9R6kx6P6gHDTG4Zm83468Vjnyx4hsExyLbX"
      assert block.transactions_count == 2
      assert %DateTime{} = block.timestamp
      # getBlock exposes no leader identity.
      assert block.miner == nil
    end

    test "height is the slot asked for, never the upstream's blockHeight" do
      # The recorded response carries blockHeight 424,843,204 for slot
      # 446,800,611. Reporting that as `height` would make get_block/2 and
      # block_height/1 disagree by about 21.96 million while both claim
      # unit: :slot.
      handle = rpc(%{"getBlock" => fixture("rpc_block.json")})

      assert {:ok, %{height: 446_800_611}} = Backend.call(handle, :get_block, [446_800_611])
    end

    test "an empty slot is a success with a hash and a zero count" do
      handle = rpc(%{"getBlock" => fixture("rpc_block_empty.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [446_800_611])
      assert is_binary(block.hash)
      assert block.transactions_count == 0
    end

    test "a skipped slot is a success with no hash at all" do
      # JSON-RPC -32009, measured on slot 446,800,612, a real gap in getBlocks
      # over 446,800,612..446,800,615 on 2026-09-14. The nil hash is the
      # discriminator: a produced block always carries one, including slot
      # 1000, whose blockHeight is null.
      handle = rpc(%{"getBlock" => fixture("rpc_block_skipped.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [446_800_612])
      assert block.height == 446_800_612
      assert block.hash == nil
      assert block.timestamp == nil
      assert block.transactions_count == nil
    end

    test "a slot above the head is a failed read, not a skipped slot" do
      # -32004 rather than -32009, which is the whole reason the three
      # outcomes are distinguishable without a heuristic.
      handle = rpc(%{"getBlock" => fixture("rpc_block_unavailable.json")})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_block, [999_999_999])
    end

    test "a slot that is not a number is refused before any request" do
      handle = rpc(%{"getBlock" => fixture("rpc_block.json")})

      assert {:error, {:decode_failed, :slot}} = Backend.call(handle, :get_block, ["latest"])
      assert [] == requested_tools()
    end
  end

  describe "the response cache" do
    # Own origins, because the cache is per node and keyed by origin: sharing
    # the real hosts with the rest of this file would mean sharing entries.
    test "a repeated read is served from the cache and the upstream is asked once" do
      handle =
        rpc(%{"getEpochInfo" => fixture("rpc_epoch_info.json")},
          cache: true,
          url: "https://cache-one.solana.test/"
        )

      assert {:ok, first} = Backend.call(handle, :chain_info)
      assert {:ok, second} = Backend.call(handle, :chain_info)

      assert first == second
      assert [_one] = requested_tools()
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle =
        rpc(
          %{
            "getSlot:processed" => fixture("rpc_slot_processed.json"),
            "getSlot:finalized" => fixture("rpc_slot_finalized.json")
          },
          cache: true,
          url: "https://cache-two.solana.test/"
        )

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert length(requested_tools()) == 4
    end

    test "the catalog is cached, so resolution costs one request per hour" do
      handle =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          cache: true,
          url: "https://cache-three.sqd.test/mcp"
        )

      assert {:ok, _first} = Backend.call(handle, :chain_info)
      assert {:ok, _second} = Backend.call(handle, :chain_info)

      assert Enum.count(requested_tools(), &(&1 == "portal_list_networks")) == 1
    end

    # The three below share one origin between two handles on purpose: the
    # cache is keyed by `{origin_id, fragment}` and outlives a handle, so the
    # second handle reads the first handle's table. That is the only way to
    # ask "was the first answer stored" without reaching into the table.
    test "a tool error is not cached, so one bad catalog read does not answer for the hour" do
      # `resolve/1` runs before every SQD read and `:catalog` holds its answer
      # for an hour. The refusal arrives as HTTP 200 with `isError: true`, so
      # a cache that decided by status stored it, and one transient tool error
      # then answered every SQD read on this chain for the rest of that hour
      # while the portal was already serving again.
      url = "https://cache-catalog.sqd.test/mcp"
      broken = %{"portal_list_networks" => sse_error(%{"error" => %{"code" => "internal_error"}})}

      assert {:error, {:upstream_refused, :unknown}} =
               Backend.call(sqd(broken, cache: true, url: url), :chain_info)

      recovered =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          cache: true,
          url: url
        )

      assert {:ok, _info} = Backend.call(recovered, :chain_info)
    end

    test "a slot the node does not have yet is not cached, so the next read sees it land" do
      # -32004 for a slot at the head is a fact about this moment, and the
      # `:block` class is a minute. Recorded 2026-09-14.
      url = "https://cache-unavailable.solana.test/"
      slot = 999_999_999

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(
                 rpc(%{"getBlock" => fixture("rpc_block_unavailable.json")},
                   cache: true,
                   url: url
                 ),
                 :get_block,
                 [slot]
               )

      landed = rpc(%{"getBlock" => fixture("rpc_block.json")}, cache: true, url: url)

      assert {:ok, %{height: ^slot}} = Backend.call(landed, :get_block, [slot])
    end

    test "a skipped slot is cached, because it is permanent rather than a refusal" do
      # -32009 is the one error code this chain answers that is a fact about
      # the chain: slot 446,800,612 was skipped and always will have been. It
      # is a success here, so it is worth a minute in the table, and not
      # caching it would cost a request per read of every gap in the ledger.
      url = "https://cache-skipped.solana.test/"
      slot = 446_800_612

      assert {:ok, %{hash: nil}} =
               Backend.call(
                 rpc(%{"getBlock" => fixture("rpc_block_skipped.json")}, cache: true, url: url),
                 :get_block,
                 [slot]
               )

      _ignored = drain()
      produced = rpc(%{"getBlock" => fixture("rpc_block.json")}, cache: true, url: url)

      assert {:ok, %{hash: nil}} = Backend.call(produced, :get_block, [slot])
      assert [] == requested_tools()
    end
  end

  describe "no upstream prose escapes" do
    test "the model-facing answer text reaches no normalized field" do
      # portal_get_head returns answer: "Current value: 446,956,167." beside
      # the structured number, and portal_get_network_info returns a
      # display_name its own _tool_contract marks untrusted. Neither may travel.
      handle =
        sqd(%{
          "portal_get_head:latest" => fixture("sqd_head_latest.sse"),
          "portal_get_head:finalized" => fixture("sqd_head_finalized.sse"),
          "portal_get_network_info" => fixture("sqd_network_info.sse")
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert {:ok, info} = Backend.call(handle, :chain_info)

      for term <- [height, info] do
        rendered = inspect(term, limit: :infinity)
        refute rendered =~ "Current value"
        refute rendered =~ "looks caught up"
        refute rendered =~ "Solana looks"
        refute rendered =~ "display_name"
      end
    end
  end

  describe "a router built as [sqd, rpc]" do
    defp router_pair(sqd_responses, rpc_responses) do
      Router.new([
        sqd(sqd_responses),
        rpc(rpc_responses)
      ])
    end

    test "the fallback answers what the primary does not declare" do
      # get_transaction/2 and account_info/2 are both absent from the SQD
      # handle, so the router walks past it without a request being made.
      router =
        router_pair(
          %{},
          %{
            "getTransaction" => fixture("rpc_transaction.json"),
            "getAccountInfo" => fixture("rpc_account_info_wallet.json")
          }
        )

      assert {:ok, transaction} =
               Router.call(router, @mainnet, :get_transaction, [@signature])

      assert transaction.hash == @signature

      assert {:ok, %{kind: :wallet}} = Router.call(router, @mainnet, :account_info, [@wallet])

      # Neither call touched the archive: no portal tool was asked.
      refute Enum.any?(requested_tools(), &String.starts_with?(&1, "portal_"))
    end

    test "the fallback answers a required callback the primary fails" do
      # A network the archive does not serve is {:unsupported_chain, _}, which
      # the router treats as a source error, so chain_info walks on to the node
      # rather than failing. Both handles are required to answer this callback,
      # so this is failover rather than absence.
      router =
        Router.new([
          sqd(%{}, network: "solana-unlisted"),
          rpc(%{"getEpochInfo" => fixture("rpc_epoch_info.json")})
        ])

      assert {:ok, info} = Router.call(router, @mainnet, :chain_info)
      assert info.total_blocks == 424_994_262

      tools = requested_tools()
      assert "portal_list_networks" in tools
      assert "getEpochInfo" in tools
    end

    test "a credential the archive wants and this deployment lacks walks on" do
      # `unauthorized` is a fact about the SOURCE, not about the question: the
      # node holds no credential and answers anyway. Reading it as
      # `{:upstream_refused, :unknown}` made it final, so a keyless archive
      # read died with a healthy node sitting behind it, while the identical
      # read on `Raxol.Web3.Backend.Tron` failed over.
      router =
        router_pair(
          %{"portal_get_network_info" => sse_error(%{"error" => %{"code" => "unauthorized"}})},
          %{"getEpochInfo" => fixture("rpc_epoch_info.json")}
        )

      assert {:ok, info} = Router.call(router, @mainnet, :chain_info)
      assert info.total_blocks == 424_994_262

      tools = requested_tools()
      assert "portal_get_network_info" in tools
      assert "getEpochInfo" in tools
    end

    test "the primary answers a required callback when it can, and the node is not asked" do
      router =
        router_pair(
          %{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          %{"getEpochInfo" => fixture("rpc_epoch_info.json")}
        )

      assert {:ok, info} = Router.call(router, @mainnet, :chain_info)
      assert info.total_blocks == 446_951_620
      refute "getEpochInfo" in requested_tools()
    end

    test "coverage names the sources, which is where the asymmetry is legible" do
      router = router_pair(%{}, %{})
      coverage = Router.coverage(router, @mainnet)

      # Both sources answer the required two, and each says which it is.
      assert coverage[:chain_info] == [:solana_sqd, :solana_rpc]
      assert coverage[:block_height] == [:solana_sqd, :solana_rpc]

      # The node alone answers each of these five, and coverage says so by
      # name rather than leaving an operator to read it off a count of one.
      for callback <- [
            :get_transaction,
            :account_info,
            :token_balances,
            :list_transactions,
            :get_block
          ] do
        assert coverage[callback] == [:solana_rpc], "#{callback} should be the node's alone"
      end

      # And nothing answers these: absence is the answer, per ADR-0039.
      for callback <- [
            :list_token_transfers,
            :read_contract,
            :contract_metadata,
            :get_logs,
            :resolve_name,
            :list_nfts,
            :raw_request
          ] do
        refute Map.has_key?(coverage, callback), "#{callback} must be absent from coverage"
      end
    end

    test "each handle names its own source while the module still names itself" do
      # `coverage/2` can only separate the two because the handles do:
      # `backend/1` answers per handle and `backend/0` is unchanged, so logs
      # and the `:source` config key still read :solana. Before the callback
      # existed both handles reported :solana, and coverage read
      # [:solana, :solana], a count of surviving sources that never said which
      # one had dropped out.
      router = router_pair(%{}, %{})

      assert [{Solana, %{source: :sqd}} = archive, {Solana, %{source: :rpc}} = node] =
               Router.candidates(router, @mainnet, :chain_info)

      assert Backend.name(archive) == :solana_sqd
      assert Backend.name(node) == :solana_rpc
      assert Solana.backend() == :solana

      # And `candidates/3` returns the handles themselves, which is where the
      # asymmetry is visible as the handle that answers rather than as a name.
      assert [{Solana, %{source: :rpc}}] =
               Router.candidates(router, @mainnet, :account_info)
    end
  end

  describe "against the real upstreams" do
    # Generous bounds, deliberately. What these prove is that the callbacks
    # answer and that a cursor pages, not that a third party is fast. Nothing
    # here asserts on elapsed time.
    defp live(source, opts \\ []) do
      {:ok, handle} =
        Solana.new(
          @mainnet,
          [source: source, http_opts: [chunk_timeout_ms: 30_000, deadline_ms: 60_000]] ++ opts
        )

      handle
    end

    @tag :live_web3
    test "the archive answers the required two, in slots" do
      handle = live(:sqd)

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == @mainnet
      assert info.total_blocks > 400_000_000

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.height > 400_000_000
      assert height.finalized_height <= height.height
      assert height.indexer.finished? == true
      assert is_integer(height.indexer.lag_blocks)
    end

    @tag :live_web3
    test "a network the archive does not serve is refused, not failed" do
      handle = live(:sqd, network: "solana-not-a-network")

      assert {:error, {:unsupported_chain, "solana-not-a-network"}} =
               Backend.call(handle, :chain_info)
    end

    @tag :live_web3
    test "the node answers the required two plus every optional it declares" do
      handle = live(:rpc)

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.total_blocks > 400_000_000

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.finalized_height <= height.height

      assert {:ok, account} = Backend.call(handle, :account_info, [@wallet])
      assert account.kind == :wallet
      assert is_integer(account.balance)

      assert {:ok, %{kind: :program, contract?: true}} =
               Backend.call(handle, :account_info, [@program])

      assert {:ok, tokens} = Backend.call(handle, :token_balances, [@wallet, []])
      assert tokens.next == nil

      assert {:ok, page} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert page.items != []

      # The transaction the listing just named, so this needs no pinned
      # signature that could be pruned from the node's history.
      assert {:ok, transaction} =
               Backend.call(handle, :get_transaction, [hd(page.items).hash])

      assert transaction.hash == hd(page.items).hash
      assert {:solana, _payer} = transaction.from

      assert {:ok, block} = Backend.call(handle, :get_block, [transaction.block])
      assert block.height == transaction.block
      assert is_binary(block.hash)
    end

    @tag :live_web3
    test "a cursor pages forward against the live node" do
      handle = live(:rpc)

      assert {:ok, first} = Backend.call(handle, :list_transactions, [@wallet, []])

      assert {:ok, next} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: first.next]])

      assert hd(first.items).hash != hd(next.items).hash
    end
  end
end
