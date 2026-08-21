defmodule Raxol.Payments.Conformance.WalletSignerParityTest do
  @moduledoc """
  Byte-for-byte parity between the wallet signer and the reference signer
  (ethers, via the riddler-client CLI).

  Both sign the same EIP-712 digest with the same key using deterministic
  (RFC 6979, low-s) ECDSA, so `r`, `s`, and the recovery byte `v` must be
  identical. ethers serializes the Ethereum-canonical `v` of 27/28; this test
  fails if the wallet ever regresses to the raw 0/1 recovery id, which on-chain
  `ecrecover` (ERC-3009 origin pull / Permit2 / x402) rejects. Regression guard
  for the `v` normalization in `Raxol.Payments.EIP712.pack_signature/1`.

  Tagged `:cli_signer` (excluded by default): needs node and the CLI checkout.
  Set `RIDDLER_CLI_DIR`, or check the CLI out beside the raxol repo.
  """
  use ExUnit.Case, async: true

  alias Raxol.Payments.Test.CliSigner
  alias Raxol.Payments.Wallets.Env

  @moduletag :cli_signer

  # secp256k1 private key 1 and its derived (buyer) address.
  @key "0x0000000000000000000000000000000000000000000000000000000000000001"
  @addr "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
  @env_var "RAXOL_SIGNER_PARITY_KEY"

  setup do
    System.put_env(@env_var, @key)
    on_exit(fn -> System.delete_env(@env_var) end)
    {:ok, cli_dir: locate_cli()}
  end

  test "Env wallet signs an ERC-3009 digest identically to the reference CLI", %{cli_dir: cwd} do
    unless cwd do
      flunk("CLI not available; set RIDDLER_CLI_DIR or run with --exclude cli_signer")
    end

    # acp-buyer-auth signs an ERC-3009 ReceiveWithAuthorization digest with
    # ethers and returns both the digest and the signature. The nonce is random
    # per invocation, so the test signs whatever digest this run produced rather
    # than a fixed vector.
    flags = [
      job_id: "12345",
      buyer: @addr,
      seller: "0xc6E555dfcC47e4A3bfecd6879570044ADc0270ff",
      amount: "1000000",
      chain: "base",
      token: "usdc",
      auth_type: "erc3009",
      deadline: "1900000000"
    ]

    assert {:ok, %{result_json: result}} =
             CliSigner.acp_buyer_auth(flags, cwd: cwd, private_key: @key)

    assert {:ok, digest} = decode_hex(result["digest"])

    # raxol signs the reference's own digest with the same key.
    assert {:ok, sig} = Env.sign_hash(digest, @env_var)

    # Deterministic ECDSA: r, s, AND the recovery byte v must match ethers exactly.
    assert "0x" <> Base.encode16(sig, case: :lower) == result["signature"]

    # The recovery byte is the on-chain-canonical 27/28, never the raw 0/1.
    assert :binary.last(sig) in [27, 28]
  end

  # Resolve the CLI checkout: explicit env var, then the two common dev layouts
  # (beside the raxol repo under a shared parent, or inside it). Returns nil when
  # absent so the test flunks with a clear message under `--only cli_signer`.
  # The CLI repo (axol-io/riddler-sdk, formerly riddler-client) became a
  # monorepo and its entry point moved to packages/sdk-taker/src/cli.ts.
  # Probing for the retired src/index.js + src/acp.js answered nil even with
  # RIDDLER_CLI_DIR set correctly, which silently retired this oracle: the test
  # is :cli_signer-tagged and excluded by default, so the flunk below was never
  # reached. Probe the entry point CliSigner actually spawns.
  defp locate_cli do
    [
      System.get_env("RIDDLER_CLI_DIR"),
      Path.expand("../../../../../../../riddler-sdk", __DIR__),
      Path.expand("../../../../../../riddler-sdk", __DIR__),
      Path.expand("../../../../../../../riddler-client", __DIR__),
      Path.expand("../../../../../../riddler-client", __DIR__)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&File.exists?(Path.join([&1, "packages", "sdk-taker", "src", "cli.ts"])))
  end

  defp decode_hex("0x" <> hex), do: Base.decode16(hex, case: :mixed)
  defp decode_hex(_), do: :error
end
