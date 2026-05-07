defmodule Raxol.ACP.Bench.Wallet do
  @moduledoc """
  Wallet used by `mix raxol_acp.bench` to sign memos during the
  in-memory benchmark.

  Wraps `Raxol.Payments.Wallets.Env` and reads its private key from
  `RAXOL_ACP_BENCH_PRIVKEY`. The bench task seeds this env var with
  the canonical Anvil/Foundry test account #0 if it is not already
  set, so a fresh checkout can run `mix raxol_acp.bench` with no
  setup.

  This wallet is for the in-memory bench only. It signs against
  `chain_id: 8453` (Base mainnet) so signatures are domain-separated
  from real production signing flows -- but no transactions ever hit
  a real network because the bench uses
  `Raxol.ACP.ContractClient.InMemory`.
  """

  use Raxol.Payments.Wallets.Env,
    env_var: "RAXOL_ACP_BENCH_PRIVKEY",
    chain_id: 8453
end
