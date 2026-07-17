# Ported from the MIT `f1729/agent_client_protocol` test suite
# (c) 2025 f1729; see NOTICE.md. Adapted to Raxol.AgentClientProtocol.Schema.Version
# and extended with coverage for the `coerce/1` defect fix (Zed legacy
# date-string handshake tolerance).
defmodule Raxol.AgentClientProtocol.Schema.VersionTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.Version

  test "v0 is 0" do
    assert Version.v0() == 0
  end

  test "v1 is 1" do
    assert Version.v1() == 1
  end

  test "latest is v1" do
    assert Version.latest() == Version.v1()
  end

  describe "from_json/1 (strict)" do
    test "integers pass through" do
      assert Version.from_json(1) == {:ok, 1}
      assert Version.from_json(0) == {:ok, 0}
      assert Version.from_json(42) == {:ok, 42}
    end

    test "rejects negative integers" do
      assert Version.from_json(-1) == {:error, :invalid_protocol_version}
    end

    test "rejects strings, including legacy date-string handshakes" do
      assert Version.from_json("2024-11-05") == {:error, :invalid_protocol_version}
      assert Version.from_json("anything") == {:error, :invalid_protocol_version}
    end

    test "rejects other shapes without raising" do
      assert Version.from_json(nil) == {:error, :invalid_protocol_version}
      assert Version.from_json(1.0) == {:error, :invalid_protocol_version}
      assert Version.from_json(%{}) == {:error, :invalid_protocol_version}
      assert Version.from_json([]) == {:error, :invalid_protocol_version}
    end
  end

  describe "coerce/1 (tolerant, Zed legacy handshake)" do
    test "integers pass through unchanged" do
      assert Version.coerce(1) == {:ok, 1}
      assert Version.coerce(0) == {:ok, 0}
    end

    test "rejects negative integers" do
      assert Version.coerce(-1) == {:error, :invalid_protocol_version}
    end

    test "coerces a Zed-style MCP date string to latest" do
      assert Version.coerce("2024-11-05") == {:ok, Version.latest()}
    end

    test "coerces any other string to latest, never raising" do
      assert Version.coerce("v1") == {:ok, Version.latest()}
      assert Version.coerce("") == {:ok, Version.latest()}
    end

    test "rejects non-integer, non-string shapes without raising" do
      assert Version.coerce(nil) == {:error, :invalid_protocol_version}
      assert Version.coerce(%{}) == {:error, :invalid_protocol_version}
      assert Version.coerce([]) == {:error, :invalid_protocol_version}
    end
  end
end
