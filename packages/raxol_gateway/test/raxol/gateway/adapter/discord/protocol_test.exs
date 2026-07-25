defmodule Raxol.Gateway.Adapter.Discord.ProtocolTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Adapter.Discord.Protocol

  describe "encode" do
    test "heartbeat carries the sequence, nil as JSON null" do
      assert Jason.decode!(Protocol.encode_heartbeat(41)) == %{
               "op" => 1,
               "d" => 41
             }

      assert Jason.decode!(Protocol.encode_heartbeat(nil)) == %{
               "op" => 1,
               "d" => nil
             }
    end

    test "identify carries token, intents, and properties" do
      decoded = Jason.decode!(Protocol.encode_identify("tok", 37_377))

      assert %{
               "op" => 2,
               "d" => %{
                 "token" => "tok",
                 "intents" => 37_377,
                 "properties" => %{"browser" => "raxol", "device" => "raxol"}
               }
             } = decoded
    end

    test "resume carries token, session id, and sequence" do
      assert Jason.decode!(Protocol.encode_resume("tok", "sess", 12)) == %{
               "op" => 6,
               "d" => %{"token" => "tok", "session_id" => "sess", "seq" => 12}
             }
    end
  end

  describe "decode" do
    test "hello yields the heartbeat interval" do
      payload = Jason.encode!(%{op: 10, d: %{heartbeat_interval: 41_250}})
      assert Protocol.decode(payload) == {:hello, 41_250}
    end

    test "a hello without a usable interval is unknown, not a crash" do
      payload = Jason.encode!(%{op: 10, d: %{}})
      assert {:unknown, _frame} = Protocol.decode(payload)
    end

    test "dispatch returns the whole string-keyed frame" do
      payload =
        Jason.encode!(%{op: 0, t: "MESSAGE_CREATE", s: 7, d: %{content: "hi"}})

      assert {:dispatch, frame} = Protocol.decode(payload)
      assert frame["t"] == "MESSAGE_CREATE"
      assert frame["s"] == 7
      assert frame["d"] == %{"content" => "hi"}
    end

    test "control opcodes classify" do
      assert Protocol.decode(Jason.encode!(%{op: 1})) == :heartbeat_request
      assert Protocol.decode(Jason.encode!(%{op: 7})) == :reconnect
      assert Protocol.decode(Jason.encode!(%{op: 11})) == :heartbeat_ack

      assert Protocol.decode(Jason.encode!(%{op: 9, d: true})) ==
               {:invalid_session, true}

      assert Protocol.decode(Jason.encode!(%{op: 9, d: false})) ==
               {:invalid_session, false}
    end

    test "unknown opcodes and non-frames are unknown" do
      assert {:unknown, _} = Protocol.decode(Jason.encode!(%{op: 99}))
      assert {:unknown, _} = Protocol.decode(Jason.encode!(%{no: "op"}))
    end

    test "invalid JSON is an error tuple" do
      assert {:error, {:invalid_json, _reason}} = Protocol.decode("{nope")
    end
  end

  test "default intents include the four message-reading intents" do
    import Bitwise

    intents = Protocol.default_intents()

    for bit <- [1 <<< 0, 1 <<< 9, 1 <<< 12, 1 <<< 15] do
      assert (intents &&& bit) == bit
    end
  end
end
