defmodule Raxol.Payments.EIP712GoldenTest do
  @moduledoc """
  Committed EIP-712 golden hashes for every signed struct, checked in default CI.

  Fable review §1.1/§3.1: the conformance suite verifies raxol's hashing against
  viem byte-for-byte, but it is `@moduletag :conformance` and skipped unless the
  external fixture/CLI is present -- so a change to a signed struct's type or
  domain would not turn CI red. These self-contained goldens close that gap: a
  canonical vector per struct, hashed through the production code path, pinned to
  a committed digest. Editing a type definition, domain, or the encoder changes
  the digest and fails here.

  The Xochi vector additionally pins the full signature against riddler-client's
  own viem pin (`@shielded_signature`), so it is a live cross-repo contract, not
  just a self-consistency lock. The x402/Permit2/Mandate digests are drift locks
  whose viem parity is established by the conformance suite when it runs.
  """

  use ExUnit.Case, async: true

  alias Raxol.Payments.{EIP712, Mandate}
  alias Raxol.Payments.Assets.UsdcDomains
  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Test.ConformanceSigner

  # secp256k1 key 1 and its derived address (shared with the conformance suite).
  @canonical_key "0x0000000000000000000000000000000000000000000000000000000000000001"
  @canonical_signer "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"

  # -- Xochi intent (viem-verified, mirrors riddler-client) --

  @xochi_types %{
    "XochiIntent" => [
      {"intentId", "string"},
      {"quoteId", "string"},
      {"wallet", "address"},
      {"fromChainId", "uint256"},
      {"toChainId", "uint256"},
      {"fromToken", "address"},
      {"toToken", "address"},
      {"fromAmount", "uint256"},
      {"toAmount", "uint256"},
      {"settlementPreference", "string"},
      {"nonce", "uint256"},
      {"deadline", "uint256"}
    ]
  }
  @xochi_domain %{name: "XochiIntent", version: "1", chainId: 8453}
  @xochi_message %{
    "intentId" => "shielded-test",
    "quoteId" => "shielded-test",
    "wallet" => "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
    "fromChainId" => 8453,
    "toChainId" => 10,
    "fromToken" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "toToken" => "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    "fromAmount" => "1000000",
    "toAmount" => "1000000",
    "settlementPreference" => "shielded",
    "nonce" => 0,
    "deadline" => 1_900_000_000
  }
  # Pinned in riddler-client test-xochi.js; the cross-repo byte-equality contract.
  @xochi_signature "0xbe2545d815e4ce15d859e9bdee5bcb3a2f81e94a4b0fd0586220bd0235682d2f4bd1ea6082ddb8e59bb5557e91cb2f80e4dd3aef800e0fa4eabd0367a04c86061b"
  @xochi_golden_digest "0xdbed39b9cac50396d859f0b229f988208dcb9cc344ffe128e55cc9d72b50a704"

  # -- x402 ERC-3009 ReceiveWithAuthorization --

  @erc3009_types %{
    "ReceiveWithAuthorization" => [
      {"from", "address"},
      {"to", "address"},
      {"value", "uint256"},
      {"validAfter", "uint256"},
      {"validBefore", "uint256"},
      {"nonce", "bytes32"}
    ]
  }
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @erc3009_message %{
    "from" => "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
    "to" => "0x2222222222222222222222222222222222222222",
    "value" => 1_000_000,
    "validAfter" => 0,
    "validBefore" => 1_900_000_000,
    "nonce" => "0x" <> String.duplicate("ab", 32)
  }
  @erc3009_golden_digest "0x794300931b17739ae0d4456a276138ccb6fe8ca18265210dd5849260902d1379"

  # -- Permit2 PermitWitnessTransferFrom --

  @permit2_quote %{
    "request" => %{
      "inputAmount" => "1000000",
      "inputToken" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    },
    "quoteExpires" => 1_900_000_000,
    "gasless" => %{
      "to" => "0x2222222222222222222222222222222222222222",
      "nonce" => "1",
      "orderId" => "0x" <> String.duplicate("cd", 32)
    }
  }
  @permit2_golden_digest "0xbe6ff8e898322b18fd9a80fac9ff02234b136ec81e07bff3e5f4c4b7542bde0e"

  defmodule CanonicalWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet
    @key Base.decode16!("0000000000000000000000000000000000000000000000000000000000000001")

    @impl true
    def address, do: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    @impl true
    def chain_id, do: 8453

    @impl true
    def sign_message(_msg), do: {:ok, <<0::512>>}

    @impl true
    def sign_typed_data(domain, types, message) do
      with {:ok, digest} <- EIP712.hash(domain, types, message),
           {:ok, sig} <- ExSecp256k1.sign(digest, @key) do
        {:ok, EIP712.pack_signature(sig)}
      end
    end

    @impl true
    def sign_hash(<<digest::binary-size(32)>>) do
      {:ok, sig} = ExSecp256k1.sign(digest, @key)
      {:ok, EIP712.pack_signature(sig)}
    end
  end

  # -- Mandate --

  @mandate_attrs %{
    human_wallet: "0x1111111111111111111111111111111111111111",
    agent_wallet: "0x2222222222222222222222222222222222222222",
    scopes: ["quote", "execute"],
    max_amount_usd: 250,
    max_calls: 20,
    expires_at: 1_900_000_000,
    nonce: "0x" <> String.duplicate("00", 31) <> "01"
  }
  @mandate_golden_digest "0xea60fa2779dcda0f94a2c3b71b99ceb077447d4ab018fd4c99fa798903cbce48"

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  describe "Xochi intent golden (viem-verified)" do
    test "digest is pinned and the signature matches riddler-client's viem pin" do
      assert {:ok, digest} = EIP712.hash(@xochi_domain, @xochi_types, @xochi_message)
      assert hex(digest) == @xochi_golden_digest

      signature =
        ConformanceSigner.sign_hex(digest, ConformanceSigner.decode_hex!(@canonical_key))

      assert signature == @xochi_signature
      assert ConformanceSigner.recover_address(digest, signature) == @canonical_signer
    end
  end

  describe "x402 ERC-3009 golden" do
    test "digest is pinned for the canonical USDC ReceiveWithAuthorization" do
      %{name: name, version: version} = UsdcDomains.lookup(8453)

      domain = %{
        name: name,
        version: version,
        chainId: 8453,
        verifyingContract: @usdc_base
      }

      assert {:ok, digest} = EIP712.hash(domain, @erc3009_types, @erc3009_message)
      assert hex(digest) == @erc3009_golden_digest
    end
  end

  describe "Permit2 PermitWitnessTransferFrom golden" do
    test "digest is pinned through the production sign_quote path" do
      assert {:ok, result} = Permit2.sign_quote(@permit2_quote, 8453, CanonicalWallet)
      assert result.digest == @permit2_golden_digest
    end
  end

  describe "Mandate golden" do
    test "digest is pinned for the canonical mandate" do
      assert {:ok, mandate} = Mandate.build(@mandate_attrs)
      assert {:ok, digest} = Mandate.digest(mandate)
      assert hex(digest) == @mandate_golden_digest
    end
  end
end
