defmodule Raxol.Payments.ProtocolTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocol

  describe "resolve/1 with known atoms" do
    test ":x402 returns X402 module" do
      assert Protocol.resolve(:x402) == Raxol.Payments.Protocols.X402
    end

    test ":mpp returns MPP module" do
      assert Protocol.resolve(:mpp) == Raxol.Payments.Protocols.MPP
    end

    test ":xochi returns Xochi module" do
      assert Protocol.resolve(:xochi) == Raxol.Payments.Protocols.Xochi
    end
  end

  describe "resolve/1 with unknown atom" do
    test "raises ArgumentError for unrecognized atom" do
      assert_raise ArgumentError, ~r/unknown payment protocol/, fn ->
        Protocol.resolve(:nonexistent_protocol)
      end
    end
  end

  describe "resolve/1 with module that lacks detect?/2" do
    test "raises ArgumentError for module without detect?/2" do
      # Enum is loaded but does not implement detect?/2
      assert_raise ArgumentError, ~r/unknown payment protocol/, fn ->
        Protocol.resolve(Enum)
      end
    end
  end
end
