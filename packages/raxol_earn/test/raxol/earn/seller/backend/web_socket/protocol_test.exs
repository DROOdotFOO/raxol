defmodule Raxol.Earn.Seller.Backend.WebSocket.ProtocolTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Seller.Backend.WebSocket.Protocol

  describe "decode/1" do
    test "OPEN with handshake metadata" do
      raw =
        "0{\"sid\":\"abc\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000}"

      assert {:open,
              %{
                "sid" => "abc",
                "upgrades" => [],
                "pingInterval" => 25_000,
                "pingTimeout" => 20_000
              }} = Protocol.decode(raw)
    end

    test "PING (bare)" do
      assert Protocol.decode("2") == :ping
    end

    test "PING with probe body is still a ping" do
      assert Protocol.decode("2probe") == :ping
    end

    test "CLOSE" do
      assert Protocol.decode("1") == :close
    end

    test "CONNECT_OK in default namespace" do
      raw = "40{\"sid\":\"sock-xyz\"}"
      assert {:connect_ok, %{"sid" => "sock-xyz"}} = Protocol.decode(raw)
    end

    test "CONNECT_OK with empty body returns empty map" do
      assert {:connect_ok, %{}} = Protocol.decode("40")
    end

    test "EVENT without ACK id" do
      raw = "42[\"onNewTask\",{\"id\":1,\"phase\":0}]"

      assert {:event, "onNewTask", [%{"id" => 1, "phase" => 0}], nil} = Protocol.decode(raw)
    end

    test "EVENT with ACK id" do
      raw = "421[\"onNewTask\",{\"id\":99}]"
      assert {:event, "onNewTask", [%{"id" => 99}], 1} = Protocol.decode(raw)
    end

    test "EVENT with multi-digit ACK id" do
      raw = "42312[\"roomJoined\",{}]"
      assert {:event, "roomJoined", [%{}], 312} = Protocol.decode(raw)
    end

    test "ACK frame" do
      raw = "431[true]"
      assert {:ack, 1, [true]} = Protocol.decode(raw)
    end

    test "DISCONNECT" do
      assert :disconnect = Protocol.decode("41")
    end

    test "CONNECT_ERROR with reason" do
      raw = "44{\"message\":\"unauthorized\"}"
      assert {:connect_error, %{"message" => "unauthorized"}} = Protocol.decode(raw)
    end

    test "unknown packet shape surfaces raw" do
      assert {:unknown, "9whatever"} = Protocol.decode("9whatever")
    end

    test "unknown socket.io subtype inside MESSAGE surfaces raw" do
      assert {:unknown, "49extra"} = Protocol.decode("49extra")
    end

    test "malformed frames surface as :unknown instead of crashing" do
      # Invalid JSON in an EVENT body.
      assert {:unknown, "42[not json"} = Protocol.decode("42[not json")
      # A non-array EVENT payload (Socket.IO events are always arrays).
      assert {:unknown, ~s(42{"id":1})} = Protocol.decode(~s(42{"id":1}))
      # An ACK frame with no id.
      assert {:unknown, "43[true]"} = Protocol.decode("43[true]")
      # Invalid JSON in an OPEN handshake.
      assert {:unknown, "0{bad"} = Protocol.decode("0{bad")
      # Invalid JSON in a CONNECT body.
      assert {:unknown, "40{bad"} = Protocol.decode("40{bad")
    end
  end

  describe "encode_pong/0" do
    test "produces the single-character pong frame" do
      assert Protocol.encode_pong() == "3"
    end
  end

  describe "encode_connect/1" do
    test "nil auth produces a bare CONNECT" do
      assert Protocol.encode_connect(nil) == "40"
    end

    test "auth map is JSON-encoded into the body" do
      raw = Protocol.encode_connect(%{walletAddress: "0xabc"})
      assert raw == "40{\"walletAddress\":\"0xabc\"}"
    end

    test "round-trips through decode/1" do
      raw = Protocol.encode_connect(%{walletAddress: "0xabc"})
      assert {:connect_ok, %{"walletAddress" => "0xabc"}} = Protocol.decode(raw)
    end
  end

  describe "encode_ack/2" do
    test "single-element ACK" do
      assert Protocol.encode_ack(1, [true]) == "431[true]"
    end

    test "multi-element ACK round-trips" do
      raw = Protocol.encode_ack(99, [true, %{ok: 1}])
      assert {:ack, 99, [true, %{"ok" => 1}]} = Protocol.decode(raw)
    end

    test "rejects negative ack id" do
      assert_raise FunctionClauseError, fn -> Protocol.encode_ack(-1, []) end
    end
  end

  describe "encode_disconnect/0" do
    test "produces the disconnect frame" do
      assert Protocol.encode_disconnect() == "41"
      assert Protocol.decode(Protocol.encode_disconnect()) == :disconnect
    end
  end
end
