defmodule Raxol.Payments.Xochi.PullContracts do
  @moduledoc """
  Verified XochiPull / XochiPullPermit2 origin-pull contracts (Riddler #591,
  deployed 2026-07-23 from the solver wallet `0x97D4...80b`).

  The Blockaid EOA-scam fix moved the origin pull off the bare solver EOA and onto
  these verified, per-chain contracts. With them enabled on the solver side
  (Riddler `xochi_pull_contract_enabled: true`), a live Xochi quote's origin-pull
  recipient -- the ERC-3009 authorization `to`, or the Permit2 `spender` -- is one
  of these contracts, NOT the solver EOA.

  `pull_recipients/0` is the full set of legitimate origin-pull recipients for the
  anti-drain pin (`config :raxol_payments, :pull_solver_allowlist`): the settlement
  wallet plus every deployed pull proxy. Pinning to this set keeps the pin's
  protection (an unknown `to`/`spender` is still rejected) while accepting the
  verified contracts.

  Mirror of Riddler `XOCHIPULL_DEPLOYMENTS.md`; keep in sync on redeploy. The USDC
  proxy differs per chain (the token address enters the proxy initcode); the
  Permit2 proxy is uniform across chains.
  """

  # The solver / settlement wallet -- still a legitimate direct recipient, and the
  # deployer of the pull contracts.
  @solver_wallet "0x97D447561fDe10E959E782a29411D8F89586d80b"

  # XochiPull USDC (ERC-3009) proxies, per chain.
  @erc3009_proxies %{
    1 => "0xC955fE2d64fe40e7208e9Daf33acEC3b0f577025",
    10 => "0xB5eE8694E4b3F0bC19fb73612cbE16Dc0ddfBa89",
    137 => "0xaA7D2343Ef76Fd8594Ad836E682Dd270C700c528",
    8453 => "0xaA8FDA73906293A0A3Cd8e057Db97670944A46F8",
    42_161 => "0x0A00b656e2363eDa59055b285A1ba025c335D7C0"
  }

  # XochiPullPermit2 proxy -- uniform across all chains (incl. Robinhood 4663).
  @permit2_proxy "0xE9B020941015e428876f60C1979B3fc2A38a2f53"

  @doc "The solver / settlement wallet."
  @spec solver_wallet() :: String.t()
  def solver_wallet, do: @solver_wallet

  @doc "The XochiPull USDC (ERC-3009) proxy for `chain_id`, or nil if none."
  @spec erc3009_proxy(pos_integer()) :: String.t() | nil
  def erc3009_proxy(chain_id), do: Map.get(@erc3009_proxies, chain_id)

  @doc "The uniform XochiPullPermit2 proxy address."
  @spec permit2_proxy() :: String.t()
  def permit2_proxy, do: @permit2_proxy

  @doc """
  Every legitimate origin-pull recipient: the solver wallet, all per-chain
  XochiPull USDC proxies, and the XochiPullPermit2 proxy. Use as the
  `:pull_solver_allowlist` so the anti-drain pin accepts the verified pull
  contracts while still rejecting an unknown `to`/`spender`.
  """
  @spec pull_recipients() :: [String.t()]
  def pull_recipients do
    [@solver_wallet | Map.values(@erc3009_proxies)] ++ [@permit2_proxy]
  end
end
