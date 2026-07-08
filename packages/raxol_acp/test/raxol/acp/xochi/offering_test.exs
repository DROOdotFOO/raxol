defmodule Raxol.ACP.Xochi.OfferingTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Xochi.Offering

  describe "offering_metadata/0" do
    test "is a storefront offering (plain job, no fund hook)" do
      meta = Offering.offering_metadata()

      assert meta.name == "xochi_cross_chain_transfer"
      assert meta.required_funds == true
      assert meta.hook_kind == "none"
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

    test "marks the corridor fields plus the signed intent as required" do
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
                 "signed_intent"
               ])
             )
    end

    test "the signed_intent object requires the bundle fields" do
      schema = Offering.requirement_schema()
      bundle = schema["properties"]["signed_intent"]

      assert bundle["type"] == "object"

      assert MapSet.equal?(
               MapSet.new(bundle["required"]),
               MapSet.new(["intent_id", "quote_id", "signature", "nonce"])
             )
    end

    test "settlement_preference is optional and bounded" do
      schema = Offering.requirement_schema()
      prop = schema["properties"]["settlement_preference"]
      assert prop["enum"] == ["public", "private", "stealth"]
      assert prop["default"] == "public"
    end
  end

  describe "valid_requirement?/1" do
    defp minimal_req do
      %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 10,
        "src_token" => "0x" <> String.duplicate("ab", 20),
        "dst_token" => "0x" <> String.duplicate("cd", 20),
        "amount_atomic" => "1000000",
        "signed_intent" => %{
          "intent_id" => "xi_1",
          "quote_id" => "xq_1",
          "signature" => "0x" <> String.duplicate("11", 65),
          "nonce" => 7
        }
      }
    end

    test "accepts a minimal valid request" do
      assert Offering.valid_requirement?(minimal_req())
    end

    test "rejects requests missing a required field" do
      refute Offering.valid_requirement?(%{"src_chain_id" => 8453})
      refute Offering.valid_requirement?(%{})
      # missing the signed intent
      refute Offering.valid_requirement?(Map.delete(minimal_req(), "signed_intent"))
    end

    test "rejects a signed_intent that is missing bundle fields or is not a map" do
      refute Offering.valid_requirement?(%{
               minimal_req()
               | "signed_intent" => %{"intent_id" => "x"}
             })

      refute Offering.valid_requirement?(%{minimal_req() | "signed_intent" => "not-a-map"})
    end

    test "rejects non-map input" do
      refute Offering.valid_requirement?(nil)
      refute Offering.valid_requirement?("string")
    end
  end

  describe "deliverable_schema/0" do
    test "intent_id, settlement_tx_hash, status are required" do
      schema = Offering.deliverable_schema()
      required = MapSet.new(schema["required"])
      assert MapSet.equal?(required, MapSet.new(["intent_id", "settlement_tx_hash", "status"]))
    end

    test "status is bounded to completed (a delivered job always settled)" do
      schema = Offering.deliverable_schema()
      assert schema["properties"]["status"]["enum"] == ["completed"]
    end

    test "the delivered fields match what the Settler produces" do
      props = Offering.deliverable_schema()["properties"]

      assert MapSet.equal?(
               MapSet.new(Map.keys(props)),
               MapSet.new([
                 "intent_id",
                 "settlement_tx_hash",
                 "receiving_tx_hash",
                 "amount_atomic",
                 "status"
               ])
             )
    end
  end
end
