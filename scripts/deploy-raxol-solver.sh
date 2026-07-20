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
#   ./scripts/deploy-raxol-solver.sh [--yes]   # --yes / ASSUME_YES=1 skips the confirm prompt

set -euo pipefail
# NB: `inherit_errexit` is deliberately NOT used -- it needs bash >= 4.4 (macOS ships
# 3.2), and it would NOT prevent an empty-secret seed anyway: a failed `op read` inside a
# printf-arg substitution is masked (printf succeeds with an empty string). stage_secrets
# resolves each secret into a CHECKED assignment instead.

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

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
  require_cmd jq
  require_op_signed_in
  require_app_exists
}

# --- Deploy ------------------------------------------------------------------------------

# Stage all solver secrets from 1Password, out of argv. printf is a bash builtin, so the
# resolved plaintext never lands in another process's command line; --stage defers the
# rollout to the single `fly deploy` below. (XOCHI_BASE_URL / XOCHI_FEE_BPS / the enable
# flag are NON-secret and live in fly.acp.toml [env].)
#
# Each op read is a discrete, CHECKED assignment before the printf -- not inlined as
# `printf "KEY=$(op read ...)"`. A failed op read inside a printf-arg substitution is
# masked (printf still succeeds with an empty string), so the inline form would silently
# stage a BLANK secret (e.g. an empty private key). Assign-then-check catches both a
# failed read and an empty value.
stage_secrets() {
  local pk evaluator auth rpc
  pk="$(op read "${OP_AGENT_PRIVATE_KEY}")"    || die "op read failed for ${OP_AGENT_PRIVATE_KEY}"
  evaluator="$(op read "${OP_AGENT_ADDRESS}")" || die "op read failed for ${OP_AGENT_ADDRESS}"
  auth="$(op read "${OP_XOCHI_AUTH_TOKEN}")"   || die "op read failed for ${OP_XOCHI_AUTH_TOKEN}"
  rpc="$(op read "${OP_BASE_RPC_URL}")"        || die "op read failed for ${OP_BASE_RPC_URL}"
  [[ -n "${pk}" && -n "${evaluator}" && -n "${auth}" && -n "${rpc}" ]] \
    || die "a resolved secret is empty; refusing to stage a blank secret"

  printf 'Staging 4 secrets into fly app %q (out of argv)...\n' "${APP}"
  printf '%s\n' \
    "RAXOL_ACP_AGENT_PRIVATE_KEY=${pk}" \
    "RAXOL_ACP_EVALUATOR=${evaluator}" \
    "XOCHI_AUTH_TOKEN=${auth}" \
    "RAXOL_ACP_RPC_URL=${rpc}" \
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
# machine would race the wallet nonce). Scale to 1, then ASSERT exactly one started
# machine and fail loudly otherwise -- never just print the list for a human to eyeball.
enforce_single_machine() {
  fly scale count 1 -a "${APP}" --yes
  local started
  started="$(fly machines list -a "${APP}" --json | jq '[.[] | select(.state == "started")] | length')" \
    || die "could not list machines for ${APP}"
  if [[ "${started}" != "1" ]]; then
    fly machines list -a "${APP}" >&2
    die "expected exactly 1 started machine, found ${started} -- a 2nd solver races the wallet nonce; scale back to 1"
  fi
  printf 'Verified: exactly one started machine.\n'
}

# Guard a live production deploy behind an interactive confirmation, unless --yes or
# ASSUME_YES=1. This deploys a real signing solver; it must not happen by accident.
confirm() {
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  printf 'Deploy the PRODUCTION signing solver %q? [y/N] ' "${APP}"
  local reply
  read -r reply || die "aborted (no confirmation)"
  [[ "${reply}" == "y" || "${reply}" == "Y" ]] || die "aborted by operator"
}

main() {
  ASSUME_YES=0
  local arg
  for arg in "$@"; do
    [[ "${arg}" == "--yes" || "${arg}" == "-y" ]] && ASSUME_YES=1
  done
  preflight
  confirm
  stage_secrets
  deploy_single_machine
  enforce_single_machine
  printf 'Done. raxol-solver deployed with staged secrets + fly.acp.toml [env].\n'
}

main "$@"
