defmodule Raxol.Payments.Xochi.StealthE2ETest do
  @moduledoc """
  End-to-end tests for the stealth address payment lifecycle.

  Verifies cryptographic correctness across the full flow:
  key derivation -> address generation -> announcement -> scanning -> claim.
  """
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Stealth
  alias Raxol.Payments.{PrivacyTier, Router, Secret}

  defp generate_keypair do
    priv = :crypto.strong_rand_bytes(32)
    {:ok, pub} = ExSecp256k1.create_public_key(priv)
    {:ok, compressed} = ExSecp256k1.public_key_compress(pub)
    {priv, compressed}
  end

  defp make_announcement(settlement, extra_metadata \\ <<>>) do
    %{
      scheme_id: 1,
      stealth_address: settlement.stealth_address,
      caller: "0x" <> String.duplicate("cc", 20),
      ephemeral_pub_key: settlement.ephemeral_pub_key,
      metadata: Stealth.create_metadata(settlement.view_tag, extra_metadata),
      block_number: :rand.uniform(1_000_000),
      tx_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      log_index: 0
    }
  end

  describe "full payment lifecycle" do
    test "recipient discovers payment and derives controlling private key" do
      # 1. Recipient sets up stealth keys
      {spending_priv, spending_pub} = generate_keypair()
      {viewing_priv, viewing_pub} = generate_keypair()
      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      # 2. Sender generates stealth address
      {:ok, settlement} = Stealth.generate(meta)

      # 3. On-chain announcement published
      announcement = make_announcement(settlement)

      # 4. Recipient scans and discovers payment
      {:ok, [payment]} = Stealth.scan(spending_priv, viewing_priv, [announcement])

      # 5. Verify stealth private key controls the stealth address
      {:ok, derived_pub} = ExSecp256k1.create_public_key(Secret.reveal(payment.stealth_priv_key))
      {:ok, compressed_pub} = ExSecp256k1.public_key_compress(derived_pub)
      # Drop 0x04 prefix from uncompressed, keccak256, take last 20 bytes
      <<_prefix::8, xy::binary>> = derived_pub
      address_bytes = ExKeccak.hash_256(xy)
      <<_first_12::binary-size(12), addr_bytes::binary-size(20)>> = address_bytes
      derived_address = "0x" <> Base.encode16(addr_bytes, case: :lower)

      assert derived_address == settlement.stealth_address
      assert byte_size(compressed_pub) == 33
    end

    test "stealth key can sign a message (simulates claim)" do
      {spending_priv, spending_pub} = generate_keypair()
      {viewing_priv, viewing_pub} = generate_keypair()
      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      {:ok, settlement} = Stealth.generate(meta)
      announcement = make_announcement(settlement)
      {:ok, [payment]} = Stealth.scan(spending_priv, viewing_priv, [announcement])

      # Sign a message with the stealth private key
      message = ExKeccak.hash_256("claim:#{settlement.stealth_address}")

      {:ok, {r, s, _recovery_id}} =
        ExSecp256k1.sign(message, Secret.reveal(payment.stealth_priv_key))

      signature = r <> s
      assert byte_size(signature) == 64

      # Verify signature
      {:ok, pub} = ExSecp256k1.create_public_key(Secret.reveal(payment.stealth_priv_key))
      assert :ok = ExSecp256k1.verify(message, signature, pub)
    end
  end

  describe "multiple payments to same recipient" do
    test "each payment gets a unique stealth address" do
      {_sp, spending_pub} = generate_keypair()
      {_vp, viewing_pub} = generate_keypair()
      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      settlements =
        for _ <- 1..10 do
          {:ok, s} = Stealth.generate(meta)
          s
        end

      addresses = Enum.map(settlements, & &1.stealth_address)
      ephemeral_keys = Enum.map(settlements, & &1.ephemeral_pub_key)

      # All addresses must be unique
      assert length(Enum.uniq(addresses)) == 10
      # All ephemeral keys must be unique
      assert length(Enum.uniq(ephemeral_keys)) == 10
    end

    test "recipient discovers all payments in batch scan" do
      {spending_priv, spending_pub} = generate_keypair()
      {viewing_priv, viewing_pub} = generate_keypair()
      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      announcements =
        for i <- 1..5 do
          {:ok, settlement} = Stealth.generate(meta)
          make_announcement(settlement, <<i::8>>)
        end

      {:ok, payments} = Stealth.scan(spending_priv, viewing_priv, announcements)
      assert length(payments) == 5

      # Each payment has a distinct stealth private key
      priv_keys = Enum.map(payments, &Secret.reveal(&1.stealth_priv_key))
      assert length(Enum.uniq(priv_keys)) == 5
    end
  end

  describe "mixed announcement scanning" do
    test "distinguishes own payments from others in a batch" do
      # Our keys
      {our_sp, our_spending_pub} = generate_keypair()
      {our_vp, our_viewing_pub} = generate_keypair()

      our_meta = %{
        spending_pub_key: our_spending_pub,
        viewing_pub_key: our_viewing_pub,
        chain_id: 1
      }

      # Other recipient's keys
      {_, other_spending_pub} = generate_keypair()
      {_, other_viewing_pub} = generate_keypair()

      other_meta = %{
        spending_pub_key: other_spending_pub,
        viewing_pub_key: other_viewing_pub,
        chain_id: 1
      }

      # Generate 3 payments to us, 7 to others
      our_announcements =
        for _ <- 1..3 do
          {:ok, s} = Stealth.generate(our_meta)
          make_announcement(s)
        end

      other_announcements =
        for _ <- 1..7 do
          {:ok, s} = Stealth.generate(other_meta)
          make_announcement(s)
        end

      all = Enum.shuffle(our_announcements ++ other_announcements)

      {:ok, payments} = Stealth.scan(our_sp, our_vp, all)

      # Should find exactly our 3
      assert length(payments) == 3

      our_addresses = Enum.map(our_announcements, & &1.stealth_address) |> MapSet.new()
      found_addresses = Enum.map(payments, & &1.announcement.stealth_address) |> MapSet.new()
      assert MapSet.equal?(our_addresses, found_addresses)
    end
  end

  describe "view tag filtering" do
    test "view tag mismatch skips full ECDH derivation" do
      {spending_priv, spending_pub} = generate_keypair()
      {viewing_priv, viewing_pub} = generate_keypair()
      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      {:ok, settlement} = Stealth.generate(meta)

      # Corrupt the view tag in the announcement metadata
      wrong_tag = rem(settlement.view_tag + 1, 256)

      announcement = %{
        scheme_id: 1,
        stealth_address: settlement.stealth_address,
        caller: "0x" <> String.duplicate("aa", 20),
        ephemeral_pub_key: settlement.ephemeral_pub_key,
        metadata: Stealth.create_metadata(wrong_tag),
        block_number: 1,
        tx_hash: "0x" <> String.duplicate("bb", 32),
        log_index: 0
      }

      # Should not find the payment (view tag mismatch)
      {:ok, payments} = Stealth.scan(spending_priv, viewing_priv, [announcement])
      assert payments == []
    end
  end

  describe "meta-address registry flow" do
    test "encode -> publish -> decode -> generate -> scan round-trip" do
      # 1. Recipient derives keys from signature
      sig = "0x" <> Base.encode16(:crypto.strong_rand_bytes(65), case: :lower)
      {:ok, keys} = Stealth.derive_keys(sig)
      {spending_priv, spending_pub} = keys.spending
      {viewing_priv, viewing_pub} = keys.viewing

      # 2. Encode meta-address for ERC-6538 registry
      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}
      encoded = Stealth.encode_meta_address(meta)

      # 3. Sender decodes meta-address from registry
      {:ok, decoded} = Stealth.decode_meta_address(encoded, 1)

      # 4. Sender generates stealth address
      {:ok, settlement} = Stealth.generate(decoded)

      # 5. Announcement on-chain
      announcement = make_announcement(settlement)

      # 6. Recipient scans
      {:ok, [payment]} = Stealth.scan(spending_priv, viewing_priv, [announcement])
      assert payment.announcement.stealth_address == settlement.stealth_address
    end
  end

  describe "integration with privacy tier routing" do
    test "trust score 25+ routes to stealth settlement" do
      tier = PrivacyTier.from_trust_score(30)
      assert tier.tier == :stealth
      assert tier.settlement == :stealth

      # Router picks xochi for stealth
      assert Router.select(trust_score: 30) == :xochi
      assert Router.settlement_for(trust_score: 30) == :stealth
    end

    test "trust score 50+ routes to shielded (PXE), not stealth" do
      tier = PrivacyTier.from_trust_score(55)
      assert tier.tier == :private
      assert tier.settlement == :shielded

      assert Router.settlement_for(trust_score: 55) == :shielded
    end

    test "a privacy tier prices nothing" do
      # It carried a fee_bps that no solver charged. Fees are a function of
      # trust tier and asset class -- `Raxol.Payments.FeeSchedule`, pinned to
      # the solver's published schedule -- and a score of 30 buys the
      # `:trusted` fee tier while buying `:stealth` settlement. Two axes.
      tier = PrivacyTier.from_trust_score(30)

      refute Map.has_key?(tier, :fee_bps)
      assert tier.settlement == :stealth
      assert Raxol.Payments.FeeSchedule.tier_for_score(30) == :trusted
      assert Raxol.Payments.FeeSchedule.headline_bps(:trusted, :stable) == 19
    end

    test "stealth tier retains wallet + amount ranges only" do
      tier = PrivacyTier.from_trust_score(30)
      assert tier.data_retention == :ranges
    end
  end

  describe "metadata with extra data (token, amount, factory, salt)" do
    test "view tag survives metadata with appended settlement data" do
      {spending_priv, spending_pub} = generate_keypair()
      {viewing_priv, viewing_pub} = generate_keypair()
      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      {:ok, settlement} = Stealth.generate(meta)

      # Simulate Xochi metadata: view_tag || token(20) || selector(4) || amount(32) || factory(20) || salt(32)
      token = :crypto.strong_rand_bytes(20)
      selector = <<0xA9, 0x05, 0x9C, 0xBB>>
      amount = <<1_000_000::unsigned-big-integer-size(256)>>
      factory = :crypto.strong_rand_bytes(20)
      salt = :crypto.strong_rand_bytes(32)

      extra = token <> selector <> amount <> factory <> salt
      announcement = make_announcement(settlement, extra)

      {:ok, [payment]} = Stealth.scan(spending_priv, viewing_priv, [announcement])
      assert payment.announcement.stealth_address == settlement.stealth_address

      # Verify we can extract the view tag from the rich metadata
      {:ok, tag} = Stealth.extract_view_tag(announcement.metadata)
      assert tag == settlement.view_tag
    end
  end
end
