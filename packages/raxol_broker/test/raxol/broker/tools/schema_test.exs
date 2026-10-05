defmodule Raxol.Broker.Tools.SchemaTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Tools.{Catalog, Schema}

  @order %{
    "type" => "object",
    "properties" => %{
      "symbol" => %{"type" => "string", "minLength" => 1},
      "side" => %{"type" => "string", "enum" => ["buy", "sell"]},
      "quantity" => %{"type" => "number", "minimum" => 0},
      "tags" => %{"type" => ["null", "array"], "items" => %{"type" => "string"}}
    },
    "required" => ["symbol", "side"],
    "additionalProperties" => false
  }

  test "a valid object passes" do
    assert Schema.validate(@order, %{"symbol" => "AAPL", "side" => "buy", "tags" => nil}) == :ok

    assert Schema.validate(@order, %{"symbol" => "AAPL", "side" => "sell", "tags" => ["a"]}) ==
             :ok
  end

  test "every violation is reported with its path" do
    assert {:error, errors} =
             Schema.validate(@order, %{
               "side" => "hold",
               "quantity" => -1,
               "tags" => ["a", 2],
               "venue" => "x"
             })

    assert {["symbol"], :required} in errors
    assert {["venue"], :unknown_property} in errors
    assert {["side"], {:enum, ["buy", "sell"]}} in errors
    assert {["quantity"], {:minimum, 0}} in errors
    assert {["tags", 1], {:type, "string"}} in errors
    assert length(errors) == 5
  end

  test "a wrong type stops at that node" do
    assert Schema.validate(@order, "AAPL") == {:error, [{[], {:type, "object"}}]}

    assert Schema.validate(@order, %{"symbol" => "", "side" => "buy"}) ==
             {:error, [{["symbol"], {:minLength, 1}}]}
  end

  test "keys must be strings, as on the wire" do
    assert {:error, errors} = Schema.validate(@order, %{symbol: "AAPL", side: "buy"})
    assert {[], {:key_not_string, :symbol}} in errors
  end

  test "the captured quote schema" do
    schema = Catalog.schema("get_equity_quotes")
    assert Schema.validate(schema, %{"symbols" => ["AAPL"]}) == :ok
    assert Schema.validate(schema, %{"symbols" => nil}) == :ok
    assert {:error, [{["symbols"], :required}]} = Schema.validate(schema, %{})
  end
end
