defmodule Raxol.Web3.Tron.AddressTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Tron.Address

  # Ground truth rather than generated, and the same addresses the payments copy
  # uses, because the two implementations differ in structure and must not
  # differ in behaviour: USDT and USDC on Tron mainnet. Each hex form was
  # derived by an independent Base58Check decode (not by this module) and its
  # checksum verified, on 2026-09-14.
  @vectors [
    {"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "0x41a614f803b6fd780986a42c78ec9c7f77e6ded13c"},
    {"TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8", "0x413487b63d30b5b2c87fb7ffa8bcfade38eaac1abe"}
  ]

  @usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  describe "the known vectors" do
    test "each Base58 address converts to its hex form and back" do
      for {base58, hex} <- @vectors do
        assert Address.to_hex(base58) == {:ok, hex}
        assert Address.from_hex(hex) == {:ok, base58}
        assert Address.valid?(base58)
      end
    end

    test "hex is accepted with and without the 0x prefix" do
      for {base58, "0x" <> bare = hex} <- @vectors do
        assert Address.from_hex(hex) == {:ok, base58}
        assert Address.from_hex(bare) == {:ok, base58}
      end
    end

    test "the decoded payload is the network prefix plus twenty address bytes" do
      for {base58, _hex} <- @vectors do
        assert {:ok, <<0x41, rest::binary>>} = Address.decode(base58)
        assert byte_size(rest) == 20
      end
    end
  end

  describe "refusals" do
    test "a corrupted checksum is refused, so a typo cannot become another account" do
      <<head::binary-size(33), last::binary>> = @usdt
      flipped = if last == "t", do: "u", else: "t"

      refute Address.valid?(head <> flipped)
      assert Address.decode(head <> flipped) == {:error, :invalid_address}
    end

    test "a character outside the Base58 alphabet is refused" do
      # `0`, `O`, `I` and `l` are the four the alphabet omits, and they are
      # exactly the ones a human retyping an address substitutes.
      for excluded <- ["0", "O", "I", "l"] do
        <<head::binary-size(33), _last::binary>> = @usdt
        refute Address.valid?(head <> excluded)
      end
    end

    test "an EVM address, garbage and a non-string are all refused" do
      for refused <- ["0x" <> String.duplicate("ab", 20), "not an address", "", nil, 123] do
        refute Address.valid?(refused)
        assert Address.decode(refused) == {:error, :invalid_address}
      end
    end

    test "hex without the network prefix, and hex of the wrong length, are refused" do
      assert Address.from_hex("0x" <> String.duplicate("ab", 21)) == {:error, :invalid_address}
      assert Address.from_hex("0x41" <> String.duplicate("ab", 19)) == {:error, :invalid_address}

      assert Address.from_hex("0x41zz" <> String.duplicate("ab", 19)) ==
               {:error, :invalid_address}
    end

    test "a length other than 34 is refused, either side of the bound" do
      <<short::binary-size(33), _last::binary>> = @usdt

      refute Address.valid?(short)
      refute Address.valid?(@usdt <> "T")
    end

    test "an over-long address is refused before any decode work" do
      # `to_integer/2` is `number * 58 + value` per character, so an unbounded
      # caller string is O(n^2) bignum work on a path the rate limiter and the
      # circuit breaker sit behind: this is reached from the `web3_account_info`
      # `account` argument. Reductions rather than elapsed time, because the
      # property is how much work ran and not how fast the runner is -- the
      # recursion alone charges one reduction per character.
      long = String.duplicate("T", 20_000)

      {:reductions, before} = Process.info(self(), :reductions)
      assert Address.decode(long) == {:error, :invalid_address}
      {:reductions, after_decode} = Process.info(self(), :reductions)

      assert after_decode - before < 1_000
    end
  end

  describe "canonical/1" do
    test "both encodings of one account collapse onto the same reference" do
      # The property the Tron backend needs: two callers holding one account in
      # different encodings reach one cache entry, one rate-limit spend and one
      # answer.
      for {base58, "0x" <> bare = hex} <- @vectors do
        assert Address.canonical(base58) == {:ok, base58}
        assert Address.canonical(hex) == {:ok, base58}
        assert Address.canonical(bare) == {:ok, base58}
      end
    end

    test "a 20-byte EVM address is refused rather than given a network prefix" do
      # Inventing the 0x41 would mint a Tron address for an account that was
      # never on this chain.
      assert Address.canonical("0x" <> String.duplicate("ab", 20)) == {:error, :invalid_address}
      assert Address.canonical(nil) == {:error, :invalid_address}
    end
  end
end
