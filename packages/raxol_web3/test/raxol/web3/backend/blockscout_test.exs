defmodule Raxol.Web3.Backend.BlockscoutTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Cursor

  @fixtures Path.expand("../../../fixtures/blockscout", __DIR__)

  @vitalik {:evm, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"}
  @tether {:evm, "0xdAC17F958D2ee523a2206206994597C13D831ec7"}

  # Recorded from the live API on 2026-09-13, trimmed to two items per page.
  # A fixture is not a mock: it is what the upstream actually said, and it is
  # the only thing that makes "the shape changed" a red test rather than a
  # production surprise, since the vendor publishes no spec for this surface.
  defp fixture(name), do: File.read!(Path.join(@fixtures, "#{name}.json"))

  # Both limiters are given room here on purpose. Every test in this file talks
  # to one origin (the chain's real host), so the shared bucket and breaker
  # would couple unrelated tests to each other through it. They are
  # `Raxol.Web3.HTTPTest`'s subject, not this file's.
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

  # Routes a request by path, and answers a JSON-RPC POST by method, so a
  # backend that composes REST with RPC can be exercised in one arrangement.
  defp serving(routes, rpc) do
    fn _vetted, request, _opts ->
      send(self(), {:request, request})

      case request.method do
        "POST" -> rpc_response(request, rpc)
        _get -> rest_response(request, routes)
      end
    end
  end

  defp rest_response(request, routes) do
    path = request.path |> String.split("?") |> hd()

    case Map.fetch(routes, path) do
      {:ok, {status, body}} -> {:ok, %{status: status, headers: [], body: body}}
      {:ok, body} -> {:ok, %{status: 200, headers: [], body: body}}
      :error -> {:ok, %{status: 404, headers: [], body: ~s({"message":"Not found"})}}
    end
  end

  defp rpc_response(request, rpc) do
    %{"method" => method, "id" => id} = Jason.decode!(request.body)

    body =
      case Map.fetch(rpc, method) do
        {:ok, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
        :error -> %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_601}}
      end

    {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
  end

  defp handle(routes, opts \\ []) do
    rpc = Keyword.get(opts, :rpc, %{})

    http_opts = [{:exchange, serving(routes, rpc)} | unmetered()]

    {:ok, handle} =
      Blockscout.new(Keyword.get(opts, :chain_ref, "eip155:1"),
        rpc_url: Keyword.get(opts, :rpc_url),
        http_opts: http_opts,
        # Off by default here, and this is not a convenience. The cache is
        # per-node and keyed by origin plus endpoint, so every test in this
        # file asking chain 1 the same question would share one entry and the
        # first to run would answer for the rest. The cache has its own tests
        # below, on their own chains.
        cache: Keyword.get(opts, :cache, false)
      )

    handle
  end

  defp state(handle), do: elem(handle, 1)

  defp requested_paths do
    Enum.map(drain(), & &1.path)
  end

  defp drain(acc \\ []) do
    receive do
      {:request, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "chains" do
    test "maps the chains that answered, with final hosts only" do
      # Optimism's Blockscout subdomain answers 301 to explorer.optimism.io and
      # section 7 refuses redirects, so the table has to carry the destination
      # or that chain simply fails.
      assert {:ok, {Blockscout, %{host: "eth.blockscout.com"}}} = Blockscout.new("eip155:1")
      assert {:ok, {Blockscout, %{host: "explorer.optimism.io"}}} = Blockscout.new("eip155:10")
      assert {:ok, {Blockscout, %{host: "base.blockscout.com"}}} = Blockscout.new("eip155:8453")
    end

    test "chain 4663 is admitted, not excluded" do
      # Its API paths answered 403 with `cf-mitigated: challenge` while `/`
      # returned 200. That is a dated WAF state, so it is carried as health (the
      # breaker trips, the router fails over) rather than as absence, which
      # would need a code change to undo.
      assert {:ok, {Blockscout, %{host: "robinhoodchain.blockscout.com"}}} =
               Blockscout.new("eip155:4663")

      assert {"robinhoodchain.blockscout.com", :challenge_gated} = Blockscout.hosts()[4663]
    end

    test "a chain with no instance is refused rather than guessed at" do
      # Both branches name the reference they refused. The bare atom this
      # pinned was the only reason in the package that did not: it reached a
      # caller as `:unsupported_chain` with no way to tell WHICH chain, and it
      # sat next to `chain_id/1`'s tupled form in the same `with`.
      assert {:error, {:unsupported_chain, "eip155:999999"}} = Blockscout.new("eip155:999999")
      assert {:error, {:unsupported_chain, "solana:mainnet"}} = Blockscout.new("solana:mainnet")
    end
  end

  describe "capabilities" do
    test "read_contract appears only with an RPC url, because only RPC can answer it" do
      refute :read_contract in Blockscout.capabilities(state(handle(%{})))

      assert :read_contract in Blockscout.capabilities(
               state(handle(%{}, rpc_url: "https://rpc.test/"))
             )
    end

    test "raw_request is declined, so the read allowlist is empty by construction" do
      # A REST backend has no method parameter to abuse. Declining the callback
      # is stronger than policing it.
      handle = handle(%{})

      refute :raw_request in Blockscout.capabilities(state(handle))
      refute Backend.supports?(handle, :raw_request)
      assert {:error, {:unsupported, :raw_request}} = Backend.call(handle, :raw_request, [%{}])
    end

    test "the four demoted reads are declared, so the demotion cost nothing here" do
      # ADR-0039 made get_transaction, account_info, list_transactions and
      # token_balances optional because a raw node and an archive cannot answer
      # them: each needs an index over things of its kind. An explorer has
      # those indexes, so this backend declares all four and a caller of chain
      # 1 sees no change from the amendment.
      handle = handle(%{})

      for callback <- [:get_transaction, :account_info, :list_transactions, :token_balances] do
        assert Backend.supports?(handle, callback), "#{callback} is not declared"
      end
    end
  end

  describe "chain_info/1" do
    test "maps the stats endpoint, where total_blocks is a count and not a height" do
      handle = handle(%{"/api/v2/stats" => fixture("stats")})

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == "eip155:1"
      assert info.average_block_time_ms == 1.2e4
      assert is_integer(info.total_blocks)
      assert is_integer(info.total_transactions)
      refute Map.has_key?(info, :height)
    end
  end

  describe "the response cache" do
    # These use their own chains, because the cache is per node and keyed by
    # origin: sharing chain 1 with the rest of this file would mean sharing
    # entries with it.
    test "a repeated read is served from the cache, and the upstream is asked once" do
      handle =
        handle(%{"/api/v2/stats" => fixture("stats")}, cache: true, chain_ref: "eip155:8453")

      assert {:ok, first} = Backend.call(handle, :chain_info)
      assert {:ok, second} = Backend.call(handle, :chain_info)

      assert first == second
      assert [_one] = requested_paths()
    end

    test "a height is asked every time, whatever the cache is doing" do
      # The rule that is about correctness rather than freshness. A cached
      # height beside a live finalized height is what makes finalized > height.
      handle =
        handle(
          %{
            "/api/v2/blocks" => ~s({"items":[{"height":100}]}),
            "/api/v2/main-page/indexing-status" => fixture("indexing_status")
          },
          cache: true,
          chain_ref: "eip155:137"
        )

      assert {:ok, %{height: 100}} = Backend.call(handle, :block_height)
      assert {:ok, %{height: 100}} = Backend.call(handle, :block_height)

      # Two block reads, and the indexer status is cached by nothing either.
      assert Enum.count(requested_paths(), &String.contains?(&1, "/blocks")) == 2
    end

    test "a non-2xx is not cached, so a challenge page cannot outlive the breaker" do
      handle =
        handle(%{"/api/v2/stats" => {403, "<html>challenge</html>"}},
          cache: true,
          chain_ref: "eip155:42161"
        )

      assert {:error, {:http, 403}} = Backend.call(handle, :chain_info)
      assert {:error, {:http, 403}} = Backend.call(handle, :chain_info)

      assert length(requested_paths()) == 2
    end

    test "two pages of one walk are two entries, not one" do
      # A cached page and a cursor have to coexist: if the cursor's parameters
      # were not part of the key, page two would be served page one's body.
      path = "/api/v2/addresses/#{elem(@vitalik, 1)}/transactions"

      handle =
        handle(%{path => fixture("address_transactions")},
          cache: true,
          chain_ref: "eip155:10"
        )

      assert {:ok, %{next: cursor}} = Backend.call(handle, :list_transactions, [@vitalik, []])
      _first = drain()

      assert {:ok, _page} = Backend.call(handle, :list_transactions, [@vitalik, [cursor: cursor]])

      assert [requested] = requested_paths()
      assert requested =~ "block_number="
    end

    test "the cache can be turned off for a caller that must see the head" do
      handle = handle(%{"/api/v2/stats" => fixture("stats")}, cache: false)

      assert {:ok, _first} = Backend.call(handle, :chain_info)
      assert {:ok, _second} = Backend.call(handle, :chain_info)

      assert length(requested_paths()) == 2
    end
  end

  describe "block_height/1" do
    test "without an RPC url, the height is REST and finality is nil, never invented" do
      handle =
        handle(%{
          "/api/v2/blocks" => ~s({"items":[{"height":25970304}]}),
          "/api/v2/main-page/indexing-status" => fixture("indexing_status")
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.height == 25_970_304
      assert height.finalized_height == nil
      assert height.unit == :block
      assert height.indexer == %{finished?: true, indexed_ratio: 1.0}
    end

    test "with an RPC url, both numbers come from the node and the pair is monotone" do
      # The composition ADR-0038 rejects would take the height from the indexer
      # and finality from the node. Here the indexer is deliberately behind
      # (a 0.5 ratio) and the pair still holds, because REST contributes no
      # number at all.
      handle =
        handle(
          %{
            "/api/v2/main-page/indexing-status" =>
              ~s({"finished_indexing_blocks":false,"indexed_blocks_ratio":"0.50"})
          },
          rpc_url: "https://rpc.test/",
          rpc: %{
            "eth_blockNumber" => "0x18c7f00",
            "eth_getBlockByNumber" => %{"number" => "0x18c7ec0"}
          }
        )

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.height == 0x18C7F00
      assert height.finalized_height == 0x18C7EC0
      assert height.finalized_height <= height.height
      assert height.indexer == %{finished?: false, indexed_ratio: 0.5}
    end

    test "a chain whose node does not know the finalized tag reports nil, not an error" do
      handle =
        handle(%{"/api/v2/main-page/indexing-status" => fixture("indexing_status")},
          rpc_url: "https://rpc.test/",
          rpc: %{"eth_blockNumber" => "0x10", "eth_getBlockByNumber" => nil}
        )

      assert {:ok, %{height: 16, finalized_height: nil}} = Backend.call(handle, :block_height)
    end

    test "the indexer status is advisory: losing it does not fail the height" do
      handle =
        handle(%{},
          rpc_url: "https://rpc.test/",
          rpc: %{"eth_blockNumber" => "0x10", "eth_getBlockByNumber" => %{"number" => "0x8"}}
        )

      assert {:ok, %{height: 16, indexer: nil}} = Backend.call(handle, :block_height)
    end
  end

  describe "token_balances/2" do
    test "reads the paginated endpoint, not the unpaginated one" do
      # `/token-balances` returned 3,289,596 bytes carrying 8,009 items for this
      # exact address on 2026-09-13. No byte ceiling bounds an unpaginated list,
      # so the fix is a different endpoint. This assertion is the fix.
      handle =
        handle(%{
          "/api/v2/addresses/#{elem(@vitalik, 1)}/tokens" => fixture("address_tokens")
        })

      assert {:ok, page} = Backend.call(handle, :token_balances, [@vitalik])

      paths = requested_paths()
      assert Enum.any?(paths, &String.ends_with?(&1, "/tokens"))
      refute Enum.any?(paths, &String.contains?(&1, "token-balances"))

      assert [%{token: token, amount: amount} | _rest] = page.items
      assert token.symbol == "WHITE"
      assert token.decimals == 18
      assert token.type == "ERC-20"
      assert is_integer(amount)
    end
  end

  describe "pagination" do
    test "a page carries an opaque cursor that decodes to the upstream keyset" do
      handle =
        handle(%{
          "/api/v2/addresses/#{elem(@vitalik, 1)}/transactions" => fixture("address_transactions")
        })

      assert {:ok, page} = Backend.call(handle, :list_transactions, [@vitalik, []])
      assert length(page.items) == 2
      assert is_binary(page.next)

      origin = Raxol.Web3.Origin.id(URI.new!("https://eth.blockscout.com/"))
      assert {:ok, params} = Cursor.decode(page.next, origin, :address_transactions)
      assert params["block_number"] == 25_574_152
      refute Map.has_key?(params, "items_count")
    end

    test "a cursor turns into the upstream's own query parameters on the next call" do
      path = "/api/v2/addresses/#{elem(@vitalik, 1)}/transactions"
      handle = handle(%{path => fixture("address_transactions")})

      assert {:ok, %{next: cursor}} = Backend.call(handle, :list_transactions, [@vitalik, []])
      _first = drain()

      assert {:ok, _page} = Backend.call(handle, :list_transactions, [@vitalik, [cursor: cursor]])

      assert [requested] = requested_paths()
      assert requested =~ "block_number=25574152"
      assert requested =~ "index=149"
      refute requested =~ "items_count"
    end

    test "a cursor from another endpoint is refused before the request is built" do
      path = "/api/v2/addresses/#{elem(@vitalik, 1)}/transactions"
      handle = handle(%{path => fixture("address_transactions")})

      assert {:ok, %{next: cursor}} = Backend.call(handle, :list_transactions, [@vitalik, []])
      _first = drain()

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Backend.call(handle, :get_logs, [@vitalik, [cursor: cursor]])

      assert [] == requested_paths()
    end

    test "the last page has no cursor" do
      path = "/api/v2/addresses/#{elem(@vitalik, 1)}/tokens"
      handle = handle(%{path => ~s({"items":[],"next_page_params":null})})

      assert {:ok, %{items: [], next: nil}} = Backend.call(handle, :token_balances, [@vitalik])
    end
  end

  describe "the mapped shapes" do
    test "a transaction carries its status, value, fee and counterparties" do
      hash = "0x6fb7ecc59484bb9ff748461c4f298f9e24d2e7f0d61d4e82c8f9097c8700354e"
      handle = handle(%{"/api/v2/transactions/#{hash}" => fixture("transaction")})

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [hash])
      assert transaction.hash == hash
      assert transaction.status == :success
      assert transaction.block == 25_956_569
      assert transaction.value == 3_944_975_481_977
      assert transaction.fee == 14_125_879_072_786
      assert transaction.to == @vitalik
      assert %DateTime{} = transaction.timestamp
    end

    test "an account carries its balance, its ENS name and what the upstream says about code" do
      handle = handle(%{"/api/v2/addresses/#{elem(@vitalik, 1)}" => fixture("address")})

      assert {:ok, account} = Backend.call(handle, :account_info, [@vitalik])
      assert account.ref == @vitalik
      assert account.ens == "vitalik.eth"
      assert is_integer(account.balance)

      # `true` for a famous EOA, and correct: this address carries an EIP-7702
      # delegation designator, so it HAS code. The field is passed through
      # rather than reinterpreted, and the backend's moduledoc says why a
      # consumer must not read it as "not an EOA".
      assert account.contract? == true
    end

    test "a token transfer, a log and an NFT each normalize to their contract" do
      address = elem(@vitalik, 1)

      handle =
        handle(%{
          "/api/v2/addresses/#{address}/token-transfers" => fixture("address_token_transfers"),
          "/api/v2/addresses/#{elem(@tether, 1)}/logs" => fixture("address_logs"),
          "/api/v2/addresses/#{address}/nft" => fixture("address_nft")
        })

      assert {:ok, transfers} = Backend.call(handle, :list_token_transfers, [@vitalik, []])
      assert [%{token: %{type: type}, block: block} | _] = transfers.items
      assert is_binary(type)
      assert is_integer(block)

      assert {:ok, logs} = Backend.call(handle, :get_logs, [@tether, []])
      assert [%{address: log_address, topics: topics} | _] = logs.items
      assert log_address == elem(@tether, 1)
      assert is_list(topics)

      assert {:ok, nfts} = Backend.call(handle, :list_nfts, [@vitalik, []])
      assert [%{token_id: token_id} | _] = nfts.items
      assert is_binary(token_id)
    end

    test "contract metadata carries the ABI and the verification state" do
      handle =
        handle(%{"/api/v2/smart-contracts/#{elem(@tether, 1)}" => fixture("smart_contract")})

      assert {:ok, metadata} = Backend.call(handle, :contract_metadata, [@tether])
      assert metadata.name == "TetherToken"
      assert metadata.verified? == true
      assert metadata.language == "solidity"
      assert is_list(metadata.abi)
    end

    test "a block carries its height, hash and miner" do
      handle = handle(%{"/api/v2/blocks/23000000" => fixture("block")})

      assert {:ok, block} = Backend.call(handle, :get_block, [23_000_000])
      assert is_integer(block.height)
      assert is_binary(block.hash)
      assert {:evm, _miner} = block.miner
    end

    test "an integer field that does not parse WHOLE fails the read instead of truncating" do
      # `Integer.parse/1` answers `{1, ".5e18"}`, `{0, "x1f"}` and
      # `{12, "abc"}` for these, so taking the number and dropping the rest
      # turned each into a small plausible integer nothing downstream could
      # tell from a real one. A height of 0 is worse than no height.
      for value <- ["1.5e18", "1e18", "0x1f", "12abc", true] do
        handle = handle(%{"/api/v2/blocks/1" => Jason.encode!(%{"height" => value})})

        assert Backend.call(handle, :get_block, [1]) == {:error, {:decode_failed, :height}},
               "#{inspect(value)} was read as a height"
      end
    end

    test "a token's decimals must parse whole, because every amount is read through it" do
      # `amount / 10 ** decimals`: "18abc" taken as 18 is luck, and taken as
      # 1 -- which is what the truncating parse did with "1.8e1" -- is a
      # 10^17 error in the number a user reads as money.
      body =
        Jason.encode!(%{
          "items" => [%{"value" => "1000", "token" => %{"decimals" => "18abc"}}]
        })

      handle = handle(%{"/api/v2/addresses/#{elem(@vitalik, 1)}/tokens" => body})

      assert {:error, {:decode_failed, :decimals}} =
               Backend.call(handle, :token_balances, [@vitalik, []])
    end

    test "a REST height that does not parse is a failed read, not a nil height" do
      # `"23e6"` truncated to 23: a height off by seven orders of magnitude,
      # handed to a caller as the chain's head.
      handle = handle(%{"/api/v2/blocks" => ~s({"items":[{"height":"23e6"}]})})

      assert {:error, {:decode_failed, :height}} = Backend.call(handle, :block_height)
    end

    test "a stats counter that does not parse names itself in the failure" do
      handle = handle(%{"/api/v2/stats" => ~s({"total_blocks":"1.5e18"})})

      assert {:error, {:decode_failed, :total_blocks}} = Backend.call(handle, :chain_info)
    end
  end

  describe "resolve_name/2" do
    test "finds the address behind an ENS name" do
      handle = handle(%{"/api/v2/search" => fixture("search")})

      assert {:ok, @vitalik} = Backend.call(handle, :resolve_name, ["vitalik.eth"])
    end

    test "a name with no match is a refusal, not an empty success" do
      handle = handle(%{"/api/v2/search" => ~s({"items":[]})})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :resolve_name, ["nothing.eth"])
    end
  end

  describe "read_contract/2" do
    test "goes to eth_call, which is the path any balance gate takes" do
      handle =
        handle(%{}, rpc_url: "https://rpc.test/", rpc: %{"eth_call" => "0x2a"})

      assert {:ok, "0x2a"} =
               Backend.call(handle, :read_contract, [%{to: "0xabc", data: "0x70a08231"}])
    end

    test "without an RPC url it is refused rather than faked from REST" do
      handle = handle(%{})

      assert {:error, {:unsupported, :read_contract}} =
               Backend.call(handle, :read_contract, [%{to: "0xabc", data: "0x"}])
    end
  end

  describe "refusals" do
    test "a non-EVM account reference is refused by tag, before any request" do
      # The reason `account_info/2` takes a tagged reference at all: Canton has
      # party ids and no addresses, Tron has two encodings for one account.
      handle = handle(%{})

      assert {:error, {:unsupported_account_ref, :party}} =
               Backend.call(handle, :account_info, [{:party, "Alice::1220abcd"}])

      assert [] == requested_paths()
    end

    test "an account reference that is not an address is refused before any request" do
      # `is_binary/1` was the only check, and `Serialize.account_ref/1` builds
      # `{:evm, value}` out of anything a tool argument prefixes with `"evm:"`,
      # so this value reached `/api/v2/addresses/../../admin?x=1` -- an
      # arbitrary path and query on this host, with the body handed back to the
      # model. Refused at the function that makes the request, not at the tool
      # boundary.
      handle = handle(%{})

      for refused <- [
            "../../admin?x=1",
            "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA960",
            "d8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
            "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA960zz",
            ""
          ] do
        assert {:error, {:unsupported_account_ref, :not_an_address}} =
                 Backend.call(handle, :account_info, [{:evm, refused}])
      end

      assert [] == requested_paths()
    end

    test "a checksummed address is passed through unchanged" do
      # EIP-55 mixed case is the caller's own typo protection, so the format
      # check must not normalize it away.
      handle = handle(%{"/api/v2/addresses/#{elem(@vitalik, 1)}" => fixture("address")})

      assert {:ok, %{ref: @vitalik}} = Backend.call(handle, :account_info, [@vitalik])
    end

    test "a transaction hash cannot escape the /transactions/ prefix" do
      # The hash arrives from a model as the `web3_get_transaction` argument
      # and has no single format to validate against, so encoding is what
      # holds: `URI.encode/1`'s default predicate leaves `/`, `?` and `#`
      # alone and was not a defence anywhere in this package.
      handle = handle(%{})

      assert {:error, {:http, 404}} =
               Backend.call(handle, :get_transaction, ["../../v2/admin?x=1#y"])

      assert [requested] = requested_paths()
      assert "/api/v2/transactions/" <> encoded = requested
      refute String.contains?(encoded, ["/", "?", "#"])
    end

    test "a block identifier cannot escape the /blocks/ prefix" do
      handle = handle(%{})

      assert {:error, {:http, 404}} = Backend.call(handle, :get_block, ["../../v2/admin"])

      assert [requested] = requested_paths()
      assert "/api/v2/blocks/" <> encoded = requested
      refute String.contains?(encoded, "/")
    end

    test "a non-2xx becomes a status, carrying no upstream body" do
      handle = handle(%{"/api/v2/stats" => {403, "<html>challenge</html>"}})

      assert {:error, {:http, 403}} = Backend.call(handle, :chain_info)
    end

    test "a body that is not JSON is a decode failure, not a crash" do
      handle = handle(%{"/api/v2/stats" => "<html>not json</html>"})

      assert {:error, {:decode_failed, :json}} = Backend.call(handle, :chain_info)
    end
  end

  describe "against a real upstream" do
    # Generous bounds, deliberately. What these two prove is that the callbacks
    # answer and that a cursor pages, not that a third party is fast. The
    # bounds themselves are `Raxol.Web3.ExchangeTest`'s subject, against a
    # scripted peer that misbehaves on purpose; leaving the ten-second chunk
    # timeout in place here only buys a red test when somebody else's service
    # has a slow minute, which it did on one run of this very test.
    defp live do
      [http_opts: [chunk_timeout_ms: 30_000, deadline_ms: 60_000]]
    end

    @tag :live_web3
    test "the required callbacks answer for real" do
      {:ok, handle} = Blockscout.new("eip155:1", live())

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.total_blocks > 25_000_000

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :block
      assert height.height > 25_000_000

      assert {:ok, account} = Backend.call(handle, :account_info, [@vitalik])
      assert account.ens == "vitalik.eth"

      # One call, not two. An earlier version asked for this page twice to
      # assert determinism, which is not a contract worth a second round trip
      # to somebody else's service. Paging is proved by the cursor test below.
      assert {:ok, page} = Backend.call(handle, :token_balances, [@vitalik])
      assert page.items != []
      assert is_binary(page.next)
    end

    @tag :live_web3
    test "a cursor pages forward against the live endpoint" do
      {:ok, handle} = Blockscout.new("eip155:1", live())

      assert {:ok, first} = Backend.call(handle, :list_transactions, [@vitalik, []])

      assert {:ok, next} =
               Backend.call(handle, :list_transactions, [@vitalik, [cursor: first.next]])

      assert hd(first.items).hash != hd(next.items).hash
    end
  end
end
