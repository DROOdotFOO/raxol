defmodule Raxol.Payments.ZksarTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Zksar

  @now 1_700_000_000

  # anvil account 0 + 1 keys -- real, valid secp256k1 scalars
  @signer_key Base.decode16!(
                "AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80",
                case: :mixed
              )
  @other_key Base.decode16!(
               "59C6995E998F97A5A0044966F0945389DC9E86DAE88C7A8412F4603B6B78690D",
               case: :mixed
             )

  # Address of @signer_key, derived inline (the Signer helper below isn't
  # compiled yet at attribute-evaluation time).
  @issuer (
            {:ok, pub} = ExSecp256k1.create_public_key(@signer_key)
            <<_prefix::8, body::binary-size(64)>> = pub
            <<_first_12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(body)
            "0x" <> Base.encode16(addr, case: :lower)
          )

  # A structurally-valid proof with a placeholder (non-recovering) signature.
  # Use with `verify_signature: false` to exercise non-signature logic.
  @valid_proof %{
    type_code: 0x01,
    issuer: @issuer,
    subject: "0x00000000000000000000000000000000000000ff",
    issued_at: @now - 100,
    expires_at: @now + 3600,
    signature: "0xdeadbeef",
    payload: <<1, 2, 3, 4>>
  }

  defmodule Signer do
    @moduledoc false

    # Build a proof signed by `key` over `Zksar.attestation_digest/1`, so it
    # recovers to the key's address. `overrides` applied BEFORE signing.
    def signed_proof(key, overrides \\ %{}) do
      proof =
        Map.merge(
          %{
            type_code: 0x01,
            issuer: address_for(key),
            subject: "0x00000000000000000000000000000000000000ff",
            issued_at: 1_700_000_000 - 100,
            expires_at: 1_700_000_000 + 3600,
            signature: "",
            payload: <<1, 2, 3, 4>>
          },
          overrides
        )

      digest = Zksar.attestation_digest(proof)
      {:ok, {r, s, v}} = ExSecp256k1.sign(digest, key)
      sig = "0x" <> Base.encode16(<<r::binary-size(32), s::binary-size(32), v::8>>, case: :lower)
      %{proof | signature: sig}
    end

    def address_for(key) do
      {:ok, pub} = ExSecp256k1.create_public_key(key)
      <<_prefix::8, body::binary-size(64)>> = pub
      <<_first_12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(body)
      "0x" <> Base.encode16(addr, case: :lower)
    end
  end

  describe "verify/2 -- signature verification (secure default)" do
    test "accepts a proof whose signature recovers to an allowed issuer" do
      proof = Signer.signed_proof(@signer_key)

      assert {:ok, vp} =
               Zksar.verify(proof, now: @now, allowed_issuers: [@issuer])

      assert vp.type == :compliance
      assert vp.issuer == @issuer
      assert vp.valid == true
    end

    test "the issuer allowlist is case-insensitive" do
      proof = Signer.signed_proof(@signer_key)
      upper = "0x" <> String.upcase(String.replace_prefix(@issuer, "0x", ""))

      assert {:ok, _} = Zksar.verify(proof, now: @now, allowed_issuers: [upper])
    end

    test "verifies each proof type code (each is signed over its own digest)" do
      for {code, expected_type} <- [
            {0x01, :compliance},
            {0x02, :risk_score},
            {0x03, :pattern},
            {0x04, :attestation},
            {0x05, :membership},
            {0x06, :non_membership}
          ] do
        proof = Signer.signed_proof(@signer_key, %{type_code: code})
        assert {:ok, vp} = Zksar.verify(proof, now: @now, allowed_issuers: [@issuer])
        assert vp.type == expected_type
      end
    end

    test "rejects a forged proof that merely names a trusted issuer" do
      # The attack the signature check exists to stop: copy a trusted issuer
      # address, attach a garbage signature.
      forged = %{@valid_proof | issuer: @issuer, signature: "0xdeadbeef"}

      assert {:error, :invalid_signature} =
               Zksar.verify(forged, now: @now, allowed_issuers: [@issuer])
    end

    test "rejects a proof tampered after signing (payload changed)" do
      proof = Signer.signed_proof(@signer_key)
      tampered = %{proof | payload: <<9, 9, 9, 9>>}

      assert {:error, :invalid_signature} =
               Zksar.verify(tampered, now: @now, allowed_issuers: [@issuer])
    end

    test "rejects a proof tampered after signing (issued_at changed)" do
      proof = Signer.signed_proof(@signer_key)
      tampered = %{proof | issued_at: proof.issued_at - 1}

      assert {:error, :invalid_signature} =
               Zksar.verify(tampered, now: @now, allowed_issuers: [@issuer])
    end

    test "rejects a signature from a different key than the named issuer" do
      # Signed by @other_key but claims @issuer (= @signer_key's address).
      proof = Signer.signed_proof(@other_key, %{issuer: @issuer})

      assert {:error, :invalid_signature} =
               Zksar.verify(proof, now: @now, allowed_issuers: [@issuer])
    end

    test "rejects a validly-signed proof whose issuer is not on the allowlist" do
      proof = Signer.signed_proof(@signer_key)

      assert {:error, :invalid_issuer} =
               Zksar.verify(proof,
                 now: @now,
                 allowed_issuers: ["0x000000000000000000000000000000000000dead"]
               )
    end

    test "fails closed when no allowlist is supplied" do
      proof = Signer.signed_proof(@signer_key)
      assert {:error, :issuer_required} = Zksar.verify(proof, now: @now)
    end
  end

  describe "verify/2 -- structural checks (verify_signature: false)" do
    @opts [now: @now, verify_signature: false]

    test "verifies a structurally valid proof" do
      assert {:ok, vp} = Zksar.verify(@valid_proof, @opts)
      assert vp.type == :compliance
      assert vp.subject == @valid_proof.subject
      assert vp.issuer == @issuer
      assert vp.valid == true
    end

    test "accepts allowed issuer" do
      assert {:ok, _} = Zksar.verify(@valid_proof, [allowed_issuers: [@issuer]] ++ @opts)
    end

    test "rejects disallowed issuer" do
      assert {:error, :invalid_issuer} =
               Zksar.verify(@valid_proof, [allowed_issuers: ["0xotherOracle"]] ++ @opts)
    end

    test "accepts any issuer when signature checking is explicitly disabled" do
      # The legacy lenient path -- only reachable with verify_signature: false.
      assert {:ok, _} = Zksar.verify(@valid_proof, @opts)
    end
  end

  describe "verify/2 -- structural rejections (independent of signature)" do
    test "rejects expired proof" do
      proof = %{@valid_proof | expires_at: @now - 1}
      assert {:error, :expired} = Zksar.verify(proof, now: @now)
    end

    test "rejects proof expiring at exactly now" do
      proof = %{@valid_proof | expires_at: @now}
      assert {:error, :expired} = Zksar.verify(proof, now: @now)
    end

    test "rejects unknown type code" do
      proof = %{@valid_proof | type_code: 0xFF}
      assert {:error, :unknown_type} = Zksar.verify(proof, now: @now)
    end

    test "rejects malformed proof (missing fields)" do
      assert {:error, :malformed} = Zksar.verify(%{}, now: @now)
    end

    test "rejects proof with empty subject" do
      proof = %{@valid_proof | subject: ""}
      assert {:error, :malformed} = Zksar.verify(proof, now: @now)
    end

    test "rejects proof with empty issuer" do
      proof = %{@valid_proof | issuer: ""}
      assert {:error, :malformed} = Zksar.verify(proof, now: @now)
    end

    test "rejects proof with empty signature" do
      proof = %{@valid_proof | signature: ""}
      assert {:error, :malformed} = Zksar.verify(proof, now: @now)
    end
  end

  describe "verify_batch/2" do
    @opts [now: @now, verify_signature: false]

    test "returns verified and errors separately" do
      expired = %{@valid_proof | expires_at: @now - 1}
      unknown = %{@valid_proof | type_code: 0xFF}

      {verified, errors} = Zksar.verify_batch([@valid_proof, expired, unknown], @opts)

      assert length(verified) == 1
      assert hd(verified).type == :compliance
      assert length(errors) == 2
      assert {^expired, :expired} = Enum.at(errors, 0)
      assert {^unknown, :unknown_type} = Enum.at(errors, 1)
    end

    test "empty list returns empty results" do
      assert {[], []} = Zksar.verify_batch([], @opts)
    end

    test "preserves order" do
      p1 = %{@valid_proof | type_code: 0x01}
      p2 = %{@valid_proof | type_code: 0x05}

      {verified, []} = Zksar.verify_batch([p1, p2], @opts)
      assert [%{type: :compliance}, %{type: :membership}] = verified
    end
  end

  describe "proof_type_name/1 and proof_type_code/1" do
    test "round-trips all six types" do
      for {code, name} <- [
            {0x01, :compliance},
            {0x02, :risk_score},
            {0x03, :pattern},
            {0x04, :attestation},
            {0x05, :membership},
            {0x06, :non_membership}
          ] do
        assert {:ok, ^name} = Zksar.proof_type_name(code)
        assert {:ok, ^code} = Zksar.proof_type_code(name)
      end
    end

    test "unknown code returns :error" do
      assert :error = Zksar.proof_type_name(0x99)
    end

    test "unknown name returns :error" do
      assert :error = Zksar.proof_type_code(:bogus)
    end
  end

  describe "from_json/1" do
    test "parses valid JSON map" do
      json = %{
        "typeCode" => 0x01,
        "issuer" => "0xoracle",
        "subject" => "0xsubject",
        "issuedAt" => 1000,
        "expiresAt" => 2000,
        "signature" => "0xsig",
        "payload" => "DEADBEEF"
      }

      assert {:ok, proof} = Zksar.from_json(json)
      assert proof.type_code == 0x01
      assert proof.payload == <<0xDE, 0xAD, 0xBE, 0xEF>>
    end

    test "rejects missing fields" do
      assert {:error, :malformed} = Zksar.from_json(%{"typeCode" => 1})
    end

    test "rejects invalid hex payload" do
      json = %{
        "typeCode" => 1,
        "issuer" => "0x",
        "subject" => "0x",
        "issuedAt" => 1,
        "expiresAt" => 2,
        "signature" => "0x",
        "payload" => "not_hex!"
      }

      assert {:error, :malformed} = Zksar.from_json(json)
    end
  end

  describe "adversarial cases" do
    test "expired proof (expires_at = now - 1) returns :expired" do
      proof = %{@valid_proof | expires_at: @now - 1}
      assert {:error, :expired} = Zksar.verify(proof, now: @now)
    end

    test "proof with empty signature returns :malformed" do
      proof = %{@valid_proof | signature: ""}
      assert {:error, :malformed} = Zksar.verify(proof, now: @now)
    end

    test "proof with empty subject returns :malformed" do
      proof = %{@valid_proof | subject: ""}
      assert {:error, :malformed} = Zksar.verify(proof, now: @now)
    end

    test "batch with mix of valid and invalid proofs returns both lists" do
      valid = @valid_proof
      expired = %{@valid_proof | expires_at: @now - 1}
      malformed = %{@valid_proof | subject: ""}
      unknown = %{@valid_proof | type_code: 0xFF}

      {verified, errors} =
        Zksar.verify_batch([valid, expired, malformed, unknown],
          now: @now,
          verify_signature: false
        )

      assert length(verified) == 1
      assert hd(verified).type == :compliance
      assert length(errors) == 3

      error_reasons = Enum.map(errors, fn {_proof, reason} -> reason end)
      assert :expired in error_reasons
      assert :malformed in error_reasons
      assert :unknown_type in error_reasons
    end

    test "proof with unknown type_code 0xFF returns :unknown_type" do
      proof = %{@valid_proof | type_code: 0xFF}
      assert {:error, :unknown_type} = Zksar.verify(proof, now: @now)
    end
  end

  describe "proof_types/0" do
    test "returns all six types" do
      types = Zksar.proof_types()
      assert length(types) == 6
      assert :compliance in types
      assert :non_membership in types
    end
  end
end
