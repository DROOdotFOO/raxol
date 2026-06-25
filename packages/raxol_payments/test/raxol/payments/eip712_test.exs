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

  describe "nested struct types" do
    # Vector generated by ethers v5 via
    # riddler-permit2-erc3009/src/index.js sign-permit2 (commit b870aa2):
    #
    #   PRIVATE_KEY=0x0000...0001 node src/index.js sign-permit2 \
    #     --chain base \
    #     --quote '{"request":{"inputAmount":"1000000","refundAddress":...,
    #                          "inputToken":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"},
    #              "quoteExpires":1900000000,
    #              "gasless":{"to":"0xc6E555dfcC47e4A3bfecd6879570044ADc0270ff",
    #                         "nonce":"1",
    #                         "orderId":"0xdeadbeef0000...",
    #                         "type":"permit2"}}'
    #
    # ethers prints `digest: 0x45ea6009dda9a4c02d810fa2d3e4b6e9f01759e604183fe79fe34f42a98c6518`.
    @permit2_types %{
      "PermitWitnessTransferFrom" => [
        {"permitted", "TokenPermissions"},
        {"spender", "address"},
        {"nonce", "uint256"},
        {"deadline", "uint256"},
        {"witness", "OriginPullWitness"}
      ],
      "TokenPermissions" => [{"token", "address"}, {"amount", "uint256"}],
      "OriginPullWitness" => [{"orderId", "bytes32"}]
    }

    @permit2_domain %{
      name: "Permit2",
      chainId: 8453,
      verifyingContract: "0x000000000022D473030F116dDEE9F6B43aC78BA3"
    }

    @permit2_message %{
      "permitted" => %{
        "token" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        "amount" => 1_000_000
      },
      "spender" => "0xc6E555dfcC47e4A3bfecd6879570044ADc0270ff",
      "nonce" => 1,
      "deadline" => 1_900_000_000,
      "witness" => %{
        "orderId" => "0xdeadbeef00000000000000000000000000000000000000000000000000000000"
      }
    }

    @expected_digest "0x45ea6009dda9a4c02d810fa2d3e4b6e9f01759e604183fe79fe34f42a98c6518"

    test "Permit2 PermitWitnessTransferFrom digest matches ethers v5 byte-for-byte" do
      assert {:ok, digest} =
               EIP712.hash(@permit2_domain, @permit2_types, @permit2_message)

      assert "0x" <> Base.encode16(digest, case: :lower) == @expected_digest
    end

    test "rejects a nested struct field whose type is not in the types map" do
      types = %{
        "Outer" => [{"inner", "Missing"}]
      }

      assert {:error, {:unknown_struct_type, "Missing"}} =
               EIP712.hash(%{name: "Test"}, types, %{"inner" => %{"x" => 1}})
    end

    test "two-level nested struct hashes deterministically" do
      types = %{
        "L1" => [{"a", "uint256"}, {"l2", "L2"}],
        "L2" => [{"b", "uint256"}, {"l3", "L3"}],
        "L3" => [{"c", "uint256"}]
      }

      message = %{
        "a" => 1,
        "l2" => %{"b" => 2, "l3" => %{"c" => 3}}
      }

      assert {:ok, h1} = EIP712.hash(%{name: "Test"}, types, message)
      assert {:ok, h2} = EIP712.hash(%{name: "Test"}, types, message)
      assert h1 == h2
      assert byte_size(h1) == 32
    end

    test "type collection sorts referenced types alphabetically" do
      # OriginPullWitness < TokenPermissions when sorted alphabetically.
      # If sorting is broken, the typeHash differs and the digest changes.
      out_of_order = %{
        "PermitWitnessTransferFrom" => [
          {"permitted", "TokenPermissions"},
          {"spender", "address"},
          {"nonce", "uint256"},
          {"deadline", "uint256"},
          {"witness", "OriginPullWitness"}
        ],
        # Put TokenPermissions before OriginPullWitness on purpose.
        "TokenPermissions" => [{"token", "address"}, {"amount", "uint256"}],
        "OriginPullWitness" => [{"orderId", "bytes32"}]
      }

      assert {:ok, digest} =
               EIP712.hash(@permit2_domain, out_of_order, @permit2_message)

      # Same input as the canonical vector -> same digest, proving sort is correct.
      assert "0x" <> Base.encode16(digest, case: :lower) == @expected_digest
    end
  end

  describe "pack_signature/1" do
    @r String.duplicate(<<0xAA>>, 32)
    @s String.duplicate(<<0xBB>>, 32)

    test "normalizes a 0 recovery id to canonical v = 27" do
      assert <<r::binary-size(32), s::binary-size(32), 27>> =
               EIP712.pack_signature({@r, @s, 0})

      assert r == @r
      assert s == @s
    end

    test "normalizes a 1 recovery id to canonical v = 28" do
      assert <<_r::binary-size(32), _s::binary-size(32), 28>> =
               EIP712.pack_signature({@r, @s, 1})
    end

    test "is idempotent for already-canonical 27/28" do
      assert <<_::binary-size(64), 27>> = EIP712.pack_signature({@r, @s, 27})
      assert <<_::binary-size(64), 28>> = EIP712.pack_signature({@r, @s, 28})
    end

    test "always produces a 65-byte signature" do
      assert byte_size(EIP712.pack_signature({@r, @s, 0})) == 65
    end

    test "raises on a non-canonical recovery id rather than packing a bad signature" do
      assert_raise ArgumentError, ~r/non-canonical/, fn ->
        EIP712.pack_signature({@r, @s, 2})
      end
    end
  end
end
