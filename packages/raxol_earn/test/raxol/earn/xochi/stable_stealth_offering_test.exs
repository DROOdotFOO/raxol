defmodule Raxol.Earn.Xochi.StableStealthOfferingTest do
  # async: false -- deliver tests set/clear :xochi_transfer_settler app env.
  use ExUnit.Case, async: false

  alias Raxol.Earn.Xochi.{Offering, StableStealthOffering}

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_eth "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  @usdc_arb "0xaf88d065e77c8cc2239327c5edb3a432268e5831"

  @meta %{
    "spending_pub_key" => "0x02" <> String.duplicate("ab", 32),
    "viewing_pub_key" => "0x03" <> String.duplicate("cd", 32)
  }

  @ctx %{job_id: "j1", buyer: "0xbuyer", seller: "0xseller", state: :request}

  setup do
    Application.delete_env(:raxol_earn, :xochi_transfer_settler)
    Raxol.Payments.Xochi.Capabilities.reset()

    on_exit(fn ->
      Application.delete_env(:raxol_earn, :xochi_transfer_settler)
      Raxol.Payments.Xochi.Capabilities.reset()
    end)

    :ok
  end

  # A well-formed stealth requirement: USDC Base -> Ethereum L1, stealth tier,
  # with the ERC-5564 meta-address keys.
  defp req(overrides) do
    Map.merge(
      %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 1,
        "src_token" => @usdc_base,
        "dst_token" => @usdc_eth,
        "amount_atomic" => "1100000",
        "settlement_preference" => "stealth",
        "stealth_meta_address" => @meta,
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

  describe "offering metadata + schema" do
    test "declares the stealth offering" do
      assert StableStealthOffering.offering_name() == "xochi_stable_stealth"
      assert StableStealthOffering.cluster() == "on_chain"
    end

    test "requirement schema pins stealth + Ethereum L1 + requires the meta-address" do
      schema = StableStealthOffering.requirements_schema()
      assert schema == Offering.requirement_schema(:stealth)
      assert schema["properties"]["settlement_preference"]["enum"] == ["stealth"]
      assert schema["properties"]["dst_chain_id"]["const"] == 1
      assert "stealth_meta_address" in schema["required"]
    end

    test "deliverable schema requires the ERC-5564 announcement fields" do
      schema = StableStealthOffering.deliverables_schema()

      for field <- ["settlement_type", "stealth_address", "ephemeral_pub_key", "view_tag"] do
        assert field in schema["required"]
      end
    end
  end

  describe "handle_request/2 accepts a valid X->L1 stealth transfer" do
    test "USDC Base -> Ethereum L1 with meta-address" do
      r = req(%{})
      assert {:accept, ^r} = StableStealthOffering.handle_request(r, @ctx)
    end
  end

  describe "handle_request/2 rejects before escrow with focused errors" do
    test "a non-Ethereum destination (cross-chain stealth is not live)" do
      r = req(%{"dst_chain_id" => 42_161, "dst_token" => @usdc_arb})

      assert {:reject, {:stealth_requires_l1_destination, 42_161}} =
               StableStealthOffering.handle_request(r, @ctx)
    end

    test "a missing stealth_meta_address" do
      r = req(%{}) |> Map.delete("stealth_meta_address")

      assert {:reject, :stealth_meta_address_required} =
               StableStealthOffering.handle_request(r, @ctx)
    end

    test "an incomplete stealth_meta_address (viewing key only)" do
      r = req(%{"stealth_meta_address" => %{"viewing_pub_key" => "0x03ab"}})

      assert {:reject, :stealth_meta_address_required} =
               StableStealthOffering.handle_request(r, @ctx)
    end

    test "an explicit public preference points the agent at the public offering" do
      r = req(%{"settlement_preference" => "public"})

      assert {:reject, {:wrong_offering, :expected_stealth, "xochi_stable_public"}} =
               StableStealthOffering.handle_request(r, @ctx)
    end

    test "shared guards still fire (same-chain)" do
      r = req(%{"src_chain_id" => 1, "src_token" => @usdc_eth})
      assert {:reject, :not_cross_chain} = StableStealthOffering.handle_request(r, @ctx)
    end
  end

  describe "handle_deliver/2 shares the settler relay" do
    test "fails closed when no settler is configured" do
      assert {:error, {:settler_not_configured, [:xochi_config]}} =
               StableStealthOffering.handle_deliver(req(%{}), @ctx)
    end

    test "surfaces the stealth announcement fields from the settler" do
      Application.put_env(:raxol_earn, :xochi_transfer_settler,
        settle_fn: fn %{requirement: _r} ->
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

      assert {:deliver, deliverable} = StableStealthOffering.handle_deliver(req(%{}), @ctx)
      assert deliverable["settlement_type"] == "stealth"
      assert deliverable["stealth_address"] == "0x" <> String.duplicate("5c", 20)
      assert deliverable["view_tag"] == 42
      refute Map.has_key?(deliverable, "receiving_tx_hash")
    end
  end
end
