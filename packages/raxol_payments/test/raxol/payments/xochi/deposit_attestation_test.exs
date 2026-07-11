defmodule Raxol.Payments.Xochi.DepositAttestationTest do
  # #400: a deposit-route quote returns a bare deposit_address; the client must
  # verify the deposit_attestation recovers to the pinned signer before sending
  # funds. The signed message must be byte-exact with the Riddler signer.
  use ExUnit.Case, async: true

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Xochi.DepositAttestation

  @fields %{
    intent_id: "xi_abc123",
    quote_id: "xq_def456",
    from_chain_id: 728_126_428,
    from_token: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    from_amount: "1000000",
    deposit_address: "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"
  }

  # A deterministic secp256k1 key: the "signer". Real crypto, no mocks -- the
  # signature is produced with ExSecp256k1 exactly as a wallet would.
  @priv <<1::256>>

  defp signer_address do
    {:ok, <<_prefix::8, xy::binary-size(64)>>} = ExSecp256k1.create_public_key(@priv)
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  defp sign(fields) do
    digest =
      ("\x19Ethereum Signed Message:\n" <>
         Integer.to_string(byte_size(DepositAttestation.message(fields))) <>
         DepositAttestation.message(fields))
      |> ExKeccak.hash_256()

    {:ok, sig} = ExSecp256k1.sign(digest, @priv)
    "0x" <> Base.encode16(EIP712.pack_signature(sig), case: :lower)
  end

  describe "message/1 (byte-exact Riddler parity)" do
    test "matches the v1 spec byte-for-byte" do
      assert DepositAttestation.message(@fields) ==
               "xochi-deposit-attestation:v1\n" <>
                 "xi_abc123\n" <>
                 "xq_def456\n" <>
                 "728126428\n" <>
                 "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t\n" <>
                 "1000000\n" <>
                 "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"
    end

    test "lowercases an EVM (0x-hex) address; leaves base58 verbatim" do
      msg =
        DepositAttestation.message(%{
          @fields
          | from_token: "0xAbCdEf0000000000000000000000000000000001"
        })

      assert msg =~ "0xabcdef0000000000000000000000000000000001"
      assert msg =~ "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"
    end

    test "accepts an integer from_amount" do
      assert DepositAttestation.message(%{@fields | from_amount: 1_000_000}) ==
               DepositAttestation.message(@fields)
    end
  end

  describe "recover/2 and verify/3" do
    test "an attestation recovers to the signing address" do
      assert {:ok, recovered} = DepositAttestation.recover(@fields, sign(@fields))
      assert recovered == signer_address()
    end

    test "verify/3 accepts a signature that recovers to the pinned signer" do
      assert :ok = DepositAttestation.verify(@fields, sign(@fields), signer_address())
    end

    test "verify/3 is case-insensitive on the pinned signer" do
      assert :ok =
               DepositAttestation.verify(@fields, sign(@fields), String.upcase(signer_address()))
    end

    test "a tampered deposit_address no longer recovers to the signer (MITM swap)" do
      sig = sign(@fields)
      tampered = %{@fields | deposit_address: "TTamperedAddr00000000000000000000000"}

      assert {:ok, recovered} = DepositAttestation.recover(tampered, sig)
      refute recovered == signer_address()

      assert {:error, :attestation_mismatch} =
               DepositAttestation.verify(tampered, sig, signer_address())
    end

    test "verify/3 rejects an attestation from a different signer" do
      other = "0x000000000000000000000000000000000000dead"

      assert {:error, :attestation_mismatch} =
               DepositAttestation.verify(@fields, sign(@fields), other)
    end

    test "verify/3 fails closed on a missing attestation" do
      assert {:error, :missing_attestation} =
               DepositAttestation.verify(@fields, nil, signer_address())

      assert {:error, :missing_attestation} =
               DepositAttestation.verify(@fields, "", signer_address())
    end

    test "verify/3 fails closed when no signer is pinned" do
      assert {:error, :signer_unavailable} =
               DepositAttestation.verify(@fields, sign(@fields), nil)

      assert {:error, :signer_unavailable} = DepositAttestation.verify(@fields, sign(@fields), "")
    end

    test "verify/3 rejects a malformed signature" do
      assert {:error, :invalid_signature} =
               DepositAttestation.verify(@fields, "0xdeadbeef", signer_address())

      assert {:error, :invalid_signature} = DepositAttestation.recover(@fields, "not-a-sig")
    end
  end
end
