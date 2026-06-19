defmodule Raxol.Payments.MandatePropertyTest do
  @moduledoc """
  Properties for the EIP-712 Xochi delegation `Raxol.Payments.Mandate`.

  Signing must round-trip through verification, any field mutation must break
  verification (tamper detection falls out of digest-based recovery), and the
  base64url envelope must preserve the signed mandate. These hold across
  generated mandate shapes, not just the pinned viem vector in `mandate_test`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Mandate

  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @test_address "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

  defmodule TestWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_MANDATE_PROP_KEY"
  end

  setup do
    System.put_env("RAXOL_MANDATE_PROP_KEY", @test_privkey)
    :ok
  end

  defp hex(n) do
    map(binary(length: n), &("0x" <> Base.encode16(&1, case: :lower)))
  end

  defp scopes do
    list_of(member_of(["quote", "execute", "stealth_claim"]),
      min_length: 1,
      max_length: 3
    )
    |> map(&Enum.uniq/1)
  end

  defp attrs do
    gen all(
          agent <- hex(20),
          scope_list <- scopes(),
          max_usd <- integer(0..1_000_000),
          max_calls <- integer(1..1000),
          ttl <- integer(60..1_000_000),
          nonce <- hex(32)
        ) do
      %{
        human_wallet: @test_address,
        agent_wallet: agent,
        scopes: scope_list,
        max_amount_usd: max_usd,
        max_calls: max_calls,
        expires_at: System.system_time(:second) + ttl,
        nonce: nonce
      }
    end
  end

  property "sign then verify round-trips" do
    check all(a <- attrs()) do
      {:ok, m} = Mandate.build(a)
      {:ok, signed} = Mandate.sign(m, TestWallet)
      assert :ok = Mandate.verify(signed)
    end
  end

  property "any field mutation breaks verification" do
    check all(a <- attrs()) do
      {:ok, m} = Mandate.build(a)
      {:ok, signed} = Mandate.sign(m, TestWallet)

      tampered = %{signed | max_amount_usd: signed.max_amount_usd + 1}
      assert {:error, :unauthorized_signer} = Mandate.verify(tampered)
    end
  end

  property "envelope encode/decode preserves the signed mandate" do
    check all(a <- attrs()) do
      {:ok, m} = Mandate.build(a)
      {:ok, signed} = Mandate.sign(m, TestWallet)
      {:ok, envelope} = Mandate.to_envelope(signed)
      {:ok, decoded} = Mandate.from_envelope(envelope)

      assert decoded.signature == signed.signature
      assert decoded.envelope_hash == signed.envelope_hash
      assert :ok = Mandate.verify(decoded)
    end
  end

  property "digest is deterministic for identical content" do
    check all(a <- attrs()) do
      {:ok, m1} = Mandate.build(a)
      {:ok, m2} = Mandate.build(a)
      assert Mandate.digest(m1) == Mandate.digest(m2)
    end
  end
end
