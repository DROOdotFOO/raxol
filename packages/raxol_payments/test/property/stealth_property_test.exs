defmodule Raxol.Payments.StealthPropertyTest do
  @moduledoc """
  Properties for the ERC-5564/6538 stealth scheme in `Raxol.Payments.Xochi.Stealth`.

  The money-moving invariant is that a stealth address a sender generates from a
  recipient's meta-address is discoverable by that recipient (and only that
  recipient), with the recovered key controlling the address. These properties
  exercise that across generated key material rather than fixed examples.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Xochi.Stealth

  # Any byte string seeds a recipient key pair via the domain-separated
  # signature derivation; this stands in for an EVM signature.
  defp signature do
    gen all(bytes <- binary(min_length: 8, max_length: 96)) do
      "0x" <> Base.encode16(bytes, case: :lower)
    end
  end

  defp keys(sig) do
    {:ok, k} = Stealth.derive_keys(sig)
    k
  end

  defp meta_address(%{spending: {_, sp}, viewing: {_, vp}}) do
    %{spending_pub_key: sp, viewing_pub_key: vp, chain_id: 1}
  end

  defp announcement(settlement) do
    %{
      scheme_id: Stealth.scheme_id(),
      stealth_address: settlement.stealth_address,
      caller: "0x0000000000000000000000000000000000000000",
      ephemeral_pub_key: settlement.ephemeral_pub_key,
      metadata: <<settlement.view_tag::8>>,
      block_number: 0,
      tx_hash: "0x0",
      log_index: 0
    }
  end

  property "generate then scan: the recipient discovers their own payment" do
    check all(sig <- signature(), max_runs: 50) do
      k = keys(sig)
      {:ok, settlement} = Stealth.generate(meta_address(k))

      {spending_priv, _} = k.spending
      {viewing_priv, _} = k.viewing

      {:ok, [payment]} = Stealth.scan(spending_priv, viewing_priv, [announcement(settlement)])

      assert payment.announcement.stealth_address == settlement.stealth_address
      assert byte_size(payment.stealth_priv_key) == 32
    end
  end

  property "a different recipient never discovers the payment" do
    check all(sig_a <- signature(), sig_b <- signature(), sig_a != sig_b, max_runs: 50) do
      recipient = keys(sig_a)
      stranger = keys(sig_b)

      {:ok, settlement} = Stealth.generate(meta_address(recipient))

      {spending_priv, _} = stranger.spending
      {viewing_priv, _} = stranger.viewing

      assert {:ok, []} =
               Stealth.scan(spending_priv, viewing_priv, [announcement(settlement)])
    end
  end

  property "derive_keys is deterministic for a given signature" do
    check all(sig <- signature()) do
      assert Stealth.derive_keys(sig) == Stealth.derive_keys(sig)
    end
  end

  property "spending and viewing keys are domain-separated (distinct)" do
    check all(sig <- signature()) do
      %{spending: {sp_priv, _}, viewing: {vp_priv, _}} = keys(sig)
      assert sp_priv != vp_priv
    end
  end

  property "each generate call uses a fresh ephemeral key" do
    check all(sig <- signature(), max_runs: 40) do
      meta = meta_address(keys(sig))
      {:ok, a} = Stealth.generate(meta)
      {:ok, b} = Stealth.generate(meta)
      assert a.ephemeral_pub_key != b.ephemeral_pub_key
    end
  end

  property "generate/2 is deterministic for a fixed ephemeral key" do
    check all(sig <- signature(), eph <- binary(length: 32), max_runs: 40) do
      meta = meta_address(keys(sig))
      assert Stealth.generate(meta, eph) == Stealth.generate(meta, eph)
    end
  end

  property "meta-address encode/decode round-trips" do
    check all(sig <- signature()) do
      meta = meta_address(keys(sig))

      assert {:ok, decoded} =
               meta |> Stealth.encode_meta_address() |> Stealth.decode_meta_address(1)

      assert decoded.spending_pub_key == meta.spending_pub_key
      assert decoded.viewing_pub_key == meta.viewing_pub_key
    end
  end
end
