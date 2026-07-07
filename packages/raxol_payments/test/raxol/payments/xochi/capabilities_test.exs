defmodule Raxol.Payments.Xochi.CapabilitiesTest do
  # async: false -- get/1 caches in a shared named ETS table.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Assets
  alias Raxol.Payments.Xochi.Capabilities

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdt_tron "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @tron 728_126_428
  @solana 792_703_809

  # Pre-WP-E wire shape: chains carry chain_id + chain_name only.
  @wire_evm %{
    "cross_chain_only" => true,
    "order_bounds_usd" => %{"min" => 1, "max" => 25_000},
    "chains" => [
      %{"chain_id" => 8453, "chain_name" => "Base"},
      %{"chain_id" => 42_161, "chain_name" => "Arbitrum One"}
    ],
    "tokens" => [
      %{
        "symbol" => "USDC",
        "roles" => ["origin", "destination"],
        "addresses" => %{"8453" => @usdc_base}
      },
      %{"symbol" => "WETH", "roles" => ["destination"], "addresses" => %{}}
    ]
  }

  # WP-E wire shape: vm_type present, Tron corridor advertised.
  @wire_multi_vm Map.update!(@wire_evm, "chains", fn chains ->
                   chains ++
                     [
                       %{"chain_id" => @tron, "chain_name" => "Tron", "vm_type" => "tvm"},
                       %{"chain_id" => @solana, "chain_name" => "Solana", "vm_type" => "svm"}
                     ]
                 end)
                 |> Map.update!("tokens", fn tokens ->
                   [
                     %{
                       "symbol" => "USDT",
                       "roles" => ["destination"],
                       "addresses" => %{Integer.to_string(@tron) => @usdt_tron}
                     }
                     | tokens
                   ]
                 end)

  setup do
    Capabilities.reset()
    on_exit(fn -> Capabilities.reset() end)
    :ok
  end

  defp json_plug(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  describe "parse/1" do
    test "parses the worker-wrapped shape, carrying the source" do
      assert {:ok, caps} = Capabilities.parse(%{"source" => "live", "capabilities" => @wire_evm})
      assert caps.source == :live
      assert Capabilities.chain_ids(caps) == [8453, 42_161]

      assert {:ok, fallback} =
               Capabilities.parse(%{"source" => "fallback", "capabilities" => @wire_evm})

      assert fallback.source == :fallback
    end

    test "parses a bare matrix, defaulting absent vm_type to :evm" do
      assert {:ok, caps} = Capabilities.parse(@wire_evm)
      assert Capabilities.vm_type(caps, 8453) == :evm
    end

    test "parses vm_type when present (WP-E shape)" do
      assert {:ok, caps} = Capabilities.parse(@wire_multi_vm)
      assert Capabilities.vm_type(caps, @tron) == :tvm
      assert Capabilities.vm_type(caps, @solana) == :svm
      assert Capabilities.vm_type(caps, 8453) == :evm
      # Unknown chain defaults conservatively.
      assert Capabilities.vm_type(caps, 999) == :evm
    end

    test "drops malformed entries and unknown vm types without failing" do
      wire =
        @wire_evm
        |> Map.update!("chains", &(&1 ++ [%{"chain_name" => "no id"}, "garbage"]))
        |> Map.update!("tokens", &(&1 ++ [%{"roles" => ["origin"]}, 42]))
        |> Map.put("future_field", %{"nested" => true})

      assert {:ok, caps} = Capabilities.parse(wire)
      assert Capabilities.chain_ids(caps) == [8453, 42_161]
      assert Enum.map(caps.tokens, & &1.symbol) == ["USDC", "WETH"]
    end

    test "returns :error on structurally unusable input" do
      assert :error = Capabilities.parse(nil)
      assert :error = Capabilities.parse("nope")
      assert :error = Capabilities.parse(%{})
      assert :error = Capabilities.parse(%{"chains" => [], "tokens" => []})
      assert :error = Capabilities.parse(%{"chains" => [%{"chain_name" => "x"}], "tokens" => []})
    end
  end

  describe "fallback/0" do
    test "reproduces the static Assets universe exactly" do
      caps = Capabilities.fallback()
      assert caps.source == :fallback
      assert Capabilities.chain_ids(caps) == Assets.supported_chain_ids()

      for symbol <- Assets.symbols(),
          {chain, address} <- Assets.evm_tokens()[symbol] do
        assert Capabilities.fillable?(caps, chain, address, :origin)
        assert Capabilities.fillable?(caps, chain, address, :destination)
        assert Assets.known?(chain, address)
      end
    end
  end

  describe "fillable?/4" do
    test "is direction-aware" do
      {:ok, caps} = Capabilities.parse(@wire_multi_vm)
      assert Capabilities.fillable?(caps, @tron, @usdt_tron, :destination)
      refute Capabilities.fillable?(caps, @tron, @usdt_tron, :origin)
    end

    test "compares EVM addresses case-insensitively, base58 case-sensitively" do
      {:ok, caps} = Capabilities.parse(@wire_multi_vm)
      assert Capabilities.fillable?(caps, 8453, String.upcase(@usdc_base), :origin)
      refute Capabilities.fillable?(caps, @tron, String.downcase(@usdt_tron), :destination)
    end

    test "rejects unadvertised chains and blank tokens" do
      {:ok, caps} = Capabilities.parse(@wire_evm)
      refute Capabilities.fillable?(caps, 1, @usdc_base, :origin)
      refute Capabilities.fillable?(caps, 8453, "", :origin)
      refute Capabilities.fillable?(caps, 8453, nil, :origin)
    end
  end

  describe "valid_address?/3" do
    test "dispatches on the chain's vm family" do
      {:ok, caps} = Capabilities.parse(@wire_multi_vm)

      assert Capabilities.valid_address?(caps, 8453, @usdc_base)
      refute Capabilities.valid_address?(caps, 8453, @usdt_tron)

      # Tron leg: full Base58Check via Raxol.Payments.Tron.Address.
      assert Capabilities.valid_address?(caps, @tron, @usdt_tron)
      refute Capabilities.valid_address?(caps, @tron, @usdc_base)
      # Structural base58 but a corrupt checksum must fail (real USDT address, last char flipped).
      refute Capabilities.valid_address?(caps, @tron, "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6u")

      # Solana leg: structural base58, 32-44 chars.
      assert Capabilities.valid_address?(
               caps,
               @solana,
               "So11111111111111111111111111111111111111112"
             )

      refute Capabilities.valid_address?(caps, @solana, @usdc_base)
    end
  end

  describe "fetch/1 and get/1" do
    test "fetch unwraps the worker envelope over HTTP" do
      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(%{"source" => "live", "capabilities" => @wire_evm})]
      }

      assert {:ok, caps} = Capabilities.fetch(config)
      assert caps.source == :live
      assert Capabilities.chain_ids(caps) == [8453, 42_161]
    end

    test "fetch surfaces HTTP and parse failures as errors" do
      bad = %{base_url: "https://api.xochi.fi", req_options: [plug: json_plug(%{}, 503)]}
      assert {:error, {:http, 503, _}} = Capabilities.fetch(bad)

      garbage = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(%{"nope" => 1})]
      }

      assert {:error, :unparseable_capabilities} = Capabilities.fetch(garbage)
    end

    test "get caches within the TTL and degrades to fallback on a cold failure" do
      counter = :counters.new(1, [])

      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [
          plug: fn conn ->
            :counters.add(counter, 1, 1)
            json_plug(%{"source" => "live", "capabilities" => @wire_evm}).(conn)
          end
        ]
      }

      assert %{source: :live} = Capabilities.get(config)
      assert %{source: :live} = Capabilities.get(config)
      assert :counters.get(counter, 1) == 1

      Capabilities.reset()
      down = %{base_url: "https://api.xochi.fi", req_options: [plug: json_plug(%{}, 503)]}
      assert %{source: :fallback} = caps = Capabilities.get(down)
      assert Capabilities.chain_ids(caps) == Assets.supported_chain_ids()
    end

    test "get serves the stale cached matrix when a refresh fails" do
      live = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(%{"source" => "live", "capabilities" => @wire_evm})]
      }

      assert %{source: :live} = Capabilities.get(live, ttl_ms: 0)

      down = %{base_url: "https://api.xochi.fi", req_options: [plug: json_plug(%{}, 503)]}
      assert %{source: :live} = caps = Capabilities.get(down, ttl_ms: 0)
      assert Capabilities.chain_ids(caps) == [8453, 42_161]
    end

    test "get with nil config never touches the network" do
      assert %{source: :fallback} = Capabilities.get(nil)
    end
  end
end
