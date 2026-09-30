defmodule Raxol.Web3.FXTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.FX
  alias Raxol.Web3.FX.{Chainlink, Quality, Sleuth}
  alias Raxol.Web3.MCP.FXTools

  @sleuth_fixtures Path.expand("../../fixtures/sleuth", __DIR__)
  @chainlink_fixtures Path.expand("../../fixtures/chainlink", __DIR__)

  @key "test-key-not-real"

  # Recorded 2026-09-30 from the live API and the live feeds. A fixture is what
  # the upstream said, so a changed shape is a red test here rather than a
  # production surprise.
  defp sleuth_fixture(name), do: File.read!(Path.join(@sleuth_fixtures, "#{name}.json"))
  defp feed(name), do: Jason.decode!(File.read!(Path.join(@chainlink_fixtures, "#{name}.json")))

  defp limits do
    [
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _host, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end
    ]
  end

  # -- Sleuth --------------------------------------------------------------------

  defp sleuth(routes) do
    exchange = fn _vetted, request, _opts ->
      send(self(), {:request, request})
      [path | _] = String.split(request.path, "?")

      case Map.fetch(routes, path) do
        {:ok, {status, body}} -> {:ok, %{status: status, headers: [], body: body}}
        {:ok, body} -> {:ok, %{status: 200, headers: [], body: body}}
        :error -> {:ok, %{status: 404, headers: [], body: ~s({"error":"not found"})}}
      end
    end

    {:ok, sleuth} =
      Sleuth.new(api_key: @key, cache: false, http_opts: [{:exchange, exchange} | limits()])

    sleuth
  end

  describe "Sleuth" do
    test "the key travels as a Bearer header and never in the URL or inspect/1" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      assert {:ok, _} = Sleuth.stables(s, partner_only: true)

      assert_received {:request, request}
      assert {"authorization", "Bearer " <> @key} in request.headers
      refute request.path =~ @key
      assert request.path == "/api/mcp/fx/stables?partnerOnly=1"
      refute inspect(s) =~ @key
    end

    test "neither the key nor a keyed RPC URL renders from a crashed holder's state" do
      # The FX handle sits in every agent tool context, and a GenServer that
      # crashes holding one has its state formatted into the crash report.
      rpc_key = "rpc-provider-key-not-real"
      chainlink = Chainlink.new(rpc_urls: %{8453 => "https://base.example/v2/#{rpc_key}"})
      fx = FX.new(sleuth(%{}), chainlink)

      refute inspect(fx, limit: :infinity) =~ @key
      refute inspect(fx, limit: :infinity) =~ rpc_key

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} = Agent.start(fn -> %{fx: fx} end)
          ref = Process.monitor(pid)
          Agent.cast(pid, fn _state -> raise "boom" end)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
          Logger.flush()
        end)

      # Without this the refutations below would pass on an empty log.
      assert log =~ "Raxol.Web3.FX.Chainlink"
      refute log =~ rpc_key
      refute log =~ @key

      # And the handle still holds what it needs to read the feed.
      assert chainlink.rpc_urls[8453] =~ rpc_key
    end

    test "figures are Decimals and symbols are canonical Assets symbols" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      assert {:ok, snapshot} = Sleuth.stables(s)

      symbols = Enum.map(snapshot.assets, & &1.symbol)
      assert "EURe" in symbols
      assert "ZCHF" in symbols
      refute "EURE" in symbols

      for asset <- snapshot.assets do
        assert %Decimal{} = asset.price_usd
        assert is_integer(asset.sleuth_deviation_bps)
      end

      assert %Decimal{} = snapshot.sleuth_fx_rates_usd["EUR"]
    end

    test "detail carries top pools and a canonical symbol" do
      s = sleuth(%{"/api/mcp/fx/stables/EURC" => sleuth_fixture("stable_eurc")})
      assert {:ok, %{asset: asset}} = Sleuth.stable(s, "EURC")

      assert asset.symbol == "EURC"
      assert [%{price_usd: %Decimal{}, pair: "0x" <> _} | _] = asset.top_pools
    end

    test "EURe is looked up by Sleuth's own name" do
      s = sleuth(%{"/api/mcp/fx/stables/EURE" => sleuth_fixture("stable_eurc")})
      assert {:ok, _} = Sleuth.stable(s, "EURe")
      assert_received {:request, %{path: "/api/mcp/fx/stables/EURE"}}
    end

    test "corridors drop their asset lists unless asked" do
      s = sleuth(%{"/api/mcp/fx/corridors" => sleuth_fixture("corridors")})

      assert {:ok, %{corridors: [first | _]}} = Sleuth.corridors(s)
      refute Map.has_key?(first, :assets)
      assert is_integer(first.asset_count)

      assert {:ok, %{corridors: [with_assets | _]}} = Sleuth.corridors(s, include_assets: true)
      assert is_list(with_assets.assets)
    end

    test "bad arguments are refused before any request is built" do
      s = sleuth(%{})

      assert {:error, {:invalid_argument, "limit"}} = Sleuth.stables(s, limit: 301)
      assert {:error, {:invalid_argument, "sort"}} = Sleuth.stables(s, sort: "garbage")
      assert {:error, {:invalid_argument, "corridor"}} = Sleuth.stables(s, corridor: "eur")
      assert {:error, {:invalid_argument, "api_key"}} = Sleuth.stables(s, api_key: "x")
      assert {:error, {:invalid_argument, "symbol"}} = Sleuth.stable(s, "../manifest")

      refute_received {:request, _}
    end

    test "refusals map to the closed taxonomy and carry no upstream text" do
      body = ~s({"error":"invalid key upstream-echoed-secret"})

      for {status, reason} <- [
            {401, {:upstream_refused, :auth}},
            {404, {:upstream_refused, :not_found}},
            {429, {:upstream_refused, :rate_limit}},
            {400, {:invalid_argument, "query"}},
            {502, {:http, 502}}
          ] do
        s = sleuth(%{"/api/mcp/fx/stables" => {status, body}})
        assert Sleuth.stables(s) == {:error, reason}
      end
    end

    test "a body that is not the documented shape is a decode failure" do
      s = sleuth(%{"/api/mcp/fx/stables" => ~s({"assets":"nope"})})
      assert Sleuth.stables(s) == {:error, {:decode_failed, :sleuth}}
    end

    test "new/1 requires a key and an https base" do
      assert {:error, {:missing_argument, "api_key"}} = Sleuth.new([])

      assert {:error, {:invalid_argument, "base_url"}} =
               Sleuth.new(api_key: "k", base_url: "http://www.sleuthintel.io/api/mcp")
    end
  end

  # -- Chainlink -----------------------------------------------------------------

  @feeds ~w(eur_usd_base eur_usd_ethereum chf_usd_ethereum sequencer_base)

  # Answers `eth_call` from the recorded feeds, keyed by (chain, proxy,
  # selector). `overrides` replaces a recorded result, by the same key.
  defp chainlink(opts \\ []) do
    overrides = Keyword.get(opts, :overrides, %{})

    table =
      for name <- @feeds, rec = feed(name), {selector, field} <- selectors(), into: %{} do
        {{rec["chain_id"], String.downcase(rec["proxy"]), selector}, rec[field]}
      end
      |> Map.merge(overrides)

    exchange = fn _vetted, request, _opts ->
      chain = if request.path =~ "base", do: 8453, else: 1

      %{"id" => id, "params" => [%{"to" => to, "data" => data}, _tag]} =
        Jason.decode!(request.body)

      result = Map.fetch!(table, {chain, String.downcase(to), data})

      {:ok,
       %{status: 200, headers: [], body: Jason.encode!(%{jsonrpc: "2.0", id: id, result: result})}}
    end

    Chainlink.new(
      rpc_urls:
        Keyword.get(opts, :rpc_urls, %{
          1 => "https://rpc.test/eth",
          8453 => "https://rpc.test/base"
        }),
      http_opts: [{:exchange, exchange} | limits()],
      now: fn -> Keyword.get(opts, :now, recorded_at()) end,
      cache: false
    )
  end

  defp selectors,
    do: [
      {"0x7284e416", "description"},
      {"0x313ce567", "decimals"},
      {"0xfeaf968c", "latestRoundData"}
    ]

  defp updated_at(name) do
    {:ok, %{updated_at: at}} = Chainlink.decode_round(feed(name)["latestRoundData"])
    at
  end

  # The moment the fixtures were read: every feed was fresh then.
  defp recorded_at do
    feed("eur_usd_base")["read_at"]
    |> DateTime.from_iso8601()
    |> elem(1)
    |> DateTime.to_unix()
  end

  defp word(n), do: n |> :binary.encode_unsigned() |> String.pad_leading(32, <<0>>)

  defp round_hex(answer, started_at, updated_at) do
    "0x" <>
      Base.encode16(word(1) <> word(answer) <> word(started_at) <> word(updated_at) <> word(1),
        case: :lower
      )
  end

  @base_eur "0xc91d87e81fab8f93699ecf7ee9b44d11e1d53f0f"
  @eth_eur "0xb49f677943bc038e9857d61e7d053caa2c1734c1"
  @base_seq "0xbcf85224fc0756b9fa45aa7892530b47e10b6433"

  describe "Chainlink" do
    test "EUR comes from the Base feed first, with its precision" do
      assert {:ok, rate} = Chainlink.rate(chainlink(), "EUR")

      assert rate.source == {8453, "0xc91D87E81faB8f93699ECf7Ee9B44D11e1D53F0F"}
      assert rate.precision_bps == 10
      assert Decimal.gt?(rate.rate, "1.0") and Decimal.lt?(rate.rate, "1.3")
    end

    test "CHF comes from Ethereum, USD is the identity, anything else has no feed" do
      assert {:ok, %{source: {1, _}, precision_bps: 15}} = Chainlink.rate(chainlink(), "CHF")
      assert {:ok, %{rate: one, source: :identity}} = Chainlink.rate(chainlink(), "USD")
      assert Decimal.equal?(one, 1)
      assert {:error, :no_feed} = Chainlink.rate(chainlink(), "GBP")
    end

    test "a stale primary fails over; the fallback's own heartbeat still applies" do
      # Past Base's 3960 s budget, well inside Ethereum's 95040 s.
      now = updated_at("eur_usd_base") + 3_961
      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(now: now), "EUR")

      # Past both, so no rate at all, reported by the primary.
      now = updated_at("eur_usd_ethereum") + 95_041
      assert {:error, :stale} = Chainlink.rate(chainlink(now: now), "EUR")
    end

    test "the freshness margin is exactly heartbeat * 1.1" do
      at = updated_at("chf_usd_ethereum")
      assert {:ok, _} = Chainlink.rate(chainlink(now: at + 95_040), "CHF")
      assert {:error, :stale} = Chainlink.rate(chainlink(now: at + 95_041), "CHF")
    end

    test "a down or freshly restarted Base sequencer skips the Base feed" do
      now = recorded_at()

      down = %{{8453, @base_seq, "0xfeaf968c"} => round_hex(1, now - 7_200, now)}
      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(overrides: down), "EUR")

      restarted = %{{8453, @base_seq, "0xfeaf968c"} => round_hex(0, now - 60, now)}
      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(overrides: restarted), "EUR")
    end

    test "a proxy that is not the expected pair is blocked, not failed over" do
      wrong = %{{8453, @base_eur, "0x7284e416"} => feed("chf_usd_ethereum")["description"]}

      assert {:error, {:blocked, :feed_mismatch}} =
               Chainlink.rate(chainlink(overrides: wrong), "EUR")
    end

    test "a non-positive answer is not a rate" do
      now = recorded_at()
      zero = %{{1, @eth_eur, "0xfeaf968c"} => round_hex(0, now, now)}

      assert {:error, :bad_answer} =
               Chainlink.rate(
                 chainlink(overrides: zero, rpc_urls: %{1 => "https://rpc.test/eth"}),
                 "EUR"
               )
    end

    test "a chain with no configured RPC URL is skipped" do
      assert {:ok, %{source: {1, _}}} =
               Chainlink.rate(chainlink(rpc_urls: %{1 => "https://rpc.test/eth"}), "EUR")

      assert {:error, :no_rpc} = Chainlink.rate(chainlink(rpc_urls: %{}), "EUR")
    end
  end

  # -- Quality -------------------------------------------------------------------

  defp asset(fields),
    do:
      Map.merge(
        %{peg_currency: "EUR", yield_bearing?: false, price_usd: Decimal.new("1.1350")},
        Map.new(fields)
      )

  defp rates, do: %{"EUR" => {:ok, %{rate: Decimal.new("1.1350"), precision_bps: 10}}}

  describe "Quality" do
    test "the 100 bps boundary: at it is ok, past it is suspect" do
      at = asset(price_usd: Decimal.new("1.146350"))
      past = asset(price_usd: Decimal.new("1.146464"))

      assert %{status: :ok, deviation_bps: 100} = Quality.judge(at, rates())
      assert %{status: :suspect, deviation_bps: 101} = Quality.judge(past, rates())
      assert %{status: :suspect} = Quality.judge(asset(price_usd: Decimal.new("1.1235")), rates())
    end

    test "yield-bearing wins over everything, and gets no deviation" do
      verdict = Quality.judge(asset(yield_bearing?: true, price_usd: Decimal.new("9")), rates())
      assert %{status: :yield_bearing, deviation_bps: nil} = verdict
    end

    test "no usable rate, or no feed at all, is :no_rate" do
      assert %{status: :no_rate} = Quality.judge(asset(peg_currency: "GBP"), rates())
      assert %{status: :no_rate} = Quality.judge(asset([]), %{"EUR" => {:error, :stale}})
    end

    test "an asset with no price cannot be verified, so it is suspect" do
      assert %{status: :suspect, deviation_bps: nil} =
               Quality.judge(asset(price_usd: nil), rates())
    end
  end

  describe "FX, end to end on the recorded data" do
    test "every asset carries our verdict, and the known outliers land where they should" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_deviation")})
      fx = FX.new(s, chainlink())

      assert {:ok, %{assets: assets}} = FX.stables(fx, sort: "deviationBps", limit: 6)
      by_symbol = Map.new(assets, &{&1.symbol, &1.quality})

      # REUR: a fiat-backed EUR token priced at $4.13.
      assert %{status: :suspect} = by_symbol["REUR"]
      assert %{status: :yield_bearing} = by_symbol["USDY"]
    end

    test "the partner set judges ok against Chainlink, not against Sleuth's stale rates" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      assert {:ok, %{assets: assets}} = FX.stables(FX.new(s, chainlink()), partner_only: true)

      for %{symbol: symbol, quality: quality} <- assets do
        assert quality.status == :ok, "#{symbol}: #{inspect(quality)}"
      end
    end
  end

  describe "MCP tools" do
    defp tool(fx, name), do: Enum.find(FXTools.tool_defs(fx), &(&1.name == name))

    test "every tool is prefixed web3_fx_, read-only and sensitive" do
      fx = FX.new(sleuth(%{}), chainlink())

      for %{name: name, annotations: annotations} <- FXTools.tool_defs(fx) do
        assert String.starts_with?(name, "web3_fx_")
        assert annotations == %{readOnlyHint: true, sensitive: true}
      end
    end

    test "a result is JSON with string figures and our verdict on every asset" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      stables = tool(FX.new(s, chainlink()), "web3_fx_stables")

      assert {:ok, result} = stables.callback.(%{"partner_only" => true})
      decoded = result |> Jason.encode!() |> Jason.decode!()

      eure = Enum.find(decoded["assets"], &(&1["symbol"] == "EURe"))
      assert is_binary(eure["price_usd"])
      assert %{"status" => "ok", "rate" => rate, "deviation_bps" => bps} = eure["quality"]
      assert is_binary(rate) and is_integer(bps)
    end

    test "bad arguments answer a closed error code and send nothing" do
      fx = FX.new(sleuth(%{}), chainlink())

      assert {:error, %{code: "invalid_argument", detail: "limit"}} =
               tool(fx, "web3_fx_stables").callback.(%{"limit" => 9_999})

      assert {:error, %{code: "missing_argument", detail: "symbol"}} =
               tool(fx, "web3_fx_stable").callback.(%{})

      assert {:error, %{code: "invalid_argument", detail: "include_assets"}} =
               tool(fx, "web3_fx_corridors").callback.(%{"include_assets" => "yes"})

      refute_received {:request, _}
    end

    test "an upstream refusal is not counted against the tool unless it is a fault" do
      s = sleuth(%{"/api/mcp/fx/stables/NOPE" => {404, ~s({"error":"x"})}})
      stable = tool(FX.new(s, chainlink()), "web3_fx_stable")

      assert {:error, error} = stable.callback.(%{"symbol" => "NOPE"})
      refute stable.fault?.(error)
      assert stable.fault?.(%{code: "upstream_refused", detail: :auth})
    end
  end

  describe "price_fn/2" do
    test "EUR and CHF stables price at the Chainlink rate; everything else falls back" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      fx = FX.new(s, chainlink())
      {:ok, eur} = Chainlink.rate(fx.chainlink, "EUR")
      {:ok, chf} = Chainlink.rate(fx.chainlink, "CHF")

      price =
        FX.price_fn(fx, fn
          "ETH" -> Decimal.new("2500")
          _ -> nil
        end)

      assert price.("EURe") == eur.rate
      assert price.("EURC") == eur.rate
      assert price.("ZCHF") == chf.rate
      assert price.("ETH") == Decimal.new("2500")
      # Dollar stables are the ledger's own business (usdc_price), not ours.
      assert price.("USDT") == nil

      # One snapshot at build time, none per lookup.
      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "a non-ok EUR asset is nil and never falls through to the fallback" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      price = FX.price_fn(FX.new(s, chainlink(rpc_urls: %{})), fn _ -> Decimal.new(1) end)

      assert price.("EURe") == nil
      assert price.("WETH") == Decimal.new(1)
    end

    test "a failed snapshot prices only through the fallback" do
      s = sleuth(%{"/api/mcp/fx/stables" => {401, "{}"}})

      price =
        ExUnit.CaptureLog.with_log(fn ->
          FX.price_fn(FX.new(s, chainlink()), fn _ -> :fallback end)
        end)
        |> elem(0)

      assert price.("EURe") == :fallback
    end
  end
end
