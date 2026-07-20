defmodule Mix.Tasks.Acp.RegisterOfferingTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Acp.RegisterOffering

  @virtuals_fields ~w(name description price priceType slaMinutes requiredFunds requirement)

  describe "build_payload/1" do
    test "wraps the offering in a top-level jobs array, nothing else at the root" do
      payload = RegisterOffering.build_payload(:usdc_public)
      assert Map.keys(payload) == ["jobs"]
      assert [offering] = payload["jobs"]
      assert MapSet.equal?(MapSet.new(Map.keys(offering)), MapSet.new(@virtuals_fields))
    end
  end

  describe "build_offering/1" do
    test "emits exactly the Virtuals offering fields, nothing else" do
      offering = RegisterOffering.build_offering(:usdc_public)
      assert MapSet.equal?(MapSet.new(Map.keys(offering)), MapSet.new(@virtuals_fields))
    end

    test "defaults to the USDC-only launch offering, 0.10 percentage fee, no funds" do
      offering = RegisterOffering.build_offering(:usdc_public)

      assert offering["name"] == "xochi_usdc_public"
      assert offering["priceType"] == "percentage"
      assert offering["price"] == 0.10
      # Funds move off-ACP via the buyer's signed intent, so no ACP fund hook.
      assert offering["requiredFunds"] == false
      assert offering["slaMinutes"] == 10
    end

    test "requirement is a bare JSON Schema (no $schema URL) requiring only the signed intent" do
      requirement = RegisterOffering.build_offering(:usdc_public)["requirement"]

      refute Map.has_key?(requirement, "$schema")
      assert requirement["type"] == "object"
      assert requirement["additionalProperties"] == false
      assert requirement["required"] == ["signed_intent"]
    end

    test "usdc offering pins both legs to the CCTP mesh" do
      props = RegisterOffering.build_offering(:usdc_public)["requirement"]["properties"]
      assert props["src_chain_id"]["enum"] == [1, 10, 137, 8453, 42_161]
      assert props["dst_chain_id"]["enum"] == [1, 10, 137, 8453, 42_161]
    end

    test "--offering legacy emits the deprecated token-agnostic offering" do
      offering = RegisterOffering.build_offering(:legacy)
      assert offering["name"] == "xochi_cross_chain_transfer"
      assert offering["requiredFunds"] == false
    end

    test "unknown --offering raises with a helpful message" do
      assert_raise Mix.Error, ~r/unknown --offering/, fn ->
        RegisterOffering.build_offering(:bogus)
      end
    end

    test "payload round-trips through JSON" do
      payload = RegisterOffering.build_payload(:usdc_public)
      assert {:ok, decoded} = Jason.decode(Jason.encode!(payload))
      assert [offering] = decoded["jobs"]
      assert offering["name"] == "xochi_usdc_public"
    end
  end
end
