defmodule Raxol.Earn.SecretTest do
  @moduledoc """
  Offline (no network, no anvil) tests for `Raxol.Earn.Secret` and for the
  redaction of the key inside a `JSONRPC` adapter built via `new/1`.
  """
  use ExUnit.Case, async: true

  alias Raxol.Earn.ProviderAdapter
  alias Raxol.Earn.ProviderAdapter.JSONRPC
  alias Raxol.Earn.Secret

  # anvil account 0 key -- a real, valid secp256k1 scalar
  @key Base.decode16!(
         "AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80",
         case: :mixed
       )
  @key_hex_lower Base.encode16(@key, case: :lower)
  @key_hex_upper Base.encode16(@key, case: :upper)

  describe "new/1 and reveal/1" do
    test "round-trips the wrapped bytes" do
      assert Secret.reveal(Secret.new(@key)) == @key
    end

    test "is idempotent when given an already-wrapped secret" do
      secret = Secret.new(@key)
      assert Secret.new(secret) == secret
    end
  end

  describe "redaction" do
    test "inspect/1 of a secret never exposes the bytes" do
      out = inspect(Secret.new(@key))
      assert out == "#Raxol.Earn.Secret<redacted>"
      refute out =~ @key_hex_lower
      refute out =~ @key_hex_upper
    end

    test "inspecting a JSONRPC adapter does not leak the private key" do
      # new/1 does no network: it only validates the key and derives the
      # address. An OTP crash report inspects the adapter (a call argument)
      # into the log, so the key must not appear there.
      adapter = JSONRPC.new(chains: %{8453 => "https://mainnet.base.org"}, private_key: @key)

      out = inspect(adapter)
      refute out =~ @key_hex_lower
      refute out =~ @key_hex_upper
      refute out =~ inspect(@key)
      assert out =~ "redacted"

      # Address derivation is unaffected by the wrapping.
      assert "0x" <> _ = ProviderAdapter.get_address(adapter)
    end
  end
end
