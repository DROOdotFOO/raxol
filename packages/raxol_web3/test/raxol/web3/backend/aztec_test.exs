defmodule Raxol.Web3.Backend.AztecTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Aztec
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @fixtures Path.expand("../../../fixtures/aztec", __DIR__)

  @chain "aztec:mainnet"

  # A deployed mainnet instance, a mined transaction, and a transaction that
  # was in the pool when the fixtures were recorded. All three are from the
  # recorded responses, so the assertions below and the live tests at the end
  # ask about the same objects.
  @instance {:aztec, "0x1df9626e34c9e837d8f1402207693948f3869c3e8b920939c19697c24af18d07"}
  @mined "0x0a13cfae47782debfb1e7dbe15e7e033fc65a3eb0edf2377b32ea533a6c912f1"
  @pooled "0x0b80d11d7315a41d662199175a6dfa14a0ffa92fc01b8bd1abb0d34ae5633803"

  # Recorded from the live API on 2026-09-14, trimmed to two items per array.
  # A fixture is not a mock: it is what the upstream actually said, and it is
  # the only thing that makes "the shape changed" a red test rather than a
  # production surprise, since nothing specifies these response bodies.
  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Both limiters are given room on purpose. The seeded rate limit is a
  # labelled guess about somebody else's service and the breaker is the
  # router's subject, so coupling every test in this file to them through one
  # shared origin would buy nothing. The revocation tests below set their own.
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

  # Routes on the endpoint rather than the whole path, so a route map reads as
  # the API surface and stays the same whether the credential prefix is the
  # hosted temporary one or a self-hosted instance's. The hostname is recorded
  # alongside, because "which origin answered" is the whole question in a
  # failover test.
  defp serving(routes) do
    fn vetted, request, _opts ->
      endpoint = endpoint(request.path)
      send(self(), {:request, vetted.hostname, endpoint})

      case Map.fetch(routes, endpoint) do
        {:ok, {status, body}} -> {:ok, %{status: status, headers: [], body: body}}
        {:ok, body} -> {:ok, %{status: 200, headers: [], body: body}}
        :error -> {:ok, %{status: 404, headers: [], body: fixture("revoked_prefix_404.txt")}}
      end
    end
  end

  defp endpoint(path) do
    case String.split(path, "/l2", parts: 2) do
      [_prefix, rest] -> "/l2" <> rest
      [whole] -> whole
    end
  end

  defp handle(routes, opts \\ []) do
    http_opts = [{:exchange, serving(routes)} | unmetered()]

    {:ok, handle} =
      Aztec.new(@chain,
        base_url: Keyword.get(opts, :base_url),
        http_opts: http_opts,
        # Off by default, and not for convenience. The cache is per node and
        # keyed by origin plus endpoint, so every test here asking the hosted
        # instance the same question would share one entry and the first to run
        # would answer for the rest. The cache tests below own their origins.
        cache: Keyword.get(opts, :cache, false)
      )

    handle
  end

  defp state(handle), do: elem(handle, 1)

  defp own_origin,
    do: "https://chicmoz-#{System.unique_integer([:positive])}.example.org/v1/local"

  defp drain(acc \\ []) do
    receive do
      {:request, host, endpoint} -> drain([{host, endpoint} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp endpoints, do: Enum.map(drain(), &elem(&1, 1))

  defp hosts, do: Enum.map(drain(), &elem(&1, 0))

  defp patched(name, changes) do
    name |> fixture() |> Jason.decode!() |> Map.merge(changes) |> Jason.encode!()
  end

  describe "sources" do
    test "the temporary path is carried as data, with its network and its dated status" do
      assert {url, "MAINNET", :temporary_path} = Aztec.sources()[@chain]

      # The operational fact this backend exists around: the segment standing
      # where a key would stand says out loud that it is temporary.
      assert url == "https://api.aztecscan.xyz/v1/temporary-api-key"
    end

    test "a chain with no source is refused rather than guessed at" do
      assert {:error, {:unsupported_chain, "aztec:testnet"}} = Aztec.new("aztec:testnet")
      assert {:error, {:unsupported_chain, "eip155:1"}} = Aztec.new("eip155:1")
    end

    test "the self-hosted fallback is the same module with another base url" do
      assert {:ok, {Aztec, %{source: :chicmoz, base_url: base_url}} = fallback} =
               Aztec.new(@chain, base_url: "https://chicmoz.example.org/v1/local/")

      assert base_url == "https://chicmoz.example.org/v1/local"

      # Two names for one module: `backend/0` is the chain that config and a
      # router's failover order are written against, and `backend/1` is the
      # source `Router.coverage/2` reports.
      assert Aztec.backend() == :aztec
      assert Backend.name(fallback) == :chicmoz

      {:ok, hosted} = Aztec.new(@chain)
      assert Backend.name(hosted) == :aztecscan

      # The name is the credential a handle presents rather than the option it
      # was built from, so configuring the hosted URL by hand is still the
      # temporary path.
      hosted_url = "https://api.aztecscan.xyz/v1/temporary-api-key"
      {:ok, configured} = Aztec.new(@chain, base_url: hosted_url)
      assert Backend.name(configured) == :aztecscan
    end

    test "a base url that cannot be dialled is refused at construction, not per read" do
      assert {:error, {:invalid_base_url, :scheme}} =
               Aztec.new(@chain, base_url: "http://chicmoz.example.org/v1/local")

      assert {:error, {:invalid_base_url, :host}} =
               Aztec.new(@chain, base_url: "https:///v1/local")
    end

    test "the rate limit is seeded and labelled, and a caller can still override it" do
      assert Aztec.rate_limit() == [capacity: 5, refill_per_second: 1.0]

      assert {:ok, {Aztec, %{http_opts: seeded}}} = Aztec.new(@chain)
      assert seeded[:rate_limit] == [capacity: 5, refill_per_second: 1.0]

      own = [capacity: 2, refill_per_second: 0.5]
      assert {:ok, {Aztec, %{http_opts: given}}} = Aztec.new(@chain, http_opts: [rate_limit: own])
      assert given[:rate_limit] == own
    end
  end

  describe "capabilities" do
    test "the declared set is exactly what the surface answers" do
      # Asserted rather than described, so a callback added or dropped without
      # a probe behind it is a red test here instead of a surprise at a router.
      assert Aztec.capabilities(state(handle(%{}))) == [
               :get_transaction,
               :get_block,
               :contract_metadata
             ]
    end

    test "token_balances is absent, and nothing stands in for it" do
      # The central point of issue #1030. A private note is unobservable by
      # construction, so an empty page would be a lie a caller cannot tell
      # apart from an account holding nothing.
      handle = handle(%{})

      refute Backend.supports?(handle, :token_balances)

      # Any arity. The callback is `token_balances/3` since the cursor
      # amendment, so a check pinned to the old arity would pass on a module
      # that had grown the new one.
      refute Enum.any?(Aztec.__info__(:functions), &match?({:token_balances, _arity}, &1))

      assert {:error, {:unsupported, :token_balances}} =
               Backend.call(handle, :token_balances, [@instance, []])

      # And through a router whose only source for this chain is this one.
      assert {:error, {:unsupported, :token_balances}} =
               Router.call(Router.new([handle]), @chain, :token_balances, [@instance, []])

      # Refused before anything left the process, so there is no empty page
      # anywhere in the path either.
      assert [] == drain()
    end

    test "the account-shaped and private-shaped reads are all absent" do
      handle = handle(%{})

      for callback <- [
            :account_info,
            :list_transactions,
            :list_token_transfers,
            :get_logs,
            :list_nfts,
            :read_contract,
            :resolve_name,
            :raw_request
          ] do
        refute Backend.supports?(handle, callback), "#{callback} is declared"

        assert match?({:error, {:unsupported, ^callback}}, Backend.call(handle, callback, [nil])),
               "#{callback} answered something"
      end
    end

    test "coverage for this chain is smaller than an EVM chain's, which is the point" do
      # ADR-0039 decision 3: absence is the answer, and coverage/2 is what
      # makes the smaller surface legible to an operator instead of arriving as
      # an error per call. Polygon is the comparison because no test in this
      # suite records a failure against that host.
      {:ok, evm} = Blockscout.new("eip155:137")
      router = Router.new([handle(%{}), evm])

      aztec = Router.coverage(router, @chain)
      blockscout = Router.coverage(router, "eip155:137")

      assert map_size(aztec) < map_size(blockscout)
      assert aztec[:chain_info] == [:aztecscan]
      assert aztec[:block_height] == [:aztecscan]
      assert aztec[:get_transaction] == [:aztecscan]
      refute Map.has_key?(aztec, :token_balances)
      refute Map.has_key?(aztec, :list_transactions)
      # Named by its module, because one Blockscout handle is one host and
      # that backend declines `backend/1`.
      assert blockscout[:token_balances] == [:blockscout]
      assert blockscout[:list_transactions] == [:blockscout]
    end
  end

  describe "chain_info/1" do
    test "carries the two counters that exist and nils the two that do not" do
      handle =
        handle(%{
          "/l2/info" => fixture("info.json"),
          "/l2/stats/average-block-time" => fixture("average_block_time.json"),
          "/l2/stats/total-tx-effects" => fixture("total_tx_effects.json")
        })

      assert {:ok, info} = Backend.call(handle, :chain_info)

      assert info.chain_ref == @chain
      # Upstream sends this as a JSON string, so the value asserts the parse
      # as much as the reading.
      assert info.average_block_time_ms == 63_555
      assert info.total_transactions == 36_869
      # A height exists on this chain and a count of blocks does not. Reading
      # the former as the latter is the mistake ADR-0038 records.
      assert info.total_blocks == nil
      # No account resource, so no count of accounts.
      assert info.total_addresses == nil
    end

    test "a number that only partly parses fails the read instead of being truncated" do
      # `Integer.parse/1` answers `{1, ".5e18"}`, `{1, "e18"}`, `{0, "x1f"}`
      # and `{12, "abc"}` for the first four, so accepting `{number, _rest}`
      # handed a caller 1, 1, 0 and 12 as an average block time. A wrong
      # number is worse than no number: nothing downstream can tell it apart
      # from a real one.
      for probe <- ["1.5e18", "1e18", "0x1f", "12abc", true] do
        handle =
          handle(%{
            "/l2/info" => fixture("info.json"),
            "/l2/stats/average-block-time" => Jason.encode!(probe),
            "/l2/stats/total-tx-effects" => fixture("total_tx_effects.json")
          })

        assert {:error, {:decode_failed, :average_block_time_ms}} =
                 Backend.call(handle, :chain_info),
               "#{inspect(probe)} was accepted"
      end
    end

    test "a source pointed at another network is refused before its counters are read" do
      handle = handle(%{"/l2/info" => ~s({"l2NetworkId":"TESTNET","l1ChainId":11155111})})

      assert {:error, {:decode_failed, :network_mismatch}} = Backend.call(handle, :chain_info)

      # The failure mode a configured fallback actually has is a URL aimed at
      # the wrong network, and it is the only one that answers confidently.
      assert endpoints() == ["/l2/info"]
    end
  end

  describe "block_height/1" do
    test "the height and its finalized half come out of one response" do
      handle = handle(%{"/l2/tips" => fixture("tips.json")})

      assert {:ok, height} = Backend.call(handle, :block_height)

      assert height.unit == :block
      assert height.height == 83_597
      assert height.finalized_height == 83_561
      assert height.finalized_height < height.height

      # One request, which is the whole reason `l2/tips` is used instead of
      # composing a height with a separately fetched finality.
      assert endpoints() == ["/l2/tips"]
    end

    test "the indexer reports the measure this source publishes and omits the two it does not" do
      handle = handle(%{"/l2/tips" => fixture("tips.json")})

      assert {:ok, %{indexer: indexer}} = Backend.call(handle, :block_height)

      assert indexer.finished? == true
      assert indexer.lag_seconds == 24
      refute Map.has_key?(indexer, :indexed_ratio)
      refute Map.has_key?(indexer, :lag_blocks)
    end

    test "an unreadable staleness costs the lag, never the height" do
      # `stalenessMs` is diagnostic and `block_height/1` is a required
      # callback, so an upstream shipping one bad optional field must not take
      # the height down with it -- `{:decode_failed, _}` fails the router over,
      # and every source publishes the same field.
      for probe <- [~s("1.5e18"), ~s("12abc"), "true", "null"] do
        body = ~s({"tips":{"proposed":{"number":7}},"stalenessMs":#{probe}})

        assert {:ok, height} = Backend.call(handle(%{"/l2/tips" => body}), :block_height),
               "#{probe} failed the read"

        assert height.height == 7

        # No age, rather than a truncated one. Same answer a negative age gets.
        refute Map.has_key?(height.indexer, :lag_seconds)
      end
    end

    test "a ladder whose finalized rung is above the head is refused, not repaired" do
      # The one invariant the height shape exists to express. A consumer
      # computing confirmation depth from an inverted pair reads a negative
      # number, so the read fails and the router tries the other source.
      body = ~s({"tips":{"proposed":{"number":100},"finalized":{"block":{"number":101}}}})

      assert {:error, {:decode_failed, :tips}} =
               Backend.call(handle(%{"/l2/tips" => body}), :block_height)
    end

    test "a chain with no finalized rung yet reports nil rather than zero" do
      body = ~s({"tips":{"proposed":{"number":3}},"stale":true,"stalenessMs":90000})

      assert {:ok, height} = Backend.call(handle(%{"/l2/tips" => body}), :block_height)

      assert height.height == 3
      assert height.finalized_height == nil
      assert height.indexer == %{finished?: false, lag_seconds: 90}
    end

    test "a body that is not the tips shape at all is a decode failure, not a crash" do
      assert {:error, {:decode_failed, :tips}} =
               Backend.call(handle(%{"/l2/tips" => ~s({"error":"nope"})}), :block_height)

      assert {:error, {:decode_failed, :not_an_object}} =
               Backend.call(handle(%{"/l2/tips" => "83597"}), :block_height)
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle =
        handle(%{"/l2/tips" => fixture("tips.json")}, cache: true, base_url: own_origin())

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert endpoints() == ["/l2/tips", "/l2/tips"]
    end
  end

  describe "beyond the contract" do
    test "rollup/1 is where the two facts that identify an L2 are visible" do
      # `chain_info()` has no field for an L1 chain id or a rollup version,
      # and widening a shape shared by every chain for one chain's identity is
      # what ADR-0033 section 7 refuses.
      handle = handle(%{"/l2/info" => fixture("info.json")})

      assert {:ok, rollup} = Aztec.rollup(state(handle))

      assert rollup.network == "MAINNET"
      assert rollup.l1_chain_id == 1
      assert rollup.rollup_version == "4248422647"
      assert rollup.l1_rollup == {:evm, "0x91ff8bbd8ebb07893010d50a48a1609e5ebd8e34"}
      assert rollup.l1_registry == {:evm, "0x35b22e09ee0390539439e24f06da43d83f90e298"}

      # Normalized down to the two anchors that identify the rollup, rather
      # than the upstream's eleven-address map passed through.
      refute Map.has_key?(rollup, :l1ContractAddresses)
    end

    test "tips/1 carries the whole ladder, which is what finalized_height cannot" do
      handle = handle(%{"/l2/tips" => fixture("tips.json")})

      assert {:ok, tips} = Aztec.tips(state(handle))

      assert tips.proposed == 83_597
      assert tips.checkpointed == 83_597
      assert tips.proven == 83_589
      assert tips.finalized == 83_561
      assert tips.stale? == false
      assert tips.staleness_ms == 24_815
      assert tips.degraded? == false
    end
  end

  describe "the response cache" do
    test "a repeated read is served from the cache, and the upstream is asked once" do
      routes = %{
        "/l2/info" => fixture("info.json"),
        "/l2/stats/average-block-time" => fixture("average_block_time.json"),
        "/l2/stats/total-tx-effects" => fixture("total_tx_effects.json")
      }

      handle = handle(routes, cache: true, base_url: own_origin())

      assert {:ok, first} = Backend.call(handle, :chain_info)
      assert {:ok, second} = Backend.call(handle, :chain_info)

      assert first == second
      assert length(endpoints()) == 3
    end

    test "a non-2xx is not cached, so a withdrawn prefix cannot outlive the breaker" do
      handle =
        handle(%{"/l2/tips" => {403, "<html>challenge</html>"}},
          cache: true,
          base_url: own_origin()
        )

      assert {:error, {:http, 403}} = Backend.call(handle, :block_height)
      assert {:error, {:http, 403}} = Backend.call(handle, :block_height)

      assert length(endpoints()) == 2
    end

    test "two key prefixes on one host do not share a cache entry" do
      # The credential is a path segment on this upstream, and
      # `Raxol.Web3.HTTP` keys on `{origin_id, fragment}` where an origin id is
      # only `scheme://host:port`. A fragment that was the endpoint path alone
      # named the prefix in neither half, so a second or rotated key on the same
      # host was served the first key's body.
      host = "https://chicmoz-#{System.unique_integer([:positive])}.example.org"
      endpoint = "/l2/tx-effects/#{@mined}"

      first =
        handle(%{endpoint => fixture("tx_effects.json")},
          cache: true,
          base_url: host <> "/v1/key-one"
        )

      second =
        handle(%{endpoint => patched("tx_effects.json", %{"blockHeight" => 90_001})},
          cache: true,
          base_url: host <> "/v1/key-two"
        )

      assert {:ok, %{block: 83_582}} = Backend.call(first, :get_transaction, [@mined])
      assert {:ok, %{block: 90_001}} = Backend.call(second, :get_transaction, [@mined])

      assert length(endpoints()) == 2
    end
  end

  describe "get_transaction/2" do
    test "a mined transaction comes from the effect record, with no counterparties" do
      handle = handle(%{"/l2/tx-effects/#{@mined}" => fixture("tx_effects.json")})

      assert {:ok, tx} = Backend.call(handle, :get_transaction, [@mined])

      assert tx.hash == @mined
      assert tx.status == :success
      assert tx.block == 83_582
      assert tx.fee == 6_466_668_918_033_303_460
      assert DateTime.to_unix(tx.timestamp, :millisecond) == 1_789_380_527_000

      # The chain, not the source. The record carries `feePayer` and
      # `initiator`, and neither is a sender: promoting either would produce a
      # field a caller cannot tell apart from a measured one.
      assert tx.from == nil
      assert tx.to == nil
      assert tx.value == nil
      assert tx.method == nil
    end

    test "a transaction still in the pool is pending, which is read rather than assumed" do
      handle = handle(%{"/l2/txs/#{@pooled}" => fixture("tx_pending.json")})

      assert {:ok, tx} = Backend.call(handle, :get_transaction, [@pooled])

      assert tx.status == :pending
      assert tx.block == nil
      # Gas limits and max fees are bounds, not a fee. What was paid is known
      # once it is mined.
      assert tx.fee == nil
      assert DateTime.to_unix(tx.timestamp, :millisecond) == 1_788_027_417_612

      # The effect first, the pool second: `l2/txs` is the pending pool and
      # answers 404 for a hash that has been mined.
      assert endpoints() == ["/l2/tx-effects/#{@pooled}", "/l2/txs/#{@pooled}"]
    end

    test "a hash that is neither mined nor pooled is not found" do
      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle(%{}), :get_transaction, [@mined])
    end

    test "a nonzero revert code is reverted, and an unreadable one is refused" do
      reverted = patched("tx_effects.json", %{"revertCode" => %{"code" => 1}})

      assert {:ok, %{status: :reverted}} =
               Backend.call(
                 handle(%{"/l2/tx-effects/#{@mined}" => reverted}),
                 :get_transaction,
                 [@mined]
               )

      # A mined effect whose revert code cannot be read is not a transaction of
      # unknown status, because the contract has no such status.
      unreadable = patched("tx_effects.json", %{"revertCode" => nil})

      assert {:error, {:decode_failed, :revert_code}} =
               Backend.call(
                 handle(%{"/l2/tx-effects/#{@mined}" => unreadable}),
                 :get_transaction,
                 [@mined]
               )
    end

    test "a revert code that only partly parses is refused, never read as success" do
      # The one field where a truncating parse changes an ANSWER rather than a
      # statistic: `{0, "x1f"}` for "0x1f" reads a reverted transaction as
      # successful, and a caller settling on that has no way to tell.
      for probe <- ["0x1f", "1.5e18", "1e18", "12abc", true] do
        body = patched("tx_effects.json", %{"revertCode" => %{"code" => probe}})

        assert {:error, {:decode_failed, :revert_code}} =
                 Backend.call(
                   handle(%{"/l2/tx-effects/#{@mined}" => body}),
                   :get_transaction,
                   [@mined]
                 ),
               "#{inspect(probe)} was accepted"
      end
    end

    test "a hash cannot reshape the path it is interpolated into" do
      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle(%{}), :get_transaction, ["../../l2/info?x=1"])

      # Percent-encoded to the unreserved set, so the separators a caller
      # supplied are data in one segment rather than structure in the path.
      encoded = "..%2F..%2Fl2%2Finfo%3Fx%3D1"

      assert endpoints() == ["/l2/tx-effects/#{encoded}", "/l2/txs/#{encoded}"]
    end
  end

  describe "get_block/2" do
    test "a block maps to the contract's shape, and the coinbase is an L1 address" do
      handle = handle(%{"/l2/blocks/83582" => fixture("block.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [83_582])

      assert block.height == 83_582
      assert block.hash == "0x104fcc7b43c69f0f63b465740b8d0b412b57a46e899caed25727b3de3e745027"
      assert block.transactions_count == 1
      assert DateTime.to_unix(block.timestamp, :millisecond) == 1_789_380_527_000

      # 20 bytes, paid on L1, so the EVM tag is the accurate one even inside an
      # Aztec block.
      assert block.miner == {:evm, "0x06a8eecfba446ca78704fd1ed002cb13cec12bff"}
    end

    test "the head can be asked for by name, because the upstream takes a height or a tag" do
      handle = handle(%{"/l2/blocks/latest" => fixture("block.json")})

      assert {:ok, %{height: 83_582}} = Backend.call(handle, :get_block, ["latest"])
    end

    test "a block whose height cannot be read is a decode failure" do
      handle = handle(%{"/l2/blocks/1" => ~s({"hash":"0xabc"})})

      assert {:error, {:decode_failed, :block}} = Backend.call(handle, :get_block, [1])
    end
  end

  describe "contract_metadata/2" do
    test "an instance answers the shape, and verified? is measured rather than defaulted" do
      {:aztec, address} = @instance
      handle = handle(%{"/l2/contract-instances/#{address}" => fixture("contract_instance.json")})

      assert {:ok, metadata} = Backend.call(handle, :contract_metadata, [@instance])

      # Verification is a real concept here: chicmoz serves verify-source and a
      # verifiedSourceOnly filter, and that filter answered `[]` on 2026-09-14
      # while all 23 mainnet instances carried a null sourceCodeUrl. So false
      # means no source is registered, not that a verification failed.
      assert metadata.verified? == false
      assert metadata.name == nil
      # `selectorMap` carries no argument types, so it is not an ABI, and no
      # mainnet instance has an artifact to record a mapping against.
      assert metadata.abi == nil
      assert metadata.language == nil
      assert metadata.compiler_version == nil
      assert metadata.proxy_type == nil
    end

    test "a registered source url and artifact name are what fill the two fields that exist" do
      # The fields are present and null in every recorded mainnet instance, so
      # this row sets them to prove the mapping rather than the default.
      {:aztec, address} = @instance

      body =
        patched("contract_instance.json", %{
          "sourceCodeUrl" => "https://example.org/src",
          "artifactContractName" => "TokenContract"
        })

      handle = handle(%{"/l2/contract-instances/#{address}" => body})

      assert {:ok, %{verified?: true, name: "TokenContract"}} =
               Backend.call(handle, :contract_metadata, [@instance])
    end

    test "a non-Aztec account reference is refused by tag, before any request" do
      handle = handle(%{})

      assert {:error, {:unsupported_account_ref, :evm}} =
               Backend.call(handle, :contract_metadata, [{:evm, "0xd8dA6BF269"}])

      assert {:error, {:unsupported_account_ref, :unknown}} =
               Backend.call(handle, :contract_metadata, ["0xd8dA6BF269"])

      assert [] == drain()
    end

    test "an address with no deployed instance is not found rather than an empty record" do
      handle = handle(%{})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :contract_metadata, [@instance])
    end
  end

  describe "the temporary path's revocation" do
    # Each of these owns its origins. The breaker table is per node and keyed
    # by origin, so a test that asserts on breaker state has to be the only
    # writer of the key it reads, and a shared host would make that a race with
    # an async sibling.
    defp pair(primary_answer, opts \\ []) do
      suffix = System.unique_integer([:positive])
      primary_url = "https://revoked-#{suffix}.example.org/v1/temporary-api-key"
      fallback_url = "https://chicmoz-#{suffix}.example.org/v1/local"

      exchange = fn vetted, request, _opts ->
        send(self(), {:request, vetted.hostname, endpoint(request.path)})

        if String.starts_with?(vetted.hostname, "revoked-") do
          primary_answer
        else
          {:ok, %{status: 200, headers: [], body: fixture("tips.json")}}
        end
      end

      http_opts = [{:exchange, exchange} | Keyword.merge(unmetered(), opts)]

      {:ok, primary} =
        Aztec.new(@chain, base_url: primary_url, http_opts: http_opts, cache: false)

      {:ok, fallback} =
        Aztec.new(@chain, base_url: fallback_url, http_opts: http_opts, cache: false)

      {primary, fallback, {:origin, Origin.id(URI.new!(primary_url))}}
    end

    defp withdrawn do
      # The measured shape, 2026-09-14: substituting a bogus key segment
      # answers 404 text/plain from the edge, not 403.
      {:ok, %{status: 404, headers: [], body: fixture("revoked_prefix_404.txt")}}
    end

    defp challenged do
      # The other shape a key-gated edge answers, and the one Blockscout's
      # chain 4663 row measured on 2026-09-13. The body is irrelevant: a
      # non-2xx carries none onward.
      {:ok, %{status: 403, headers: [], body: "<html>challenge</html>"}}
    end

    test "a withdrawn prefix 404s an endpoint that has no resource to miss" do
      {primary, _fallback, _key} = pair(withdrawn())

      # `/l2/tips` takes no parameter, so a 404 on it cannot mean the resource
      # is absent. Every endpoint under a withdrawn prefix answers this way.
      #
      # This pinned `{:upstream_refused, :auth}`, which was chosen for its
      # place in the router's failover set rather than for being true: `:auth`
      # is "this deployment does not hold the credential" everywhere else in
      # the package, and a withdrawn URL prefix is not a credential anyone can
      # hand us. The failover is unchanged; the reason now says what happened.
      assert {:error, {:source_unavailable, :endpoint}} = Backend.call(primary, :block_height)
    end

    test "the router fails over to the configured chicmoz instance" do
      # A threshold of one failure for this pair, so coverage is free to move
      # on the first bad answer. That it does not is the point of the 404 test
      # below, and here it is what an operator reads while it happens.
      {primary, fallback, _key} = pair(withdrawn(), breaker: [failure_threshold: 1])
      router = Router.new([primary, fallback])
      _ignored = drain()

      # Two sources, named apart. `[:aztec, :aztec]` would say that two are
      # believed healthy and not which of them is the temporary path, and
      # which one is the whole question during a revocation.
      assert Router.coverage(router, @chain)[:block_height] == [:aztecscan, :chicmoz]

      assert {:ok, %{height: 83_597}} = Router.call(router, @chain, :block_height)

      asked = hosts()
      assert Enum.any?(asked, &String.starts_with?(&1, "revoked-"))
      assert Enum.any?(asked, &String.starts_with?(&1, "chicmoz-"))

      # The survivor served the read and coverage still names both, because a
      # 404 records health: the report cannot narrow here, so the names are
      # the only part of it that moves with the failover.
      assert Router.coverage(router, @chain)[:block_height] == [:aztecscan, :chicmoz]
    end

    test "a 404 records no breaker failure, which is why the classification carries the failover" do
      # `Raxol.Web3.HTTP` records a 404 as health, by design: a definitive
      # answer about a missing thing is a healthy upstream. So health alone can
      # never move a revoked prefix off the front of the candidate list.
      {primary, _fallback, key} = pair(withdrawn())

      assert {:error, {:source_unavailable, :endpoint}} = Backend.call(primary, :block_height)

      assert CircuitBreaker.status(Tables.breakers(), key).failures == 0
    end

    test "a challenge response does record a breaker failure, and also fails over" do
      {primary, fallback, key} = pair(challenged())

      assert {:error, {:http, 403}} = Backend.call(primary, :block_height)
      assert CircuitBreaker.status(Tables.breakers(), key).failures == 1

      _ignored = drain()

      assert {:ok, %{height: 83_597}} =
               Router.call(Router.new([primary, fallback]), @chain, :block_height)

      assert Enum.any?(hosts(), &String.starts_with?(&1, "chicmoz-"))
    end

    test "an open breaker narrows coverage to the named survivor" do
      # The challenge shape, because it is the one that records a failure. At
      # a threshold of one the report goes from two sources to the one that is
      # left, and the transition is only legible because the two are named
      # apart.
      {primary, fallback, key} = pair(challenged(), breaker: [failure_threshold: 1])
      router = Router.new([primary, fallback])

      assert Router.coverage(router, @chain)[:block_height] == [:aztecscan, :chicmoz]

      assert {:error, {:http, 403}} = Backend.call(primary, :block_height)
      assert CircuitBreaker.status(Tables.breakers(), key).state == :open

      assert Router.coverage(router, @chain)[:block_height] == [:chicmoz]

      _ignored = drain()

      assert {:ok, %{height: 83_597}} = Router.call(router, @chain, :block_height)

      # The dial matches the report: the open source is not asked at all.
      assert [host] = hosts()
      assert String.starts_with?(host, "chicmoz-")
    end

    test "a 404 on an addressed endpoint is an answer, so the fallback is never asked" do
      # The other half of the split, and it is a routing decision rather than a
      # taste one: the fallback would answer the same thing about a hash that
      # does not exist, and asking it doubles the cost of every miss.
      {primary, fallback, _key} = pair(withdrawn())
      router = Router.new([primary, fallback])
      _ignored = drain()

      assert {:error, {:upstream_refused, :not_found}} =
               Router.call(router, @chain, :get_transaction, [@mined])

      refute Enum.any?(hosts(), &String.starts_with?(&1, "chicmoz-"))
    end
  end

  describe "against a real upstream" do
    # Generous bounds and an unmetered bucket, deliberately. What these prove
    # is that the dated claims in the moduledoc still hold, not that somebody
    # else's service is fast, and the seeded rate limit is a guess about their
    # budget rather than a property worth failing a build over.
    defp live do
      [
        cache: false,
        http_opts: [
          rate_limit: [capacity: 100, refill_per_second: 50.0],
          chunk_timeout_ms: 30_000,
          deadline_ms: 60_000
        ]
      ]
    end

    @tag :live_web3
    test "the temporary path still answers, and still identifies mainnet" do
      {:ok, handle} = Aztec.new(@chain, live())

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == @chain
      assert info.average_block_time_ms > 0
      assert info.total_transactions > 30_000
      assert info.total_blocks == nil
      assert info.total_addresses == nil

      assert {:ok, rollup} = Aztec.rollup(state(handle))
      assert rollup.network == "MAINNET"
      assert rollup.l1_chain_id == 1
      assert is_binary(rollup.rollup_version)
      assert {:evm, _rollup_address} = rollup.l1_rollup
      assert {:evm, _registry} = rollup.l1_registry
    end

    @tag :live_web3
    test "the unit claim re-probes: latest-height is a block number and slots outrun it" do
      {:ok, handle} = Aztec.new(@chain, live())

      assert {:ok, tips} = Aztec.tips(state(handle))
      assert tips.finalized <= tips.proven
      assert tips.proven <= tips.proposed

      # These two endpoints are deliberately not part of the backend:
      # `l2/latest-height` because `l2/tips` answers both halves of the height
      # at one moment, and the raw block because the block shape carries no
      # slot. The moduledoc's dated claims are about them, so the re-probe goes
      # through the guarded client directly rather than inventing a callback.
      base = "https://api.aztecscan.xyz/v1/temporary-api-key"
      opts = live()[:http_opts]

      assert {:ok, %{status: 200, body: body}} = HTTP.get(base <> "/l2/latest-height", opts)
      assert {latest, ""} = Integer.parse(String.trim(body))
      assert latest > 83_000

      # A bound rather than equality: the chain moves between two requests.
      assert abs(latest - tips.proposed) <= 5

      assert {:ok, %{status: 200, body: head}} = HTTP.get(base <> "/l2/blocks/latest", opts)
      assert {:ok, block} = Jason.decode(head)

      variables = block["header"]["globalVariables"]
      assert variables["blockNumber"] == String.to_integer(block["height"])
      assert variables["slotNumber"] > variables["blockNumber"]

      # The four-value ladder the moduledoc records, plus the transient it also
      # emits. A new value here is a drift worth a red test.
      assert block["nativeStatus"] in ~w(proposed checkpointed proven finalized unknown)
    end

    @tag :live_web3
    test "every declared callback answers against mainnet, and the absent ones stay absent" do
      {:ok, handle} = Aztec.new(@chain, live())

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :block
      assert height.height > 83_000
      assert height.finalized_height <= height.height
      assert height.indexer.finished? in [true, false]

      assert {:ok, tx} = Backend.call(handle, :get_transaction, [@mined])
      assert tx.hash == @mined
      assert tx.status == :success
      assert tx.from == nil

      assert {:ok, block} = Backend.call(handle, :get_block, [83_582])
      assert block.height == 83_582

      assert {:ok, metadata} = Backend.call(handle, :contract_metadata, [@instance])
      assert metadata.verified? == false

      assert {:error, {:unsupported, :token_balances}} =
               Backend.call(handle, :token_balances, [@instance, []])
    end
  end
end
