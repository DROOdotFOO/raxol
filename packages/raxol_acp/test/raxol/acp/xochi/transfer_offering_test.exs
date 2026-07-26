defmodule Raxol.ACP.Xochi.TransferOfferingTest do
  # async: false -- the deliver tests set/clear :xochi_transfer_settler app env.
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.{Offering, TransferOffering}

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_arb "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
  @usdt_base "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2"
  @usdt_arb "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"
  @weth_base "0x4200000000000000000000000000000000000006"
  @weth_arb "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"
  @usdt_poly "0xc2132d05d31c914a87c6611c10748aeb04b58e8f"
  @usdg_robinhood "0x5fc5360d0400a0fd4f2af552add042d716f1d168"

  @ctx %{job_id: "j1", buyer: "0xbuyer", seller: "0xseller", state: :request}

  setup do
    Application.delete_env(:raxol_acp, :xochi_transfer_settler)
    Raxol.Payments.Xochi.Capabilities.reset()

    on_exit(fn ->
      Application.delete_env(:raxol_acp, :xochi_transfer_settler)
      Raxol.Payments.Xochi.Capabilities.reset()
    end)

    :ok
  end

  defp req(overrides) do
    Map.merge(
      %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 42_161,
        "src_token" => @usdc_base,
        "dst_token" => @usdc_arb,
        "amount_atomic" => "1100000",
        "signed_intent" => %{
          "intent_id" => "xi_1",
          "quote_id" => "xq_1",
          "signature" => "0x" <> String.duplicate("11", 65),
          "nonce" => 7,
          "pull_signature" => "0x" <> String.duplicate("22", 65)
        }
      },
      overrides
    )
  end

  describe "use Raxol.ACP.Offering DSL" do
    test "exposes the declared offering metadata" do
      assert TransferOffering.offering_name() == "xochi_cross_chain_transfer"
      assert Decimal.equal?(TransferOffering.price_usdc(), Decimal.new("0.25"))
      assert TransferOffering.sla_minutes() == 10
      assert TransferOffering.cluster() == "on_chain"
    end

    test "schemas delegate to the Xochi.Offering draft (single source of truth)" do
      assert TransferOffering.requirements_schema() == Offering.requirement_schema()
      assert TransferOffering.deliverables_schema() == Offering.deliverable_schema()
    end

    test "spec/0 builds a registrable spec pointing back at this handler" do
      spec = TransferOffering.spec()
      assert spec.name == "xochi_cross_chain_transfer"
      assert spec.handler == TransferOffering
      assert spec.cluster == "on_chain"
      assert spec.requirements_schema["type"] == "object"
    end
  end

  describe "handle_request/2 accepts supported corridors" do
    test "USDC Base -> Arbitrum" do
      r = req(%{})
      assert {:accept, ^r} = TransferOffering.handle_request(r, @ctx)
    end

    test "USDT Base -> Arbitrum (Permit2 token)" do
      r = req(%{"src_token" => @usdt_base, "dst_token" => @usdt_arb})
      assert {:accept, ^r} = TransferOffering.handle_request(r, @ctx)
    end

    test "WETH Base -> Arbitrum (18-decimal token)" do
      r = req(%{"src_token" => @weth_base, "dst_token" => @weth_arb})
      assert {:accept, ^r} = TransferOffering.handle_request(r, @ctx)
    end

    test "a stealth settlement to a different recipient is relayed, not gated (#368)" do
      # The privacy tier and recipient live inside the buyer's opaque signed
      # intent; the storefront relays it verbatim. So a requirement declaring
      # settlement_preference "stealth" and a destination distinct from the
      # funder must be accepted -- raxol has no same-owner or public-only gate.
      r =
        req(%{
          "settlement_preference" => "stealth",
          "destination" => "0x" <> String.duplicate("fe", 20)
        })

      assert {:accept, ^r} = TransferOffering.handle_request(r, @ctx)
    end
  end

  describe "handle_request/2 rejects bad requests before escrow" do
    test "a malformed requirement (missing fields)" do
      assert {:reject, :malformed_requirement} =
               TransferOffering.handle_request(%{"src_chain_id" => 8453}, @ctx)
    end

    test "a same-chain transfer" do
      r = req(%{"dst_chain_id" => 8453, "dst_token" => @usdc_base})
      assert {:reject, :not_cross_chain} = TransferOffering.handle_request(r, @ctx)
    end

    test "a non-positive amount" do
      assert {:reject, :non_positive_amount} =
               TransferOffering.handle_request(req(%{"amount_atomic" => "0"}), @ctx)

      assert {:reject, :non_positive_amount} =
               TransferOffering.handle_request(req(%{"amount_atomic" => "nope"}), @ctx)
    end

    test "an unsupported source token" do
      bogus = "0x" <> String.duplicate("ab", 20)

      assert {:reject, {:unsupported_src_token, 8453, ^bogus}} =
               TransferOffering.handle_request(req(%{"src_token" => bogus}), @ctx)
    end

    test "an unsupported destination chain" do
      # Solana-ish chain id with the Base USDC address -- not in the registry.
      r = req(%{"dst_chain_id" => 999, "dst_token" => @usdc_base})

      assert {:reject, {:unsupported_dst_token, 999, @usdc_base}} =
               TransferOffering.handle_request(r, @ctx)
    end
  end

  describe "handle_deliver/2" do
    test "fails closed when no settler is configured" do
      assert {:error, {:settler_not_configured, missing}} =
               TransferOffering.handle_deliver(req(%{}), @ctx)

      # The relay Settler needs only :xochi_config (no signing wallet).
      assert missing == [:xochi_config]
    end

    test "delivers the settler's result, stringified with nils dropped" do
      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        settle_fn: fn %{requirement: _req} ->
          {:ok,
           %{
             intent_id: "int_1",
             settlement_tx_hash: "0xabc",
             receiving_tx_hash: nil,
             amount_atomic: "1100000",
             status: "completed"
           }}
        end
      )

      assert {:deliver, deliverable} = TransferOffering.handle_deliver(req(%{}), @ctx)

      assert deliverable == %{
               "intent_id" => "int_1",
               "settlement_tx_hash" => "0xabc",
               "amount_atomic" => "1100000",
               "status" => "completed"
             }

      refute Map.has_key?(deliverable, "receiving_tx_hash")
    end

    test "a stealth deliverable surfaces the ERC-5564 announcement fields (#368)" do
      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        settle_fn: fn %{requirement: _req} ->
          {:ok,
           %{
             intent_id: "int_1",
             settlement_tx_hash: "0xabc",
             receiving_tx_hash: nil,
             amount_atomic: "1100000",
             status: "completed",
             settlement_type: "stealth",
             stealth_address: "0x" <> String.duplicate("5c", 20),
             ephemeral_pub_key: "0x02" <> String.duplicate("ab", 32),
             view_tag: 42
           }}
        end
      )

      r = req(%{"settlement_preference" => "stealth", "destination" => "0xrecipient"})
      assert {:deliver, deliverable} = TransferOffering.handle_deliver(r, @ctx)

      # present/1 stringifies keys and keeps the non-nil announcement fields
      # (dropping only the nil receiving_tx_hash), so the evaluator can verify
      # the stealth delivery on-chain.
      assert deliverable["settlement_type"] == "stealth"
      assert deliverable["stealth_address"] == "0x" <> String.duplicate("5c", 20)
      assert deliverable["ephemeral_pub_key"] == "0x02" <> String.duplicate("ab", 32)
      assert deliverable["view_tag"] == 42
      refute Map.has_key?(deliverable, "receiving_tx_hash")
    end

    test "propagates a settler error so the job expires instead of completing" do
      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        settle_fn: fn _ -> {:error, {:settlement_failed, :expired, "int_x", nil}} end
      )

      assert {:error, {:settlement_failed, :expired, "int_x", nil}} =
               TransferOffering.handle_deliver(req(%{}), @ctx)
    end

    test "passes the buyer's requirement through to the settler" do
      parent = self()

      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        settle_fn: fn args ->
          send(parent, {:settle_args, args})
          {:ok, %{intent_id: "i", status: "settled"}}
        end
      )

      r = req(%{"src_token" => @usdt_base, "dst_token" => @usdt_arb})
      assert {:deliver, _} = TransferOffering.handle_deliver(r, @ctx)
      assert_received {:settle_args, %{requirement: ^r}}
    end
  end

  describe "multi-VM corridors via the capability matrix" do
    @tron 728_126_428
    @usdt_tron "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

    # Live matrix advertising a Base -> Tron corridor (Riddler WP-E shape).
    defp tron_matrix do
      %{
        "source" => "live",
        "capabilities" => %{
          "chains" => [
            %{"chain_id" => 8453, "chain_name" => "Base"},
            %{"chain_id" => @tron, "chain_name" => "Tron", "vm_type" => "tvm"}
          ],
          "tokens" => [
            %{
              "symbol" => "USDC",
              "roles" => ["origin"],
              "addresses" => %{"8453" => @usdc_base}
            },
            %{
              "symbol" => "USDT",
              "roles" => ["destination"],
              "addresses" => %{Integer.to_string(@tron) => @usdt_tron}
            }
          ]
        }
      }
    end

    defp put_live_capabilities do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(tron_matrix()))
      end

      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        xochi_config: %{base_url: "https://api.xochi.fi", req_options: [plug: plug]}
      )
    end

    test "a base58 destination token on an advertised Tron corridor passes validation" do
      put_live_capabilities()
      r = req(%{"dst_chain_id" => @tron, "dst_token" => @usdt_tron})

      # Validation clears (schema + addresses + corridor); the request then
      # reaches the settler stage, i.e. it was NOT rejected before escrow.
      assert Offering.valid_requirement?(r)
      assert {:accept, ^r} = TransferOffering.handle_request(r, @ctx)
    end

    test "an EVM-hex token on the Tron leg is rejected as an invalid address" do
      put_live_capabilities()
      r = req(%{"dst_chain_id" => @tron, "dst_token" => @usdc_arb})

      assert {:reject, {:invalid_address, :dst_token, @tron, @usdc_arb}} =
               TransferOffering.handle_request(r, @ctx)
    end

    test "a base58 token on an EVM leg is rejected as an invalid address" do
      put_live_capabilities()
      r = req(%{"src_token" => @usdt_tron})

      assert {:reject, {:invalid_address, :src_token, 8453, @usdt_tron}} =
               TransferOffering.handle_request(r, @ctx)
    end

    test "a live matrix narrows corridors direction-aware" do
      put_live_capabilities()
      # USDC is origin-only in this matrix, so USDC on the destination leg
      # of an advertised chain is unsupported (not invalid).
      r = req(%{"dst_chain_id" => 8453, "src_chain_id" => 42_161, "src_token" => @usdc_arb})

      assert {:reject, {:unsupported_src_token, 42_161, @usdc_arb}} =
               TransferOffering.handle_request(r, @ctx)
    end

    test "without capabilities config the static fallback preserves EVM behavior" do
      # No :xochi_transfer_settler config at all: the six-chain Assets set
      # gates exactly as before, and Tron corridors stay unavailable.
      assert {:reject, {:unsupported_dst_token, @tron, @usdt_tron}} =
               TransferOffering.handle_request(
                 req(%{"dst_chain_id" => @tron, "dst_token" => @usdt_tron}),
                 @ctx
               )
    end
  end

  describe "handle_request/2 stablecoin corridor scope (allowlist enabled)" do
    setup do
      Application.put_env(:raxol_acp, :stablecoin_corridors_only, true)
      on_exit(fn -> Application.delete_env(:raxol_acp, :stablecoin_corridors_only) end)
      :ok
    end

    test "USDC Base -> Arbitrum stays accepted" do
      r = req(%{})
      assert {:accept, ^r} = TransferOffering.handle_request(r, @ctx)
    end

    test "USDT Arbitrum -> Polygon (a relay corridor) is accepted" do
      r =
        req(%{
          "src_chain_id" => 42_161,
          "dst_chain_id" => 137,
          "src_token" => @usdt_arb,
          "dst_token" => @usdt_poly
        })

      assert {:accept, ^r} = TransferOffering.handle_request(r, @ctx)
    end

    test "USDG Robinhood -> USDC hub (Arb, Base) is accepted (drain)" do
      to_arb =
        req(%{
          "src_chain_id" => 4663,
          "dst_chain_id" => 42_161,
          "src_token" => @usdg_robinhood,
          "dst_token" => @usdc_arb
        })

      to_base =
        req(%{
          "src_chain_id" => 4663,
          "dst_chain_id" => 8453,
          "src_token" => @usdg_robinhood,
          "dst_token" => @usdc_base
        })

      assert {:accept, ^to_arb} = TransferOffering.handle_request(to_arb, @ctx)
      assert {:accept, ^to_base} = TransferOffering.handle_request(to_base, @ctx)
    end

    test "USDT on Base is declined -- not a relay corridor" do
      r = req(%{"src_token" => @usdt_base, "dst_token" => @usdt_arb})

      assert {:reject, {:unsupported_corridor, 8453, 42_161}} =
               TransferOffering.handle_request(r, @ctx)
    end

    test "WETH is declined -- volatile, not a launch stablecoin" do
      r = req(%{"src_token" => @weth_base, "dst_token" => @weth_arb})

      assert {:reject, {:unsupported_corridor, 8453, 42_161}} =
               TransferOffering.handle_request(r, @ctx)
    end

    test "USDG inbound to Robinhood is declined -- drain direction only" do
      r =
        req(%{
          "src_chain_id" => 42_161,
          "dst_chain_id" => 4663,
          "src_token" => @usdc_arb,
          "dst_token" => @usdg_robinhood
        })

      assert {:reject, {:unsupported_corridor, 42_161, 4663}} =
               TransferOffering.handle_request(r, @ctx)
    end
  end
end
