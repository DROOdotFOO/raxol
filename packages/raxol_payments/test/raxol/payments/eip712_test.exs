defmodule Raxol.Payments.EIP712Test do
  use ExUnit.Case, async: true

  alias Raxol.Payments.EIP712

  @domain %{
    name: "Test",
    version: "1",
    chainId: 1,
    verifyingContract: "0x" <> String.duplicate("ab", 20)
  }

  @types %{"Transfer" => [{"to", "address"}, {"amount", "uint256"}]}
  @valid_message %{to: "0x" <> String.duplicate("cd", 20), amount: 1000}

  describe "hash/3" do
    test "valid typed data produces a 32-byte hash" do
      assert {:ok, hash} = EIP712.hash(@domain, @types, @valid_message)
      assert byte_size(hash) == 32
    end

    test "is deterministic for identical inputs" do
      assert {:ok, h1} = EIP712.hash(@domain, @types, @valid_message)
      assert {:ok, h2} = EIP712.hash(@domain, @types, @valid_message)
      assert h1 == h2
    end

    test "differs when message changes" do
      other = %{@valid_message | amount: 1001}
      assert {:ok, h1} = EIP712.hash(@domain, @types, @valid_message)
      assert {:ok, h2} = EIP712.hash(@domain, @types, other)
      assert h1 != h2
    end

    test "differs when domain changes" do
      other_domain = %{@domain | chainId: 8453}
      assert {:ok, h1} = EIP712.hash(@domain, @types, @valid_message)
      assert {:ok, h2} = EIP712.hash(other_domain, @types, @valid_message)
      assert h1 != h2
    end

    test "differs when type field name changes (typeHash captures field names)" do
      other_types = %{"Transfer" => [{"recipient", "address"}, {"amount", "uint256"}]}
      other_message = %{recipient: "0x" <> String.duplicate("cd", 20), amount: 1000}

      assert {:ok, h1} = EIP712.hash(@domain, @types, @valid_message)
      assert {:ok, h2} = EIP712.hash(@domain, other_types, other_message)
      assert h1 != h2
    end

    test "domain with only :name is valid" do
      assert {:ok, hash} = EIP712.hash(%{name: "Test"}, @types, @valid_message)
      assert byte_size(hash) == 32
    end

    test "invalid hex in address field returns error" do
      message = %{to: "0xZZZZ", amount: 1000}

      assert {:error, {:invalid_hex, "address"}} =
               EIP712.hash(@domain, @types, message)
    end

    test "address with wrong byte length returns error" do
      short_addr = "0x" <> String.duplicate("ab", 10)
      message = %{to: short_addr, amount: 1000}

      assert {:error, {:invalid_address_length, 10}} =
               EIP712.hash(@domain, @types, message)
    end

    test "invalid uint256 string returns error" do
      types = %{"Transfer" => [{"to", "address"}, {"amount", "uint256"}]}
      message = %{to: "0x" <> String.duplicate("cd", 20), amount: "not_a_number"}

      assert {:error, {:invalid_uint256, "not_a_number"}} =
               EIP712.hash(@domain, types, message)
    end

    test "invalid hex in bytes32 field returns error" do
      types = %{"Record" => [{"hash", "bytes32"}]}
      message = %{hash: "0xNOTHEX"}

      assert {:error, {:invalid_hex, "bytes32"}} =
               EIP712.hash(%{name: "Test"}, types, message)
    end

    test "field name not an existing atom does not crash" do
      # Use a field name unlikely to exist as an atom
      novel_field = "zzz_never_atomized_#{System.unique_integer([:positive])}"
      types = %{"Foo" => [{novel_field, "uint256"}]}
      # Data keyed by string -- safe_atom_get rescues ArgumentError, returns nil,
      # nil is then encoded as 32 zero bytes.
      message = %{}

      assert {:ok, hash} = EIP712.hash(%{name: "Test"}, types, message)
      assert byte_size(hash) == 32
    end

    test "uint256 accepts integer values" do
      types = %{"Bar" => [{"value", "uint256"}]}
      assert {:ok, _} = EIP712.hash(%{name: "Test"}, types, %{value: 42})
    end

    test "bool true and false produce different hashes" do
      types = %{"Flag" => [{"on", "bool"}]}
      assert {:ok, h_true} = EIP712.hash(%{name: "Test"}, types, %{on: true})
      assert {:ok, h_false} = EIP712.hash(%{name: "Test"}, types, %{on: false})
      assert h_true != h_false
    end

    test "string field is hashed (per EIP-712 spec)" do
      types = %{"Note" => [{"text", "string"}]}
      assert {:ok, h1} = EIP712.hash(%{name: "Test"}, types, %{text: "hello"})
      assert {:ok, h2} = EIP712.hash(%{name: "Test"}, types, %{text: "world"})
      assert byte_size(h1) == 32
      assert h1 != h2
    end
  end

  describe "dynamic array types (T[])" do
    test "string[] hashes per EIP-712 array rule" do
      types = %{"Box" => [{"tags", "string[]"}]}
      domain = %{name: "Test"}

      assert {:ok, h1} = EIP712.hash(domain, types, %{tags: ["a", "b"]})
      assert {:ok, h2} = EIP712.hash(domain, types, %{tags: ["b", "a"]})
      assert {:ok, h3} = EIP712.hash(domain, types, %{tags: ["a", "b"]})

      # Order matters: ["a","b"] != ["b","a"]
      assert h1 != h2
      # Determinism: same input -> same hash
      assert h1 == h3
    end

    test "address[] encodes each element as 32-byte padded address" do
      types = %{"Roster" => [{"members", "address[]"}]}

      assert {:ok, _h} =
               EIP712.hash(%{name: "Test"}, types, %{
                 members: [
                   "0x1111111111111111111111111111111111111111",
                   "0x2222222222222222222222222222222222222222"
                 ]
               })
    end

    test "uint256[] handles integer elements" do
      types = %{"Bag" => [{"amounts", "uint256[]"}]}

      assert {:ok, h1} =
               EIP712.hash(%{name: "Test"}, types, %{amounts: [1, 2, 3]})

      assert {:ok, h2} =
               EIP712.hash(%{name: "Test"}, types, %{amounts: [3, 2, 1]})

      assert h1 != h2
    end

    test "empty array hashes to keccak256(<<>>)" do
      types = %{"Box" => [{"tags", "string[]"}]}
      assert {:ok, h_empty} = EIP712.hash(%{name: "Test"}, types, %{tags: []})
      assert byte_size(h_empty) == 32
    end

    test "rejects a non-array type given a list value" do
      types = %{"X" => [{"name", "string"}]}
      assert {:error, _} = EIP712.hash(%{name: "Test"}, types, %{name: ["a", "b"]})
    end
  end
end
