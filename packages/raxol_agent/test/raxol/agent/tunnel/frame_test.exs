defmodule Raxol.Agent.Tunnel.FrameTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Tunnel.Frame

  describe "new_channel_id/0" do
    test "is 8 lowercase hex chars and random" do
      id = Frame.new_channel_id()
      assert id =~ ~r/^[0-9a-f]{8}$/
      refute id == Frame.new_channel_id()
    end
  end

  describe "constructors" do
    test "hello carries identity and capabilities" do
      f = Frame.hello("host-1", ["claude", "codex"])
      assert f.kind == :hello
      assert f.channel_id == nil
      assert f.payload == %{"host_id" => "host-1", "capabilities" => ["claude", "codex"]}
    end

    test "open carries path and meta" do
      f = Frame.open("c1", "/runner/x", %{"k" => "v"})
      assert f.kind == :open
      assert f.channel_id == "c1"
      assert f.payload == %{"path" => "/runner/x", "meta" => %{"k" => "v"}}
    end

    test "data defaults to text" do
      f = Frame.data("c1", "hi")
      assert f.payload == %{"data" => "hi", "binary" => false}
      assert Frame.read_data(f) == "hi"
    end

    test "data with binary: true base64-encodes and round-trips" do
      bytes = <<0, 255, 16, 32>>
      f = Frame.data("c1", bytes, binary: true)
      assert f.payload["binary"] == true
      assert Frame.read_data(f) == bytes
    end

    test "close carries code and reason" do
      f = Frame.close("c1", 1001, "owner_down")
      assert f.payload == %{"code" => 1001, "reason" => "owner_down"}
    end
  end

  describe "encode/decode round-trip" do
    test "every kind survives a round-trip" do
      for frame <- [
            Frame.hello("h", ["a"]),
            Frame.open("c1", "/p", %{"m" => 1}),
            Frame.data("c1", "payload"),
            Frame.close("c1", 1000, "bye")
          ] do
        assert {:ok, decoded} = Frame.decode(Frame.encode(frame))
        assert decoded == frame
      end
    end

    test "rejects an unknown kind without creating an atom" do
      json = Jason.encode!(%{"c" => "c1", "k" => "evil_kind", "p" => %{}})
      assert {:error, {:unknown_kind, "evil_kind"}} = Frame.decode(json)
    end

    test "rejects malformed json" do
      assert {:error, _} = Frame.decode("not json")
    end
  end
end
