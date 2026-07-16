# Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
defmodule Raxol.AgentClientProtocol.RpcTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Rpc.{Message, Notification, Request, RequestId, Response}

  test "RequestId display" do
    assert RequestId.display(nil) == "null"
    assert RequestId.display(1) == "1"
    assert RequestId.display(-1) == "-1"
    assert RequestId.display("abc") == "abc"
  end

  test "RequestId round-trip" do
    assert RequestId.from_json(nil) == nil
    assert RequestId.from_json(42) == 42
    assert RequestId.from_json("test") == "test"
  end

  test "RequestId valid?/1" do
    assert RequestId.valid?(nil)
    assert RequestId.valid?(1)
    assert RequestId.valid?("abc")
    refute RequestId.valid?(1.5)
    refute RequestId.valid?(true)
    refute RequestId.valid?(%{})
    refute RequestId.valid?([1])
  end

  test "Request to_json/from_json" do
    req = Request.new(1, "initialize", %{"protocolVersion" => 1})
    json = Request.to_json(req)
    assert json == %{"id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => 1}}
    {:ok, decoded} = Request.from_json(json)
    assert decoded.id == 1
    assert decoded.method == "initialize"
  end

  test "Request without params" do
    req = Request.new(1, "test")
    json = Request.to_json(req)
    refute Map.has_key?(json, "params")
  end

  test "Response result" do
    resp = Response.result(1, %{"value" => true})
    json = Response.to_json(resp)
    assert json == %{"id" => 1, "result" => %{"value" => true}}
    {:ok, decoded} = Response.from_json(json)
    assert decoded == {:result, 1, %{"value" => true}}
  end

  test "Response error" do
    err = Error.method_not_found()
    resp = Response.error(1, err)
    json = Response.to_json(resp)
    assert json["id"] == 1
    assert json["error"]["code"] == -32_601
    {:ok, decoded} = Response.from_json(json)
    assert {:error, 1, decoded_err} = decoded
    assert decoded_err.code == -32_601
  end

  test "Notification to_json/from_json" do
    notif = Notification.new("session/update", %{"sessionId" => "abc"})
    json = Notification.to_json(notif)
    assert json == %{"method" => "session/update", "params" => %{"sessionId" => "abc"}}
    {:ok, decoded} = Notification.from_json(json)
    assert decoded.method == "session/update"
  end

  test "Message wrap and encode" do
    req = Request.new(1, "initialize")
    msg = Message.wrap(req)
    json = Message.to_json(msg)
    assert json["jsonrpc"] == "2.0"
    assert json["id"] == 1
    assert json["method"] == "initialize"
  end

  test "Message decode request" do
    json_str = ~s({"jsonrpc":"2.0","id":1,"method":"test","params":{"key":"val"}})
    {:ok, decoded} = Message.decode(json_str)
    assert %Request{id: 1, method: "test"} = decoded
  end

  test "Message decode response" do
    json_str = ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}})
    {:ok, decoded} = Message.decode(json_str)
    assert {:result, 1, %{"ok" => true}} = decoded
  end

  test "Message decode notification" do
    json_str = ~s({"jsonrpc":"2.0","method":"cancel","params":{"sessionId":"s1"}})
    {:ok, decoded} = Message.decode(json_str)
    assert %Notification{method: "cancel"} = decoded
  end

  test "Message decode invalid version" do
    json_str = ~s({"jsonrpc":"1.0","method":"test"})
    assert {:error, :invalid_jsonrpc_version} = Message.decode(json_str)
  end

  # -- Defect-fix regression coverage ---------------------------------------

  describe "id type preservation matrix" do
    test "integer id round-trips as integer through Request" do
      {:ok, decoded} = Request.from_json(%{"id" => 7, "method" => "m"})
      assert decoded.id === 7
      assert Request.to_json(decoded)["id"] === 7
    end

    test "string id round-trips as string through Request (never coerced to integer)" do
      {:ok, decoded} = Request.from_json(%{"id" => "7", "method" => "m"})
      assert decoded.id === "7"
      assert Request.to_json(decoded)["id"] === "7"
    end

    test "null id round-trips as nil through Request" do
      {:ok, decoded} = Request.from_json(%{"id" => nil, "method" => "m"})
      assert decoded.id === nil
      json = Request.to_json(decoded)
      assert Map.has_key?(json, "id")
      assert json["id"] === nil
    end

    test "integer vs string ids that look alike stay distinguishable end to end" do
      {:ok, %Request{id: int_id}} = Request.from_json(%{"id" => 7, "method" => "m"})
      {:ok, %Request{id: str_id}} = Request.from_json(%{"id" => "7", "method" => "m"})
      assert int_id === 7
      assert str_id === "7"
      refute int_id === str_id
    end

    test "Response result id round-trips per wire type (int/string/null)" do
      for id <- [1, "abc", nil] do
        {:ok, {:result, decoded_id, _}} = Response.from_json(%{"id" => id, "result" => %{}})
        assert decoded_id === id
      end
    end

    test "Response error id round-trips per wire type (int/string/null)" do
      err_json = Error.to_json(Error.internal_error())

      for id <- [1, "abc", nil] do
        {:ok, {:error, decoded_id, _}} = Response.from_json(%{"id" => id, "error" => err_json})
        assert decoded_id === id
      end
    end

    test "Message round-trip through JSON preserves string id (not coerced to integer)" do
      req = Request.new("req-42", "initialize")
      encoded = Message.encode!(Message.wrap(req))
      {:ok, decoded} = Message.decode(encoded)
      assert decoded.id === "req-42"
    end

    test "Message round-trip through JSON preserves integer id" do
      req = Request.new(42, "initialize")
      encoded = Message.encode!(Message.wrap(req))
      {:ok, decoded} = Message.decode(encoded)
      assert decoded.id === 42
    end
  end

  describe "null-id error response" do
    test "a parse-error response can legitimately carry a null id" do
      resp = Response.error(nil, Error.parse_error())
      json = Response.to_json(resp)
      assert json["id"] == nil
      assert Map.has_key?(json, "id")

      {:ok, decoded} = Response.from_json(json)
      assert {:error, nil, decoded_err} = decoded
      assert decoded_err.code == -32_700
    end

    test "an invalid-request error response can carry a null id through Message encode/decode" do
      msg = Message.wrap(Response.error(nil, Error.invalid_request()))
      encoded = Jason.encode!(msg)
      {:ok, decoded} = Message.decode(encoded)
      assert {:error, nil, _err} = decoded
    end
  end

  describe "malformed JSON -> parse_error" do
    test "unterminated JSON returns {:error, :parse_error}, never raises" do
      assert {:error, :parse_error} = Message.decode(~s({"jsonrpc":"2.0","id":1))
    end

    test "empty string returns {:error, :parse_error}" do
      assert {:error, :parse_error} = Message.decode("")
    end

    test "garbage bytes return {:error, :parse_error}" do
      assert {:error, :parse_error} = Message.decode("not json at all {{{")
    end

    test "non-string input to decode/1 returns {:error, :parse_error}, never raises" do
      assert {:error, :parse_error} = Message.decode(nil)
      assert {:error, :parse_error} = Message.decode(123)
    end

    test "well-formed JSON that isn't an object is {:error, :invalid_request}, not a crash" do
      assert {:error, :invalid_request} = Message.decode(~s([1,2,3]))
      assert {:error, :invalid_request} = Message.decode(~s("just a string"))
    end
  end

  describe "total decoding: shape-valid-but-wrong never raises" do
    test "Request.from_json/1 rejects missing method without raising" do
      assert {:error, :invalid_request} = Request.from_json(%{"id" => 1})
    end

    test "Request.from_json/1 rejects a non-wire-valid id type without raising" do
      assert {:error, :invalid_request} = Request.from_json(%{"id" => %{}, "method" => "m"})
      assert {:error, :invalid_request} = Request.from_json(%{"id" => [1], "method" => "m"})
      assert {:error, :invalid_request} = Request.from_json(%{"id" => 1.5, "method" => "m"})
    end

    test "Request.from_json/1 rejects non-map input without raising" do
      assert {:error, :invalid_request} = Request.from_json("not a map")
      assert {:error, :invalid_request} = Request.from_json(nil)
    end

    test "Notification.from_json/1 rejects missing method without raising" do
      assert {:error, :invalid_request} = Notification.from_json(%{"params" => %{}})
      assert {:error, :invalid_request} = Notification.from_json(%{})
    end

    test "Response.from_json/1 rejects a malformed nested error without raising" do
      assert {:error, :invalid_request} =
               Response.from_json(%{"id" => 1, "error" => %{"message" => "no code"}})
    end

    test "Response.from_json/1 rejects a non-wire-valid id without raising" do
      assert {:error, :invalid_request} = Response.from_json(%{"id" => true, "result" => %{}})
    end

    test "Message.decode/1 never crashes on an object with neither method nor result/error" do
      assert {:error, :invalid_request} = Message.decode(~s({"jsonrpc":"2.0","id":1}))
    end
  end

  describe "unknown wire fields fold into _meta" do
    test "Request preserves and re-emits unknown fields" do
      {:ok, req} =
        Request.from_json(%{"id" => 1, "method" => "m", "_meta" => %{"tag" => "v1"}})

      assert req._meta == %{"_meta" => %{"tag" => "v1"}}
      assert Request.to_json(req)["_meta"] == %{"tag" => "v1"}
    end

    test "Notification preserves and re-emits unknown fields" do
      {:ok, notif} = Notification.from_json(%{"method" => "m", "traceId" => "abc"})
      assert notif._meta == %{"traceId" => "abc"}
      assert Notification.to_json(notif)["traceId"] == "abc"
    end
  end
end
