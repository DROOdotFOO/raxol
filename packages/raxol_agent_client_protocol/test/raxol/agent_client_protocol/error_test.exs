# Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
defmodule Raxol.AgentClientProtocol.ErrorTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Error

  test "error codes" do
    assert Error.parse_error_code() == -32700
    assert Error.invalid_request_code() == -32600
    assert Error.method_not_found_code() == -32601
    assert Error.invalid_params_code() == -32602
    assert Error.internal_error_code() == -32603
    assert Error.auth_required_code() == -32000
    assert Error.resource_not_found_code() == -32002
  end

  test "convenience constructors" do
    err = Error.parse_error()
    assert err.code == -32700
    assert err.message == "Parse error"
  end

  test "to_json/from_json round-trip" do
    err = Error.new(-32600, "Invalid request")
    json = Error.to_json(err)
    assert json == %{"code" => -32600, "message" => "Invalid request"}
    assert {:ok, decoded} = Error.from_json(json)
    assert decoded.code == err.code
    assert decoded.message == err.message
  end

  test "with data" do
    err = Error.resource_not_found("file:///test")
    assert err.data == %{"uri" => "file:///test"}
    json = Error.to_json(err)
    assert json["data"] == %{"uri" => "file:///test"}
  end

  test "with_data/2 attaches data to an existing error" do
    err = Error.internal_error() |> Error.with_data(%{"detail" => "boom"})
    assert err.data == %{"detail" => "boom"}
  end

  test "code_name" do
    assert Error.code_name(-32700) == :parse_error
    assert Error.code_name(-32601) == :method_not_found
    assert Error.code_name(42) == {:other, 42}
  end

  test "Jason.Encoder" do
    err = Error.internal_error()
    encoded = Jason.encode!(err)
    decoded = Jason.decode!(encoded)
    assert decoded["code"] == -32603
    assert decoded["message"] == "Internal error"
  end

  # -- Defect-fix regression coverage ---------------------------------------

  test "from_json/1 is total: missing required fields never raise" do
    assert {:error, :invalid_error} = Error.from_json(%{"message" => "no code"})
    assert {:error, :invalid_error} = Error.from_json(%{"code" => -32000})
    assert {:error, :invalid_error} = Error.from_json(%{})
    assert {:error, :invalid_error} = Error.from_json("not a map")
    assert {:error, :invalid_error} = Error.from_json(nil)
    assert {:error, :invalid_error} = Error.from_json([1, 2, 3])
  end

  test "from_json/1 is total: wrong-typed code/message never raise" do
    assert {:error, :invalid_error} = Error.from_json(%{"code" => "nope", "message" => "x"})
    assert {:error, :invalid_error} = Error.from_json(%{"code" => -1, "message" => 42})
  end

  test "unknown wire fields fold into _meta and round-trip on encode" do
    map = %{
      "code" => -32000,
      "message" => "Authentication required",
      "data" => %{"reason" => "expired"},
      "vendor_extra" => %{"foo" => "bar"}
    }

    assert {:ok, err} = Error.from_json(map)
    assert err._meta == %{"vendor_extra" => %{"foo" => "bar"}}

    reencoded = Error.to_json(err)
    assert reencoded["vendor_extra"] == %{"foo" => "bar"}
    assert reencoded["code"] == -32000
    assert reencoded["message"] == "Authentication required"
  end

  test "nested inside a struct, Jason.encode! never crashes on unknown-field errors" do
    {:ok, err} = Error.from_json(%{"code" => -32602, "message" => "bad", "x-trace" => "abc"})
    encoded = Jason.encode!(err)
    decoded = Jason.decode!(encoded)
    assert decoded["x-trace"] == "abc"
  end
end
