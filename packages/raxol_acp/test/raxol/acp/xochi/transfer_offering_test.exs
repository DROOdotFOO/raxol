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

  @ctx %{job_id: "j1", buyer: "0xbuyer", seller: "0xseller", state: :request}

  setup do
    Application.delete_env(:raxol_acp, :xochi_transfer_settler)
    on_exit(fn -> Application.delete_env(:raxol_acp, :xochi_transfer_settler) end)
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
        "destination" => "0x000000000000000000000000000000000000dEaD",
        "slippage_bps" => 50
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

      assert :wallet_address in missing
      assert :xochi_config in missing
      assert :xochi_wallet in missing
    end

    test "delivers the settler's result, stringified with nils dropped" do
      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        settle_fn: fn %{requirement: _req} ->
          {:ok,
           %{
             intent_id: "int_1",
             quote_id: "q_1",
             src_tx_hash: "0xabc",
             dst_tx_hash: nil,
             status: "settled"
           }}
        end
      )

      assert {:deliver, deliverable} = TransferOffering.handle_deliver(req(%{}), @ctx)

      assert deliverable == %{
               "intent_id" => "int_1",
               "quote_id" => "q_1",
               "src_tx_hash" => "0xabc",
               "status" => "settled"
             }

      refute Map.has_key?(deliverable, "dst_tx_hash")
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
end
