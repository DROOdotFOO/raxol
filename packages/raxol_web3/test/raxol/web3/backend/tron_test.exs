defmodule Raxol.Web3.Backend.TronTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.Era
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Tron
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @fixtures Path.expand("../../../fixtures/tron", __DIR__)

  # A Binance cold wallet, in both encodings, and they are the same account:
  # `Raxol.Web3.Tron.Address.to_hex/1` of the first is the second.
  @base58 "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @hex "41e28b3cfd4e0e909077821478e9fcb86b84be786e"

  @tx "ef3d8c0ab6c9d0624e0b7e72e2376924503bfd71d6990df33943254ed8d76938"

  # Recorded from the live upstreams on 2026-09-14 and trimmed to two items per
  # page. A fixture is not a mock: it is what the upstream actually said, which
  # is the only thing that makes "the shape changed" a red test rather than a
  # production surprise. None of these upstreams publishes a schema for its
  # tool results, and one of them publishes a schema its own tool violates.
  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # SQD Portal is one server behind both this backend and
  # `Raxol.Web3.Backend.Solana`, and it answers an unknown network the same
  # way whichever VM asked. The recorded refusal is read from the Solana
  # directory rather than copied into this one: two copies of one recording
  # is how the two backends came to classify it differently in the first
  # place.
  defp sqd_fixture(name) do
    @fixtures |> Path.join("../solana") |> Path.join(name) |> File.read!()
  end

  # Both limiters are given room, and the resolver answers without DNS. Every
  # test here talks to one of three real hostnames, so a shared bucket or
  # breaker would couple unrelated tests through it.
  defp unmetered do
    [
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: &stub_resolver/2
    ]
  end

  defp stub_resolver(_charlist, :inet), do: {:ok, [{93, 184, 216, 34}]}
  defp stub_resolver(_charlist, :inet6), do: {:ok, []}

  # One seam for three session models. It routes on the JSON-RPC method, and on
  # the tool name for a `tools/call`, so the same arrangement drives a stateless
  # POST and a legacy handshake plus session.
  #
  # The recorded envelope is re-stamped with the id the client actually sent:
  # answering a stale id would leave the request pending and the test would
  # time out instead of exercising the mapping.
  defp seam(routes, opts \\ []) do
    context = %{
      routes: routes,
      owner: self(),
      # Measured 2026-09-14: TronGrid frames `data: {...}` with the space and
      # TronScan frames `data:{...}` without one, so a strict parser breaks on
      # one of them and each source replays its own framing here.
      spacer: Keyword.get(opts, :spacer, " "),
      initialize: Keyword.get(opts, :initialize, "trongrid_initialize.json"),
      session: Keyword.get(opts, :session, "11111111-2222-3333-4444-555555555555"),
      hold_ms: Keyword.get(opts, :hold_ms, 0)
    }

    fn _vetted, request, _exchange_opts ->
      request.body |> IO.iodata_to_binary() |> Jason.decode!() |> answer(context)
    end
  end

  # The transport probes an origin it holds no era verdict for with
  # `server/discover`, and all three of these upstreams answer it the way a
  # legacy server does: JSON-RPC -32601. Answering it here rather than
  # pre-seeding alone is what keeps a cache miss -- a fresh table, an expired
  # TTL, a session-rejected re-probe -- a mapped verdict instead of a crash in
  # the seam.
  defp answer(%{"method" => "server/discover", "id" => id}, _context) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_601, "message" => "Method not found"}
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  defp answer(%{"method" => "initialize", "id" => id}, context) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"content-type", "application/json"},
         {"mcp-session-id", context.session}
       ],
       body: restamp(fixture(context.initialize), id)
     }}
  end

  defp answer(%{"method" => "notifications/initialized"}, _context) do
    {:ok, %{status: 202, headers: [{"content-type", "application/json"}], body: ""}}
  end

  defp answer(%{"method" => "tools/call"} = envelope, context) do
    %{"id" => id, "params" => %{"name" => tool, "arguments" => arguments}} = envelope
    reference = make_ref()
    send(context.owner, {:called, tool, arguments, reference})
    hold(context.owner, reference, context.hold_ms)

    routed(route(context.routes, tool, arguments), tool, id, context)
  end

  # What a route resolves to: a client-level failure, a bare status, a recorded
  # body, or the name of a recording to read.
  defp routed({:ok, {:error, reason}}, _tool, _id, _context), do: {:error, reason}

  defp routed({:ok, {:status, status}}, _tool, _id, _context) do
    {:ok, %{status: status, headers: [], body: ""}}
  end

  defp routed({:ok, {:body, body}}, _tool, id, context), do: streamed(body, id, context)

  defp routed({:ok, name}, _tool, id, context) when is_binary(name) do
    name |> fixture() |> streamed(id, context)
  end

  defp routed(:error, tool, _id, _context) do
    flunk("no recorded response for tool #{tool}")
  end

  defp streamed(body, id, context) do
    {:ok,
     %{
       status: 200,
       headers: [{"content-type", "text/event-stream"}],
       body: frame(body, id, context.spacer)
     }}
  end

  # Only a `tools/call` is bracketed, so the handshake does not appear in the
  # concurrency log. The sleep is what makes an overlap observable at all.
  defp hold(_owner, _reference, 0), do: :ok

  defp hold(owner, reference, ms) do
    Process.sleep(ms)
    send(owner, {:returned, reference})
  end

  # A route may be a fixture name or a function of the arguments, because one
  # read can call one tool twice with different arguments and the whole point
  # of the second call is that it lands on a different block.
  defp route(routes, tool, arguments) do
    case Map.fetch(routes, tool) do
      {:ok, fun} when is_function(fun, 1) -> {:ok, fun.(arguments)}
      other -> other
    end
  end

  defp sampled_block(%{"id_or_num" => _number}), do: "trongrid_block_earlier.sse"
  defp sampled_block(_head), do: "trongrid_block.sse"

  defp frame(recorded, id, spacer) do
    "event: message\ndata:" <> spacer <> restamp(recorded, id) <> "\n\n"
  end

  defp restamp(recorded, id) do
    recorded
    |> payload()
    |> Jason.decode!()
    |> Map.put("id", id)
    |> Jason.encode!()
  end

  defp payload(recorded) do
    case Regex.run(~r/^data:[ ]?(.*)$/m, recorded) do
      [_line, data] -> data
      nil -> recorded
    end
  end

  defp account_fixture_with_balance(value) do
    envelope = fixture("trongrid_account_info.sse") |> payload() |> Jason.decode!()
    result = envelope["result"]
    content = result["content"]
    inner = content |> hd() |> Map.fetch!("text") |> Jason.decode!()

    changed =
      Map.update!(inner, "data", fn [account | rest] ->
        [Map.put(account, "balance", value) | rest]
      end)

    changed_content =
      List.update_at(content, 0, &Map.put(&1, "text", Jason.encode!(changed)))

    changed_result =
      result
      |> Map.put("content", changed_content)
      |> Map.put("structuredContent", changed)

    envelope |> Map.put("result", changed_result) |> Jason.encode!()
  end

  # -- handles -----------------------------------------------------------------

  defp stateful(source, routes, opts \\ []) do
    eras = :ets.new(:eras, [:public, :set])
    breakers = Keyword.get_lazy(opts, :breakers, fn -> :ets.new(:breakers, [:public, :set]) end)
    Era.remember(eras, Era.key(URI.new!(Tron.sources()[source].url)), :legacy)

    seam_opts =
      opts
      |> Keyword.put(:spacer, if(source == :tronscan, do: "", else: " "))
      |> Keyword.put(:initialize, "#{source}_initialize.json")

    # `:restart` is `:temporary` for the tests that kill the client on
    # purpose. Under the default the test supervisor restarts it, and the
    # replacement races teardown of the ETS tables above, which is noise about
    # the harness rather than about the backend.
    spec =
      Tron.client_spec(source,
        name: :"tron_#{source}_#{System.unique_integer([:positive])}",
        exchange: seam(routes, seam_opts),
        tables: %{eras: eras, breakers: breakers},
        resolver: &stub_resolver/2
      )
      |> Map.put(:restart, Keyword.get(opts, :restart, :permanent))

    client = start_supervised!(spec)
    await_ready(client)

    {:ok, handle} =
      Tron.new(source, client: client, cache: Keyword.get(opts, :cache, false))

    handle
  end

  # The handshake is asynchronous: `initialize` is dispatched from `init/1` and
  # its reply arrives as a message, so a call issued immediately answers
  # `{:not_ready, :initializing}`. Waiting here rather than retrying inside the
  # backend is deliberate: a client that is not ready yet is the client's
  # business, and a retry in a read would hide a stuck handshake.
  defp await_ready(client, remaining \\ 400) do
    case Client.status(client) do
      %{status: :ready} ->
        :ok

      %{status: status} when remaining == 0 ->
        flunk("client never became ready, stuck in #{inspect(status)}")

      _still_starting ->
        Process.sleep(5)
        await_ready(client, remaining - 1)
    end
  end

  defp sqd(routes, opts \\ []) do
    {:ok, handle} =
      Tron.new(:sqd,
        http_opts: [{:exchange, seam(routes)} | unmetered()],
        cache: Keyword.get(opts, :cache, false)
      )

    handle
  end

  defp state(handle), do: elem(handle, 1)

  defp calls(acc \\ []) do
    receive do
      {:called, tool, arguments, _reference} -> calls([{tool, arguments} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain do
    receive do
      _anything -> drain()
    after
      0 -> :ok
    end
  end

  # -- the height fixtures, shared by several describes ------------------------

  defp trongrid_height_routes do
    %{
      "getBlock" => "trongrid_block.sse",
      "solidityGetBlock" => "trongrid_solidity_block.sse"
    }
  end

  describe "sources and chain references" do
    test "carries the measured session and concurrency facts as data" do
      sources = Tron.sources()

      assert sources.trongrid.concurrency == :pooled
      assert sources.trongrid.stateful?
      assert sources.trongrid.tools == 149

      assert sources.tronscan.concurrency == :serialized
      assert sources.tronscan.stateful?
      assert sources.tronscan.tools == 119

      assert sources.sqd.concurrency == :stateless
      refute sources.sqd.stateful?
    end

    test "accepts the registered CAIP-2 form and the alias, and canonicalizes" do
      assert {:ok, handle} = Tron.new(:sqd, chain_ref: "tron:mainnet")
      assert state(handle).chain_ref == "tron:0x2b6653dc"

      assert {:ok, other} = Tron.new(:sqd, chain_ref: "tron:0x2b6653dc")
      assert state(other).chain_ref == state(handle).chain_ref

      assert Tron.supported_chain_ids(state(handle)) == ["tron:0x2b6653dc"]
    end

    test "refuses a chain reference that is not in the dated alias table" do
      assert {:error, {:unsupported_chain, "tron:shasta"}} =
               Tron.new(:sqd, chain_ref: "tron:shasta")

      assert {:error, {:unsupported_chain, "eip155:1"}} = Tron.new(:sqd, chain_ref: "eip155:1")
    end

    test "a stateful source refuses to build a handle without a client" do
      # The alternative would be a handle that looks usable and fails on first
      # read, and there is no honest default: this module opens no socket of
      # its own and ADR-0037's client is the only sanctioned path to a session.
      assert {:error, :client_required} = Tron.new(:trongrid)
      assert {:error, :client_required} = Tron.new(:tronscan)
      assert {:ok, _handle} = Tron.new(:sqd)
    end

    test "the client spec carries the measured concurrency policy, not a default" do
      assert %{start: {_module, :start_link, [trongrid]}} = Tron.client_spec(:trongrid)
      assert Keyword.fetch!(trongrid, :concurrency) == :pooled
      assert Keyword.fetch!(trongrid, :url) == "https://mcp.trongrid.io/mcp"

      assert %{start: {_module, :start_link, [tronscan]}} = Tron.client_spec(:tronscan)
      assert Keyword.fetch!(tronscan, :concurrency) == :serialized
    end

    test "a handle names its source, while the module stays :tron" do
      # `backend/0` is the chain and is what config and a failover order are
      # keyed on, so it does not become per-source. `backend/1` is the handle,
      # and the two are different questions: without the second, three handles
      # over three upstreams are indistinguishable to everything that reports
      # on them.
      assert Tron.backend() == :tron

      for source <- [:trongrid, :tronscan] do
        handle = declared(source)
        assert Backend.name(handle) == source
      end

      assert Backend.name(sqd(%{})) == :sqd
    end
  end

  describe "capabilities" do
    test "every declared capability is implemented" do
      for source <- [:trongrid, :tronscan] do
        handle = declared(source)

        for callback <- Tron.capabilities(elem(handle, 1)) do
          assert Backend.supports?(handle, callback),
                 "#{source} declares #{callback} without implementing it"
        end
      end
    end

    test "the archive source declares nothing, and a read on it is refused" do
      handle = sqd(%{})

      assert Tron.capabilities(state(handle)) == []
      refute Backend.supports?(handle, :account_info)

      # Absent, not empty. An empty page from a source that cannot be asked the
      # question is the one shape a gate could read as "holds nothing".
      assert {:error, {:unsupported, :account_info}} =
               Backend.call(handle, :account_info, [{:tron, @base58}])

      assert {:error, {:unsupported, :list_transactions}} =
               Backend.call(handle, :list_transactions, [{:tron, @base58}, []])
    end

    test "the explorer source declines list_transactions and the node source declares it" do
      # Measured 2026-09-14: TronScan's account-scoped transaction tools take a
      # single `fromAddress` or `toAddress`, so "the transactions of this
      # address" would be two half-answers stitched together. TronGrid's
      # `getAccountTransactions` takes one address and answers both directions.
      trongrid = declared(:trongrid)
      tronscan = declared(:tronscan)

      assert Backend.supports?(trongrid, :list_transactions)
      refute Backend.supports?(tronscan, :list_transactions)
      assert Backend.supports?(tronscan, :list_token_transfers)
    end
  end

  # A handle that opens nothing, for the declarations alone. `capabilities/1`
  # and `supports?/2` read only the source, so a client is not needed to ask
  # what a source claims to answer.
  defp declared(source) do
    {:ok, handle} = Tron.new(source, client: self())
    handle
  end

  describe "block_height/1" do
    test "the node source takes finalized from the irreversible view, not the head" do
      handle = stateful(:trongrid, trongrid_height_routes())

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height == 86_236_775
      # `solidityGetBlock`, which is what the 25 `solidity*` tools are for. The
      # head fixture says 86,236,775 and the irreversible one 86,236,757, so a
      # backend that reported the head twice would fail here.
      assert height.finalized_height == 86_236_757
      assert height.finalized_height < height.height
      # No indexing status is published by this upstream, and a cheerful
      # `%{finished?: true}` would claim a component exists and is healthy.
      assert height.indexer == nil

      assert [{"getBlock", _}, {"solidityGetBlock", _}] = calls()
    end

    test "the explorer source takes finalized from the confirmed flag it publishes" do
      handle = stateful(:tronscan, %{"getBlocks" => "tronscan_blocks.sse"})

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height == 86_236_775
      # 18 blocks back at 19 confirmations, which is Tron's two-thirds-of-27
      # rule rather than a number this module chose.
      assert height.finalized_height == 86_236_757
      assert height.height - height.finalized_height == 18

      assert [{"getBlocks", %{"sort" => "-number"}}] = calls()
    end

    test "the archive source answers both halves and its own lag, in one call" do
      handle = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.finalized_height < height.height

      # Set what the upstream publishes and omit the rest: a lag in blocks and
      # in seconds, and no ratio at all, so `:indexed_ratio` is absent rather
      # than a fabricated 1.0 in the one field that exists so lag is visible.
      assert height.indexer.finished? == true
      assert height.indexer.lag_blocks == 20
      assert height.indexer.lag_seconds == 60
      refute Map.has_key?(height.indexer, :indexed_ratio)
    end

    test "a height is never cached, even on a handle that caches" do
      handle = stateful(:trongrid, trongrid_height_routes(), cache: true)

      assert {:ok, first} = Tron.block_height(state(handle))
      assert {:ok, ^first} = Tron.block_height(state(handle))

      # Four calls, not two. A cached height beside a live finalized height is
      # what produces `finalized_height > height`.
      assert length(calls()) == 4
    end
  end

  describe "chain_info/1" do
    test "the node source derives a block time from two real block timestamps" do
      # The head fixture is block 86,236,775 at 1,789,382,436,000 and the
      # sampled one is 86,236,675 at 1,789,382,136,000, so 300,000 ms over 100
      # blocks is 3,000 ms a block. Derived, not asserted: Tron's protocol
      # constant is 3 seconds and reporting that would be a number this module
      # claimed rather than one it read.
      handle = stateful(:trongrid, %{"getBlock" => &sampled_block/1})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.chain_ref == "tron:0x2b6653dc"
      assert info.average_block_time_ms == 3000.0
      # A node keeps no aggregate counters, and a fabricated total would read
      # as a fact about the chain.
      assert info.total_blocks == nil
      assert info.total_transactions == nil
      assert info.total_addresses == nil

      assert [{"getBlock", %{"detail" => false}}, {"getBlock", %{"id_or_num" => "86236675"}}] =
               calls()
    end

    test "a sample the node cannot answer leaves the block time absent" do
      # Both calls answer the head, so the derived interval is zero and the
      # honest answer is no answer rather than a zero block time.
      handle = stateful(:trongrid, %{"getBlock" => "trongrid_block.sse"})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.average_block_time_ms == nil
    end

    test "the explorer source answers the aggregate counters it publishes" do
      handle = stateful(:tronscan, %{"getStatsOverview" => "tronscan_stats_overview.sse"})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.average_block_time_ms == 3000
      assert info.total_blocks == 85_821_047
      assert info.total_transactions == 15_309_085_194
      assert info.total_addresses == 401_512_246
    end

    test "the archive source confirms the chain rather than asserting it" do
      handle = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.chain_ref == "tron:0x2b6653dc"
      assert info.average_block_time_ms == nil
      assert [{"portal_get_network_info", %{"network" => "tron-mainnet"}}] = calls()
    end
  end

  describe "the account reference accepts both encodings" do
    test "Base58 and hex for one account answer identically and ask identically" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:ok, from_base58} = Tron.account_info(state(handle), {:tron, @base58})
      assert {:ok, from_hex} = Tron.account_info(state(handle), {:tron, @hex})
      assert {:ok, from_prefixed_hex} = Tron.account_info(state(handle), {:tron, "0x" <> @hex})

      assert from_base58 == from_hex
      assert from_base58 == from_prefixed_hex
      assert from_base58.ref == {:tron, @base58}

      # And the same argument went upstream all three times. A cache key or a
      # rate-limit spend that differed by encoding is the bug this prevents,
      # and it is invisible in the return value alone.
      assert [
               {"getAccountInfo", %{"address" => @base58}},
               {"getAccountInfo", %{"address" => @base58}},
               {"getAccountInfo", %{"address" => @base58}}
             ] = calls()
    end

    test "a reference in another chain's tag is refused by its tag" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:error, {:unsupported_account_ref, :evm}} =
               Tron.account_info(state(handle), {:evm, "0x" <> @hex})

      assert {:error, {:unsupported_account_ref, :tron}} =
               Tron.account_info(state(handle), {:tron, "not-an-address"})

      assert calls() == []
    end

    test "the mapped account omits a kind and answers code presence" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:ok, account} = Tron.account_info(state(handle), {:tron, @base58})
      assert account.balance == 2_061_293_347_241_804
      assert account.contract? == false
      # Tron draws no account-kind distinction that changes how `balance` is
      # read, so the optional key is absent rather than nil.
      refute Map.has_key?(account, :kind)
    end

    test "malformed monetary integers are rejected instead of truncated" do
      for malformed <- ["12.5", "12sun"] do
        body = account_fixture_with_balance(malformed)
        handle = stateful(:trongrid, %{"getAccountInfo" => {:body, body}})

        assert {:error, {:decode_failed, :balance}} =
                 Tron.account_info(state(handle), {:tron, @base58})
      end
    end

    test "the explorer source answers the same account from its own shape" do
      handle = stateful(:tronscan, %{"getAccountDetail" => "tronscan_account_detail.sse"})

      assert {:ok, account} = Tron.account_info(state(handle), {:tron, @hex})
      assert account.ref == {:tron, @base58}
      assert account.balance == 2_061_293_347_241_804
      assert account.name == "Binance-Cold 2"
    end
  end

  describe "token_balances/3" do
    test "a TRC-10 and a TRC-20 balance both come back, distinguishable" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:ok, page} = Tron.token_balances(state(handle), {:tron, @base58}, [])

      trc10 = Enum.filter(page.items, &(&1.token.type == "TRC-10"))
      trc20 = Enum.filter(page.items, &(&1.token.type == "TRC-20"))

      assert length(trc10) == 2
      assert length(trc20) == 2

      # A TRC-10 asset is keyed by a numeric id and has no address to put in
      # `token()`'s `address`, so the id lands in `token_id` and the address is
      # absent rather than filled with the id.
      assert Enum.all?(trc10, &(&1.token.address == nil))
      assert Enum.all?(trc10, &(&1.token_id != nil))
      assert %{token_id: "1002721", amount: 10_000_000} = hd(trc10)

      # A TRC-20 is the other way round.
      assert Enum.all?(trc20, &(&1.token_id == nil))
      assert Enum.all?(trc20, &(&1.token.address != nil))
      assert %{token: %{address: "TSPigbpXYgt8JdgRmKew2SmJx41zymepb1"}} = hd(trc20)
      assert hd(trc20).amount == 100_000_000_000

      # One object, not a page, so there is no second page to walk.
      assert page.next == nil
    end

    test "the explorer source distinguishes the same two standards and the native asset" do
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_account_tokens.sse"})

      assert {:ok, page} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      assert [trc10, trc20] = page.items

      assert trc10.token.type == "TRC-10"
      assert trc10.token_id == "1002000"
      assert trc10.token.address == nil
      # This source publishes the scale, so a caller reaching it can interpret
      # the amount; the node source answers `nil` rather than guessing 18.
      assert trc10.token.decimals == 6
      assert trc10.token.symbol == "BTTOLD"

      assert trc20.token.type == "TRC-20"
      assert trc20.token_id == nil
      assert trc20.token.address == "TFczxzPhnThNSqr5by8tvxsdCFRRz6cPNq"
    end

    test "the native asset is neither standard" do
      # Measured 2026-09-14: TronScan reports TRX as `tokenType: "trc10"` with
      # `tokenId: "_"`. Passing that through would report the native balance as
      # a TRC-10 asset with an id of "_".
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      assert {:ok, page} = Tron.list_token_transfers(state(handle), {:tron, @base58})
      assert [transfer | _rest] = page.items
      assert transfer.token.type == "TRX"
      assert transfer.token.address == nil
    end
  end

  describe "the mapped transaction shapes" do
    test "the node source reports an absent block rather than inventing one" do
      handle = stateful(:trongrid, %{"getTransactionById" => "trongrid_transaction.sse"})

      assert {:ok, transaction} = Tron.get_transaction(state(handle), @tx)
      assert transaction.hash == @tx
      assert transaction.status == :success
      assert transaction.method == "TriggerSmartContract"
      assert transaction.from == {:tron, "TUzaRA8m8rkwMN1vYRWdzASSosdixZKdRB"}
      # The recorded response carried `owner_address` in Base58 and
      # `contract_address` in hex, in one object. Both come out canonical.
      assert transaction.to == {:tron, "TAFjULxiVgT4qWk6UZwjqwZXTSaGaqnVp4"}
      # `getTransactionInfoById` is the tool that carries a block and a fee, and
      # on 2026-09-14 it answered isError with its own output-schema validation
      # failure, so these are absent facts and TronScan is the source that has
      # them.
      assert transaction.block == nil
      assert transaction.fee == nil
    end

    test "the tool that would have carried the block is refused, not mapped" do
      # This is the measurement behind the nils above, pinned so it is visible
      # rather than folded into a comment: on 2026-09-14 `getTransactionInfoById`
      # answered `isError: true` with its own output-schema validation failure,
      # `/fee_major: string found, number expected`. A backend that reached for
      # it would get a refusal, and the text of that refusal must not travel.
      handle = stateful(:trongrid, %{"getTransactionById" => "trongrid_transaction_info.sse"})

      assert {:error, {:upstream_refused, :unknown} = reason} =
               Tron.get_transaction(state(handle), @tx)

      refute inspect(reason) =~ "fee_major"
      refute inspect(reason) =~ "outputSchema"
    end

    test "the explorer source answers the block and fee the node source cannot" do
      handle = stateful(:tronscan, %{"getTransactionDetail" => "tronscan_transaction.sse"})

      assert {:ok, transaction} = Tron.get_transaction(state(handle), @tx)
      assert transaction.hash == @tx
      assert transaction.status == :success
      assert transaction.block == 86_233_411
      assert transaction.fee == 0
      assert %DateTime{} = transaction.timestamp
    end

    test "a listed transaction carries the block and fee the by-hash read lacks" do
      handle =
        stateful(:trongrid, %{"getAccountTransactions" => "trongrid_account_transactions.sse"})

      assert {:ok, page} = Tron.list_transactions(state(handle), {:tron, @base58})
      assert [first, _second] = page.items
      assert first.block == 86_227_373
      assert first.status == :success
      assert first.method == "UnDelegateResourceContract"
      # A resource delegation names its counterparty `receiver_address`, which
      # is not a fallback for `to_address` but a different field in a different
      # contract type.
      assert first.to == {:tron, @base58}
    end

    test "a token transfer carries the metadata the transfer list publishes" do
      handle =
        stateful(:trongrid, %{
          "getAccountTrc20Transactions" => "trongrid_trc20_transactions.sse"
        })

      assert {:ok, page} = Tron.list_token_transfers(state(handle), {:tron, @base58})
      assert [first | _rest] = page.items
      assert first.token.symbol == "BTT"
      assert first.token.decimals == 18
      assert first.token.type == "TRC-20"
      assert first.amount == 3_000_000_000_000_000_000_000_000_000_000
      assert first.transaction == @tx
    end

    test "a block reads its height out of the header" do
      handle = stateful(:trongrid, %{"getBlock" => "trongrid_block.sse"})

      assert {:ok, block} = Tron.get_block(state(handle), 86_236_775)
      assert block.height == 86_236_775
      assert block.hash == "000000000523de676259ebe55b1a9ecd339d6bc7abb4c0f6cab97db0fc60899f"
      assert %DateTime{} = block.timestamp
      assert [{"getBlock", %{"id_or_num" => "86236775"}}] = calls()
    end
  end

  describe "pagination" do
    test "the node source pages on a fingerprint the caller never sees" do
      handle =
        stateful(:trongrid, %{"getAccountTransactions" => "trongrid_account_transactions.sse"})

      assert {:ok, page} = Tron.list_transactions(state(handle), {:tron, @base58})
      assert is_binary(page.next)

      fingerprint =
        fixture("trongrid_account_transactions.sse")
        |> payload()
        |> Jason.decode!()
        |> get_in(["result", "content", Access.at(0), "text"])
        |> Jason.decode!()
        |> get_in(["meta", "fingerprint"])

      refute String.contains?(page.next, fingerprint)

      assert {:ok, _second} =
               Tron.list_transactions(state(handle), {:tron, @base58}, cursor: page.next)

      assert [{_tool, first_args}, {_tool2, second_args}] = calls()
      refute Map.has_key?(first_args, "fingerprint")
      assert second_args["fingerprint"] == fingerprint
    end

    test "the explorer source pages on an offset the caller never sees" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      assert {:ok, page} = Tron.list_token_transfers(state(handle), {:tron, @base58})
      assert is_binary(page.next)
      refute String.contains?(page.next, "start")

      assert {:ok, _second} = paged_transfers(handle, page.next)

      assert [{_tool, first_args}, {_tool2, second_args}] = calls()
      assert first_args["start"] == 0
      assert second_args["start"] == 25
      assert second_args["limit"] == 25
    end

    test "a token balance walk hands its own cursor back" do
      # `token_balances/3` grew `list_opts` on 2026-09-14, so the cursor this
      # read mints is one a caller can present. It was minted and unusable
      # before that, which is the same class of dishonesty as an empty page.
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_account_tokens.sse"})

      assert {:ok, first} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      # The fixture reports 92 rows against a page of 25, so there is a next.
      assert is_binary(first.next)

      assert {:ok, _second} =
               Tron.token_balances(state(handle), {:tron, @base58}, cursor: first.next)

      assert [{_tool, %{"start" => 0, "limit" => 25}}, {_tool2, %{"start" => 25}}] = calls()
    end

    test "a read that mints no cursor refuses one" do
      # The node source answers token balances from one account record, so it
      # has no page two. Answering page one again for a cursor it never minted
      # would be indistinguishable from a walk that ended. `:wrong_scope` is
      # the reason for it, the same one the Solana backend mints for the same
      # case, and it is a `Raxol.Web3.Cursor.reason/0` variant rather than an
      # endpoint atom naming an endpoint no cursor is scoped to.
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})
      held = offset_cursor(25)

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Tron.token_balances(state(handle), {:tron, @base58}, cursor: held)

      assert calls() == []
    end

    test "a cursor minted for one endpoint is refused on another" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      wrong_scope =
        Cursor.encode(
          %{"start" => 25, "limit" => 25},
          tronscan_origin(),
          :tronscan_account_tokens
        )

      assert {:error, {:invalid_cursor, :wrong_scope}} = paged_transfers(handle, wrong_scope)
      assert calls() == []
    end

    test "a walk that would cross the offset ceiling fails without asking" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      # 9975 + 25 is exactly the ceiling and is allowed; 9990 + 25 is not.
      assert {:ok, _page} = paged_transfers(handle, offset_cursor(9975))
      assert [{_tool, %{"start" => 9975}}] = calls()

      assert {:error, {:upstream_refused, :unknown}} =
               paged_transfers(handle, offset_cursor(9990))

      # And nothing was asked. Spending the upstream's budget on a request its
      # own documented rule refuses is the half of "fail honestly" a return
      # value cannot show.
      assert calls() == []
    end

    test "the recorded upstream refusal maps to the same error as the local check" do
      # So the local arithmetic and the upstream agree rather than diverging
      # silently the day the ceiling moves.
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_ceiling_refused.sse"})

      assert {:error, {:upstream_refused, :unknown}} =
               Tron.token_balances(state(handle), {:tron, @base58}, [])
    end

    test "the last page mints no cursor" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      # The fixture reports 1,860 rows, so a walk standing at 1,850 is the end.
      assert {:ok, page} = paged_transfers(handle, offset_cursor(1850))
      assert page.next == nil
    end

    test "every endpoint this backend pages has an allowlist entry" do
      # An endpoint absent from the table cannot mint or accept a cursor at all,
      # so a typo in a name would silently disable paging rather than fail.
      for endpoint <- [
            :tron_account_transactions,
            :tron_account_trc20_transfers,
            :tronscan_account_tokens,
            :tronscan_transfer_list
          ] do
        assert endpoint in Cursor.endpoints()
      end
    end
  end

  # Both offset-paged reads on this source share the `start`/`limit` pair and
  # the same 10,000 ceiling, so the ceiling and scope cases are driven through
  # the transfer list and the balance walk has its own test above.
  defp paged_transfers(handle, cursor) do
    Tron.list_token_transfers(state(handle), {:tron, @base58}, cursor: cursor)
  end

  defp offset_cursor(start) do
    Cursor.encode(%{"start" => start, "limit" => 25}, tronscan_origin(), :tronscan_transfer_list)
  end

  defp tronscan_origin, do: Origin.id(URI.new!(Tron.sources().tronscan.url))

  describe "errors carry no upstream text" do
    test "the archive's nested error object is classified by its code, not its prose" do
      # SQD announces a refusal as `error.code` beside a human summary, and the
      # code is a value rather than words, so it is the half this module reads.
      # The recorded body is the measurement behind declaring no optional
      # callback on this source at all: asked for an account's transactions
      # with no window, it answers 200 carrying `invalid_request` and "Provide
      # timeframe, from_block, or from_timestamp/to_timestamp to define the
      # query window", and `Backend.list_opts()` has nowhere to put one.
      handle = sqd(%{"portal_get_network_info" => "sqd_no_window.sse"})

      assert {:error, {:upstream_refused, :unknown} = reason} =
               Tron.block_height(state(handle))

      refute inspect(reason) =~ "timeframe"
      refute inspect(reason) =~ "invalid_request"
    end

    test "a refusal announced inside a successful tool result is classified" do
      handle = stateful(:trongrid, %{"getBlock" => "trongrid_missing_argument.sse"})

      assert {:error, {:upstream_refused, :unknown} = reason} =
               Tron.block_height(state(handle))

      # The recorded frame's text is "Error: Missing required argument: blockNum".
      refute inspect(reason) =~ "blockNum"
      refute inspect(reason) =~ "Missing"
    end

    test "an HTTP status from the client becomes a status and nothing else" do
      handle = stateful(:trongrid, %{"getBlock" => {:status, 500}})

      assert {:error, {:http, 500}} = Tron.block_height(state(handle))
    end

    test "a transport reason from the client lands in the closed taxonomy" do
      handle = stateful(:trongrid, %{"getBlock" => {:error, {:timeout, :chunk}}})

      assert {:error, {:timeout, :chunk}} = Tron.block_height(state(handle))
    end

    test "the ceiling refusal body names no upstream words" do
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_ceiling_refused.sse"})

      assert {:error, reason} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      refute inspect(reason) =~ "start + limit"
      refute inspect(reason) =~ "10000"
    end

    test "the archive's unknown_network is a chain this source does not serve, not a refusal" do
      # The same portal, the same recorded refusal shape, and until now two
      # different readings of it: `Raxol.Web3.Backend.Solana` mapped
      # `unknown_network` to `{:unsupported_chain, _}` and failed over, while
      # this module classified SQD's codes only on the arm that has no
      # `isError`, so every recorded refusal from this source -- all of which
      # carry `isError: true` -- became `{:upstream_refused, :unknown}` and
      # was final. A Tron read then died on the archive with TronGrid and
      # TronScan both healthy.
      handle =
        sqd(%{"portal_get_network_info" => {:body, sqd_fixture("sqd_unknown_network.sse")}})

      assert {:error, {:unsupported_chain, "tron-mainnet"} = reason} =
               Tron.block_height(state(handle))

      refute inspect(reason) =~ "nonexistent"
      refute inspect(reason) =~ "portal_list_networks"

      # And the router does what the classification is for.
      router = Router.new([handle, stateful(:trongrid, trongrid_height_routes())])

      assert {:ok, %{unit: :block}} = Router.call(router, "tron:0x2b6653dc", :block_height)
    end
  end

  describe "a client process that is not there" do
    test "a dead client is a transport failure the caller can act on, not an exit" do
      handle = stateful(:trongrid, trongrid_height_routes(), restart: :temporary)
      client = state(handle).client

      reference = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^reference, :process, ^client, :killed}

      # `Raxol.MCP.Client.call_tool/3` is a `GenServer.call`, and an exit is
      # not an error tuple: uncaught, this took down whatever process was
      # reading -- a router walking its candidates, or the MCP server running
      # a tool callback inline -- so the failover that exists for a dead
      # source could never run.
      assert {:error, {:transport, :client_down}} = Tron.block_height(state(handle))
    end

    test "the router fails over off a dead client to a live source" do
      dead = stateful(:trongrid, trongrid_height_routes(), restart: :temporary)
      client = state(dead).client

      reference = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^reference, :process, ^client, :killed}

      router = Router.new([dead, sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})])

      assert {:ok, %{unit: :block}} = Router.call(router, "tron:0x2b6653dc", :block_height)
    end
  end

  describe "the served surface carries no upstream name" do
    test "no tool name this backend sends upstream appears in a served definition" do
      # 149 plus 119 is 268 third-party tool descriptions for one chain, and
      # TronGrid's `tools/list` alone was 269,860 bytes on 2026-09-14. The
      # served surface is the normalized contract, so none of those names is in
      # it, nor in a description or an annotation.
      upstream = ~w(
        getBlock solidityGetBlock getBlockStatistics getAccountInfo
        getAccountTransactions getAccountTrc20Transactions getTrc20Balance
        getTransactionById getTransactionInfoById listAllAssets getTrc20Info
        getBlocks getStatsOverview getAccountDetail getAccountTokens
        getTransferList getTransactionDetail getNewestBlock
        portal_get_network_info portal_get_head portal_tron_query_transactions
      )

      router = Router.new([sqd(%{})])
      rendered = inspect(Tools.tool_defs(router)) <> inspect(Tools.names())

      for name <- upstream do
        refute rendered =~ name, "served surface mentions the upstream tool #{name}"
      end
    end
  end

  describe "Router.coverage/2 over the three sources" do
    setup do
      trongrid = stateful(:trongrid, trongrid_height_routes())
      tronscan = stateful(:tronscan, %{"getBlocks" => "tronscan_blocks.sse"})
      archive = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})

      {:ok, handles: [trongrid, archive, tronscan]}
    end

    test "names which source answers each callback, and the asymmetry between them",
         %{handles: handles} do
      coverage = Router.new(handles) |> Router.coverage("tron:0x2b6653dc")

      # Named rather than counted. `backend/0` is `:tron` for all three, so
      # before `backend/1` this map read `%{chain_info: [:tron, :tron, :tron],
      # get_transaction: [:tron, :tron], list_transactions: [:tron]}`: an
      # operator could see how many sources survived but not which, which is
      # the only question a coverage map is asked. Declaration order is the
      # operator's stated preference and survives into the answer.
      assert coverage.chain_info == [:trongrid, :sqd, :tronscan]
      assert coverage.block_height == [:trongrid, :sqd, :tronscan]

      # And the optional surface is asymmetric, which is the whole point of
      # declaring rather than assuming: the archive answers none of it, and the
      # explorer has no account-scoped transaction index, so the one source
      # missing from each row is now legible by name.
      assert coverage.get_transaction == [:trongrid, :tronscan]
      assert coverage.token_balances == [:trongrid, :tronscan]
      assert coverage.list_token_transfers == [:trongrid, :tronscan]
      assert coverage.account_info == [:trongrid, :tronscan]
      assert coverage.list_transactions == [:trongrid]
      assert coverage.get_block == [:trongrid]

      # Nothing on this chain reads a contract, resolves a name or passes a raw
      # request through, so those are absent rather than present and empty.
      refute Map.has_key?(coverage, :read_contract)
      refute Map.has_key?(coverage, :resolve_name)
      refute Map.has_key?(coverage, :raw_request)
      refute Map.has_key?(coverage, :get_logs)
    end

    test "candidates name which source answers each callback", %{handles: handles} do
      router = Router.new(handles)

      assert router |> Router.candidates("tron:0x2b6653dc", :block_height) |> sources() ==
               [:trongrid, :sqd, :tronscan]

      assert router |> Router.candidates("tron:0x2b6653dc", :list_transactions) |> sources() ==
               [:trongrid]

      assert router |> Router.candidates("tron:0x2b6653dc", :get_transaction) |> sources() ==
               [:trongrid, :tronscan]
    end

    test "the archive answers a height the node source failed" do
      failing = stateful(:trongrid, %{"getBlock" => {:status, 503}})
      archive = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})
      router = Router.new([failing, archive])

      assert {:ok, height} = Router.call(router, "tron:0x2b6653dc", :block_height)
      # The archive's recorded head, so the answer came from the fallback and
      # not from a second attempt at the primary.
      assert height.height == 86_236_774
      assert height.indexer.lag_blocks == 20
    end

    test "an open breaker on the primary's origin puts it behind the fallback" do
      # The way router_test.exs does it: the breaker is the router's input, and
      # `health_key/1` names the key the outbound path itself writes.
      trongrid = stateful(:trongrid, trongrid_height_routes())
      archive = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})
      key = Tron.health_key(state(trongrid))
      on_exit(fn -> CircuitBreaker.reset(Tables.breakers(), key) end)

      router = Router.new([trongrid, archive], breaker: [failure_threshold: 1])

      assert router |> Router.candidates("tron:0x2b6653dc", :block_height) |> sources() ==
               [:trongrid, :sqd]

      CircuitBreaker.record_failure(Tables.breakers(), key, failure_threshold: 1)

      assert router |> Router.candidates("tron:0x2b6653dc", :block_height) |> sources() ==
               [:sqd, :trongrid]

      coverage = Router.coverage(router, "tron:0x2b6653dc")
      # The archive is the one that survived, by name: a count of 1 here would
      # hold just as well if the wrong source had been the one to drop out.
      assert coverage.block_height == [:sqd]
      # The only healthy handle is the archive, which declares nothing, so the
      # optional surface vanishes entirely rather than shrinking.
      refute Map.has_key?(coverage, :list_transactions)
      refute Map.has_key?(coverage, :token_balances)
    end
  end

  # Through `Backend.name/1` rather than the struct field, because that is the
  # mechanism an operator reads a source's name by; reaching into `:source`
  # here would have kept passing while `coverage/2` said `:tron` three times.
  defp sources(handles), do: Enum.map(handles, &Backend.name/1)

  describe "the declared concurrency policy is enforced by the client" do
    test "a fan-out against a serialized origin issues one request at a time" do
      # Property-tested over randomized fan-out widths, because a single-call
      # test cannot see this failure: two parallel calls on one TronScan
      # session answered 500 for both, reproducibly, on 2026-08-31.
      handle =
        stateful(:tronscan, %{"getBlocks" => "tronscan_blocks.sse"}, hold_ms: 3)

      for _round <- 1..20 do
        drain()
        width = Enum.random(2..6)
        fan_out(handle, width)

        log = concurrency_log()

        assert length(log) == 2 * width,
               "expected #{width} bracketed requests, got #{inspect(log)}"

        assert_serialized(log)
      end
    end

    test "the same detector sees overlap on a pooled origin" do
      # The control. Without it, `assert_serialized/1` could be an assertion
      # that passes by never failing, and the serialized test above would prove
      # nothing.
      handle = stateful(:trongrid, trongrid_height_routes(), hold_ms: 25)

      overlapped? =
        Enum.any?(1..3, fn _attempt ->
          drain()
          fan_out(handle, 6)
          not serialized?(concurrency_log())
        end)

      assert overlapped?, "a pooled origin serialized six calls, so the detector proves nothing"
    end
  end

  # `getBlocks` and `getBlock` are one upstream call each, so one fan-out unit
  # is one request and the log is unambiguous.
  defp fan_out(handle, width) do
    state = state(handle)

    1..width
    |> Enum.map(fn _index -> Task.async(fn -> Tron.block_height(state) end) end)
    |> Enum.each(&Task.await(&1, 5_000))
  end

  # The seam sends `:called` on entry and `:returned` on exit, so the mailbox
  # order is the interleaving. Draining before refuting is what keeps this from
  # passing on an empty mailbox.
  defp concurrency_log(acc \\ []) do
    receive do
      {:called, _tool, _arguments, reference} -> concurrency_log([{:enter, reference} | acc])
      {:returned, reference} -> concurrency_log([{:exit, reference} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp assert_serialized(log) do
    assert serialized?(log), "two requests overlapped on a serialized origin: #{inspect(log)}"
  end

  defp serialized?(log) do
    Enum.reduce_while(log, 0, fn
      {:enter, _reference}, 0 -> {:cont, 1}
      {:enter, _reference}, _in_flight -> {:halt, :overlap}
      {:exit, _reference}, in_flight -> {:cont, in_flight - 1}
    end) != :overlap
  end

  describe "against a real upstream" do
    @describetag :live_web3

    test "the archive answers both halves of the height" do
      {:ok, handle} = Tron.new(:sqd)

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height > 80_000_000
      assert height.finalized_height < height.height
      assert height.indexer.finished? == true
    end

    test "the node source answers a height from the irreversible view" do
      handle = live(:trongrid)

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height > 80_000_000
      # Generous bounds: the gap is the irreversible lag and not a constant.
      assert height.finalized_height < height.height
      assert height.height - height.finalized_height < 1_000
    end

    test "a mainnet account answers the same in both encodings" do
      handle = live(:trongrid)

      assert {:ok, base58} = Tron.account_info(state(handle), {:tron, @base58})
      assert {:ok, hex} = Tron.account_info(state(handle), {:tron, @hex})
      assert base58.ref == hex.ref
      assert base58.ref == {:tron, @base58}
    end

    test "both token standards come back from one real account" do
      handle = live(:trongrid)

      assert {:ok, page} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      assert Enum.any?(page.items, &(&1.token.type == "TRC-10"))
      assert Enum.any?(page.items, &(&1.token.type == "TRC-20"))
      assert Enum.all?(page.items, &is_integer(&1.amount))
    end

    test "the explorer source answers a height and a confirmed height" do
      handle = live(:tronscan)

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.finalized_height < height.height
    end

    # No `:tables` and no `:exchange`: this is the production wiring, so the
    # era probe, the session handshake and the real socket are all in play.
    defp live(source) do
      client = start_supervised!(Tron.client_spec(source))
      await_ready(client)
      {:ok, handle} = Tron.new(source, client: client, cache: false)
      handle
    end
  end
end
