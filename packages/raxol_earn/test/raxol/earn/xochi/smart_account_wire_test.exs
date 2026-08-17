defmodule Raxol.Earn.Xochi.SmartAccountWireTest do
  @moduledoc """
  Pins the wire shape of a SMART-ACCOUNT signature: the 72-byte ma-v2 ERC-1271
  envelope `mix raxol_earn.order --signer privy` releases.

  ## Why this exists

  Every live gate that had ever passed used an EOA buyer. Nothing exercised an
  ERC-1271 signature, and that gap let one assumption -- "a signature is 65
  bytes" -- survive three layers into production, each needing its own fix:

    1. raxol built the wrong ERC-1271 replay-safe domain (raxol#773)
    2. Xochi's ERC-1271 verification silently never ran, because no `RPC_URL_*`
       was set in production, so every smart-account signer got a bare 401
       (xochi-fi/xochi#364, deployed 2026-08-15)
    3. Riddler's request schema constrained the signature to exactly 65 bytes
       (axol-io/Riddler#802, closed 2026-08-16)

  All three are cleared. What is still worth pinning is OUR half of the contract:
  three services were taught to accept this exact envelope, so changing it is
  changing something they agreed on, and this fails the moment anyone does.

  The 65-byte pattern below is kept as a HISTORICAL literal rather than a live
  constraint. It is the shape the envelope had to outgrow, and holding it here
  keeps the reason the envelope is 72 bytes executable instead of folkloric.

  ## What this test can and cannot do

  It deliberately does NOT probe the live service, because there is no fund-free
  way to reach the constraint. Xochi verifies the signature BEFORE forwarding to
  Riddler: an intent signed with an unauthorized key is rejected at Xochi's
  ERC-1271 check and never reaches the schema, while a validly signed one
  executes the pull and moves the principal. A live probe would therefore either
  test the wrong layer or spend real money.

  Confirmation is one funded run, which a smart-account buyer now pulls through
  Permit2 rather than ERC-3009, so it needs the spender pin (and, the first time,
  the Permit2 approve):

      mix raxol_earn.order --amount 3.00 --signer privy --solver 0x<spender> --fund
  """

  use ExUnit.Case, async: true

  # The signature pattern Riddler enforced before it accepted smart-account
  # payments: verbatim from `integrations/xochi/schemas/execute_request.ex`,
  # duplicated in `web/openapi/schema.ex` and `claim_submit_request.ex`, and
  # published in `packages/api/src/spec.json` as
  # `CommerceOrderRequest.properties.signature`. Kept as the historical shape the
  # envelope had to outgrow, not as a constraint that still holds.
  @legacy_65_byte_pattern ~r/^0x[a-fA-F0-9]{130}$/

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

    test "outgrows the 65-byte pattern that used to reject it" do
      hex = "0x" <> Base.encode16(envelope(), case: :lower)

      # 72 bytes = 144 hex chars; the old pattern demanded exactly 130.
      assert String.length(hex) == 146
      refute Regex.match?(@legacy_65_byte_pattern, hex)
    end

    test "a plain EOA signature fits that pattern -- it was never simply broken" do
      hex = "0x" <> Base.encode16(@raw_sig, case: :lower)

      assert String.length(hex) == 132
      assert Regex.match?(@legacy_65_byte_pattern, hex)
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
