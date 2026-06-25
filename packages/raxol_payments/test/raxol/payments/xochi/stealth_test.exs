defmodule Raxol.Payments.Xochi.StealthTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Secret
  alias Raxol.Payments.Xochi.Stealth

  # Generate a real keypair for testing
  defp generate_keypair do
    priv = :crypto.strong_rand_bytes(32)
    {:ok, pub} = ExSecp256k1.create_public_key(priv)
    {:ok, compressed} = ExSecp256k1.public_key_compress(pub)
    {priv, compressed}
  end

  defp make_meta_address do
    {_spending_priv, spending_pub} = generate_keypair()
    {_viewing_priv, viewing_pub} = generate_keypair()

    %{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub,
      chain_id: 1
    }
  end

  describe "contract constants" do
    test "ERC-5564 Announcer address" do
      assert Stealth.announcer_address() == "0x55649E01B5Df198D18D95b5cc5051630cfD45564"
    end

    test "ERC-6538 Registry address" do
      assert Stealth.registry_address() == "0x6538E6bf4B0eBd30A8Ea093027Ac2422ce5d6538"
    end

    test "scheme ID is 1" do
      assert Stealth.scheme_id() == 1
    end
  end

  describe "generate/1" do
    test "produces a valid stealth address from meta-address" do
      meta = make_meta_address()
      assert {:ok, settlement} = Stealth.generate(meta)

      assert String.starts_with?(settlement.stealth_address, "0x")
      assert byte_size(settlement.stealth_address) == 42
      assert is_binary(settlement.ephemeral_pub_key)
      assert byte_size(settlement.ephemeral_pub_key) == 33
      assert settlement.view_tag >= 0 and settlement.view_tag <= 255
    end

    test "produces different addresses for different calls" do
      meta = make_meta_address()
      {:ok, a} = Stealth.generate(meta)
      {:ok, b} = Stealth.generate(meta)

      refute a.stealth_address == b.stealth_address
      refute a.ephemeral_pub_key == b.ephemeral_pub_key
    end

    test "rejects invalid meta-address" do
      assert {:error, _} =
               Stealth.generate(%{spending_pub_key: <<1, 2, 3>>, viewing_pub_key: <<4, 5, 6>>})
    end

    test "rejects non-map input" do
      assert {:error, :invalid_meta_address} = Stealth.generate("not a meta address")
    end
  end

  describe "scan/3 round-trip" do
    test "sender generates, recipient discovers" do
      {spending_priv, spending_pub} = generate_keypair()
      {viewing_priv, viewing_pub} = generate_keypair()

      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      {:ok, settlement} = Stealth.generate(meta)

      announcement = %{
        scheme_id: 1,
        stealth_address: settlement.stealth_address,
        caller: "0x" <> String.duplicate("a", 40),
        ephemeral_pub_key: settlement.ephemeral_pub_key,
        metadata: Stealth.create_metadata(settlement.view_tag),
        block_number: 12345,
        tx_hash: "0x" <> String.duplicate("d", 64),
        log_index: 0
      }

      {:ok, payments} = Stealth.scan(spending_priv, viewing_priv, [announcement])

      assert length(payments) == 1
      payment = hd(payments)
      assert payment.announcement.stealth_address == settlement.stealth_address
      assert byte_size(Secret.reveal(payment.stealth_priv_key)) == 32

      # the spend key is wrapped so it can't leak via inspect/logs
      assert match?(%Secret{}, payment.stealth_priv_key)
      key_hex = Base.encode16(Secret.reveal(payment.stealth_priv_key), case: :lower)
      refute inspect(payment) =~ key_hex
    end

    test "does not match announcements for other recipients" do
      {spending_priv, _spending_pub} = generate_keypair()
      {viewing_priv, _viewing_pub} = generate_keypair()

      # Generate for a DIFFERENT recipient
      other_meta = make_meta_address()
      {:ok, settlement} = Stealth.generate(other_meta)

      announcement = %{
        scheme_id: 1,
        stealth_address: settlement.stealth_address,
        caller: "0x" <> String.duplicate("a", 40),
        ephemeral_pub_key: settlement.ephemeral_pub_key,
        metadata: Stealth.create_metadata(settlement.view_tag),
        block_number: 100,
        tx_hash: "0x" <> String.duplicate("b", 64),
        log_index: 0
      }

      {:ok, payments} = Stealth.scan(spending_priv, viewing_priv, [announcement])
      assert payments == []
    end

    test "filters out non-secp256k1 scheme IDs" do
      {spending_priv, _} = generate_keypair()
      {viewing_priv, _} = generate_keypair()

      announcement = %{
        scheme_id: 99,
        stealth_address: "0x" <> String.duplicate("a", 40),
        caller: "0x" <> String.duplicate("b", 40),
        ephemeral_pub_key: <<>>,
        metadata: <<0>>,
        block_number: 1,
        tx_hash: "0x" <> String.duplicate("c", 64),
        log_index: 0
      }

      {:ok, payments} = Stealth.scan(spending_priv, viewing_priv, [announcement])
      assert payments == []
    end
  end

  describe "extract_view_tag/1" do
    test "extracts first byte from binary" do
      assert {:ok, 255} = Stealth.extract_view_tag(<<255, 1, 2>>)
      assert {:ok, 0} = Stealth.extract_view_tag(<<0, 1>>)
      assert {:ok, 128} = Stealth.extract_view_tag(<<128>>)
    end

    test "returns 0 for empty binary" do
      assert {:ok, 0} = Stealth.extract_view_tag(<<>>)
    end

    test "extracts from hex string with 0x prefix" do
      assert {:ok, 255} = Stealth.extract_view_tag("0xff1234")
      assert {:ok, 0} = Stealth.extract_view_tag("0x00abcd")
      assert {:ok, 128} = Stealth.extract_view_tag("0x80")
    end

    test "extracts from hex string without 0x prefix" do
      assert {:ok, 255} = Stealth.extract_view_tag("ff1234")
      assert {:ok, 0} = Stealth.extract_view_tag("00abcd")
    end

    test "returns 0 for empty hex" do
      assert {:ok, 0} = Stealth.extract_view_tag("0x")
    end

    test "returns error for invalid hex" do
      assert {:error, :invalid_view_tag_hex} = Stealth.extract_view_tag("0xGG")
      assert {:error, :invalid_view_tag_hex} = Stealth.extract_view_tag("0xZZ1234")
    end
  end

  describe "create_metadata/2" do
    test "creates metadata with view tag as first byte" do
      assert <<255>> = Stealth.create_metadata(255)
      assert <<0>> = Stealth.create_metadata(0)
      assert <<128>> = Stealth.create_metadata(128)
    end

    test "appends extra data" do
      assert <<255, 1, 2>> = Stealth.create_metadata(255, <<1, 2>>)
      assert <<0, 0xAB, 0xCD>> = Stealth.create_metadata(0, <<0xAB, 0xCD>>)
    end
  end

  describe "encode_meta_address/1" do
    test "encodes in st:eth:0x format" do
      {_, spending_pub} = generate_keypair()
      {_, viewing_pub} = generate_keypair()

      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}
      encoded = Stealth.encode_meta_address(meta)

      assert String.starts_with?(encoded, "st:eth:0x")
      # 9 prefix + 66 spending + 66 viewing = 141
      assert byte_size(encoded) == 141
    end
  end

  describe "decode_meta_address/2" do
    test "round-trips with encode" do
      {_, spending_pub} = generate_keypair()
      {_, viewing_pub} = generate_keypair()

      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}
      encoded = Stealth.encode_meta_address(meta)

      assert {:ok, decoded} = Stealth.decode_meta_address(encoded, 1)
      assert decoded.spending_pub_key == spending_pub
      assert decoded.viewing_pub_key == viewing_pub
      assert decoded.chain_id == 1
    end

    test "rejects invalid format" do
      assert {:error, :invalid_format} = Stealth.decode_meta_address("invalid", 1)

      assert {:error, :invalid_format} =
               Stealth.decode_meta_address("st:btc:0x" <> String.duplicate("a", 132), 1)
    end

    test "rejects wrong length" do
      assert {:error, :invalid_format} =
               Stealth.decode_meta_address("st:eth:0x" <> String.duplicate("a", 130), 1)
    end

    test "rejects invalid pubkey prefix" do
      # 01 prefix is invalid for compressed secp256k1
      bad = "st:eth:0x01" <> String.duplicate("a", 64) <> "03" <> String.duplicate("b", 64)
      assert {:error, :invalid_meta_address} = Stealth.decode_meta_address(bad, 1)
    end
  end

  describe "valid_compressed_pubkey?/1" do
    test "accepts 02-prefix 33-byte key" do
      {_, pub} = generate_keypair()
      assert Stealth.valid_compressed_pubkey?(pub)
    end

    test "rejects wrong prefix" do
      refute Stealth.valid_compressed_pubkey?(<<0x01>> <> :crypto.strong_rand_bytes(32))
      refute Stealth.valid_compressed_pubkey?(<<0x04>> <> :crypto.strong_rand_bytes(32))
    end

    test "rejects wrong length" do
      refute Stealth.valid_compressed_pubkey?(<<0x02>> <> :crypto.strong_rand_bytes(31))
      refute Stealth.valid_compressed_pubkey?(<<0x02>> <> :crypto.strong_rand_bytes(33))
    end
  end

  describe "valid_view_tag?/1" do
    test "accepts 0-255" do
      assert Stealth.valid_view_tag?(0)
      assert Stealth.valid_view_tag?(128)
      assert Stealth.valid_view_tag?(255)
    end

    test "rejects out of range" do
      refute Stealth.valid_view_tag?(-1)
      refute Stealth.valid_view_tag?(256)
      refute Stealth.valid_view_tag?(1.5)
    end
  end

  describe "derive_keys/1" do
    test "derives deterministic spending and viewing keypairs from signature" do
      sig = "0x" <> Base.encode16(:crypto.strong_rand_bytes(65), case: :lower)

      {:ok, keys} = Stealth.derive_keys(sig)

      {spending_priv, spending_pub} = keys.spending
      {viewing_priv, viewing_pub} = keys.viewing

      assert byte_size(spending_priv) == 32
      assert byte_size(spending_pub) == 33
      assert byte_size(viewing_priv) == 32
      assert byte_size(viewing_pub) == 33

      # Deterministic: same sig produces same keys
      {:ok, keys2} = Stealth.derive_keys(sig)
      assert keys2.spending == keys.spending
      assert keys2.viewing == keys.viewing
    end

    test "different signatures produce different keys" do
      sig1 = "0x" <> Base.encode16(:crypto.strong_rand_bytes(65), case: :lower)
      sig2 = "0x" <> Base.encode16(:crypto.strong_rand_bytes(65), case: :lower)

      {:ok, keys1} = Stealth.derive_keys(sig1)
      {:ok, keys2} = Stealth.derive_keys(sig2)

      refute keys1.spending == keys2.spending
      refute keys1.viewing == keys2.viewing
    end

    test "spending and viewing keys are domain-separated" do
      sig = "0xabcdef"
      {:ok, keys} = Stealth.derive_keys(sig)

      {spending_priv, _} = keys.spending
      {viewing_priv, _} = keys.viewing

      refute spending_priv == viewing_priv
    end
  end

  describe "full round-trip: derive_keys -> generate -> scan" do
    test "keys derived from signature can generate and scan" do
      sig = "0x" <> Base.encode16(:crypto.strong_rand_bytes(65), case: :lower)
      {:ok, keys} = Stealth.derive_keys(sig)

      {spending_priv, spending_pub} = keys.spending
      {viewing_priv, viewing_pub} = keys.viewing

      meta = %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub, chain_id: 1}

      {:ok, settlement} = Stealth.generate(meta)

      announcement = %{
        scheme_id: 1,
        stealth_address: settlement.stealth_address,
        caller: "0x" <> String.duplicate("a", 40),
        ephemeral_pub_key: settlement.ephemeral_pub_key,
        metadata: Stealth.create_metadata(settlement.view_tag),
        block_number: 1,
        tx_hash: "0x" <> String.duplicate("b", 64),
        log_index: 0
      }

      {:ok, [payment]} = Stealth.scan(spending_priv, viewing_priv, [announcement])
      assert payment.announcement.stealth_address == settlement.stealth_address
    end
  end
end
