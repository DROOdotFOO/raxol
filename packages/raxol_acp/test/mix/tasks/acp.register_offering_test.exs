defmodule Mix.Tasks.Acp.RegisterOfferingTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Acp.RegisterOffering

  describe "build_payload/1" do
    test "mainnet payload includes Base mainnet v2 addresses" do
      payload = RegisterOffering.build_payload(:mainnet)

      assert payload["network"]["chainId"] == 8453

      assert payload["network"]["acpCoreAddress"] ==
               "0x238E541BfefD82238730D00a2208E5497F1832E0"

      assert payload["network"]["fundTransferHookAddress"] ==
               "0x0EaD25150985Bce0B4925c54E4ee1D856381A86B"

      assert payload["network"]["acpServerUrl"] == "https://api.acp.virtuals.io"
    end

    test "sepolia payload includes Base Sepolia v2 addresses" do
      payload = RegisterOffering.build_payload(:sepolia)

      assert payload["network"]["chainId"] == 84_532

      assert payload["network"]["acpCoreAddress"] ==
               "0x0b93793923CD5De81850aF8604a233f3f24d461e"

      assert payload["network"]["fundTransferHookAddress"] ==
               "0xbbeC2c985F9483473B9e0Da0704395943034266B"

      assert payload["network"]["acpServerUrl"] == "https://api-dev.acp.virtuals.io"
    end

    test "embeds the Xochi offering metadata verbatim" do
      payload = RegisterOffering.build_payload(:mainnet)

      assert payload["name"] == "xochi_cross_chain_transfer"
      assert payload["hookKind"] == "none"
      assert payload["requiredFunds"] == false
      assert payload["slaMinutes"] == 10
      assert "payments" in payload["tags"]
    end

    test "requirement schema is JSON-Schema 2020-12 with the corridor + signed-intent fields" do
      payload = RegisterOffering.build_payload(:mainnet)
      schema = payload["requirementSchema"]

      assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
      assert schema["additionalProperties"] == false

      required = MapSet.new(schema["required"])

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

    test "deliverable schema bounds status to completed" do
      payload = RegisterOffering.build_payload(:mainnet)
      enum = payload["deliverableSchema"]["properties"]["status"]["enum"]

      assert enum == ["completed"]
    end

    test "payload round-trips through JSON" do
      payload = RegisterOffering.build_payload(:mainnet)
      json = Jason.encode!(payload)

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["name"] == "xochi_cross_chain_transfer"
    end

    test "unknown network raises with a helpful message" do
      assert_raise Mix.Error, ~r/unknown --network/, fn ->
        RegisterOffering.build_payload(:goerli)
      end
    end
  end
end
