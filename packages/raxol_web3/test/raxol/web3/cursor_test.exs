defmodule Raxol.Web3.CursorTest do
  use ExUnit.Case, async: false

  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Tables

  # Measured on 2026-09-13 from `/api/v2/addresses/{hash}/transactions`.
  @upstream %{
    "block_number" => 25_574_152,
    "fee" => "3627591707061",
    "hash" => "0xb0df984dece80ac47653afa6edee80d67f31c87317cd1ea450fdcb1aedfbc051",
    "index" => 149,
    "inserted_at" => "2026-07-20T13:13:56.336860Z",
    "value" => "3333333333333",
    "items_count" => 50
  }

  @origin "a1b2c3d4e5f60708"

  describe "cursor key configuration" do
    test "a configured short or malformed key is rejected instead of randomized" do
      previous = Application.fetch_env(:raxol_web3, :cursor_key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:raxol_web3, :cursor_key, value)
          :error -> Application.delete_env(:raxol_web3, :cursor_key)
        end
      end)

      for invalid <- ["short", String.duplicate("x", 31), nil, 42] do
        Application.put_env(:raxol_web3, :cursor_key, invalid)

        assert_raise ArgumentError, ~r/must be a binary of at least 32 bytes/, fn ->
          Tables.init([])
        end
      end
    end
  end

  describe "round trip" do
    test "what the upstream sent comes back, minus the counter" do
      cursor = Cursor.encode(@upstream, @origin, :address_transactions)

      assert {:ok, params} = Cursor.decode(cursor, @origin, :address_transactions)
      assert params == Map.delete(@upstream, "items_count")
    end

    test "the last page has no cursor, so no caller has to branch on it" do
      assert Cursor.encode(nil, @origin, :address_transactions) == nil
    end

    test "items_count is absent from the encoded bytes, not merely from the decode" do
      # "Opaque" is not "encrypted": anyone holding the cursor can Base64-decode
      # it. Decision 8 says no offset-like field is exposed, so the field has to
      # be absent rather than hidden.
      cursor = Cursor.encode(@upstream, @origin, :address_transactions)

      refute cursor =~ "items_count"
      assert payload(cursor) =~ "block_number"
      refute payload(cursor) =~ "items_count"
    end
  end

  describe "the MAC" do
    test "a flipped byte in the payload is refused" do
      [version, payload, signature] =
        @upstream |> Cursor.encode(@origin, :address_transactions) |> String.split(".")

      tampered = Enum.join([version, flip(payload), signature], ".")

      assert {:error, :bad_signature} =
               Cursor.decode(tampered, @origin, :address_transactions)
    end

    test "a re-signed payload from another key is refused" do
      # The attack the MAC exists for: decode, add a parameter, re-encode. A
      # forger without this node's key cannot produce a signature that verifies.
      forged = sign(%{"o" => @origin, "e" => "address_transactions", "p" => %{}}, "not-our-key")

      assert {:error, :bad_signature} = Cursor.decode(forged, @origin, :address_transactions)
    end

    test "a cursor with no signature at all is refused as malformed" do
      for bad <- ["", "v1", "v1.payload", "garbage", "v0.a.b", nil, 42] do
        assert {:error, :malformed} = Cursor.decode(bad, @origin, :address_transactions)
      end
    end

    test "a signature of the wrong length is refused, not raised on" do
      # `:crypto.hash_equals/2` raises `badarg` when the two binaries differ
      # in size, and the second one here is whatever the caller's third
      # dot-segment Base64-decoded to. A model that truncated or padded a
      # cursor therefore got an exception out of `decode/3` rather than this
      # taxonomy, and `Raxol.MCP.Registry` rendered it as model-visible
      # exception text plus a breaker failure.
      [version, payload, _signature] =
        @upstream |> Cursor.encode(@origin, :address_transactions) |> String.split(".")

      for bytes <- [1, 16, 31, 33, 64] do
        signature = Base.url_encode64(:binary.copy(<<0>>, bytes), padding: false)
        cursor = Enum.join([version, payload, signature], ".")

        assert {:error, :bad_signature} =
                 Cursor.decode(cursor, @origin, :address_transactions),
               "a #{bytes}-byte signature was not refused"
      end
    end

    test "a signature that is not base64 is malformed rather than unsigned" do
      [version, payload, _signature] =
        @upstream |> Cursor.encode(@origin, :address_transactions) |> String.split(".")

      for garbage <- ["!!!!", "not base64 at all", "+/==", "é"] do
        cursor = Enum.join([version, payload, garbage], ".")

        assert {:error, :malformed} = Cursor.decode(cursor, @origin, :address_transactions),
               "#{inspect(garbage)} was not refused as malformed"
      end
    end
  end

  describe "scope binding" do
    test "a cursor from one endpoint is refused on another" do
      cursor = Cursor.encode(@upstream, @origin, :address_transactions)

      assert {:error, :wrong_scope} = Cursor.decode(cursor, @origin, :address_logs)
    end

    test "a cursor from one chain is refused on another" do
      # Two Blockscout instances share a page shape, so without this a cursor
      # minted on Ethereum would page Base without complaint and return the
      # wrong chain's transactions under the right chain's reference.
      cursor = Cursor.encode(@upstream, @origin, :address_transactions)

      assert {:error, :wrong_scope} =
               Cursor.decode(cursor, "ffffffffffffffff", :address_transactions)
    end
  end

  describe "the key allowlist" do
    test "an authentic cursor still cannot introduce a parameter" do
      # Signed with this node's key, so it verifies. Verification proves we
      # minted it; it does not prove the upstream should be handed an
      # `apikey` parameter, which is why the allowlist runs after the MAC.
      smuggled =
        sign(
          %{
            "o" => @origin,
            "e" => "address_transactions",
            "p" => %{"block_number" => 1, "apikey" => "stolen"}
          },
          Tables.cursor_key()
        )

      assert {:error, {:unexpected_key, "apikey"}} =
               Cursor.decode(smuggled, @origin, :address_transactions)
    end

    test "each endpoint accepts only the keys it was measured to page on" do
      # `token-transfers` pages on two keys. A cursor carrying `tokens`' `id`
      # would be an authentic cursor for the wrong query.
      smuggled =
        sign(
          %{"o" => @origin, "e" => "address_token_transfers", "p" => %{"id" => 1}},
          Tables.cursor_key()
        )

      assert {:error, {:unexpected_key, "id"}} =
               Cursor.decode(smuggled, @origin, :address_token_transfers)
    end

    test "minting drops a key the endpoint does not page on rather than failing" do
      # An upstream that adds a field to its own `next_page_params` must not
      # break paging, and a field we never send back cannot smuggle anything.
      cursor =
        Cursor.encode(
          Map.put(@upstream, "some_new_field", "whatever"),
          @origin,
          :address_transactions
        )

      assert {:ok, params} = Cursor.decode(cursor, @origin, :address_transactions)
      refute Map.has_key?(params, "some_new_field")
    end

    test "every endpoint in the table round-trips its own measured key set" do
      measured = %{
        address_tokens: %{"id" => 20_406_217_686, "value" => "8032", "fiat_value" => "5.06"},
        address_token_transfers: %{"index" => 386, "block_number" => 25_855_974},
        address_logs: %{"index" => 457, "block_number" => 25_971_497},
        address_nft: %{
          "token_type" => "ERC-721",
          "token_contract_address_hash" => "0x026debba6a0e1f8b24923363073e99be3e4075a8",
          "token_id" => "567"
        }
      }

      for {endpoint, params} <- measured do
        cursor = Cursor.encode(Map.put(params, "items_count", 50), @origin, endpoint)

        assert {:ok, ^params} = Cursor.decode(cursor, @origin, endpoint),
               "#{endpoint} did not round-trip its measured cursor"
      end
    end
  end

  defp payload(cursor) do
    [_version, payload, _signature] = String.split(cursor, ".")
    {:ok, json} = Base.url_decode64(payload, padding: false)
    json
  end

  defp flip(payload) do
    {:ok, json} = Base.url_decode64(payload, padding: false)
    Base.url_encode64(String.replace(json, "149", "150"), padding: false)
  end

  # Builds a cursor in the wire format directly, which is the only way to test
  # what happens to a validly signed payload the encoder would never produce.
  defp sign(payload, key) do
    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    signed = "v1." <> encoded
    mac = :crypto.mac(:hmac, :sha256, key, signed)

    signed <> "." <> Base.url_encode64(mac, padding: false)
  end
end
