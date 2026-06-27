defmodule Raxol.Payments.Conformance.XochiConformanceTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Test.ConformanceFixture
  alias Raxol.Payments.Test.ConformanceSigner

  @moduletag :conformance

  # secp256k1 private key 1 from the conformance fixtures; derives the signer
  # below. Pinned here so the shielded vector signs without the JSON fixture.
  @canonical_key "0x0000000000000000000000000000000000000000000000000000000000000001"
  @canonical_signer "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"

  # XochiIntent typed data, byte-for-byte aligned with the CLI's XOCHI_TYPES
  # (riddler-client src/xochi-signing.js) and
  # Riddler.Integrations.Xochi.EIP712.type_definitions/0.
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
      {"nonce", "uint256"},
      {"deadline", "uint256"}
    ]
  }

  # The shielded XochiIntent domain mirrors the fixture generator: name/version
  # are locked for determinism (production reads them from the quote response).
  @shielded_domain %{name: "XochiIntent", version: "1", chainId: 8453}

  # Pinned in riddler-client test-xochi.js ("shielded intent signs
  # deterministically"); the cross-repo byte-equality contract for the private
  # settlement path.
  @shielded_signature "0xbe2545d815e4ce15d859e9bdee5bcb3a2f81e94a4b0fd0586220bd0235682d2f4bd1ea6082ddb8e59bb5557e91cb2f80e4dd3aef800e0fa4eabd0367a04c86061b"

  # The fixture domain (above) is a determinism-locked synthetic, NOT the live
  # worker domain. The live worker domain-separates with name "Xochi", version
  # "1-prod", and a bytes32 salt (no verifyingContract) -- pinned byte-for-byte
  # against viem in eip712_test.exs "salt domain". Kept here to guard the drift.
  @live_domain %{
    name: "Xochi",
    version: "1-prod",
    chainId: 8453,
    salt: "0x50c4e63fec78d6897bf2f854fbe944310903876e56027940293bb80e79f75fe2"
  }

  setup_all do
    case ConformanceFixture.locate() do
      {:ok, _path} -> :ok
      {:error, :not_found} -> {:skip, "conformance fixture not found"}
    end
  end

  # Xochi vectors carry their full EIP-712 typed data inline because the
  # domain has no `verifyingContract` and the `version` is deployment-scoped
  # (read from the quote response at runtime).
  describe "Xochi XochiIntent EIP-712 conformance vs CLI" do
    for vec <- ConformanceFixture.by_protocol("xochi") do
      @vec vec

      test "digest matches CLI for #{vec["name"]}" do
        vec = @vec
        eip712 = vec["eip712"]
        domain = atomize_domain(eip712["domain"])
        types = atomize_types(eip712["types"])
        message = eip712["message"]

        assert {:ok, digest_bytes} = EIP712.hash(domain, types, message)
        digest_hex = "0x" <> Base.encode16(digest_bytes, case: :lower)

        assert digest_hex == vec["expected_digest"],
               "digest mismatch for #{vec["name"]}: got #{digest_hex}, expected #{vec["expected_digest"]}"
      end

      # The fixture pins the ethers signature and signer for every vector. The
      # digest test above only proves hashing parity; this proves the full
      # hash -> sign -> pack_signature path lands on the exact bytes ethers
      # produced (deterministic RFC 6979, low-s, on-chain-canonical v of 27/28),
      # and that those bytes recover to the intent wallet. Always-on, no node.
      test "signs + recovers identically to CLI for #{vec["name"]}" do
        vec = @vec
        eip712 = vec["eip712"]
        domain = atomize_domain(eip712["domain"])
        types = atomize_types(eip712["types"])
        message = eip712["message"]

        assert {:ok, digest} = EIP712.hash(domain, types, message)

        signature =
          ConformanceSigner.sign_hex(digest, ConformanceSigner.decode_hex!(vec["private_key"]))

        assert signature == vec["expected_signature"],
               "signature mismatch for #{vec["name"]}: got #{signature}, expected #{vec["expected_signature"]}"

        assert ConformanceSigner.recover_address(digest, signature) ==
                 String.downcase(vec["expected_signer"]),
               "recovered signer mismatch for #{vec["name"]}"
      end

      test "domain has no verifyingContract for #{vec["name"]}" do
        vec = @vec
        refute Map.has_key?(vec["eip712"]["domain"], "verifyingContract")
      end
    end
  end

  # The conformance.json generator only emits `public` Xochi vectors, so the
  # shielded (Aztec) signature is pinned directly against the CLI's own pin.
  # Shielded settlement is note-based and carries no stealth address; the only
  # client-side artifact is this signature, so a regression in EIP-712 hashing
  # or the settlementPreference binding is caught here without a live solver.
  describe "shielded XochiIntent signature (pinned, mirrors riddler-client)" do
    test "signs the pinned shielded vector byte-for-byte and recovers to the signer" do
      message = shielded_message("shielded")

      assert {:ok, digest} = EIP712.hash(@shielded_domain, @xochi_types, message)

      signature =
        ConformanceSigner.sign_hex(digest, ConformanceSigner.decode_hex!(@canonical_key))

      assert signature == @shielded_signature
      assert ConformanceSigner.recover_address(digest, signature) == @canonical_signer
    end

    test "settlementPreference is bound into the digest (public != stealth != shielded)" do
      digests =
        for pref <- ~w(public stealth shielded) do
          assert {:ok, digest} =
                   EIP712.hash(@shielded_domain, @xochi_types, shielded_message(pref))

          digest
        end

      assert digests == Enum.uniq(digests), "settlement preferences must not collide"
    end
  end

  # The conformance fixture validates raxol's EIP-712 hashing math against a
  # domain the generator locks "for determinism" (XochiIntent / version "1" /
  # no salt). That is deliberately NOT the live worker domain (Xochi / version
  # "1-prod" / salt). raxol signs whatever domain the quote serves verbatim
  # (Protocols.Xochi.eip712_domain/1 copies salt + verifyingContract), so the
  # live path is correct regardless -- but a fixture digest must never be taken
  # for a live one. This guard fails loudly if the two domains ever converge,
  # forcing a conscious decision about whether the fixture should track live.
  describe "live-vs-fixture domain drift guard" do
    test "the fixture domain differs from the live worker domain (name, version, salt)" do
      fixture = ConformanceFixture.by_name("xochi-base-optimism-usdc")["eip712"]["domain"]

      assert fixture["name"] == "XochiIntent"
      assert fixture["name"] != @live_domain.name

      assert fixture["version"] == "1"
      assert fixture["version"] != @live_domain.version

      refute Map.has_key?(fixture, "salt")
      assert Map.has_key?(@live_domain, :salt)
    end

    test "the same XochiIntent message hashes differently under each domain" do
      message = shielded_message("public")

      assert {:ok, fixture_digest} =
               EIP712.hash(
                 %{name: "XochiIntent", version: "1", chainId: 8453},
                 @xochi_types,
                 message
               )

      assert {:ok, live_digest} = EIP712.hash(@live_domain, @xochi_types, message)

      refute fixture_digest == live_digest,
             "fixture and live domains must not collide: a fixture-signed intent must never validate against the live worker"
    end
  end

  # -- Fixture shape helpers --

  defp atomize_domain(domain) do
    %{name: domain["name"], chainId: domain["chainId"]}
    |> maybe_put(:version, domain["version"])
    |> maybe_put(:salt, domain["salt"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # CLI emits types as { TypeName: [{name, type}, ...], ... }; convert to
  # the {name, type} tuple shape Raxol.Payments.EIP712 expects.
  defp atomize_types(types) do
    Enum.into(types, %{}, fn {type_name, fields} ->
      tuples =
        Enum.map(fields, fn %{"name" => name, "type" => type} -> {name, type} end)

      {type_name, tuples}
    end)
  end

  defp shielded_message(settlement) do
    %{
      "intentId" => "shielded-test",
      "quoteId" => "shielded-test",
      "wallet" => "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
      "fromChainId" => 8453,
      "toChainId" => 10,
      "fromToken" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      "toToken" => "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
      "fromAmount" => "1000000",
      "toAmount" => "1000000",
      "settlementPreference" => settlement,
      "nonce" => 0,
      "deadline" => 1_900_000_000
    }
  end
end
