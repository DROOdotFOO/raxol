defmodule Raxol.Payments.MandateTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Mandate

  # Anvil/foundry default account #0 -- known private key for deterministic tests.
  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @test_address "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

  defmodule TestWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_MANDATE_TEST_KEY"
  end

  setup do
    System.put_env("RAXOL_MANDATE_TEST_KEY", @test_privkey)
    :ok
  end

  defp valid_attrs(overrides \\ %{}) do
    %{
      human_wallet: @test_address,
      agent_wallet: "0x" <> String.duplicate("aa", 20),
      scopes: ["quote", "execute"],
      max_amount_usd: 1000,
      max_calls: 50,
      expires_at: System.system_time(:second) + 3600
    }
    |> Map.merge(overrides)
  end

  describe "build/1" do
    test "builds a valid Mandate" do
      assert {:ok, m} = Mandate.build(valid_attrs())
      assert m.human_wallet == String.downcase(@test_address)
      assert m.scopes == ["quote", "execute"]
      assert m.signature == nil
      assert m.envelope_hash == nil
      assert is_binary(m.nonce)
      assert String.starts_with?(m.nonce, "0x")
      assert byte_size(m.nonce) == 66
    end

    test "generates a random nonce when omitted" do
      {:ok, m1} = Mandate.build(valid_attrs())
      {:ok, m2} = Mandate.build(valid_attrs())
      assert m1.nonce != m2.nonce
    end

    test "rejects missing required fields" do
      assert {:error, {:missing_field, :human_wallet}} =
               Mandate.build(Map.delete(valid_attrs(), :human_wallet))

      assert {:error, {:missing_field, :agent_wallet}} =
               Mandate.build(Map.delete(valid_attrs(), :agent_wallet))

      assert {:error, {:missing_field, :scopes}} =
               Mandate.build(Map.delete(valid_attrs(), :scopes))

      assert {:error, {:missing_field, :max_amount_usd}} =
               Mandate.build(Map.delete(valid_attrs(), :max_amount_usd))
    end

    test "rejects invalid addresses" do
      assert {:error, {:invalid_address, :human_wallet}} =
               Mandate.build(%{valid_attrs() | human_wallet: "not-an-address"})

      assert {:error, {:invalid_address, :agent_wallet}} =
               Mandate.build(%{valid_attrs() | agent_wallet: "0x1234"})
    end

    test "rejects empty scope list" do
      assert {:error, {:invalid_scopes, :empty}} =
               Mandate.build(%{valid_attrs() | scopes: []})
    end

    test "rejects unknown scopes" do
      assert {:error, {:invalid_scopes, :unknown_scope}} =
               Mandate.build(%{valid_attrs() | scopes: ["quote", "bogus"]})
    end

    test "rejects duplicate scopes" do
      assert {:error, {:invalid_scopes, :duplicate}} =
               Mandate.build(%{valid_attrs() | scopes: ["quote", "quote"]})
    end

    test "rejects max_calls < 1" do
      assert {:error, {:invalid_integer, :max_calls}} =
               Mandate.build(%{valid_attrs() | max_calls: 0})

      assert {:error, {:invalid_integer, :max_calls}} =
               Mandate.build(%{valid_attrs() | max_calls: -1})
    end

    test "accepts max_amount_usd == 0 (disables cap)" do
      assert {:ok, _} = Mandate.build(%{valid_attrs() | max_amount_usd: 0})
    end

    test "rejects malformed nonce" do
      assert {:error, {:invalid_nonce, :shape}} =
               Mandate.build(Map.put(valid_attrs(), :nonce, "0xshort"))

      assert {:error, {:invalid_nonce, :shape}} =
               Mandate.build(Map.put(valid_attrs(), :nonce, "abc"))
    end
  end

  describe "digest/1" do
    test "matches pinned vector for deterministic input" do
      # Cross-implementation vector. The 0x9eb5... digest below was
      # verified against viem's `hashTypedData` using the canonical
      # Xochi schema at `xochi/packages/shared/src/eip712.ts:182-263`
      # -- both implementations produced the same 32-byte digest.
      # Any change to this expected value indicates an interop break.
      {:ok, m} =
        Mandate.build(%{
          human_wallet: "0x1111111111111111111111111111111111111111",
          agent_wallet: "0x2222222222222222222222222222222222222222",
          scopes: ["quote", "execute"],
          max_amount_usd: 100_000,
          max_calls: 100,
          expires_at: 2_000_000_000,
          nonce: "0x" <> String.duplicate("ab", 32)
        })

      assert {:ok, digest} = Mandate.digest(m)

      assert "0x" <> Base.encode16(digest, case: :lower) ==
               "0x9eb56d1c8a6cf591d6a768aa01cd03b3b6df60ed86e377386e54e6287a4c610b"
    end

    test "is deterministic for the same input" do
      {:ok, m} = Mandate.build(Map.put(valid_attrs(), :nonce, "0x" <> String.duplicate("11", 32)))
      assert {:ok, d1} = Mandate.digest(m)
      assert {:ok, d2} = Mandate.digest(m)
      assert d1 == d2
    end

    test "changes when any field changes" do
      {:ok, m1} =
        Mandate.build(Map.put(valid_attrs(), :nonce, "0x" <> String.duplicate("11", 32)))

      {:ok, d1} = Mandate.digest(m1)

      {:ok, m2} =
        Mandate.build(Map.put(valid_attrs(), :nonce, "0x" <> String.duplicate("22", 32)))

      {:ok, d2} = Mandate.digest(m2)

      assert d1 != d2
    end
  end

  describe "sign/2 and verify/1" do
    test "round-trips: sign then verify" do
      {:ok, m} = Mandate.build(valid_attrs())
      assert {:ok, signed} = Mandate.sign(m, TestWallet)
      assert is_binary(signed.signature)
      assert String.starts_with?(signed.signature, "0x")
      assert byte_size(signed.signature) == 132
      assert is_binary(signed.envelope_hash)
      assert byte_size(signed.envelope_hash) == 32
      assert Mandate.verify(signed) == :ok
    end

    test "tampered field fails verification" do
      {:ok, m} = Mandate.build(valid_attrs())
      {:ok, signed} = Mandate.sign(m, TestWallet)

      tampered = %{signed | max_amount_usd: signed.max_amount_usd + 1}
      assert {:error, :unauthorized_signer} = Mandate.verify(tampered)
    end

    test "tampered signature fails verification" do
      {:ok, m} = Mandate.build(valid_attrs())
      {:ok, signed} = Mandate.sign(m, TestWallet)

      "0x" <> sig_hex = signed.signature
      # Flip a few bits in the r component.
      {byte1, rest} = String.split_at(sig_hex, 1)
      flipped = if(byte1 == "0", do: "1", else: "0") <> rest
      tampered = %{signed | signature: "0x" <> flipped}

      assert {:error, :unauthorized_signer} = Mandate.verify(tampered)
    end

    test "unsigned mandate fails verification" do
      {:ok, m} = Mandate.build(valid_attrs())
      assert {:error, :unsigned} = Mandate.verify(m)
    end
  end

  describe "to_envelope/1 and from_envelope/1" do
    test "round-trips a signed mandate" do
      {:ok, m} = Mandate.build(valid_attrs())
      {:ok, signed} = Mandate.sign(m, TestWallet)
      {:ok, envelope} = Mandate.to_envelope(signed)

      assert is_binary(envelope)
      refute String.contains?(envelope, "=")
      refute String.contains?(envelope, "+")
      refute String.contains?(envelope, "/")

      {:ok, decoded} = Mandate.from_envelope(envelope)
      assert decoded.human_wallet == signed.human_wallet
      assert decoded.agent_wallet == signed.agent_wallet
      assert decoded.scopes == signed.scopes
      assert decoded.max_amount_usd == signed.max_amount_usd
      assert decoded.max_calls == signed.max_calls
      assert decoded.expires_at == signed.expires_at
      assert decoded.nonce == signed.nonce
      assert decoded.signature == signed.signature
      assert decoded.envelope_hash == signed.envelope_hash
      assert Mandate.verify(decoded) == :ok
    end

    test "rejects unsigned mandate" do
      {:ok, m} = Mandate.build(valid_attrs())
      assert {:error, :unsigned} = Mandate.to_envelope(m)
    end

    test "rejects malformed base64url" do
      assert {:error, :invalid_base64url} = Mandate.from_envelope("not!base64url!")
    end

    test "rejects valid base64 but malformed envelope" do
      bad = Base.url_encode64(~s({"wrong": "shape"}), padding: false)
      assert {:error, :missing_envelope_fields} = Mandate.from_envelope(bad)
    end
  end

  describe "expired?/2" do
    test "returns true after expires_at" do
      {:ok, m} = Mandate.build(valid_attrs(%{expires_at: 1000}))
      assert Mandate.expired?(m, 1001) == true
      assert Mandate.expired?(m, 1000) == true
      assert Mandate.expired?(m, 999) == false
    end

    test "uses system time when now omitted" do
      {:ok, m} = Mandate.build(valid_attrs(%{expires_at: 1}))
      assert Mandate.expired?(m) == true
    end
  end

  describe "covers_scope?/2" do
    test "matches declared scopes" do
      {:ok, m} = Mandate.build(valid_attrs(%{scopes: ["quote", "execute"]}))
      assert Mandate.covers_scope?(m, "quote")
      assert Mandate.covers_scope?(m, "execute")
      refute Mandate.covers_scope?(m, "stealth_claim")
    end
  end

  describe "compute_envelope_hash/1" do
    test "stable across re-signing the same content" do
      {:ok, m} = Mandate.build(Map.put(valid_attrs(), :nonce, "0x" <> String.duplicate("33", 32)))
      {:ok, signed_a} = Mandate.sign(m, TestWallet)
      {:ok, signed_b} = Mandate.sign(m, TestWallet)
      # Same content, same signature (signing is deterministic for the same key+digest)
      # and therefore same envelope_hash.
      assert signed_a.envelope_hash == signed_b.envelope_hash
    end

    test "matches between sign and from_envelope" do
      {:ok, m} = Mandate.build(valid_attrs())
      {:ok, signed} = Mandate.sign(m, TestWallet)
      {:ok, envelope} = Mandate.to_envelope(signed)
      {:ok, decoded} = Mandate.from_envelope(envelope)
      assert signed.envelope_hash == decoded.envelope_hash
    end
  end
end
