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
