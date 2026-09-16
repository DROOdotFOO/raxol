defmodule Raxol.Web3.Backend.JSONRPCTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Backend.JSONRPC
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @fixtures Path.expand("../../../fixtures/jsonrpc", __DIR__)

  # Every fixture below was recorded from https://rpc.mainnet.chain.robinhood.com
  # on 2026-09-14 and trimmed: blocks keep two transaction hashes, the log list
  # keeps two of four entries, and the contract's runtime code keeps its first
  # 32 bytes of 3,249, because the only question asked of it is whether there is
  # any. A fixture is not a mock. It is what the node actually said, and it is
  # what makes "the node's shape changed" a red test.
  defp fixture(name),
    do: @fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()

  defp result(name), do: fixture(name)["result"]

  @eoa {:evm, "0xb754e001604508f841d768e64d38b7c98c859c05"}
  @token {:evm, "0x5317c0d077d2eeb639448939b930d49c4984b63b"}
  @hash "0x0b88f6bbaae329a1de198da8b14a3db03a9d1d5bb29345b116bb12fe64496839"
  @head 0x3BD25D0
  @robinhood "https://rpc.mainnet.chain.robinhood.com"

  # Both limiters are given room, as in `Raxol.Web3.Backend.BlockscoutTest`:
  # every test here shares one origin per URL, so the bucket and the breaker
  # would otherwise couple unrelated tests through it. They are
  # `Raxol.Web3.HTTPTest`'s subject.
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

  # Answers a JSON-RPC POST by method. A value may be a result, a one-argument
  # function of the params (for the methods whose answer depends on what was
  # asked), or `{:error, code}` for a node that refuses.
  defp serving(rpc) do
    fn _vetted, request, _opts ->
      %{"method" => method, "params" => params, "id" => id} = Jason.decode!(request.body)
      send(self(), {:rpc, method, params})

      answer =
        case Map.fetch(rpc, method) do
          {:ok, fun} when is_function(fun, 1) -> %{"result" => fun.(params)}
          {:ok, {:error, code}} -> %{"error" => %{"code" => code}}
          {:ok, result} -> %{"result" => result}
          :error -> %{"error" => %{"code" => -32_601}}
        end

      body = Map.merge(%{"jsonrpc" => "2.0", "id" => id}, answer)

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end
  end

  defp handle(rpc, opts \\ []) do
    http_opts = [{:exchange, serving(rpc)} | unmetered()]

    {:ok, handle} =
      JSONRPC.new(
        Keyword.get(opts, :chain_ref, "eip155:4663"),
        url: Keyword.get(opts, :url, "https://node.test/"),
        http_opts: http_opts,
        # Off by default, and not for convenience: the cache is per node and
        # keyed by origin, so two tests asking one URL the same question would
        # share an entry and the first to run would answer for the second. The
        # cache tests below give themselves their own URLs.
        cache: Keyword.get(opts, :cache, false),
        log_window: Keyword.get(opts, :log_window, 2_000),
        log_lookback: Keyword.get(opts, :log_lookback, 10_000)
      )

    handle
  end

  defp state(handle), do: elem(handle, 1)

  defp drain(acc \\ []) do
    receive do
      {:rpc, method, params} -> drain([{method, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp methods, do: Enum.map(drain(), &elem(&1, 0))

  # The node table, so a test can express "latest", "finalized" and the sample
  # block the average block time is derived from in one place.
  defp blocks do
    fn
      ["latest", false] -> result("block")
      ["finalized", false] -> result("block_finalized")
      [number, false] -> Map.get(%{"0x3bd256c" => result("block_earlier")}, number)
    end
  end

  describe "chains" do
    test "chain 4663 has a default URL in library code, which is where it was missing" do
      # ADR-0033 gap 2: the only URL for this chain lived in a shell script.
      # Probed 2026-09-14, this endpoint answered eth_chainId with 0x1237.
      assert JSONRPC.default_urls() == %{4663 => @robinhood}
      assert {:ok, {JSONRPC, %{url: @robinhood, chain_id: 4663}}} = JSONRPC.new("eip155:4663")
    end

    test "an explicit url overrides the table" do
      assert {:ok, {JSONRPC, %{url: "https://node.test/"}}} =
               JSONRPC.new("eip155:4663", url: "https://node.test/")
    end

    test "a chain that was never probed needs a url rather than getting a guess" do
      # A table entry is a claim about a live endpoint on a date, so an absent
      # chain is an absent claim, not a default worth inventing.
      assert {:error, :no_rpc_url} = JSONRPC.new("eip155:1")
      assert {:error, {:unsupported_chain, _}} = JSONRPC.new("solana:mainnet")
    end

    test "a url that is not https is refused where it is configured, not where it is dialled" do
      assert {:error, :invalid_rpc_url} = JSONRPC.new("eip155:1", url: "http://node.test/")
      assert {:error, :invalid_rpc_url} = JSONRPC.new("eip155:1", url: "not a url")
    end
  end

  describe "capabilities" do
    test "declares what an eth_* allowlist can answer" do
      handle = handle(%{})

      for callback <- [:get_transaction, :account_info, :get_block, :read_contract, :raw_request] do
        assert Backend.supports?(handle, callback), "#{callback} is not declared"
      end

      assert Backend.supports?(handle, :get_logs)
    end

    test "the reads a node has no index for are absent, not stubbed" do
      # ADR-0039 decision 3: absence is the answer. This asserts absence rather
      # than an error shape on purpose, because a callback that existed and
      # returned {:error, {:unsupported, _}} would satisfy every assertion about
      # an error shape while being exactly the stub the rules forbid.
      #
      # get_transaction/2 sits on the other side of the same line and is
      # asserted here so the file says plainly which reads a node can and
      # cannot answer: a node has an index over transaction ids, and none over
      # accounts.
      Code.ensure_loaded!(JSONRPC)
      handle = handle(%{})
      declared = JSONRPC.capabilities(state(handle))

      assert :get_transaction in declared
      assert function_exported?(JSONRPC, :get_transaction, 2)

      for {callback, arity} <- [
            list_transactions: 3,
            token_balances: 2,
            list_token_transfers: 3,
            list_nfts: 3,
            contract_metadata: 2,
            resolve_name: 2
          ] do
        refute callback in declared, "#{callback} is declared"
        refute Backend.supports?(handle, callback)
        refute function_exported?(JSONRPC, callback, arity), "#{callback}/#{arity} exists"
      end
    end
  end

  describe "chain_info/1" do
    test "answers a chain reference and a derived block time, and nil for an indexer's counters" do
      handle =
        handle(%{
          "eth_chainId" => result("chain_id"),
          "eth_getBlockByNumber" => blocks()
        })

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == "eip155:4663"

      # Two real timestamps 100 blocks apart: 0x6aa7c87a - 0x6aa7c86f is 11
      # seconds, so 110 ms a block. Derived, not decorative.
      assert info.average_block_time_ms == 110.0

      # A node keeps no aggregate counters, and nil is what it knows.
      assert info.total_blocks == nil
      assert info.total_transactions == nil
      assert info.total_addresses == nil
    end

    test "a url whose chain id disagrees with the handle is an error, not an answer" do
      # The test that catches 4663's handle pointed at chain 1, or the reverse.
      # Without it every callback here would answer, correctly, about a chain
      # nobody asked about.
      handle =
        handle(
          %{"eth_chainId" => result("chain_id"), "eth_getBlockByNumber" => blocks()},
          chain_ref: "eip155:1",
          url: "https://wrong-chain.test/"
        )

      assert {:error, {:blocked, :chain_mismatch}} = Backend.call(handle, :chain_info)

      # And it stops there: the identity check runs before anything is read.
      assert methods() == ["eth_chainId"]
    end

    test "a mismatch is terminal at the router, not a quiet failover" do
      # The consequence of classifying it as {:blocked, _}: failing over would
      # answer this caller from the next candidate and leave the misconfigured
      # handle in the router answering about the wrong chain forever. An error
      # is what gets it fixed.
      misconfigured =
        handle(
          %{"eth_chainId" => result("chain_id"), "eth_getBlockByNumber" => blocks()},
          chain_ref: "eip155:1",
          url: "https://wrong-chain.test/"
        )

      {:ok, well} = Stub.new("eip155:1", answers: %{chain_info: {:ok, %{marker: :stub}}})

      assert {:error, {:blocked, :chain_mismatch}} =
               Router.call(Router.new([misconfigured, well]), "eip155:1", :chain_info)
    end

    test "the block time is advisory: a node that cannot serve the sample still answers" do
      handle =
        handle(%{
          "eth_chainId" => result("chain_id"),
          "eth_getBlockByNumber" => fn
            ["latest", false] -> result("block")
            [_pruned, false] -> nil
          end
        })

      assert {:ok, %{average_block_time_ms: nil, chain_ref: "eip155:4663"}} =
               Backend.call(handle, :chain_info)
    end
  end

  describe "block_height/1" do
    test "both numbers come from the node, and there is no indexer to report" do
      handle =
        handle(%{
          "eth_blockNumber" => result("block_number"),
          "eth_getBlockByNumber" => blocks()
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.height == 0x3BD25DE
      assert height.finalized_height == 0x3BD05F0
      assert height.finalized_height <= height.height
      assert height.unit == :block

      # nil, not %{finished?: true}. There is no indexer here to be behind, and
      # inventing a healthy one would claim a component that does not exist.
      assert height.indexer == nil
    end

    test "a node that does not know the finalized tag reports nil rather than failing" do
      handle =
        handle(%{
          "eth_blockNumber" => result("block_number"),
          "eth_getBlockByNumber" => fn _params -> nil end
        })

      assert {:ok, %{height: 0x3BD25DE, finalized_height: nil}} =
               Backend.call(handle, :block_height)
    end
  end

  describe "get_transaction/2" do
    test "a mined transaction carries its status and its fee, both from the receipt" do
      handle =
        handle(%{
          "eth_getTransactionByHash" => result("transaction"),
          "eth_getTransactionReceipt" => result("receipt")
        })

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [@hash])
      assert transaction.hash == @hash
      assert transaction.status == :success
      assert transaction.block == @head
      assert transaction.value == 0
      assert transaction.from == @eoa
      assert transaction.to == @token
      assert transaction.fee == 0x7099 * 0x43C59C0

      # The four-byte selector of approve(address,uint256): a node has no ABI,
      # so this is the whole of what it knows about the method.
      assert transaction.method == "0x095ea7b3"

      # A node's transaction record carries no timestamp, and the block that
      # does would be a third round trip for a field get_block/2 answers.
      assert transaction.timestamp == nil
    end

    test "a transaction the node holds but has not mined is :pending, not an error" do
      # The same record the node gave, minus the two fields a pooled
      # transaction has not got yet, and with no receipt: this is exactly what
      # a node answers between acceptance and inclusion.
      pooled = Map.merge(result("transaction"), %{"blockNumber" => nil, "blockHash" => nil})

      handle =
        handle(%{
          "eth_getTransactionByHash" => pooled,
          "eth_getTransactionReceipt" => nil
        })

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [@hash])
      assert transaction.status == :pending
      assert transaction.block == nil
      assert transaction.fee == nil
    end

    test "a hash the node has never seen is a refusal about the question" do
      # Not a source error, so the router must not fail over on it: another
      # node would answer the same and hide the first answer.
      handle = handle(%{"eth_getTransactionByHash" => nil})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_transaction, [@hash])

      # And the receipt is never asked for, because there is nothing to receipt.
      assert methods() == ["eth_getTransactionByHash"]
    end
  end

  describe "account_info/2" do
    test "answers from a balance and a code read, which is all a node can offer" do
      handle =
        handle(%{
          "eth_getBalance" => result("balance"),
          "eth_getCode" => result("code_eoa")
        })

      assert {:ok, account} = Backend.call(handle, :account_info, [@eoa])
      assert account.ref == @eoa
      assert account.balance == 0xEAD018F86947B
      assert account.contract? == false

      # A node has no source and no name service, so these are false and nil
      # rather than absent or invented.
      assert account.verified? == false
      assert account.name == nil
      assert account.ens == nil

      assert methods() == ["eth_getBalance", "eth_getCode"]
    end

    test "contract? is code presence, which since EIP-7702 is not account type" do
      handle =
        handle(%{
          "eth_getBalance" => result("balance"),
          "eth_getCode" => result("code_contract")
        })

      assert {:ok, %{contract?: true}} = Backend.call(handle, :account_info, [@token])
    end

    test "a non-EVM account reference is refused by tag, before any request" do
      handle = handle(%{})

      assert {:error, {:unsupported_account_ref, :party}} =
               Backend.call(handle, :account_info, [{:party, "Alice::1220abcd"}])

      assert drain() == []
    end
  end

  describe "get_block/2" do
    test "a number goes to eth_getBlockByNumber and a hash to eth_getBlockByHash" do
      hash = result("block")["hash"]

      handle =
        handle(%{
          "eth_getBlockByNumber" => fn ["0x3bd25d0", false] -> result("block") end,
          "eth_getBlockByHash" => fn [^hash, false] -> result("block") end
        })

      assert {:ok, block} = Backend.call(handle, :get_block, [@head])
      assert block.height == @head
      assert block.hash == hash
      assert %DateTime{} = block.timestamp
      assert block.miner == {:evm, "0xa4b000000000000000000073657175656e636572"}
      # Two, because the fixture is trimmed to two hashes of the block's eight.
      assert block.transactions_count == 2

      assert {:ok, ^block} = Backend.call(handle, :get_block, [hash])
      assert methods() == ["eth_getBlockByNumber", "eth_getBlockByHash"]
    end

    test "a block the node does not have is a refusal rather than an empty block" do
      handle = handle(%{"eth_getBlockByNumber" => fn _params -> nil end})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_block, [999_999_999])
    end
  end

  describe "get_logs/3" do
    # head 10, lookback 4, window 2: page one is blocks 7..8 and page two 9..10.
    defp paging_handle(opts \\ []) do
      handle(
        %{
          "eth_blockNumber" => "0xa",
          "eth_getLogs" => fn [%{"fromBlock" => from}] ->
            case from do
              "0x7" -> [Enum.at(result("logs"), 0)]
              "0x9" -> [Enum.at(result("logs"), 1)]
            end
          end
        },
        Keyword.merge([log_window: 2, log_lookback: 4], opts)
      )
    end

    test "pages forward, and the second page continues where the first stopped" do
      handle = paging_handle()

      assert {:ok, first} = Backend.call(handle, :get_logs, [@token, []])
      assert [%{address: address, topics: [_transfer | _rest]}] = first.items
      assert address == elem(@token, 1)
      assert is_binary(first.next)

      assert [{"eth_blockNumber", _}, {"eth_getLogs", [filter]}] = drain()

      assert filter == %{
               "address" => elem(@token, 1),
               "fromBlock" => "0x7",
               "toBlock" => "0x8"
             }

      assert {:ok, second} = Backend.call(handle, :get_logs, [@token, [cursor: first.next]])

      # The head is established once, by page one, and pinned into the cursor:
      # a walk that re-read it each page would chase a moving head forever.
      assert [{"eth_getLogs", [next_filter]}] = drain()
      assert next_filter["fromBlock"] == "0x9"
      assert next_filter["toBlock"] == "0xa"

      # The two recorded logs share a block and differ by index, which is what
      # distinguishes one page's item from the other's here.
      assert hd(second.items).index != hd(first.items).index
      # The walk ends at the head it was pinned to, so the last page has no cursor.
      assert second.next == nil
    end

    test "the cursor carries only the two numbers the walk is made of" do
      handle = paging_handle()
      origin = Origin.id(URI.new!("https://node.test/"))

      assert {:ok, %{next: cursor}} = Backend.call(handle, :get_logs, [@token, []])
      assert {:ok, params} = Cursor.decode(cursor, origin, :rpc_logs)
      assert params == %{"from_block" => 9, "to_block" => 10}
    end

    test "a cursor is refused on another endpoint and on another origin" do
      handle = paging_handle()
      origin = Origin.id(URI.new!("https://node.test/"))

      assert {:ok, %{next: cursor}} = Backend.call(handle, :get_logs, [@token, []])
      _first_walk = drain()

      assert {:error, :wrong_scope} = Cursor.decode(cursor, origin, :address_logs)

      elsewhere = paging_handle(url: "https://other-node.test/")

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Backend.call(elsewhere, :get_logs, [@token, [cursor: cursor]])

      # Refused before a request is built, which is the point: a cursor's
      # contents become upstream query parameters.
      assert drain() == []
    end

    test "a request is bounded, because an unbounded range is how a node refuses" do
      handle =
        handle(
          %{
            "eth_blockNumber" => result("block_number"),
            "eth_getLogs" => fn _params -> [] end
          },
          log_window: 2_000,
          log_lookback: 10_000
        )

      assert {:ok, %{items: []}} = Backend.call(handle, :get_logs, [@token, []])

      assert [{"eth_blockNumber", _}, {"eth_getLogs", [filter]}] = drain()
      {:ok, from} = Raxol.Web3.RPC.decode_quantity(filter["fromBlock"])
      {:ok, to} = Raxol.Web3.RPC.decode_quantity(filter["toBlock"])
      assert to - from + 1 == 2_000
    end
  end

  describe "read_contract/2" do
    test "goes to eth_call, which is a read a challenge-gated explorer cannot serve" do
      handle = handle(%{"eth_call" => result("call")})

      assert {:ok, hex} =
               Backend.call(handle, :read_contract, [%{to: "0xabc", data: "0x18160ddd"}])

      assert hex == result("call")
    end
  end

  describe "raw_request/2" do
    test "passes an allowlisted method through" do
      handle = handle(%{"eth_chainId" => result("chain_id")})

      assert {:ok, "0x1237"} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])
    end

    test "refuses a method outside the allowlist before a request is built" do
      # The assertion that matters is the second one. A passthrough that
      # refused only in its return value would still have spent a token, opened
      # a socket and, for a write method, reached a node.
      handle = handle(%{"eth_chainId" => result("chain_id")})

      # The positive control, in the same test and against the same handle: an
      # allowlisted method does reach the seam, so the emptiness asserted below
      # is an observation and not a test that passes by never looking.
      assert {:ok, _chain_id} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])

      assert methods() == ["eth_chainId"]

      assert {:error, {:unsupported, :rpc_method}} =
               Backend.call(handle, :raw_request, [
                 %{method: "eth_sendRawTransaction", params: ["0xdeadbeef"]}
               ])

      assert drain() == []
    end

    test "a request that is not a method and params is refused the same way" do
      handle = handle(%{})

      assert {:error, {:unsupported, :rpc_method}} =
               Backend.call(handle, :raw_request, [%{method: :eth_chainId}])

      assert {:error, {:unsupported, :rpc_method}} = Backend.call(handle, :raw_request, [%{}])
      assert drain() == []
    end
  end

  describe "the response cache" do
    # Own URLs, because the cache is per node and keyed by origin.
    test "a repeated account read is served from the cache" do
      handle =
        handle(
          %{"eth_getBalance" => result("balance"), "eth_getCode" => result("code_eoa")},
          cache: true,
          url: "https://cache-account.test/"
        )

      assert {:ok, first} = Backend.call(handle, :account_info, [@eoa])
      assert {:ok, ^first} = Backend.call(handle, :account_info, [@eoa])

      assert methods() == ["eth_getBalance", "eth_getCode"]
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle =
        handle(
          %{"eth_blockNumber" => result("block_number"), "eth_getBlockByNumber" => blocks()},
          cache: true,
          url: "https://cache-height.test/"
        )

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert Enum.count(methods(), &(&1 == "eth_blockNumber")) == 2
    end
  end

  describe "refusals" do
    test "a JSON-RPC error object becomes a class, and its message stays upstream" do
      handle = handle(%{"eth_chainId" => {:error, -32_005}})

      assert {:error, {:upstream_refused, :rate_limit}} = Backend.call(handle, :chain_info)
    end

    test "a body that is not JSON-RPC is a decode failure, not a crash" do
      exchange = fn _vetted, _request, _opts ->
        {:ok, %{status: 200, headers: [], body: "<html>challenge</html>"}}
      end

      {:ok, handle} =
        JSONRPC.new("eip155:4663",
          url: "https://not-json.test/",
          http_opts: [{:exchange, exchange} | unmetered()],
          cache: false
        )

      assert {:error, {:decode_failed, :json}} = Backend.call(handle, :chain_info)
    end
  end

  describe "chain 4663 routes" do
    test "a breakered explorer orders behind the node, and the node answers" do
      # Issue #1026's third acceptance item, and the point of this backend.
      # Before ADR-0039 this router had one candidate and no fallback: the only
      # explorer for this chain answered 403 with cf-mitigated: challenge on
      # 2026-09-13, and a raw node could not be expressed as a backend at all.
      {:ok, blockscout} = Blockscout.new("eip155:4663", cache: false)

      node =
        handle(%{
          "eth_blockNumber" => result("block_number"),
          "eth_getBlockByNumber" => blocks(),
          "eth_getBalance" => result("balance"),
          "eth_getCode" => result("code_eoa")
        })

      router = Router.new([blockscout, node])
      health = Backend.health_key(blockscout)

      # This chain has exactly one explorer, so its breaker key is fixed rather
      # than per-test, and the sibling test below trips the same one. Reset it
      # here, or whichever of the two runs second inherits the other's health
      # and this assertion passes or fails on the seed.
      CircuitBreaker.reset(Tables.breakers(), health)

      assert [{Blockscout, _} | _rest] = Router.candidates(router, "eip155:4663", :block_height)

      CircuitBreaker.record_failure(Tables.breakers(), health, failure_threshold: 1)

      assert [{JSONRPC, _} | _demoted] =
               Router.candidates(router, "eip155:4663", :block_height)

      # Answered by the node, and the shape says so: an explorer reports an
      # indexer and this reports nil, because there is no indexer here.
      assert {:ok, height} = Router.call(router, "eip155:4663", :block_height)
      assert height.height == 0x3BD25DE
      assert height.indexer == nil

      assert {:ok, account} = Router.call(router, "eip155:4663", :account_info, [@eoa])
      assert account.balance == 0xEAD018F86947B
      assert account.ens == nil
    end

    test "coverage reports the partial shape rather than the declared one" do
      # What an operator gets instead of a per-call error: with the explorer
      # breakered open, the chain keeps the reads a node can serve and loses
      # the ones that need an index over accounts.
      {:ok, blockscout} = Blockscout.new("eip155:4663", cache: false)
      node = handle(%{})
      router = Router.new([blockscout, node])

      CircuitBreaker.record_failure(Tables.breakers(), Backend.health_key(blockscout),
        failure_threshold: 1
      )

      coverage = Router.coverage(router, "eip155:4663")

      assert coverage[:block_height] == [:jsonrpc]
      assert coverage[:account_info] == [:jsonrpc]
      assert coverage[:read_contract] == [:jsonrpc]
      assert coverage[:raw_request] == [:jsonrpc]

      refute Map.has_key?(coverage, :list_transactions)
      refute Map.has_key?(coverage, :token_balances)
      refute Map.has_key?(coverage, :resolve_name)
    end
  end

  describe "against a real upstream" do
    # Generous bounds, and no assertion on elapsed time: what this proves is
    # that the default URL is live and that the chain id is what the table
    # claims, not that somebody else's node is fast.
    @tag :live_web3
    test "the default URL answers, and 4663 is the chain the table says it is" do
      {:ok, handle} =
        JSONRPC.new("eip155:4663",
          cache: false,
          http_opts: [chunk_timeout_ms: 30_000, deadline_ms: 60_000]
        )

      assert state(handle).url == @robinhood

      assert {:ok, "0x1237"} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])

      # chain_info/1 runs the same comparison internally, so this answering at
      # all is the identity check passing against the live node.
      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == "eip155:4663"
      assert info.total_blocks == nil
      assert is_number(info.average_block_time_ms)
      assert info.average_block_time_ms > 0

      # 0x3bd25de was the head on 2026-09-14, so the chain can only be past it.
      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :block
      assert height.height >= 0x3BD25DE
      assert height.finalized_height <= height.height
      assert height.indexer == nil
    end
  end
end
