defmodule Raxol.Payments.SecretTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Secret

  # anvil account 0 key -- a real, valid secp256k1 scalar
  @key Base.decode16!(
         "AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80",
         case: :mixed
       )
  @key_hex_lower Base.encode16(@key, case: :lower)
  @key_hex_upper Base.encode16(@key, case: :upper)

  describe "new/1 and reveal/1" do
    test "round-trips the wrapped bytes" do
      secret = Secret.new(@key)
      assert Secret.reveal(secret) == @key
    end

    test "is idempotent when given an already-wrapped secret" do
      secret = Secret.new(@key)
      assert Secret.new(secret) == secret
      assert Secret.reveal(Secret.new(secret)) == @key
    end
  end

  describe "redaction" do
    test "inspect/1 of a secret never exposes the bytes" do
      out = inspect(Secret.new(@key))
      assert out == "#Raxol.Payments.Secret<redacted>"
      refute out =~ @key_hex_lower
      refute out =~ @key_hex_upper
    end

    test "inspecting a map that holds a secret redacts the field" do
      # Mirrors the Wallets.Op GenServer state shape. An OTP crash report
      # inspects this state into the log; the key must not appear.
      state = %{
        op_ref: "op://Employee/Key/credential",
        privkey: Secret.new(@key),
        address: "0xabc"
      }

      out = inspect(state)

      refute out =~ @key_hex_lower
      refute out =~ @key_hex_upper
      refute out =~ inspect(@key)
      assert out =~ "redacted"
    end

    test "does not implement String.Chars, so it cannot be interpolated into a string" do
      refute String.Chars.impl_for(Secret.new(@key))
    end
  end

  describe "with_revealed/2" do
    test "reveals the raw bytes to the function and passes its result through" do
      secret = Secret.new(@key)
      assert Secret.with_revealed(secret, fn bytes -> {:ok, bytes} end) == {:ok, @key}
    end

    test "passes an {:error, _} return through unchanged" do
      secret = Secret.new(@key)
      assert Secret.with_revealed(secret, fn _ -> {:error, :nope} end) == {:error, :nope}
    end

    test "converts a raise into a fixed error atom without surfacing the exception" do
      secret = Secret.new(@key)

      # A signing NIF that raises badarg would put the raw key in its stacktrace;
      # the guard must swallow the exception entirely, leaking nothing.
      result = Secret.with_revealed(secret, fn _ -> raise "boom #{@key_hex_lower}" end)

      assert result == {:error, :secret_operation_crashed}
      refute inspect(result) =~ @key_hex_lower
    end

    test "converts a throw and an exit into the same fixed error atom" do
      secret = Secret.new(@key)

      assert Secret.with_revealed(secret, fn _ -> throw(:boom) end) ==
               {:error, :secret_operation_crashed}

      assert Secret.with_revealed(secret, fn _ -> exit(:boom) end) ==
               {:error, :secret_operation_crashed}
    end
  end
end
