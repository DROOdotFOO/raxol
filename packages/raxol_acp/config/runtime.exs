import Config

# Runtime (boot-time) config for the read-only settlement-accounting sidecar.
#
# Prod-gated so `mix`/tests in this package are unaffected. Reads the accounting
# deployment contract via `Raxol.Payments.Accounting.env_config/0` -- the same
# helper the root raxol release uses -- so the two configs cannot drift.
#
# Deliberately NOT included: the origin-pull solver-pin guard from the root
# config/runtime.exs. That guard fails a boot closed unless XOCHI_SOLVER_* is set,
# to protect a node that SIGNS origin pulls. This sidecar is read-only and never
# signs, so the guard is irrelevant here and would force an unrelated env var.
#
# The sidecar runs without Erlang distribution (see rel/env.sh.eex), so it holds no
# cookie-reachable node and no signing key; the distribution/REPL boot gates in
# Raxol.Payments.Deployment are therefore not wired here.
if config_env() == :prod do
  config :logger, level: :info

  {accounting_opts, accounting_enabled} = Raxol.Payments.Accounting.env_config()

  config :raxol_payments, :accounting, accounting_opts
  config :raxol_acp, accounting_enabled: accounting_enabled
end

# ACP contract version: :v1 targets the sunsetted ACPSimple/ACPRouter; :v2 the
# active AgenticCommerceV3 core. The code default in
# `Raxol.ACP.ContractClient.Onchain` is still :v1, so a deployment flips to the
# active contract by setting ACP_VERSION=v2 at boot -- no code change. Unset =
# leave the code default (tests are unaffected). This override applies in every
# env so staging can validate the v2 lifecycle before the code default flips.
case System.get_env("ACP_VERSION") do
  "v2" -> config :raxol_acp, acp_version: :v2
  "v1" -> config :raxol_acp, acp_version: :v1
  nil -> :ok
  other -> raise "invalid ACP_VERSION #{inspect(other)}; expected \"v1\" or \"v2\""
end
