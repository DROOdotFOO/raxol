defmodule Raxol.Web3.Backend.CantonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Canton
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Router
  alias Raxol.Web3.Serialize

  @fixtures Path.expand("../../../fixtures/canton", __DIR__)

  # A real party id, from a live `POST /v0/transactions` page on 2026-09-14, and
  # the party every recorded holdings fixture below was taken for.
  @party {:party,
          "tradefast-wallet3-1::1220674b79cae334aa788ffa394a6bd7d10e427d9f2abd418048e5be49ceb4256ca4"}

  # The DSO party, which holds no amulet: its holdings page is the recorded
  # empty-page-with-a-cursor case.
  @dso {:party, "DSO::1220b1431ef217342db44d516bb9befde802be7d8899637d290895fa58880f19accc"}

  # The bootstrap update, migration 0, offset 1. Immutable by construction, so a
  # live test can name it and keep naming it.
  @update_id "1220c7d293ea23275dcc7bfef9d47fa10e76477d26c93db4074ee5dff5e2cd8a5680"

  # Recorded from the live API on 2026-09-14 and trimmed. `dso.json` keeps two
  # of the fifteen super-validator node states (the migration id is read from
  # them) and drops the amulet and DSO rule bodies; `update.json` keeps both
  # root events and drops their Daml create and choice arguments. A fixture is
  # not a mock: it is what the upstream said, and it is the only thing that
  # makes "the shape changed" a red test rather than a production surprise.
  defp fixture(name), do: File.read!(Path.join(@fixtures, "#{name}.json"))

  # Both limiters get room on purpose. Every test here talks to the same two
  # origins, so the shared bucket and breaker would couple unrelated tests
  # through them; they are `Raxol.Web3.HTTPTest`'s subject. One test asks for
  # `metered: true` instead, so the backend's own seed is exercised rather than
  # read out of module data and compared with itself.
  defp unmetered(metered?) do
    breaker_and_dns() ++
      if metered?,
        do: [],
        else: [rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0]]
  end

  defp breaker_and_dns do
    [
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end
    ]
  end

  defp serving(routes) do
    fn _vetted, request, _opts ->
      send(self(), {:request, request})

      path = request.path |> String.split("?") |> hd()

      case Map.fetch(routes, path) do
        {:ok, %{} = pages} -> {:ok, %{status: 200, headers: [], body: page_for(pages, request)}}
        {:ok, {status, body}} -> {:ok, %{status: status, headers: [], body: body}}
        {:ok, body} -> {:ok, %{status: 200, headers: [], body: body}}
        :error -> {:ok, %{status: 404, headers: [], body: ~s({"error":"not found"})}}
      end
    end
  end

  # A route carrying several recorded pages of one endpoint, told apart by the
  # `after` the upstream itself minted. A request for a page nobody recorded
  # raises here rather than being answered with the wrong one.
  defp page_for(pages, request), do: Map.fetch!(pages, Jason.decode!(request.body)["after"])

  defp handle(routes, opts \\ []) do
    http_opts = [{:exchange, serving(routes)} | unmetered(Keyword.get(opts, :metered, false))]

    {:ok, handle} =
      Canton.new(
        Keyword.get(opts, :chain_ref, "canton:global"),
        Keyword.merge(
          [http_opts: http_opts, cache: Keyword.get(opts, :cache, false)],
          Keyword.take(opts, [:ccscan_key, :migration_id, :scan_url])
        )
      )

    handle
  end

  defp state(handle), do: elem(handle, 1)

  # The keyless Splice Scan surface, as recorded. Every test that is not about a
  # refusal starts from this map and overrides one row.
  defp scan_routes do
    %{
      "/v0/round-of-latest-data" => fixture("round_of_latest_data"),
      "/v0/dso" => fixture("dso"),
      "/v0/state/acs/snapshot-timestamp" => fixture("acs_snapshot_timestamp"),
      "/v0/splice-instance-names" => ~s({"amulet_name":"Canton Coin","amulet_name_acronym":"CC"}),
      "/v0/holdings/summary" => fixture("holdings_summary"),
      "/v0/holdings/state" => fixture("holdings_state"),
      "/v0/updates/#{@update_id}" => fixture("update")
    }
  end

  defp drain(acc \\ []) do
    receive do
      {:request, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp requested_paths, do: Enum.map(drain(), & &1.path)

  describe "chain references" do
    test "the canonical reference is ours rather than registered, and the alias normalizes" do
      # No CAIP-2 namespace exists for Canton, so this pair is a decision this
      # backend documents rather than a registry lookup.
      assert {:ok, {Canton, %{chain_ref: "canton:global"}}} = Canton.new("canton:global")
      assert {:ok, {Canton, %{chain_ref: "canton:global"}}} = Canton.new("canton:mainnet")
      assert Canton.chain_refs() |> Enum.sort() == ["canton:global", "canton:mainnet"]
    end

    test "a reference this backend does not answer for is refused rather than guessed at" do
      assert {:error, {:unsupported_chain, "eip155:1"}} = Canton.new("eip155:1")
      assert {:error, {:unsupported_chain, "canton:devnet"}} = Canton.new("canton:devnet")
    end

    test "the scan base carries its own path prefix, so a Scan instance is a url change" do
      # `api.cantonnodes.com` serves the Splice Scan v0 surface under `/v0`; a
      # Scan instance serves it under `/api/scan/v0`.
      {:ok, {Canton, pinned}} =
        Canton.new("canton:global", scan_url: "https://scan.example/api/scan/v0/")

      assert pinned.scan_url == "https://scan.example/api/scan/v0"
    end
  end

  describe "capabilities" do
    test "get_block is not declared, because this chain has no blocks" do
      handle = handle(scan_routes())

      refute :get_block in Canton.capabilities(state(handle))
      refute Backend.supports?(handle, :get_block)
      assert {:error, {:unsupported, :get_block}} = Backend.call(handle, :get_block, [1])
    end

    test "Router.coverage reports the absence rather than the backend faking a block" do
      router = Router.new([handle(scan_routes())])
      coverage = Router.coverage(router, "canton:global")

      # The two required callbacks are always covered, and the four this handle
      # declares are there beside them.
      assert Map.has_key?(coverage, :chain_info)
      assert Map.has_key?(coverage, :block_height)
      assert coverage[:account_info] == [:canton]
      assert coverage[:token_balances] == [:canton]
      assert coverage[:get_transaction] == [:canton]
      assert coverage[:raw_request] == [:canton]

      # And absence is legible: this is the property ADR-0039 makes load-bearing.
      refute Map.has_key?(coverage, :get_block)
    end

    test "every read this chain cannot be asked is absent, not an empty page" do
      # `list_transactions/3` because no surveyed source lists by party;
      # `resolve_name/2` because the CNS directory answered empty for every
      # prefix probed; the rest because Canton has no EVM call, no contract at a
      # party, no logs and no NFT standard on this surface.
      handle = handle(scan_routes())

      for callback <- [
            :list_transactions,
            :list_token_transfers,
            :get_logs,
            :list_nfts,
            :read_contract,
            :contract_metadata,
            :resolve_name
          ] do
        refute Backend.supports?(handle, callback), "#{callback} is declared"
        assert {:error, {:unsupported, ^callback}} = Backend.call(handle, callback, [@party, []])
      end
    end

    test "the declared set does not change when a credential appears" do
      # `raw_request/2` is declared with and without a key, so a missing
      # credential is a named refusal rather than `{:unsupported, _}`, which
      # would claim the source cannot answer when it can, with an account.
      without = Canton.capabilities(state(handle(%{})))
      with_key = Canton.capabilities(state(handle(%{}, ccscan_key: "not-a-real-key")))

      assert without == with_key
      assert :raw_request in without
    end
  end

  describe "the required callbacks, keyless" do
    test "both answer with no credential configured, from the keyless scan host" do
      # This is the corrected finding. ADR-0033 and the survey both say Canton
      # has no fully keyless path; measured 2026-09-14 it has one, and these two
      # callbacks are on it. A test rather than a comment claiming it.
      handle = handle(scan_routes())

      assert state(handle).ccscan_key == nil

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == "canton:global"

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :round

      requests = drain()
      assert requests != []

      # No credential travelled, on any of them, in any header.
      for request <- requests do
        names = Enum.map(request.headers, fn {name, _value} -> String.downcase(name) end)
        refute "authorization" in names
      end

      # And every one of them went to the scan host rather than to ccscan.
      assert Enum.all?(requests, &String.starts_with?(&1.path, "/v0/"))
    end

    test "chain_info reports the round cadence and no counts it cannot have" do
      handle = handle(scan_routes())

      assert {:ok, info} = Backend.call(handle, :chain_info)

      # `tickDuration` is 600,000,000 microseconds in the recorded DSO body.
      assert info.average_block_time_ms == 600_000

      # Not gaps: there are no blocks to count, no addresses to count, and the
      # keyless surface publishes no chain-wide transaction total.
      assert info.total_blocks == nil
      assert info.total_addresses == nil
      assert info.total_transactions == nil
    end

    test "block_height counts rounds, and says so" do
      handle = handle(scan_routes())

      assert {:ok, height} = Backend.call(handle, :block_height)

      assert height.unit == :round
      assert height.height == 113_141

      # The same number, deliberately: Canton commits through BFT consensus with
      # no fork choice, so a round whose data is complete cannot be
      # reorganized and a consumer's confirmation depth is 0.
      assert height.finalized_height == height.height

      # `finished?` is the endpoint's own claim; the lag is the age of the
      # `effectiveAt` it carries. No ratio is published and there are no blocks
      # to lag by, so neither key is invented.
      assert height.indexer.finished? == true
      assert is_integer(height.indexer.lag_seconds)
      assert height.indexer.lag_seconds >= 0
      refute Map.has_key?(height.indexer, :indexed_ratio)
      refute Map.has_key?(height.indexer, :lag_blocks)
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle = handle(scan_routes(), cache: true, scan_url: "https://cache-a.example/v0")

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert Enum.count(requested_paths(), &String.ends_with?(&1, "/round-of-latest-data")) == 2
    end

    test "a round the response does not carry is a decode failure, not a zero" do
      handle = handle(%{"/v0/round-of-latest-data" => ~s({"effectiveAt":"2026-09-14T00:00:00Z"})})

      assert {:error, {:decode_failed, :round}} = Backend.call(handle, :block_height)
    end
  end

  describe "account_info/2, over a party id" do
    test "answers for a real party, with the balance in the smallest unit" do
      handle = handle(scan_routes())

      assert {:ok, account} = Backend.call(handle, :account_info, [@party])

      assert account.ref == @party

      # 1844175.4850303696 Canton Coin at ten decimal places. The upstream's
      # own gross total, not a figure netted of the accrued holding fee.
      assert account.balance == 18_441_754_850_303_696

      # The party id's own name component, self-asserted and not unique.
      assert account.name == "tradefast-wallet3-1"

      # A party holds no code and there is nothing to verify.
      assert account.contract? == false
      assert account.verified? == false
      assert account.ens == nil
    end

    test "kind is omitted rather than nil, because Canton has no account kinds" do
      # Absent means the question does not apply on this chain, which is a
      # different fact from `nil` meaning unknown.
      handle = handle(scan_routes())

      assert {:ok, account} = Backend.call(handle, :account_info, [@party])
      refute Map.has_key?(account, :kind)
    end

    test "a party with no summary row reports nil, never zero" do
      # The two are indistinguishable in the response, and no gate may read a
      # non-answer as an empty wallet.
      routes =
        Map.put(
          scan_routes(),
          "/v0/holdings/summary",
          ~s({"record_time":"2026-09-14T00:00:00Z","migration_id":4,"summaries":[]})
        )

      assert {:ok, account} = Backend.call(handle(routes), :account_info, [@dso])
      assert account.balance == nil
    end

    test "a non-party reference is refused by tag, before any request" do
      handle = handle(scan_routes())

      assert {:error, {:unsupported_account_ref, :evm}} =
               Backend.call(handle, :account_info, [{:evm, "0xdead"}])

      assert {:error, {:unsupported_account_ref, :solana}} =
               Backend.call(handle, :token_balances, [{:solana, "So1"}])

      assert [] == requested_paths()
    end

    test "the party travels in a POST body, so its colons need no escaping" do
      handle = handle(scan_routes())

      assert {:ok, _account} = Backend.call(handle, :account_info, [@party])

      summary = Enum.find(drain(), &(&1.path == "/v0/holdings/summary"))
      assert summary.method == "POST"
      assert %{"owner_party_ids" => [party]} = Jason.decode!(summary.body)
      assert party == elem(@party, 1)
      assert party =~ "::"
    end

    test "the snapshot is resolved from the derived migration id, not a hardcoded one" do
      # Measured 2026-09-14: every `migrationId` published in `/v0/dso` is "4",
      # nested per super-validator inside a Daml-encoded map.
      handle = handle(scan_routes())

      assert {:ok, _account} = Backend.call(handle, :account_info, [@party])

      snapshot = Enum.find(drain(), &String.starts_with?(&1.path, "/v0/state/acs/"))
      assert snapshot.path =~ "migration_id=4"
    end

    test "a pinned migration id skips the derivation rather than overriding it after the fact" do
      handle = handle(scan_routes(), migration_id: 0)

      assert {:ok, _account} = Backend.call(handle, :account_info, [@party])

      paths = requested_paths()
      assert Enum.any?(paths, &(&1 =~ "migration_id=0"))
      refute Enum.any?(paths, &(&1 == "/v0/dso"))
    end

    test "a migration id nowhere in the DSO body is a decode failure, not a default" do
      routes = Map.put(scan_routes(), "/v0/dso", ~s({"dso_party_id":"DSO::1220ab"}))

      assert {:error, {:decode_failed, :migration_id}} =
               Backend.call(handle(routes), :account_info, [@party])
    end
  end

  describe "the party tag, across the served surface" do
    test "a party reference round-trips as party:Alice::1220abcd" do
      # The parse splits on the FIRST colon only, which is what makes a party
      # id's own `::` survive. This is the backend half of what
      # `Raxol.Web3.MCP.ToolsTest` asserts on the surface side.
      assert Serialize.account_ref("party:Alice::1220abcd") == {:party, "Alice::1220abcd"}
      assert Serialize.result({:party, "Alice::1220abcd"}) == "party:Alice::1220abcd"
    end

    test "a reference parsed from the surface comes back out of the backend unchanged" do
      handle = handle(scan_routes())
      incoming = "party:" <> elem(@party, 1)

      assert {:ok, account} =
               Backend.call(handle, :account_info, [Serialize.account_ref(incoming)])

      assert Serialize.result(account.ref) == incoming
    end
  end

  describe "token_balances/3 and the POST after-cursor" do
    test "a holding normalizes to the amulet, in the smallest unit" do
      handle = handle(scan_routes())

      assert {:ok, page} = Backend.call(handle, :token_balances, [@party])
      assert [balance] = page.items

      assert balance.amount == 18_441_754_850_303_696
      assert balance.token.decimals == 10
      assert balance.token.symbol == "CC"
      assert balance.token.name == "Canton Coin"

      # The asset's identity on this chain is a Daml template, not an address,
      # and the holding's identity is a contract id.
      assert balance.token.address =~ "Splice.Amulet:Amulet"
      assert balance.token_id =~ "007809b877cb"
    end

    test "the page sum agrees with the gross total account_info reports" do
      # The property that matters when both are read together, and it held to
      # the digit against the live upstream on 2026-09-14.
      handle = handle(scan_routes())

      assert {:ok, page} = Backend.call(handle, :token_balances, [@party])
      assert {:ok, account} = Backend.call(handle, :account_info, [@party])

      assert Enum.sum(Enum.map(page.items, & &1.amount)) == account.balance
    end

    test "the last page carries no cursor" do
      handle = handle(scan_routes())

      assert {:ok, %{next: nil}} = Backend.call(handle, :token_balances, [@party])
    end

    test "an empty page with a token still carries a cursor, because the walk is not over" do
      # Measured 2026-09-14: the DSO's first holdings page has zero
      # `created_events` and a non-null `next_page_token`. Minting `next` from
      # the items would report a party as holding nothing while its holdings
      # were one page further on.
      routes = Map.put(scan_routes(), "/v0/holdings/state", fixture("holdings_state_empty_page"))

      assert {:ok, page} = Backend.call(handle(routes), :token_balances, [@dso])
      assert page.items == []
      assert is_binary(page.next)
    end

    test "a cursor pages forward through two recorded pages, and a null token ends it" do
      # The DSO's first page is the recorded zero-items-with-a-token case, which
      # is what says the walk continues; feeding that cursor back answers with a
      # page carrying a holding and a null token, which is what ends it. The
      # second page is the one recorded for @party: a fixture is what the
      # upstream said about a PAGE, and what is under test is the walk rather
      # than whose holdings it reports.
      pages = %{
        nil => fixture("holdings_state_empty_page"),
        8_926_540_676 => fixture("holdings_state")
      }

      handle = handle(Map.put(scan_routes(), "/v0/holdings/state", pages))

      # The cursor is the callback's own parameter now, so the walk goes through
      # the contract rather than beside it.
      assert Backend.supports?(handle, :token_balances)

      assert {:ok, first} = Backend.call(handle, :token_balances, [@dso])
      assert first.items == []
      assert is_binary(first.next)

      assert {:ok, second} = Backend.call(handle, :token_balances, [@dso, [cursor: first.next]])
      assert [balance] = second.items
      assert balance.amount == 18_441_754_850_303_696
      assert second.next == nil
    end

    test "the cursor decodes to the measured keyset, and pins the snapshot" do
      routes = Map.put(scan_routes(), "/v0/holdings/state", fixture("holdings_state_empty_page"))
      handle = handle(routes)

      assert {:ok, %{next: cursor}} = Backend.call(handle, :token_balances, [@dso])

      origin = Origin.id(URI.new!("https://api.cantonnodes.com/v0"))
      assert {:ok, params} = Cursor.decode(cursor, origin, :canton_holdings_state)

      assert params["after"] == 8_926_540_676
      assert params["migration_id"] == 4
      assert params["record_time"] == "2026-09-14T00:00:00Z"

      # The subject of the query is deliberately not in the payload: a cursor
      # that carried it would let a held cursor ask about somebody else's party.
      refute Map.has_key?(params, "owner_party_ids")
    end

    test "a cursor becomes the upstream's own after parameter, without re-resolving a snapshot" do
      routes = Map.put(scan_routes(), "/v0/holdings/state", fixture("holdings_state_empty_page"))
      handle = handle(routes)

      assert {:ok, %{next: cursor}} = Backend.call(handle, :token_balances, [@dso])
      _first = drain()

      assert {:ok, _page} = Backend.call(handle, :token_balances, [@dso, [cursor: cursor]])

      requests = drain()
      assert [posted] = Enum.filter(requests, &(&1.path == "/v0/holdings/state"))

      body = Jason.decode!(posted.body)
      assert body["after"] == 8_926_540_676
      assert body["record_time"] == "2026-09-14T00:00:00Z"
      assert body["owner_party_ids"] == [elem(@dso, 1)]

      # Required, and easy to miss: omitting `page_size` answers 400 with
      # `DecodingFailure at .page_size: Missing required field`, measured
      # 2026-09-14. It is not in the cursor's keyset, so it has to be re-added
      # from module data on a resumed page too, which is what this asserts.
      assert body["page_size"] == 100

      # The snapshot was NOT re-resolved: the held cursor is what pins the walk
      # to the snapshot it was minted against rather than drifting onto today's.
      refute Enum.any?(requests, &String.starts_with?(&1.path, "/v0/state/acs/"))
      refute Enum.any?(requests, &(&1.path == "/v0/dso"))
    end

    test "a cursor from another endpoint is refused before the request is built" do
      routes = Map.put(scan_routes(), "/v0/holdings/state", fixture("holdings_state_empty_page"))
      handle = handle(routes)

      assert {:ok, %{next: cursor}} = Backend.call(handle, :token_balances, [@dso])
      _first = drain()

      origin = Origin.id(URI.new!("https://api.cantonnodes.com/v0"))
      assert {:error, :wrong_scope} = Cursor.decode(cursor, origin, :address_tokens)
    end

    test "an after outside the snapshot range arrives as a status, carrying no upstream text" do
      # The one 400 this endpoint produces. The range it names is upstream
      # prose and stays there; a caller restarts the walk.
      routes =
        Map.put(
          scan_routes(),
          "/v0/holdings/state",
          {400,
           ~s|{"error":"Invalid after token, outside of snapshot range 8926540585 to 8930855612."}|}
        )

      assert {:error, {:http, 400}} = Backend.call(handle(routes), :token_balances, [@party])
    end
  end

  describe "get_transaction/2" do
    test "an update normalizes to its id, its record time and its root choice" do
      handle = handle(scan_routes())

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [@update_id])

      assert transaction.hash == @update_id
      assert transaction.method == "DsoBootstrap_Bootstrap"
      assert %DateTime{} = transaction.timestamp

      # An update in the Scan's history is committed; a rejected Canton command
      # never becomes one.
      assert transaction.status == :success

      # Thin on purpose: a Daml update has no single sender, recipient, value or
      # fee, and there is no block to report either.
      assert transaction.block == nil
      assert transaction.from == nil
      assert transaction.to == nil
      assert transaction.value == nil
      assert transaction.fee == nil
    end

    test "an unknown update id is a status rather than a fabricated transaction" do
      handle = handle(scan_routes())

      assert {:error, {:http, 404}} = Backend.call(handle, :get_transaction, ["1220nope"])
    end

    test "an update id cannot escape the /updates/ prefix or add a query" do
      # `URI.encode/1`'s default predicate leaves `/`, `?` and `#` unescaped, so
      # it encoded this id to itself and the composed path was
      # `/v0/updates/../../v0/admin?x=1#y`: an arbitrary path, with a query of
      # the caller's choosing, on a credentialed host. The id arrives from a
      # model -- it is the `hash` argument of `web3_get_transaction`.
      handle = handle(scan_routes())

      assert {:error, {:http, 404}} =
               Backend.call(handle, :get_transaction, ["../../v0/admin?x=1#y"])

      assert [requested] = requested_paths()
      assert "/v0/updates/" <> encoded = requested
      refute String.contains?(encoded, ["/", "?", "#"])
    end
  end

  describe "the ccscan account requirement" do
    test "no credential is a named refusal, and costs no request" do
      handle = handle(scan_routes())

      assert {:error, {:upstream_refused, :auth}} =
               Backend.call(handle, :raw_request, [%{tool: "get_round", arguments: %{round: 1}}])

      assert [] == requested_paths()
    end

    test "the refusal is mapped from the recognised body, not from a status" do
      # ccscan answers HTTP 200 with `result.isError: true` and
      # `content[0].text` holding `{"error":"account_required",...}`. The 200 is
      # explicit in this arrangement rather than the seam's default, because it
      # is the whole point: a status-derived mapping reads this as a success.
      routes = Map.put(scan_routes(), "/mcp", {200, fixture("ccscan_account_required")})
      handle = handle(routes, ccscan_key: "not-a-real-key")

      assert {:error, {:upstream_refused, :auth}} =
               Backend.call(handle, :raw_request, [%{tool: "get_round", arguments: %{round: 1}}])

      assert [called] = drain()
      assert called.path == "/mcp"
    end

    test "an announced failure this backend does not recognise is not guessed at" do
      routes =
        Map.put(
          scan_routes(),
          "/mcp",
          ~s({"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"{\\"error\\":\\"something_else\\"}"}]}})
        )

      handle = handle(routes, ccscan_key: "not-a-real-key")

      assert {:error, {:upstream_refused, :unknown}} =
               Backend.call(handle, :raw_request, [%{tool: "get_round", arguments: %{round: 1}}])
    end

    test "a tool outside the allowlist is refused before any request" do
      handle = handle(scan_routes(), ccscan_key: "not-a-real-key")

      assert {:error, {:unsupported, :raw_request}} =
               Backend.call(handle, :raw_request, [%{tool: "tools/list", arguments: %{}}])

      assert [] == requested_paths()
      assert length(Canton.raw_request_allowlist()) == 13
    end

    test "a nested argument is refused rather than forwarded" do
      # The arguments are the one thing on this path a caller chooses, and on an
      # MCP surface a caller can be a model.
      handle = handle(scan_routes(), ccscan_key: "not-a-real-key")

      assert {:error, {:unsupported, :raw_request}} =
               Backend.call(handle, :raw_request, [
                 %{tool: "search", arguments: %{"query" => %{"nested" => true}}}
               ])

      assert [] == requested_paths()
    end

    test "a call with no tool at all is refused rather than crashing the router" do
      handle = handle(scan_routes(), ccscan_key: "not-a-real-key")

      assert {:error, {:unsupported, :raw_request}} =
               Backend.call(handle, :raw_request, [%{arguments: %{}}])
    end
  end

  describe "the credential is held in transit only" do
    @key "ccscan-secret-value-47"

    test "it reaches the request header and nothing else" do
      routes = Map.put(scan_routes(), "/mcp", fixture("ccscan_account_required"))
      handle = handle(routes, ccscan_key: @key)

      log =
        capture_log(fn ->
          assert {:error, reason} =
                   Backend.call(handle, :raw_request, [
                     %{tool: "get_round", arguments: %{round: 1}}
                   ])

          # Not in the error term, which travels furthest of the three: into a
          # log line, a telemetry measurement, and on an MCP surface into text
          # the model reads.
          refute inspect(reason) =~ @key
          refute inspect(Serialize.error(reason)) =~ @key
        end)

      # Not in a log line. This is where it leaks in practice, so the assertion
      # is here rather than in a comment.
      refute log =~ @key

      # It did travel, once, in the header it is supposed to travel in. Without
      # this the three refutations above would pass by never being exercised.
      assert [called] = drain()
      assert {_name, "Bearer " <> @key} = List.keyfind(called.headers, "authorization", 0)
    end

    test "it is not in the cache key, because a passthrough is not cached" do
      routes = Map.put(scan_routes(), "/mcp", fixture("ccscan_account_required"))

      handle =
        handle(routes, ccscan_key: @key, cache: true, scan_url: "https://cache-b.example/v0")

      call = %{tool: "get_round", arguments: %{round: 1}}

      assert {:error, {:upstream_refused, :auth}} = Backend.call(handle, :raw_request, [call])
      assert {:error, {:upstream_refused, :auth}} = Backend.call(handle, :raw_request, [call])

      assert length(requested_paths()) == 2
    end
  end

  describe "the response cache" do
    # Their own scan hosts, because the cache is per node and keyed by origin:
    # sharing the real host with the rest of this file would mean sharing
    # entries with it.
    test "a repeated reference read is served from the cache" do
      handle = handle(scan_routes(), cache: true, scan_url: "https://cache-c.example/v0")

      assert {:ok, first} = Backend.call(handle, :chain_info)
      assert {:ok, second} = Backend.call(handle, :chain_info)

      assert first == second
      assert [_one] = requested_paths()
    end

    test "a non-2xx is not cached, so a refusal cannot outlive the breaker" do
      routes = Map.put(scan_routes(), "/v0/dso", {403, "RBAC: access denied"})

      handle = handle(routes, cache: true, scan_url: "https://cache-d.example/v0")

      assert {:error, {:http, 403}} = Backend.call(handle, :chain_info)
      assert {:error, {:http, 403}} = Backend.call(handle, :chain_info)

      assert length(requested_paths()) == 2
    end

    test "a body that is not JSON is a decode failure, not a crash" do
      routes = Map.put(scan_routes(), "/v0/dso", "<html>not json</html>")

      assert {:error, {:decode_failed, :json}} = Backend.call(handle(routes), :chain_info)
    end
  end

  describe "the rate-limit seed" do
    test "covers one cold read, then refuses the next burst rather than sending it" do
      # The refill is a guess anchored on an observed 429 threshold; the
      # capacity is derived, and this is the derivation. A cold
      # `token_balances/3` is four requests: the DSO body, the ACS snapshot, the
      # asset catalog and the page itself.
      assert Canton.rate_limit()[:capacity] == 4
      assert Canton.rate_limit()[:refill_per_second] == 0.2

      handle = handle(scan_routes(), metered: true, scan_url: "https://metered.example/v0")

      assert {:ok, _page} = Backend.call(handle, :token_balances, [@party])
      assert length(requested_paths()) == 4

      # And the next one is refused by our own bucket rather than being sent and
      # answered 429 by somebody else's, which is what the seed is for.
      assert {:error, {:rate_limited, retry_after_ms}} =
               Backend.call(handle, :token_balances, [@party])

      assert retry_after_ms > 0
      assert [] == requested_paths()
    end
  end

  describe "against a real upstream" do
    # Generous bounds, and the backend's OWN rate-limit seed rather than a
    # widened one. What these prove is that the callbacks answer and that a
    # cursor pages, not that somebody else's service is fast, and none of them
    # asserts on measured elapsed time.
    #
    # Widening the bucket here was tried first and it made the upstream answer
    # 429 to the burst, which is the honest reason the seed is small. So the
    # live tests keep the seed and WAIT OUT its refusal through `paced/1`
    # below: `{:rate_limited, ms}` carries how long to wait, and waiting it out
    # is exactly the caller behaviour `Raxol.Web3.HTTP` documents when it
    # explains why it does not sleep inside the client. The breaker is given
    # room because a transient 429 from a shared origin must not quarantine the
    # rest of the run.
    defp live(opts \\ []) do
      http_opts = [
        chunk_timeout_ms: 30_000,
        deadline_ms: 60_000,
        breaker: [failure_threshold: 200]
      ]

      Keyword.merge([http_opts: http_opts], opts)
    end

    # Retries exactly two outcomes, both of which mean "wait": our own bucket's
    # `{:rate_limited, ms}`, for the duration that term itself names, and the
    # upstream's `{:http, 429}`, for a fixed backoff, because this host
    # publishes no limit and sends no `retry-after` this package reads. Every
    # other outcome is returned untouched, so a host that is actually down, or
    # a shape that actually changed, is still a red test rather than something
    # this helper waits out. No assertion is made on how long it took.
    @upstream_429_backoff_ms 6_000

    defp paced(fun, attempts \\ 12) do
      case fun.() do
        {:error, {:rate_limited, ms}} when attempts > 0 ->
          Process.sleep(ms + 100)
          paced(fun, attempts - 1)

        {:error, {:http, 429}} when attempts > 0 ->
          Process.sleep(@upstream_429_backoff_ms)
          paced(fun, attempts - 1)

        result ->
          result
      end
    end

    # The skip below is attached to exactly ONE test, by name, and it is
    # computed here rather than checked inside a test body. That is the whole
    # enforcement: the keyless tests carry no such tag, so removing the
    # credential from the environment cannot silence them. They run, and they
    # fail if the keyless host stops answering, which is the thing that would
    # otherwise turn this describe block quietly green on nothing.
    @ccscan_key System.get_env("RAXOL_CCSCAN_KEY")

    @tag :live_web3
    @tag timeout: 300_000
    test "the two required callbacks answer keyless, which is the corrected finding" do
      {:ok, handle} = Canton.new("canton:global", live())

      assert {:ok, info} = paced(fn -> Backend.call(handle, :chain_info) end)
      assert info.chain_ref == "canton:global"
      assert info.average_block_time_ms > 0

      assert {:ok, height} = paced(fn -> Backend.call(handle, :block_height) end)
      assert height.unit == :round
      # 113,141 on 2026-09-14, and a round ticks every ten minutes.
      assert height.height > 100_000
      assert height.finalized_height == height.height
      assert height.indexer.finished? == true
    end

    @tag :live_web3
    @tag timeout: 300_000
    test "a real party id answers for a balance and a holdings page" do
      {:ok, handle} = Canton.new("canton:global", live())

      assert {:ok, account} = paced(fn -> Backend.call(handle, :account_info, [@party]) end)
      assert account.ref == @party
      assert is_integer(account.balance)
      refute Map.has_key?(account, :kind)

      assert {:ok, page} = paced(fn -> Backend.call(handle, :token_balances, [@party]) end)
      assert page.items != []
      assert Enum.all?(page.items, &is_integer(&1.amount))
    end

    @tag :live_web3
    @tag timeout: 300_000
    test "a cursor is accepted by the live endpoint and advances the walk" do
      # The DSO holds no amulet, so its pages are empty and its cursor is
      # non-null: exactly the case that proves `next` must come from the token
      # rather than from the items.
      {:ok, handle} = Canton.new("canton:global", live())

      assert {:ok, first} = paced(fn -> Backend.call(handle, :token_balances, [@dso]) end)
      assert is_binary(first.next)

      assert {:ok, second} =
               paced(fn ->
                 Backend.call(handle, :token_balances, [@dso, [cursor: first.next]])
               end)

      assert is_binary(second.next)

      origin = Origin.id(URI.new!("https://api.cantonnodes.com/v0"))
      assert {:ok, one} = Cursor.decode(first.next, origin, :canton_holdings_state)
      assert {:ok, two} = Cursor.decode(second.next, origin, :canton_holdings_state)
      assert two["after"] > one["after"]
    end

    @tag :live_web3
    @tag timeout: 300_000
    test "a real update id answers for a transaction" do
      {:ok, handle} = Canton.new("canton:global", live())

      assert {:ok, transaction} =
               paced(fn -> Backend.call(handle, :get_transaction, [@update_id]) end)

      assert transaction.hash == @update_id
      assert transaction.status == :success
      assert is_binary(transaction.method)
    end

    @tag :live_web3
    @tag skip: is_nil(@ccscan_key) && "set RAXOL_CCSCAN_KEY to exercise the ccscan passthrough"
    test "the ccscan passthrough answers with a credential" do
      {:ok, handle} = Canton.new("canton:global", live(ccscan_key: @ccscan_key))

      assert {:ok, payload} =
               paced(fn ->
                 Backend.call(handle, :raw_request, [
                   %{tool: "get_network_overview", arguments: %{}}
                 ])
               end)

      assert is_map(payload)
      # Whatever it carries, it is not the refusal every keyless call gets.
      refute payload["error"] == "account_required"
    end

    @tag :live_web3
    test "without a credential the live ccscan surface refuses in the named way" do
      # Runs whether or not a key is configured, because this is the refusal
      # path rather than the success path, and it is reachable keyless.
      {:ok, handle} = Canton.new("canton:global", live())

      assert {:error, {:upstream_refused, :auth}} =
               paced(fn ->
                 Backend.call(handle, :raw_request, [
                   %{tool: "get_network_overview", arguments: %{}}
                 ])
               end)
    end
  end
end
