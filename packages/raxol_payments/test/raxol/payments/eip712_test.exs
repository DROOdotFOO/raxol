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
      other_types = %{
        "Transfer" => [{"recipient", "address"}, {"amount", "uint256"}]
      }

      other_message = %{
        recipient: "0x" <> String.duplicate("cd", 20),
        amount: 1000
      }

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

      message = %{
        to: "0x" <> String.duplicate("cd", 20),
        amount: "not_a_number"
      }

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

      assert {:error, _} =
               EIP712.hash(%{name: "Test"}, types, %{name: ["a", "b"]})
    end
  end

  describe "nested struct types" do
    # Vector generated by ethers v5 via
    # riddler-client/src/index.js sign-permit2 (commit b870aa2):
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

  describe "salt domain (Xochi XochiIntent)" do
    # The Xochi worker domain-separates the XochiIntent with a bytes32 `salt`
    # instead of a verifyingContract. Vector generated by viem hashTypedData
    # (xochi-eip712 repo) over the typed data the worker serves on
    # POST /api/intent/quote:
    #
    #   domain = { name: "Xochi", version: "1-prod", chainId: 8453, salt }
    #   primaryType = "XochiIntent"
    #
    # viem prints digest 0x2250ca7332932abfec5b02ad59a540ed60f03b5a33bdac4f23699b72fe38ba11.
    # Dropping salt yields 0xc2cbb4e9...b2e248, which the worker rejects (the
    # signer recovers to a different address -> HTTP 401). See GitHub #333.
    @xochi_types %{
      "XochiIntent" => [
        {"intentId", "string"},
        {"quoteId", "string"},
        {"wallet", "address"},
        {"fromChainId", "uint256"},
        {"toChainId", "uint256"},
        {"fromToken", "address"},
        {"toToken", "address"},
        {"fromAmount", "uint256"},
        {"toAmount", "uint256"},
        {"settlementPreference", "string"},
        {"deadline", "uint256"}
      ]
    }

    @xochi_salt "0x50c4e63fec78d6897bf2f854fbe944310903876e56027940293bb80e79f75fe2"
    @xochi_domain %{
      name: "Xochi",
      version: "1-prod",
      chainId: 8453,
      salt: @xochi_salt
    }

    @xochi_message %{
      "intentId" => "xi_c3d0ee6c0b69d86f60965ac521dedba9",
      "quoteId" => "xq_b6a5903083bc4a23838e44c11d6bf79c",
      "wallet" => "0xd8da6bf26964af9d7eed9e03e53415d37aa96045",
      "fromChainId" => 8453,
      "toChainId" => 42_161,
      "fromToken" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "toToken" => "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
      "fromAmount" => "10000000",
      "toAmount" => "9949983",
      "settlementPreference" => "public",
      "deadline" => 1_782_422_954
    }

    @xochi_digest "0x2250ca7332932abfec5b02ad59a540ed60f03b5a33bdac4f23699b72fe38ba11"

    test "XochiIntent digest matches viem byte-for-byte (salt participates)" do
      assert {:ok, digest} =
               EIP712.hash(@xochi_domain, @xochi_types, @xochi_message)

      assert "0x" <> Base.encode16(digest, case: :lower) == @xochi_digest
    end

    test "dropping salt produces a different digest" do
      no_salt = Map.delete(@xochi_domain, :salt)

      assert {:ok, with_salt} =
               EIP712.hash(@xochi_domain, @xochi_types, @xochi_message)

      assert {:ok, without_salt} =
               EIP712.hash(no_salt, @xochi_types, @xochi_message)

      assert with_salt != without_salt
    end

    test "salt is encoded as bytes32 in the domain separator" do
      other_salt =
        Map.put(@xochi_domain, :salt, "0x" <> String.duplicate("11", 32))

      assert {:ok, a} = EIP712.hash(@xochi_domain, @xochi_types, @xochi_message)
      assert {:ok, b} = EIP712.hash(other_salt, @xochi_types, @xochi_message)
      assert a != b
    end
  end

  describe "hash_with_separator/3" do
    @permit2 "0x000000000022D473030F116dDEE9F6B43aC78BA3"
    @separator_types %{"Thing" => [{"x", "uint256"}]}
    @separator_message %{"x" => 42}

    test "agrees with hash/3 when given the separator hash/3 would have built" do
      # Supplying the same domain in a different form must not change the
      # digest, or the two entry points would disagree about what was signed.
      domain = %{name: "Permit2", chainId: 8453, verifyingContract: @permit2}

      {:ok, computed} = EIP712.hash(domain, @separator_types, @separator_message)

      {:ok, supplied} =
        EIP712.hash_with_separator(
          domain_separator(domain),
          @separator_types,
          @separator_message
        )

      assert supplied == computed
    end

    test "a different separator gives a different digest, so the domain is load-bearing" do
      # The whole point of the arity-3 form: the domain half comes from the
      # caller (in production, read from the verifying contract), so a domain
      # this module would have built differently is visible rather than
      # cancelled out on both sides. See GitHub #772.
      three_field =
        domain_separator(%{name: "Permit2", chainId: 8453, verifyingContract: @permit2})

      four_field =
        domain_separator(%{
          name: "Permit2",
          version: nil,
          chainId: 8453,
          verifyingContract: @permit2
        })

      refute three_field == four_field

      {:ok, a} = EIP712.hash_with_separator(three_field, @separator_types, @separator_message)
      {:ok, b} = EIP712.hash_with_separator(four_field, @separator_types, @separator_message)

      refute a == b
    end

    test "refuses a separator that is not 32 bytes rather than padding it" do
      assert {:error, {:invalid_domain_separator_length, 4}} =
               EIP712.hash_with_separator(<<1, 2, 3, 4>>, @separator_types, @separator_message)
    end

    # The separator comes off the wire -- an `eth_call` result a caller decoded --
    # so a non-binary is a shape this is asked about, not a caller bug. Returning
    # the error the spec promises beats raising out of a public function.
    test "refuses a separator that is not a binary at all" do
      for bad <- [nil, :error, 42, {:ok, <<0>>}] do
        assert {:error, {:invalid_domain_separator, ^bad}} =
                 EIP712.hash_with_separator(bad, @separator_types, @separator_message)
      end
    end

    test "propagates an encoding error from the struct half" do
      assert {:error, _} =
               EIP712.hash_with_separator(
                 :binary.copy(<<0>>, 32),
                 %{"Thing" => [{"x", "address"}]},
                 %{"x" => "not-an-address"}
               )
    end

    # EIP712Domain separator built the long way, so the test does not lean on the
    # function under test to produce its own oracle.
    defp domain_separator(domain) do
      fields =
        [
          {"name", "string", :name},
          {"version", "string", :version},
          {"chainId", "uint256", :chainId},
          {"verifyingContract", "address", :verifyingContract},
          {"salt", "bytes32", :salt}
        ]
        |> Enum.filter(fn {_n, _t, key} -> Map.has_key?(domain, key) end)

      type_string =
        "EIP712Domain(" <> Enum.map_join(fields, ",", fn {n, t, _} -> "#{t} #{n}" end) <> ")"

      encoded =
        Enum.map_join(fields, "", fn {_n, type, key} ->
          encode_domain_field(type, Map.get(domain, key))
        end)

      ExKeccak.hash_256(ExKeccak.hash_256(type_string) <> encoded)
    end

    defp encode_domain_field("string", nil), do: ExKeccak.hash_256("")
    defp encode_domain_field("string", v), do: ExKeccak.hash_256(v)
    defp encode_domain_field("uint256", v), do: <<v::unsigned-big-256>>

    defp encode_domain_field("address", "0x" <> hex),
      do: <<0::size(96)>> <> Base.decode16!(hex, case: :mixed)

    defp encode_domain_field("bytes32", "0x" <> hex), do: Base.decode16!(hex, case: :mixed)
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

  describe "address_from_pubkey/1" do
    test "derives the canonical privkey=1 Ethereum address" do
      # Well-known vector: secp256k1 private key 1 -> this address.
      {:ok, pubkey} = ExSecp256k1.create_public_key(<<1::256>>)
      assert byte_size(pubkey) == 65
      assert <<0x04, _xy::binary-size(64)>> = pubkey

      assert Raxol.Payments.EIP712.address_from_pubkey(pubkey) ==
               "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
    end

    test "normalize_address trims, downcases and strips a leading 0x" do
      assert Raxol.Payments.EIP712.normalize_address("  0xAbCdEf0123456789  ") ==
               "abcdef0123456789"

      assert Raxol.Payments.EIP712.normalize_address("deadBEEF") == "deadbeef"
    end
  end
end
