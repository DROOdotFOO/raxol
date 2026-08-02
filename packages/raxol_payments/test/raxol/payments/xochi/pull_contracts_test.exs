defmodule Raxol.Payments.Xochi.PullContractsTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Xochi.PullContracts

  @solver "0x97D447561fDe10E959E782a29411D8F89586d80b"
  @base_erc3009 "0xaA8FDA73906293A0A3Cd8e057Db97670944A46F8"
  @permit2 "0xE9B020941015e428876f60C1979B3fc2A38a2f53"

  test "solver_wallet is the settlement wallet" do
    assert PullContracts.solver_wallet() == @solver
  end

  test "erc3009_proxy resolves the per-chain USDC pull proxy" do
    assert PullContracts.erc3009_proxy(8453) == @base_erc3009
    assert PullContracts.erc3009_proxy(1) == "0xC955fE2d64fe40e7208e9Daf33acEC3b0f577025"
    assert PullContracts.erc3009_proxy(42_161) == "0x0A00b656e2363eDa59055b285A1ba025c335D7C0"
  end

  test "erc3009_proxy is nil for a chain with no deployed USDC proxy" do
    # Robinhood (4663) is Permit2-only (no ERC-3009 USDC).
    assert PullContracts.erc3009_proxy(4663) == nil
    assert PullContracts.erc3009_proxy(999_999) == nil
  end

  test "permit2_proxy is the uniform cross-chain proxy" do
    assert PullContracts.permit2_proxy() == @permit2
  end

  test "pull_recipients includes the solver, every ERC-3009 proxy, and the permit2 proxy" do
    recipients = PullContracts.pull_recipients()

    assert @solver in recipients
    assert @base_erc3009 in recipients
    assert @permit2 in recipients
    # 1 solver + 5 per-chain ERC-3009 proxies + 1 permit2 proxy.
    assert length(recipients) == 7
  end

  test "pull_recipients has no duplicates and all entries are 20-byte addresses" do
    recipients = PullContracts.pull_recipients()

    assert recipients == Enum.uniq(recipients)

    for addr <- recipients do
      assert Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, addr), "malformed address: #{addr}"
    end
  end

  test "pull_recipients normalize into the allowlist form used by the pin" do
    # The pin compares EIP712.normalize_address(to) against the normalized list;
    # normalization lowercases and strips the 0x prefix, so the match is case-
    # and prefix-insensitive. Every recipient must survive it (non-empty).
    for addr <- PullContracts.pull_recipients() do
      normalized = EIP712.normalize_address(addr)
      assert normalized != ""
      assert normalized == addr |> String.downcase() |> String.replace_prefix("0x", "")
    end
  end
end
