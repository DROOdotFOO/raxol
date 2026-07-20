#!/usr/bin/env bash
#
# deploy-raxol-solver.sh -- seed the raxol_acp Xochi solver's runtime secrets into a
# DEDICATED, isolated fly.io app ('raxol-solver') and ship a single rolling deploy.
#
# CANONICAL SAFE PATTERN (mirrors ansible vars/vault_axol.yml op:// refs): nothing secret
# lives at rest. Every value is a 1Password reference resolved at deploy time via 'op read'
# and piped straight into 'fly secrets import' on STDIN. Secrets are NEVER written to disk,
# echoed, assigned to a variable, or passed as a command-line argument (so they never appear
# in flyctl's argv / `ps` / shell history). Before running you MUST:
#   1. 'op signin' (the 1Password CLI must be authenticated),
#   2. create the fly app once ('fly apps create raxol-solver'), and
#   3. replace the PLACEHOLDER op:// paths below with your real vault/item/field names.
#
# This app is intentionally SEPARATE from the public 'raxol' playground app (the anonymous
# SSH sandbox on :2222). Keeping the solver isolated is the whole point -- do not co-locate.
#
# ----------------------------------------------------------------------------------------
# CRITICAL: RAXOL_ACP_AGENT_PRIVATE_KEY MUST be a LOW-VALUE OPERATIONAL / gas wallet.
# It signs ACP auth + on-chain submit/complete for job settlement. It must NEVER be the
# high-value Riddler relayer / inventory wallet. Pointing this at the inventory key would
# collapse the blast-radius isolation this dedicated app exists to provide.
# ----------------------------------------------------------------------------------------
#
# Usage:
#   ./scripts/deploy-raxol-solver.sh

set -euo pipefail
# A failed 'op read' inside a command substitution must abort the whole run rather than
# silently seeding an empty secret. inherit_errexit propagates set -e into $( ... ).
shopt -s inherit_errexit

# Run from the repo root so `fly deploy -c fly.acp.toml` and the Docker build context resolve.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# --- Configuration -----------------------------------------------------------------------

# Target fly.io app + its config file. Dedicated + isolated -- NOT the public 'raxol' app.
readonly APP="raxol-solver"
readonly FLY_CONFIG="fly.acp.toml"

# PLACEHOLDER op:// references -- REPLACE with your real vault/item/field names.
# (../raxol is a PUBLIC repo: never commit real vault names, addresses, or tokens here.)
#
# Trusted-buyer mode: the evaluator is the agent's OWN address, so both the private key and
# the evaluator address are read from the SAME low-value agent wallet item.
readonly OP_AGENT_PRIVATE_KEY="op://Vault/Raxol ACP Agent Wallet/private-key"
readonly OP_AGENT_ADDRESS="op://Vault/Raxol ACP Agent Wallet/address"
readonly OP_XOCHI_AUTH_TOKEN="op://Vault/Xochi Worker Token/credential"
readonly OP_BASE_RPC_URL="op://Vault/Base RPC/url"

# --- Preflight ---------------------------------------------------------------------------

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf 'error: required command %q not found on PATH\n' "${cmd}" >&2
    exit 1
  fi
}

require_op_signed_in() {
  # 'op whoami' exits non-zero when no account is signed in.
  if ! op whoami >/dev/null 2>&1; then
    printf 'error: 1Password CLI is not signed in. Run: op signin\n' >&2
    exit 1
  fi
}

require_app_exists() {
  if ! fly status -a "${APP}" >/dev/null 2>&1; then
    printf 'error: fly app %q does not exist. Create it once with: fly apps create %q\n' \
      "${APP}" "${APP}" >&2
    exit 1
  fi
}

preflight() {
  require_cmd op
  require_cmd fly
  require_op_signed_in
  require_app_exists
}

# --- Deploy ------------------------------------------------------------------------------

# Stage all solver secrets from 1Password, out of argv. printf is a bash builtin, so the
# resolved plaintext never lands in another process's command line; --stage defers the
# rollout to the single `fly deploy` below. (XOCHI_BASE_URL / XOCHI_FEE_BPS / the enable
# flag are NON-secret and live in fly.acp.toml [env].)
stage_secrets() {
  printf 'Staging %d secrets into fly app %q (out of argv)...\n' 4 "${APP}"
  printf '%s\n' \
    "RAXOL_ACP_AGENT_PRIVATE_KEY=$(op read "${OP_AGENT_PRIVATE_KEY}")" \
    "RAXOL_ACP_EVALUATOR=$(op read "${OP_AGENT_ADDRESS}")" \
    "XOCHI_AUTH_TOKEN=$(op read "${OP_XOCHI_AUTH_TOKEN}")" \
    "RAXOL_ACP_RPC_URL=$(op read "${OP_BASE_RPC_URL}")" \
    | fly secrets import --stage -a "${APP}"
}

# Ship the image + fly.acp.toml [env] (incl. XOCHI_SOLVER_ENABLED) and apply the staged
# secrets, as a single-machine deploy. `fly secrets set` alone would NOT apply [env] from a
# non-default config filename, and would leave the solver flag unset (boots healthy-but-inert).
deploy_single_machine() {
  printf 'Deploying %q from %q (single machine)...\n' "${APP}" "${FLY_CONFIG}"
  fly deploy -c "${FLY_CONFIG}" -a "${APP}" --ha=false
}

# Enforce the single-machine invariant (one shared signing EOA + one SSE stream: a second
# machine would race the wallet nonce). Then show the machine list for verification.
enforce_single_machine() {
  fly scale count 1 -a "${APP}" --yes
  printf 'Deployed machines (expect exactly one started):\n'
  fly machines list -a "${APP}"
}

main() {
  preflight
  stage_secrets
  deploy_single_machine
  enforce_single_machine
  printf 'Done. raxol-solver deployed with staged secrets + fly.acp.toml [env].\n'
}

main "$@"
