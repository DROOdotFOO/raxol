# Opt-in tags, excluded by default; enable with `mix test --include <tag>`:
#   :live_chain / :live_bundler / :live_acp_dev -- spin up a real Anvil node and
#     exercise the on-chain pipeline (need foundry: anvil + cast).
#   :live_relay -- moves real funds (broadcasts an on-chain deposit).
#   :live_xochi_order / :live_xochi_order_preflight -- a buyer orders the
#     xochi_cross_chain_transfer offering; the settle variant moves real funds
#     (see run_live_acp_order_gate.sh). The preflight variant is read-only.
#   :cli_signer -- spawns the riddler-client CLI; auto-enabled when
#     RIDDLER_CLI_DIR is set.
#
# A single ExUnit.start sets the full list; a second ExUnit.configure(exclude:)
# would replace it rather than merge, so it is computed once here.
live_exclude = [
  :live_chain,
  :live_bundler,
  :live_acp_dev,
  :live_relay,
  :live_xochi_order,
  :live_xochi_order_preflight
]

cli_exclude = if System.get_env("RIDDLER_CLI_DIR"), do: [], else: [:cli_signer]

ExUnit.start(exclude: live_exclude ++ cli_exclude)

# Bring up the seller stack with the in-process backend. Tests that need
# specific Queue defaults (wallet, memo_opts, seller_address) overwrite
# the env and recycle the Queue in their own setup.
Application.put_env(:raxol_acp, :seller_enabled, true)

Application.put_env(
  :raxol_acp,
  :seller_backend,
  Raxol.ACP.Seller.Backend.InMemory
)

# In :test the OTP application's :mod is not declared, so the supervisor
# does not auto-start. Bring it up explicitly for the test run.
{:ok, _} = Raxol.ACP.Supervisor.start_link()
