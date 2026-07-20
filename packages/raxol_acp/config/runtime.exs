import Config

# Runtime (boot-time) config for the raxol_acp release. Two modes share this file:
#
#   * accounting sidecar (default) -- read-only ledger/monitor over public RPC; it
#     holds no signing key and never moves funds.
#   * solver (XOCHI_SOLVER_ENABLED=true, wired below) -- a SIGNING runtime: it reads
#     RAXOL_ACP_AGENT_PRIVATE_KEY at boot and signs EIP-712 auth plus on-chain ACP
#     tx. In this mode the "read-only/keyless" framing below does NOT hold.
#
# Prod-gated so `mix`/tests in this package are unaffected. Reads the accounting
# deployment contract via `Raxol.Payments.Accounting.env_config/0` -- the same
# helper the root raxol release uses -- so the two configs cannot drift.
#
# Deliberately NOT included: the origin-pull solver-pin guard from the root
# config/runtime.exs. That guard fails a boot closed unless XOCHI_SOLVER_* is set,
# to protect a node that SIGNS origin pulls -- it is not wired here. The
# distribution/REPL boot gates in Raxol.Payments.Deployment are likewise not wired.
# Because those gates are absent, solver mode instead fails the boot CLOSED below if
# Erlang distribution is on (see the RELEASE_DISTRIBUTION guard): the signing node
# must expose no cookie-reachable REPL. rel/env.sh.eex defaults distribution to
# "none"; the guard catches an operator override.
if config_env() == :prod do
  config :logger, level: :info

  {accounting_opts, accounting_enabled} = Raxol.Payments.Accounting.env_config()

  config :raxol_payments, :accounting, accounting_opts
  config :raxol_acp, accounting_enabled: accounting_enabled

  # Solver mode is gated by Application config, not an env var -- wire the flag from
  # XOCHI_SOLVER_ENABLED so a fly deploy can toggle the signing solver without a
  # rebuild. Defaults false (accounting-only) for any other/unset value.
  solver_enabled? = System.get_env("XOCHI_SOLVER_ENABLED") == "true"
  config :raxol_acp, xochi_solver_enabled: solver_enabled?

  # Solver mode holds a real signing EOA, and the distribution/REPL security boot
  # gates are not wired here (see the moduledoc). Nothing else keeps distribution
  # off, so fail the boot CLOSED if an operator turned it on: a cookie-reachable
  # REPL onto a wallet-holding node is a remote path to the signing key.
  # rel/env.sh.eex defaults RELEASE_DISTRIBUTION to "none".
  if solver_enabled? and System.get_env("RELEASE_DISTRIBUTION", "none") not in ["none", ""] do
    raise """
    raxol_acp solver mode forbids Erlang distribution: RELEASE_DISTRIBUTION must be \
    unset or "none" (got #{inspect(System.get_env("RELEASE_DISTRIBUTION"))}). The \
    signing node must expose no cookie-reachable REPL.
    """
  end

  # Solver mode signs real transactions; it must run on an explicitly-configured
  # (private) Base RPC, never silently fall back to the rate-limited public endpoint
  # (that path 429-storms nonce fetch + tx submit -- the axol RPC-429 crashloop class).
  # Require RAXOL_ACP_RPC_URL rather than defaulting it; set it as a fly secret.
  if solver_enabled? and String.trim(System.get_env("RAXOL_ACP_RPC_URL", "")) == "" do
    raise """
    raxol_acp solver mode requires RAXOL_ACP_RPC_URL (a private Base RPC). Refusing to \
    boot on the public-RPC default -- set it as a fly secret (scripts/deploy-raxol-solver.sh).
    """
  end
end
