defmodule Raxol.ACP.Xochi.StablePublicOfferingTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.{Offering, StablePublicOffering}

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_arb "0xaf88d065e77c8cc2239327c5edb3a432268e5831"

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

  describe "offering metadata + schema" do
    test "declares the public offering" do
      assert StablePublicOffering.offering_name() == "xochi_stable_public"
      assert StablePublicOffering.cluster() == "on_chain"
    end

    test "requirement schema pins public settlement" do
      schema = StablePublicOffering.requirements_schema()
      assert schema == Offering.requirement_schema(:public)
      assert schema["properties"]["settlement_preference"]["enum"] == ["public"]
    end

    test "deliverable schema drops the stealth announcement fields" do
      props = StablePublicOffering.deliverables_schema()["properties"]
      refute Map.has_key?(props, "stealth_address")
      refute Map.has_key?(props, "settlement_type")
    end
  end

  describe "handle_request/2" do
    test "accepts a public stablecoin corridor (no settlement_preference)" do
      r = req(%{})
      assert {:accept, ^r} = StablePublicOffering.handle_request(r, @ctx)
    end

    test "accepts an explicit public settlement_preference" do
      r = req(%{"settlement_preference" => "public"})
      assert {:accept, ^r} = StablePublicOffering.handle_request(r, @ctx)
    end

    test "rejects a stealth preference, pointing at the stealth offering" do
      r = req(%{"settlement_preference" => "stealth"})

      assert {:reject, {:wrong_offering, :expected_public, "xochi_stable_stealth"}} =
               StablePublicOffering.handle_request(r, @ctx)
    end

    test "rejects a private preference too" do
      r = req(%{"settlement_preference" => "private"})

      assert {:reject, {:wrong_offering, :expected_public, "xochi_stable_stealth"}} =
               StablePublicOffering.handle_request(r, @ctx)
    end

    test "shared guards still fire (unsupported token)" do
      bogus = "0x" <> String.duplicate("ab", 20)

      assert {:reject, {:unsupported_src_token, 8453, ^bogus}} =
               StablePublicOffering.handle_request(req(%{"src_token" => bogus}), @ctx)
    end
  end
end
