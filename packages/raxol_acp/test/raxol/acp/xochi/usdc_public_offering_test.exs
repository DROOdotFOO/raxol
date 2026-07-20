defmodule Raxol.ACP.Xochi.UsdcPublicOfferingTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.{TransferCore, UsdcPublicOffering}

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_arb "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
  # A supported stablecoin that is NOT USDC, to prove the USDC gate short-circuits
  # before the shared token guards ever run.
  @usdt_base "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2"

  @cctp_chains [1, 10, 137, 8453, 42_161]

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
          "nonce" => 7
        }
      },
      overrides
    )
  end

  describe "offering metadata + schema" do
    test "declares the USDC-only public offering" do
      assert UsdcPublicOffering.offering_name() == "xochi_usdc_public"
      assert UsdcPublicOffering.cluster() == "on_chain"
    end

    test "requirement schema pins public settlement and the CCTP chain mesh" do
      schema = UsdcPublicOffering.requirements_schema()
      assert schema["properties"]["settlement_preference"]["enum"] == ["public"]
      assert schema["properties"]["src_chain_id"]["enum"] == @cctp_chains
      assert schema["properties"]["dst_chain_id"]["enum"] == @cctp_chains
    end

    test "requirement schema documents the USDC-only token constraint" do
      props = UsdcPublicOffering.requirements_schema()["properties"]
      assert props["src_token"]["description"] =~ "Only USDC is accepted"
      assert props["dst_token"]["description"] =~ "Only USDC is accepted"
    end

    test "deliverable schema drops the stealth announcement fields" do
      props = UsdcPublicOffering.deliverables_schema()["properties"]
      refute Map.has_key?(props, "stealth_address")
      refute Map.has_key?(props, "settlement_type")
    end
  end

  describe "handle_request/2" do
    test "accepts a USDC->USDC cross-chain corridor" do
      r = req(%{})
      assert {:accept, ^r} = UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "rejects a non-USDC src leg, pointing at the broader stablecoin offering" do
      r = req(%{"src_token" => @usdt_base})

      assert {:reject, {:wrong_offering, :expected_usdc, "xochi_stable_public"}} =
               UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "rejects a non-USDC dst leg too" do
      r = req(%{"dst_token" => @usdt_base})

      assert {:reject, {:wrong_offering, :expected_usdc, "xochi_stable_public"}} =
               UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "the USDC gate short-circuits before the shared token guard" do
      # A completely unknown token still reports :expected_usdc, not
      # :unsupported_src_token -- the USDC check runs first.
      bogus = "0x" <> String.duplicate("ab", 20)

      assert {:reject, {:wrong_offering, :expected_usdc, "xochi_stable_public"}} =
               UsdcPublicOffering.handle_request(req(%{"src_token" => bogus}), @ctx)
    end

    test "shared guards still fire once both legs are USDC (same-chain corridor)" do
      r = req(%{"dst_chain_id" => 8453, "dst_token" => @usdc_base})

      assert {:reject, :not_cross_chain} = UsdcPublicOffering.handle_request(r, @ctx)
    end
  end

  describe "describe_rejection/1" do
    test "explains the :expected_usdc rejection and names the fallback offering" do
      msg = TransferCore.describe_rejection({:wrong_offering, :expected_usdc, "xochi_stable_public"})
      assert msg =~ "USDC-only"
      assert msg =~ "xochi_stable_public"
    end
  end
end
