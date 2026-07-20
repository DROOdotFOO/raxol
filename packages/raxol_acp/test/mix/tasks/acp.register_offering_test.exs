defmodule Mix.Tasks.Acp.RegisterOfferingTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Acp.RegisterOffering

  @virtuals_fields ~w(name description jobFee jobFeeType requiredFunds requirement)

  describe "build_payload/1" do
    test "emits exactly the Virtuals offering fields, nothing else" do
      payload = RegisterOffering.build_payload(:usdc_public)
      assert MapSet.equal?(MapSet.new(Map.keys(payload)), MapSet.new(@virtuals_fields))
    end

    test "defaults to the USDC-only launch offering, 8 bps percentage, no funds" do
      payload = RegisterOffering.build_payload()

      assert payload["name"] == "xochi_usdc_public"
      assert payload["jobFeeType"] == "percentage"
      # Percent units: 0.08 == 0.08% == 8 bps.
      assert payload["jobFee"] == 0.08
      assert payload["requiredFunds"] == false
    end

    test "requirement is a bare JSON Schema (no $schema URL) with the corridor fields" do
      requirement = RegisterOffering.build_payload(:usdc_public)["requirement"]

      refute Map.has_key?(requirement, "$schema")
      assert requirement["type"] == "object"
      assert requirement["additionalProperties"] == false

      required = MapSet.new(requirement["required"])

      assert MapSet.equal?(
               required,
               MapSet.new([
                 "src_chain_id",
                 "dst_chain_id",
                 "src_token",
                 "dst_token",
                 "amount_atomic",
                 "signed_intent"
               ])
             )
    end

    test "usdc offering pins both legs to the CCTP mesh" do
      props = RegisterOffering.build_payload(:usdc_public)["requirement"]["properties"]
      assert props["src_chain_id"]["enum"] == [1, 10, 137, 8453, 42_161]
      assert props["dst_chain_id"]["enum"] == [1, 10, 137, 8453, 42_161]
    end

    test "--offering legacy emits the deprecated token-agnostic offering" do
      payload = RegisterOffering.build_payload(:legacy)
      assert payload["name"] == "xochi_cross_chain_transfer"
      assert payload["requiredFunds"] == false
    end

    test "unknown --offering raises with a helpful message" do
      assert_raise Mix.Error, ~r/unknown --offering/, fn ->
        RegisterOffering.build_payload(:bogus)
      end
    end

    test "payload round-trips through JSON" do
      payload = RegisterOffering.build_payload(:usdc_public)
      assert {:ok, decoded} = Jason.decode(Jason.encode!(payload))
      assert decoded["name"] == "xochi_usdc_public"
    end
  end
end
