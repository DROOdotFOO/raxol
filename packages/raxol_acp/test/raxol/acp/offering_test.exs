defmodule Raxol.ACP.OfferingTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Offering
  alias Raxol.ACP.TestSupport.{EchoOffering, MinimalOffering}

  describe "use Raxol.ACP.Offering DSL: metadata accessors" do
    test "EchoOffering exposes declared metadata via module functions" do
      assert EchoOffering.offering_name() == "test.echo"
      assert Decimal.equal?(EchoOffering.price_usdc(), Decimal.new("0.01"))
      assert EchoOffering.sla_minutes() == 1
      assert EchoOffering.cluster() == "information"
    end

    test "MinimalOffering returns nil for unset metadata" do
      assert MinimalOffering.offering_name() == "test.minimal"
      assert MinimalOffering.price_usdc() == nil
      assert MinimalOffering.sla_minutes() == nil
      assert MinimalOffering.cluster() == nil
    end
  end

  describe "Handler behaviour conformance" do
    test "EchoOffering implements handle_request and handle_deliver" do
      ctx = %{job_id: "j1", buyer: "0xbuyer", seller: "0xseller", state: :request}

      assert {:accept, %{"text" => "hi"}} =
               EchoOffering.handle_request(%{"text" => "hi"}, ctx)

      assert {:deliver, %{"echo" => "hi"}} =
               EchoOffering.handle_deliver(%{"text" => "hi"}, ctx)
    end

    test "EchoOffering returns error tuple on bad input" do
      ctx = %{job_id: "j1", buyer: "0xb", seller: "0xs", state: :transaction}
      assert {:error, :missing_text} = EchoOffering.handle_deliver(%{}, ctx)
    end
  end

  describe "spec/0 builds a Registry.Spec without registering" do
    test "EchoOffering.spec/0 has all metadata + schemas" do
      spec = EchoOffering.spec()

      assert spec.name == "test.echo"
      assert spec.handler == EchoOffering
      assert spec.requirements_schema.type == "object"
      assert spec.deliverables_schema.required == ["echo"]
    end
  end

  describe "__coerce_price__/1" do
    test "passes nil through" do
      assert Offering.__coerce_price__(nil) == nil
    end

    test "leaves Decimal unchanged" do
      d = Decimal.new("1.23")
      assert Offering.__coerce_price__(d) == d
    end

    test "converts integer to Decimal" do
      assert Decimal.equal?(Offering.__coerce_price__(5), Decimal.new(5))
    end

    test "parses binary as Decimal" do
      assert Decimal.equal?(Offering.__coerce_price__("0.50"), Decimal.new("0.50"))
    end
  end
end
