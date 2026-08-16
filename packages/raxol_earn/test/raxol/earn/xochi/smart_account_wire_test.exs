defmodule Raxol.Earn.Xochi.SmartAccountWireTest do
  @moduledoc """
  Pins the wire shape of a SMART-ACCOUNT signature against the constraint that
  currently rejects it downstream.

  ## Why this exists

  Every live gate that has ever passed used an EOA buyer. Nothing exercised an
  ERC-1271 signature, and that gap let one assumption -- "a signature is 65
  bytes" -- survive three layers into production:

    1. raxol built the wrong ERC-1271 replay-safe domain (fixed, #773)
    2. Xochi's ERC-1271 verification silently never ran, because no `RPC_URL_*`
       was set in production, so every smart-account signer got a bare 401
       (fixed, xochi-fi/xochi#364, deployed 2026-08-15)
    3. Riddler's request schema constrains the signature to exactly 65 bytes,
       `~r/^0x[a-fA-F0-9]{130}$/` (open, axol-io/Riddler#802)

  Layer 3 is why a real funded order (job 73295) still fails today, at
  `validation_failed: Request validation failed`.

  ## What this test can and cannot do

  It asserts OUR half: the ma-v2 envelope raxol produces is 72 bytes, and a
  72-byte signature cannot match the 65-byte pattern the solver enforces. That
  makes the incompatibility an executable fact rather than a note in an issue,
  and it fails immediately if anyone changes the envelope.

  It deliberately does NOT probe the live service, because there is no
  fund-free way to reach the constraint. Xochi verifies the signature BEFORE
  forwarding to Riddler: an intent signed with an unauthorized key is rejected
  at Xochi's ERC-1271 check and never reaches the schema, while a validly
  signed one executes the pull and moves the principal. A live probe would
  therefore either test the wrong layer or spend real money.

  When #802 lands, the confirmation is one funded run:
  `mix raxol_earn.order --amount 3.00 --signer privy --fund` (~0.017 USDC).
  """

  use ExUnit.Case, async: true

  # Verbatim from Riddler `integrations/xochi/schemas/execute_request.ex:42`,
  # duplicated in `web/openapi/schema.ex:92` and `claim_submit_request.ex:63`,
  # and published in `packages/api/src/spec.json` as
  # `CommerceOrderRequest.properties.signature`.
  @riddler_signature_pattern ~r/^0x[a-fA-F0-9]{130}$/

  @account "0x468aeae798b3a6548ac2401d276f83afdc172283"
  @chain 8453
  @raw_sig :binary.copy(<<0xAB>>, 64) <> <<27>>

  # Stands in for the managed Privy authority, in the ProviderAdapter shape the
  # wallet dispatches through. It returns a fixed 65-byte signature, so this
  # pins the ENVELOPE rather than secp256k1.
  defmodule MockAuthority do
    @moduledoc false
    def new, do: %{adapter: __MODULE__, config: %{}}

    def sign_typed_data(_provider, _chain_id, _typed_data),
      do: {:ok, Raxol.Earn.Xochi.SmartAccountWireTest.raw_sig()}
  end

  def raw_sig, do: @raw_sig

  def provider, do: MockAuthority.new()

  defmodule Wallet do
    @moduledoc false
    use Raxol.Earn.Wallet.Sma7702,
      account_address: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      chain_id: 8453,
      provider: {Raxol.Earn.Xochi.SmartAccountWireTest, :provider}
  end

  defp envelope do
    {:ok, sig} =
      Wallet.sign_typed_data(
        %{name: "XochiIntent", version: "1", chainId: @chain, verifyingContract: @account},
        %{"Intent" => [{"amount", "uint256"}]},
        %{"amount" => 3_000_000}
      )

    sig
  end

  describe "the ma-v2 ERC-1271 envelope" do
    test "is 72 bytes: 0x00 || uint32(0) || 0xFF || 0x00 || sig65" do
      sig = envelope()

      assert <<0x00, 0::unsigned-big-32, 0xFF, 0x00, inner::binary>> = sig
      assert byte_size(inner) == 65
      assert byte_size(sig) == 72
      assert inner == @raw_sig
    end

    test "does not satisfy Riddler's 65-byte signature pattern (axol-io/Riddler#802)" do
      hex = "0x" <> Base.encode16(envelope(), case: :lower)

      # 72 bytes = 144 hex chars; the pattern demands exactly 130.
      assert String.length(hex) == 146
      refute Regex.match?(@riddler_signature_pattern, hex)
    end

    test "a plain EOA signature does satisfy it -- the pattern is not simply broken" do
      hex = "0x" <> Base.encode16(@raw_sig, case: :lower)

      assert String.length(hex) == 132
      assert Regex.match?(@riddler_signature_pattern, hex)
    end
  end

  describe "the account itself" do
    test "matches the buyer `raxol_earn.order --signer privy` signs as" do
      alias Mix.Tasks.RaxolEarn.Order.Sma7702Wallet

      assert Wallet.address() == Sma7702Wallet.address()
      assert Wallet.chain_id() == Sma7702Wallet.chain_id()
    end
  end
end
