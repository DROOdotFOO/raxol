defmodule Raxol.ACP.Xochi.OfferingTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Xochi.Offering

  describe "offering_metadata/0" do
    test "is a fund-transfer offering with USDC settlement" do
      meta = Offering.offering_metadata()

      assert meta.name == "xochi_cross_chain_transfer"
      assert meta.required_funds == true
      assert meta.hook_kind == "fund_transfer"
      assert meta.sla_minutes == 10
      assert "payments" in meta.tags
    end

    test "requirement and deliverable schemas are JSON-Schema 2020-12" do
      meta = Offering.offering_metadata()

      assert meta.requirement_schema["$schema"] ==
               "https://json-schema.org/draft/2020-12/schema"

      assert meta.deliverable_schema["$schema"] ==
               "https://json-schema.org/draft/2020-12/schema"
    end
  end

  describe "requirement_schema/0" do
    test "rejects extra properties so buyers can't smuggle fields" do
      schema = Offering.requirement_schema()
      assert schema["additionalProperties"] == false
    end

    test "marks the 7 essential fields as required" do
      schema = Offering.requirement_schema()
      required = MapSet.new(schema["required"])

      assert MapSet.equal?(
               required,
               MapSet.new([
                 "src_chain_id",
                 "dst_chain_id",
                 "src_token",
                 "dst_token",
                 "amount_atomic",
                 "destination",
                 "slippage_bps"
               ])
             )
    end

    test "settlement_preference is optional and bounded" do
      schema = Offering.requirement_schema()
      prop = schema["properties"]["settlement_preference"]
      assert prop["enum"] == ["public", "private"]
      assert prop["default"] == "public"
    end
  end

  describe "valid_requirement?/1" do
    test "accepts a minimal valid request" do
      req = %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 10,
        "src_token" => "0x" <> String.duplicate("ab", 20),
        "dst_token" => "0x" <> String.duplicate("cd", 20),
        "amount_atomic" => "1000000",
        "destination" => "0x" <> String.duplicate("ef", 20),
        "slippage_bps" => 50
      }

      assert Offering.valid_requirement?(req)
    end

    test "rejects requests missing a required field" do
      refute Offering.valid_requirement?(%{"src_chain_id" => 8453})
      refute Offering.valid_requirement?(%{})
    end

    test "rejects non-map input" do
      refute Offering.valid_requirement?(nil)
      refute Offering.valid_requirement?("string")
    end
  end

  describe "deliverable_schema/0" do
    test "intent_id, src_tx_hash, status are required" do
      schema = Offering.deliverable_schema()
      required = MapSet.new(schema["required"])
      assert MapSet.equal?(required, MapSet.new(["intent_id", "src_tx_hash", "status"]))
    end

    test "status is bounded" do
      schema = Offering.deliverable_schema()

      assert schema["properties"]["status"]["enum"] == [
               "pending",
               "settled",
               "failed",
               "refunded"
             ]
    end
  end
end
