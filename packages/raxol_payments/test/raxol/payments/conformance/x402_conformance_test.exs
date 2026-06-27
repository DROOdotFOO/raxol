defmodule Raxol.Payments.Conformance.X402ConformanceTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Assets.UsdcDomains
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Test.ConformanceFixture
  alias Raxol.Payments.Test.ConformanceSigner

  @moduletag :conformance

  setup_all do
    case ConformanceFixture.locate() do
      {:ok, _path} -> :ok
      {:error, :not_found} -> {:skip, "conformance fixture not found"}
    end
  end

  # ERC-3009 vectors in the fixture exercise the x402 protocol's signing
  # path. The CLI hardcodes per-chain USDC name/version in config.js; we
  # cross-check that raxol_payments' UsdcDomains.lookup/1 agrees and that
  # EIP712.hash/3 produces the same digest byte-for-byte.
  @erc3009_types %{
    "ReceiveWithAuthorization" => [
      {"from", "address"},
      {"to", "address"},
      {"value", "uint256"},
      {"validAfter", "uint256"},
      {"validBefore", "uint256"},
      {"nonce", "bytes32"}
    ]
  }

  describe "ERC-3009 (x402) EIP-712 conformance vs CLI" do
    for vec <- ConformanceFixture.by_protocol("erc3009") do
      @vec vec

      test "digest matches CLI for #{vec["name"]}" do
        vec = @vec
        domain = atomize_domain(vec["domain"])
        message = parse_message(vec["message"])

        assert {:ok, digest_bytes} = EIP712.hash(domain, @erc3009_types, message)
        digest_hex = "0x" <> Base.encode16(digest_bytes, case: :lower)

        assert digest_hex == vec["expected_digest"],
               "digest mismatch for #{vec["name"]}: got #{digest_hex}, expected #{vec["expected_digest"]}"
      end

      test "UsdcDomains.lookup/1 agrees with CLI domain for #{vec["name"]}" do
        vec = @vec
        chain_id = vec["domain"]["chainId"]
        %{name: name, version: version} = UsdcDomains.lookup(chain_id)

        assert name == vec["domain"]["name"],
               "USDC name mismatch for chain #{chain_id}: got #{name}, expected #{vec["domain"]["name"]}"

        assert version == vec["domain"]["version"],
               "USDC version mismatch for chain #{chain_id}: got #{version}, expected #{vec["domain"]["version"]}"
      end

      # The digest test proves hashing parity; this proves the full
      # hash -> sign -> pack_signature path lands on the exact bytes ethers
      # produced and that they recover to the signer. Offline, no node.
      test "signs + recovers identically to CLI for #{vec["name"]}" do
        vec = @vec
        domain = atomize_domain(vec["domain"])
        message = parse_message(vec["message"])

        assert {:ok, digest} = EIP712.hash(domain, @erc3009_types, message)

        signature =
          ConformanceSigner.sign_hex(digest, ConformanceSigner.decode_hex!(vec["private_key"]))

        assert signature == vec["expected_signature"],
               "signature mismatch for #{vec["name"]}: got #{signature}, expected #{vec["expected_signature"]}"

        assert ConformanceSigner.recover_address(digest, signature) ==
                 String.downcase(vec["expected_signer"]),
               "recovered signer mismatch for #{vec["name"]}"
      end
    end
  end

  defp atomize_domain(domain) do
    %{
      name: domain["name"],
      version: domain["version"],
      chainId: domain["chainId"],
      verifyingContract: domain["verifyingContract"]
    }
  end

  # CLI emits `value` and `validBefore`/`validAfter` as strings or numbers;
  # nonce as a 0x-prefixed bytes32. EIP712.encode_value already handles
  # uint256 from string or int, but normalize value to integer here for
  # clarity. nonce stays as 0x-string (bytes32 clause handles that).
  defp parse_message(message) do
    %{
      "from" => message["from"],
      "to" => message["to"],
      "value" => to_int(message["value"]),
      "validAfter" => to_int(message["validAfter"]),
      "validBefore" => to_int(message["validBefore"]),
      "nonce" => message["nonce"]
    }
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
end
