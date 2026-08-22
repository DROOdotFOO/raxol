#!/usr/bin/env bash
# Unified live-settlement gate for the stablecoin cross-chain launch.
#
# One entrypoint drives every asset across every route. It replaces the four
# per-package gates (run_live_xochi_gate.sh, run_live_acp_order_gate.sh,
# run_live_robinhood_gate.sh, run_live_relay_gate.sh).
#
#   scripts/run_live_gates.sh --asset ASSET[,ASSET...] [--route ROUTE[,ROUTE...]]
#
# ASSETS (stablecoins only for launch): USDC, USDT, USDG (or "all").
# ROUTES (default all): xochi, acp, relay (or "all").
#   xochi -- direct Xochi intent path (api.xochi.fi). Agent quotes/signs/executes
#            and polls, moving funds itself. Runs the raxol_payments matrix test.
#   acp   -- another agent ORDERS our cross-chain service through the ACP; the
#            seller settles on delivery. Runs the raxol_earn order test.
#   relay -- EVM->Tron rail via the Riddler solver (riddler.axol.io/relay). Runs
#            the raxol_earn relay test. Tron-settled, so USDC/USDT only.
#   fee   -- take-rate validation (opt-in; NOT in "all"). Drives the real
#            SolverAgent: a buyer signs a live Xochi intent for a known
#            principal, the solver proposes the budget, and the test asserts the
#            on-chain setBudget == GATE_FEE_BPS (default 8) bps of the principal.
#            Moves NO funds (off-chain signature + captured on-chain write), but
#            needs a real GATE_KEY to sign. Runs the raxol_earn solver-fee test.
#
# The asset x route grid, and the corridor each cell rides, is fixed here to
# match what Riddler and Xochi actually support (see the asset_cfg table):
#   USDC  ERC-3009 pull, CCTP full mesh. Base->Arbitrum by default.
#   USDT  Permit2 pull, Arbitrum<->Polygon corridors (NOT Base, no USDT there).
#   USDG  Permit2 pull, Robinhood Chain (4663) DRAIN only: 4663 USDG -> USDC on a
#         hub (Base/Arbitrum). Expressed as token USDC over a 4663-origin corridor;
#         the test's leg_symbol maps the 4663 leg to USDG. USDG has no Tron leg,
#         so USDG x relay is skipped.
#
# LAUNCH STATUS (server side, from riddler docs):
#   USDC is the one clean rail today (ERC-3009, funded, unblocked).
#   USDT/USDG pull via Permit2 with a bare-EOA spender, which trips wallet
#   scam warnings; their public launch is gated on riddler's XochiPullPermit2
#   verified-spender contract (PR #639, unmerged) plus front-run reconciliation.
#   USDT is also unfunded on the solver. Selecting them is allowed for dry-run
#   rehearsal; a funded run prints the gate warning first.
#
# SAFETY: a funded run MOVES REAL FUNDS. --dry-run does read-only preflight only.
#   Preflight per route: xochi/acp quote every cell read-only and assert can_solve
#   plus the pinned origin-pull solver; relay probes /relay/quote. Nothing signs.
#
# SECRETS / INPUTS (env):
#   GATE_KEY              funded private key (all routes share it). A funded run
#                         requires it; dry-run defaults it to 0xdummy.
#   GATE_XOCHI_TOKEN      Xochi Member service token; else read from 1Password
#                         (OP_XOCHI_TOKEN_REF). Needed for xochi + acp routes.
#   GATE_RELAY_TOKEN      Tron relay API token; else 1Password (OP_RELAY_TOKEN_REF).
#                         Needed for the relay route.
#   GATE_RPC_<chainid>    JSON-RPC URL per chain. Required to SETTLE a Permit2
#                         asset (USDT needs GATE_RPC_42161; USDG needs GATE_RPC_4663)
#                         on the acp route, and for the relay source chain.
#   GATE_FROM_ADDRESS     EVM source address for the relay quote probe.
#   GATE_PULL_SPENDER     the Permit2 spender the acp route may grant an origin
#                         allowance to. REQUIRED to SETTLE a cell whose quote
#                         pulls via Permit2; there is no default, because Permit2
#                         has no on-chain recipient guard and the allowance is
#                         what makes that address able to move the origin
#                         balance. A Permit2 cell SKIPs without it. Take it from
#                         Riddler's XochiPull deployment record -- it is the pull
#                         proxy, not GATE_SOLVER's settlement wallet.
#   GATE_TRON_ADDRESS     Tron recipient WALLET for the relay route. REQUIRED to
#                         probe or settle relay; there is no default, because a
#                         Tron settlement is final and the destination token
#                         contract is a well-formed address that would swallow
#                         the funds. A relay cell SKIPs without it.
#
# FLAGS:
#   --asset A[,A...]      REQUIRED. USDC|USDT|USDG|all
#   --route R[,R...]      xochi|acp|relay|all (default all)
#   --amount N            human stablecoin amount for xochi/acp (default 5.00;
#                         kept above the ~$3 zone where sub-$3 orders can 500)
#   --corridors SPEC      override the per-asset corridor(s), "from>to,from>to"
#                         or "mesh". Applies to xochi + acp.
#   --auth mandate|member Xochi auth mode (default mandate). xochi route only.
#   --dry-run             read-only preflight for every cell, NO funds move
#   --yes                 skip the funded-run confirmation prompt (for CI/GATE_YES=1)
#   -h, --help            this help
#
# A funded run (no --dry-run) prints the plan and a worst-case spend ceiling, then
# asks for confirmation (type "yes", or pass --yes). Every cell runs in isolation:
# one cell failing does not abort the rest. A results matrix (PASS/SKIP/FAIL) is
# printed at the end, and the gate exits non-zero if any cell failed. --corridors
# applies to one asset at a time (per-asset defaults otherwise).
#
# EXAMPLES:
#   # Rehearse the whole grid, no funds:
#   GATE_FROM_ADDRESS=0x<addr> ./scripts/run_live_gates.sh --asset all --dry-run
#
#   # Launch rail: real USDC across all three routes:
#   GATE_KEY=0x<funded> GATE_FROM_ADDRESS=0x<addr> GATE_RPC_8453=https://mainnet.base.org \
#   GATE_TRON_ADDRESS=T<your Tron wallet> \
#     ./scripts/run_live_gates.sh --asset USDC
#
#   # Just the ACP order path for USDC:
#   GATE_KEY=0x<funded> ./scripts/run_live_gates.sh --asset USDC --route acp
#
#   # Validate the live take-rate is 8 bps (NO funds; needs a real signing key):
#   GATE_KEY=0x<key> GATE_FEE_BPS=8 ./scripts/run_live_gates.sh --asset USDC --route fee
#
#   # USDG drain rehearsal (Robinhood -> Base), acp route:
#   GATE_KEY=0x<funded seller w/ USDG on 4663> GATE_RPC_4663=https://rpc.mainnet.chain.robinhood.com \
#     ./scripts/run_live_gates.sh --asset USDG --route xochi,acp --dry-run
set -euo pipefail

CANONICAL_SOLVER="0x97D447561fDe10E959E782a29411D8F89586d80b"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYMENTS_DIR="$REPO_ROOT/packages/raxol_payments"
ACP_DIR="$REPO_ROOT/packages/raxol_earn"

XOCHI_TEST="test/raxol/payments/xochi/live_xochi_test.exs"
ORDER_TEST="test/raxol/earn/xochi/live_order_test.exs"
RELAY_TEST="test/raxol/earn/relay/live_relay_test.exs"
SOLVER_FEE_TEST="test/raxol/earn/xochi/solver_fee_live_test.exs"

# --- defaults / env inputs ---
ASSETS=""
ROUTES="xochi,acp,relay"
AMOUNT="${GATE_AMOUNT:-5.00}"
RELAY_AMOUNT="${GATE_RELAY_AMOUNT:-0.10}"
CORRIDORS_OVERRIDE=""
AUTH="${GATE_AUTH:-mandate}"
DRY_RUN="${DRY_RUN:-}"
ASSUME_YES="${GATE_YES:-0}"

XOCHI_URL="${GATE_XOCHI_URL:-https://api.xochi.fi}"
RELAY_URL="${GATE_RELAY_URL:-https://riddler.axol.io}"
OP_XOCHI_TOKEN_REF="${OP_XOCHI_TOKEN_REF:-op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential}"
OP_RELAY_TOKEN_REF="${OP_RELAY_TOKEN_REF:-op://Employee/Riddler Tron Relay API Token/password}"

log()  { printf '%s\n' "$*" >&2; }
err()  { printf 'error: %s\n' "$*" >&2; }
rule() { printf -- '----------------------------------------------------------------\n' >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: scripts/run_live_gates.sh --asset A[,A...] [--route R[,R...]] [options]

  --asset   USDC|USDT|USDG|all      (required)
  --route   xochi|acp|relay|fee|all (default all; fee is opt-in, fund-free)
  --amount  N                    human stablecoin amount for xochi/acp (default 5.00)
  --corridors SPEC               override corridors, "from>to,from>to" or "mesh"
  --auth    mandate|member       Xochi auth mode (default mandate)
  --dry-run                      read-only preflight, no funds move
  --yes                          skip the funded-run confirmation prompt (for CI)
  -h, --help                     full docs are in the file header

Secrets via env: GATE_KEY, GATE_XOCHI_TOKEN, GATE_RELAY_TOKEN,
GATE_RPC_<chainid> (e.g. GATE_RPC_42161), GATE_FROM_ADDRESS,
GATE_PULL_SPENDER (Permit2 allowance pin; Permit2 cells SKIP without it),
GATE_TRON_ADDRESS (relay recipient wallet; relay cells SKIP without it).
EOF
}

# --- arg parse ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --asset)      ASSETS="$2"; shift 2 ;;
    --route)      ROUTES="$2"; shift 2 ;;
    --amount)     AMOUNT="$2"; shift 2 ;;
    --corridors)  CORRIDORS_OVERRIDE="$2"; shift 2 ;;
    --auth)       AUTH="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --yes)        ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) err "unknown flag: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$ASSETS" ]]; then
  err "pass --asset USDC|USDT|USDG|all (comma-separated for several)"
  usage
  exit 2
fi

[[ "$ASSETS" == "all" ]] && ASSETS="USDC,USDT,USDG"
[[ "$ROUTES" == "all" ]] && ROUTES="xochi,acp,relay"

# csv -> space-separated, uppercased for assets / lowercased for routes
ASSET_LIST="$(printf '%s' "$ASSETS" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')"
ROUTE_LIST="$(printf '%s' "$ROUTES" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')"

for a in $ASSET_LIST; do
  case "$a" in USDC|USDT|USDG) ;; *) err "unknown asset: $a (want USDC|USDT|USDG)"; exit 2 ;; esac
done
for r in $ROUTE_LIST; do
  case "$r" in xochi|acp|relay|fee) ;; *) err "unknown route: $r (want xochi|acp|relay|fee)"; exit 2 ;; esac
done

# --- input validation (cheap, before any work) ---
case "$AUTH" in
  mandate|member) ;;
  *) err "--auth must be mandate|member (got: $AUTH)"; exit 2 ;;
esac

if ! [[ "$AMOUNT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  err "--amount must be a positive decimal (got: $AMOUNT)"; exit 2
fi
awk -v a="$AMOUNT" 'BEGIN { exit !(a > 0) }' || { err "--amount must be > 0"; exit 2; }
if awk -v a="$AMOUNT" 'BEGIN { exit !(a < 3) }'; then
  log "WARNING: --amount $AMOUNT is under ~3 USDC; sub-\$3 orders can 500 from the solver."
fi

# --corridors is per-asset: a single corridor set cannot be right for USDC (mesh),
# USDG (4663 drain), and USDT (arb/poly) at once. Refuse it when several assets
# are selected; run one asset at a time to override its corridor.
read -ra _assets_arr <<<"$ASSET_LIST"
if [[ -n "$CORRIDORS_OVERRIDE" && "${#_assets_arr[@]}" -gt 1 ]]; then
  err "--corridors applies to one asset at a time; you selected: $ASSET_LIST"
  err "run each asset separately, or omit --corridors to use per-asset defaults."
  exit 2
fi

# --- per-asset config: token_symbol | default_corridors | permit2(0/1) | permit2_chain ---
# permit2_chain is the origin chain whose Permit2 allowance the acp route must
# broadcast (needs GATE_RPC_<chain>). USDC pulls via ERC-3009, so none.
asset_cfg() {
  case "$1" in
    USDC) printf 'USDC|8453>42161|0|'      ;;
    USDT) printf 'USDT|42161>137|1|42161'  ;;
    USDG) printf 'USDC|4663>8453|1|4663'   ;;
  esac
}

# --- relay origin config: from_chain | token_symbol. USDG has no Tron leg. ---
relay_cfg() {
  case "$1" in
    USDC) printf '8453|USDC' ;;
    USDT) printf '8453|USDT' ;;
    USDG) return 1 ;;
  esac
}

rpc_for() { local v="GATE_RPC_$1"; printf '%s' "${!v:-}"; }

# The settleable EVM chains, matching @evm_chains in live_order_test.exs. A cell
# originating on any of them needs an endpoint for the pull-signature preflight
# to have anything to ask.
ORDER_RPC_CHAINS="1 10 137 8453 42161 4663"

# Hand every configured GATE_RPC_<chain> through as XOCHI_ORDER_RPC_<chain>, and
# say out loud which chains have none. A cell whose origin has no endpoint
# reports "pull preflight: skipped" -- which reads exactly like a check that
# passed unless the absence is announced up front.
export_order_rpcs() {
  local asset="$1" c rpc found=false missing=""
  for c in $ORDER_RPC_CHAINS; do
    rpc="$(rpc_for "$c")"
    if [[ -n "$rpc" ]]; then
      export "XOCHI_ORDER_RPC_$c=$rpc"
      found=true
    else
      missing="$missing $c"
    fi
  done

  if [[ "$found" == false ]]; then
    log "acp $asset: NOTE -- no GATE_RPC_<chain> is set, so the pull-signature"
    log "             preflight SKIPS every cell and checks nothing. Set at least"
    log "             GATE_RPC_8453 to have the rehearsal verify what it signs."
  elif [[ -n "$missing" ]]; then
    log "acp $asset: no endpoint for chain(s):$missing -- cells originating there"
    log "             skip the pull-signature check."
  fi
}

# --- secret loading (lazy: only what the selected routes need) ---
need_xochi=false; need_relay=false
for r in $ROUTE_LIST; do
  case "$r" in xochi|acp|fee) need_xochi=true ;; relay) need_relay=true ;; esac
done

# Funded key: required for a real run; dummy is fine for dry-run (tests compile
# on its presence but never sign under preflight-only).
KEY="${GATE_KEY:-}"
if [[ -z "$KEY" ]]; then
  if [[ -n "$DRY_RUN" ]]; then KEY="0xdummy"; else
    err "set GATE_KEY to a funded private key (or pass --dry-run)"; exit 2
  fi
fi

load_op() {  # ref -> value on stdout, via 1Password
  if ! command -v op >/dev/null 2>&1; then
    err "op CLI not found; set the token env var directly"; exit 2
  fi
  op read "$1"
}

XOCHI_TOKEN="${GATE_XOCHI_TOKEN:-}"
if [[ "$need_xochi" == true && -z "$XOCHI_TOKEN" ]]; then
  log "reading Xochi Member token from 1Password ($OP_XOCHI_TOKEN_REF)..."
  XOCHI_TOKEN="$(load_op "$OP_XOCHI_TOKEN_REF")"
fi

RELAY_TOKEN="${GATE_RELAY_TOKEN:-}"
if [[ "$need_relay" == true && -z "$RELAY_TOKEN" ]]; then
  log "reading Tron relay token from 1Password ($OP_RELAY_TOKEN_REF)..."
  RELAY_TOKEN="$(load_op "$OP_RELAY_TOKEN_REF")"
fi

# The relay quote probe (every relay cell, dry-run included) needs an EVM source.
if [[ "$need_relay" == true && -z "${GATE_FROM_ADDRESS:-}" && -z "${RELAY_LIVE_FROM_ADDRESS:-}" ]]; then
  err "relay route needs GATE_FROM_ADDRESS (the EVM source address)"; exit 2
fi

# --- server-gate warning for the Permit2 stables ---
gated_selected=false
for a in $ASSET_LIST; do case "$a" in USDT|USDG) gated_selected=true ;; esac; done
if [[ "$gated_selected" == true ]]; then
  rule
  log "NOTE: USDT/USDG pull via Permit2. Public launch is gated on riddler's"
  log "verified-spender contract (XochiPullPermit2, PR #639) + front-run"
  log "reconciliation; USDT is also unfunded on the solver. A funded run may be"
  log "declined server-side. Set the solver pin (XOCHI_*_SOLVER_PIN stays on by"
  log "default) and confirm funding before treating a pass as launch-ready."
  rule
fi

# ================= route runners =================

run_xochi() {
  local asset="$1" cfg tok corr p2 _p2chain corridors
  cfg="$(asset_cfg "$asset")"
  IFS='|' read -r tok corr p2 _p2chain <<<"$cfg"
  corridors="${CORRIDORS_OVERRIDE:-$corr}"

  export XOCHI_LIVE_URL="$XOCHI_URL" XOCHI_LIVE_KEY="$KEY" XOCHI_LIVE_TOKEN="$XOCHI_TOKEN"
  export XOCHI_LIVE_AUTH="$AUTH" XOCHI_LIVE_AMOUNT="$AMOUNT"
  export XOCHI_LIVE_MATRIX=true XOCHI_LIVE_SETTLEMENTS=public
  export XOCHI_LIVE_CORRIDORS="$corridors" XOCHI_LIVE_TOKENS="$tok"
  export XOCHI_LIVE_SOLVER="${GATE_SOLVER:-$CANONICAL_SOLVER}"
  if [[ "$p2" == "1" ]]; then export XOCHI_LIVE_SETTLE_PERMIT2=true; else unset XOCHI_LIVE_SETTLE_PERMIT2; fi

  cd "$PAYMENTS_DIR"
  log "xochi preflight: quote [$corridors] token=$tok read-only (no funds)..."
  env MIX_ENV=test mix test --only live_xochi_preflight "$XOCHI_TEST"
  [[ -n "$DRY_RUN" ]] && { log "xochi $asset: dry-run preflight passed, no funds moved."; return 0; }
  log "xochi settle: fillable subset of [$corridors] token=$tok (REAL funds)..."
  env MIX_ENV=test mix test --only live_xochi_matrix "$XOCHI_TEST"
}

run_acp() {
  local asset="$1" cfg tok corr p2 p2chain corridors rpc
  cfg="$(asset_cfg "$asset")"
  IFS='|' read -r tok corr p2 p2chain <<<"$cfg"
  corridors="${CORRIDORS_OVERRIDE:-$corr}"

  export XOCHI_ORDER_LIVE_URL="$XOCHI_URL" XOCHI_ORDER_LIVE_KEY="$KEY" XOCHI_ORDER_LIVE_TOKEN="$XOCHI_TOKEN"
  export XOCHI_ORDER_AMOUNT="$AMOUNT"
  export XOCHI_ORDER_CORRIDORS="$corridors" XOCHI_ORDER_TOKENS="$tok"
  export XOCHI_ORDER_SOLVER="${GATE_SOLVER:-$CANONICAL_SOLVER}"
  # The Permit2 allowance pin is separate and deliberately undefaulted: it names
  # the spender an ERC-20 approve would make able to pull the origin balance, and
  # Permit2 bounds the destination nowhere on-chain. Unset, Permit2 cells SKIP.
  if [[ -n "${GATE_PULL_SPENDER:-}" ]]; then
    export XOCHI_ORDER_PULL_SPENDER="$GATE_PULL_SPENDER"
  else
    unset XOCHI_ORDER_PULL_SPENDER
  fi
  # Order the launch offering (xochi_stable_public) under its real corridor scope:
  # each asset's default corridor above is on the CorridorAllowlist.
  export XOCHI_ORDER_STABLECOIN_ALLOWLIST=true

  # Origin-chain endpoints for the read-only pull-signature preflight. This used
  # to be exported only for a Permit2 asset, where it was needed to broadcast the
  # allowance -- so on USDC (p2=0, and the LIVE launch asset) no endpoint was
  # ever set and the preflight reported "skipped" on every cell. The check needs
  # an endpoint for whichever chain a cell ORIGINATES on, which is independent of
  # the allowance question below.
  export_order_rpcs "$asset"

  if [[ "$p2" == "1" ]]; then
    rpc="$(rpc_for "$p2chain")"
    if [[ -z "$rpc" && -z "$DRY_RUN" ]]; then
      log "acp $asset: SKIP settle -- Permit2 origin needs GATE_RPC_$p2chain to"
      log "             broadcast the allowance. Set it, or run --dry-run."
      return 10
    fi
  fi

  cd "$ACP_DIR"
  log "acp preflight: offering discovery + read-only quote [$corridors] token=$tok..."
  env MIX_ENV=test mix test --only live_xochi_order_preflight "$ORDER_TEST"
  [[ -n "$DRY_RUN" ]] && { log "acp $asset: dry-run preflight passed, no funds moved."; return 0; }
  log "acp settle: order + settle fillable subset of [$corridors] token=$tok (REAL funds)..."
  env MIX_ENV=test mix test --only live_xochi_order_settle "$ORDER_TEST"
}

run_relay() {
  local asset="$1" cfg from_chain tok atomic body code
  if ! cfg="$(relay_cfg "$asset")"; then
    log "relay $asset: SKIP -- no Tron leg for $asset (relay settles to Tron USDT)."
    return 10
  fi
  IFS='|' read -r from_chain tok <<<"$cfg"

  local from_addr="${GATE_FROM_ADDRESS:-${RELAY_LIVE_FROM_ADDRESS:-}}"

  # Resolve the origin token address for the read-only quote probe. Base is the
  # default source; both USDC and USDT there are 6-decimal. tron_usdt is the
  # public TRC-20 destination contract (the @usdt_tron constant used repo-wide).
  local tron_usdt="TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  local to_token="$tron_usdt"
  local from_token
  case "$asset" in
    USDC) from_token="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" ;;
    USDT) from_token="0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2" ;;
  esac

  # The Tron recipient is a WALLET and there is no safe default: a Tron
  # settlement is final, and the destination TOKEN contract is a well-formed
  # base58 address the relay would settle to and nobody could spend back out.
  local to_addr="${GATE_TRON_ADDRESS:-}"
  if [[ -z "$to_addr" ]]; then
    log "relay $asset: SKIP -- set GATE_TRON_ADDRESS to the Tron recipient wallet"
    log "             you control. There is no default; a Tron settlement is final."
    return 10
  fi
  if [[ "$to_addr" == "$to_token" ]]; then
    err "relay $asset: GATE_TRON_ADDRESS is the destination token contract, not a"
    err "             wallet. Funds settled there are unrecoverable. No funds moved."
    return 1
  fi

  atomic="$(awk -v a="$RELAY_AMOUNT" 'BEGIN { printf "%d", a * 1000000 }')"
  body="$(printf '{"transfer_id":"probe","from_chain_id":%s,"to_chain_id":728126428,"from_token":"%s","to_token":"%s","from_amount":"%s","from_address":"%s","to_address":"%s","slippage_bps":50}' \
    "$from_chain" "$from_token" "$to_token" "$atomic" "$from_addr" "$to_addr")"

  log "relay preflight: probing /relay/quote for $tok (read-only, no funds)..."
  code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
    -X POST "$RELAY_URL/relay/quote" \
    -H "authorization: Bearer $RELAY_TOKEN" \
    -H 'content-type: application/json' \
    -d "$body" || true)"
  if [[ "$code" != "200" ]]; then
    err "relay $asset: /relay/quote returned http ${code:-none}. Fix endpoint/token. No funds moved."
    return 1
  fi
  log "relay preflight ok (http 200)."
  [[ -n "$DRY_RUN" ]] && { log "relay $asset: dry-run probe passed, no funds moved."; return 0; }

  local rpc; rpc="$(rpc_for "$from_chain")"
  if [[ -z "$rpc" ]]; then
    log "relay $asset: SKIP settle -- needs GATE_RPC_$from_chain to broadcast the deposit."
    return 10
  fi
  export RELAY_LIVE_URL="$RELAY_URL" RELAY_LIVE_TOKEN="$RELAY_TOKEN"
  export RELAY_LIVE_KEY="$KEY" RELAY_LIVE_RPC="$rpc" RELAY_LIVE_FROM_ADDRESS="$from_addr"
  export RELAY_LIVE_FROM_CHAIN="$from_chain" RELAY_LIVE_TOKENS="$tok" RELAY_LIVE_AMOUNT="$RELAY_AMOUNT"
  export RELAY_LIVE_TO_ADDRESS="$to_addr"

  cd "$ACP_DIR"
  # The whole module runs, and the settle test and the resume test each broadcast
  # one deposit of $tok -- which is what estimate_spend counts.
  log "relay settle: EVM($from_chain) $tok -> Tron USDT at $to_addr"
  log "              (REAL, broadcasts two deposits of $RELAY_AMOUNT: settle + resume)..."
  env MIX_ENV=test mix test --include live_relay "$RELAY_TEST"
}

# Take-rate validation. Drives the REAL SolverAgent: a buyer signs a live Xochi
# intent for a known principal, the solver resolves the authoritative amount off
# Xochi and proposes the budget, and the test asserts the on-chain setBudget
# calldata == GATE_FEE_BPS (default 8) bps of the principal. Moves NO funds --
# the intent signature is off-chain and the on-chain write is captured, not sent
# -- so it runs the same whether or not --dry-run is set. It DOES need a real
# signing key (a valid EOA; funding not required) to produce the intent.
run_fee() {
  local asset="$1" cfg tok corr _p2 _pc corridors
  cfg="$(asset_cfg "$asset")"
  IFS='|' read -r tok corr _p2 _pc <<<"$cfg"
  corridors="${CORRIDORS_OVERRIDE:-$corr}"

  if [[ "$KEY" == "0xdummy" ]]; then
    log "fee $asset: SKIP -- needs a real GATE_KEY to sign the intent (no funds move)."
    return 10
  fi

  export XOCHI_ORDER_LIVE_URL="$XOCHI_URL" XOCHI_ORDER_LIVE_KEY="$KEY" XOCHI_ORDER_LIVE_TOKEN="$XOCHI_TOKEN"
  export XOCHI_ORDER_AMOUNT="$AMOUNT" XOCHI_ORDER_CORRIDORS="$corridors"
  export XOCHI_FEE_BPS="${GATE_FEE_BPS:-8}"

  cd "$ACP_DIR"
  log "fee $asset: assert on-chain budget == ${XOCHI_FEE_BPS} bps of the live-signed principal [$corridors] (NO funds)..."
  env MIX_ENV=test mix test --only live_solver_fee "$SOLVER_FEE_TEST"
}

# The routes that actually settle (and so gate on the funded-run confirmation).
# `fee` is fund-free, so a fee-only run skips the prompt.
has_settling_route() {
  local r
  for r in $ROUTE_LIST; do
    case "$r" in xochi|acp|relay) return 0 ;; esac
  done
  return 1
}

# ================= plan / spend preview =================
# corridor count for a spec: a "from>to" pair has one '>', mesh is the 5-chain
# CCTP grid (20 ordered pairs).
corridor_count() {
  local spec="$1"
  [[ "$spec" == "mesh" ]] && { printf '20'; return; }
  local only_gt="${spec//[^>]/}"
  printf '%s' "${#only_gt}"
}

# Worst-case funded spend: per-corridor amount x corridor count over settling
# cells (relay is a single corridor at RELAY_AMOUNT, but its module broadcasts
# two deposits: the settle test and the resume test). This is a CEILING -- the
# tests settle only the fillable subset, so real spend is usually lower.
estimate_spend() {
  local a r tok corr _p2 _pc eff n
  local -a pairs=()
  for a in $ASSET_LIST; do
    IFS='|' read -r tok corr _p2 _pc <<<"$(asset_cfg "$a")"
    eff="${CORRIDORS_OVERRIDE:-$corr}"
    for r in $ROUTE_LIST; do
      case "$r" in
        xochi|acp) n="$(corridor_count "$eff")"; pairs+=("$AMOUNT $n") ;;
        relay)     [[ "$a" == "USDG" ]] && continue; pairs+=("$RELAY_AMOUNT 2") ;;
      esac
    done
  done
  [[ ${#pairs[@]} -eq 0 ]] && { printf '0.00'; return; }
  printf '%s\n' "${pairs[@]}" | awk '{ s += $1 * $2 } END { printf "%.2f", s }'
}

confirm_funded() {
  local a r tok corr _p2 _pc eff est
  rule
  log "FUNDED RUN PLAN (this MOVES REAL FUNDS):"
  for a in $ASSET_LIST; do
    IFS='|' read -r tok corr _p2 _pc <<<"$(asset_cfg "$a")"
    eff="${CORRIDORS_OVERRIDE:-$corr}"
    for r in $ROUTE_LIST; do
      case "$r" in
        relay)
          if [[ "$a" == "USDG" ]]; then
            log "  $a / relay  -> skip (no Tron leg)"
          else
            log "  $a / relay  -> Base $tok -> Tron USDT at ${GATE_TRON_ADDRESS:-<unset: cell skips>}"
            log "                 two deposits of ~$RELAY_AMOUNT (settle + resume)"
          fi ;;
        fee) log "  $a / fee  -> take-rate check [$eff] (NO funds)" ;;
        *) log "  $a / $r  -> [$eff] token=$tok (~$AMOUNT/corridor)" ;;
      esac
    done
  done
  est="$(estimate_spend)"
  log "worst-case ceiling: ~$est (per-corridor amount x corridors; settles only the fillable subset)."
  rule
  if [[ "$ASSUME_YES" == "1" ]]; then log "--yes given: proceeding without prompt."; return 0; fi
  if [[ -t 0 ]]; then
    local ans
    read -r -p "Proceed with REAL funds? type 'yes' to continue: " ans
    [[ "$ans" == "yes" ]] || { log "aborted, no funds moved."; exit 130; }
  else
    err "funded run needs confirmation. Re-run with --yes to proceed non-interactively."
    exit 2
  fi
}

# ================= drive the grid =================
RESULTS=()
ANY_FAIL=0

# Each cell runs in a subshell so its exports/cwd never leak into the next, and a
# failure is captured (not fatal) -- the whole grid runs and the matrix shows what
# passed, skipped, or failed. SKIP is signalled by return code 10.
run_cell() {
  local asset="$1" route="$2" rc=0
  rule
  log "CELL asset=$asset route=$route${DRY_RUN:+  (dry-run)}"
  # NOTE: `( set -e; ... ) || rc=$?` would DISABLE errexit inside the subshell
  # (bash quirk: a subshell tested by || ignores -e). Suspend errexit in the
  # parent, run the untested subshell so its own `set -e` is honoured (a failed
  # step aborts the cell), then capture the code and restore errexit.
  set +e
  (
    set -e
    case "$route" in
      xochi) run_xochi "$asset" ;;
      acp)   run_acp   "$asset" ;;
      relay) run_relay "$asset" ;;
      fee)   run_fee   "$asset" ;;
    esac
  )
  rc=$?
  set -e
  case "$rc" in
    0)  RESULTS+=("$asset|$route|PASS") ;;
    10) RESULTS+=("$asset|$route|SKIP") ;;
    *)  RESULTS+=("$asset|$route|FAIL"); ANY_FAIL=1 ;;
  esac
}

[[ -z "$DRY_RUN" ]] && has_settling_route && confirm_funded

log "live gates: assets=[$ASSET_LIST] routes=[$ROUTE_LIST] amount=$AMOUNT auth=$AUTH${DRY_RUN:+ dry-run}"
for asset in $ASSET_LIST; do
  for route in $ROUTE_LIST; do
    run_cell "$asset" "$route"
  done
done

rule
log "RESULTS:"
for row in "${RESULTS[@]}"; do
  IFS='|' read -r a r st <<<"$row"
  printf '  %-5s %-6s %s\n' "$a" "$r" "$st" >&2
done
rule
if [[ "$ANY_FAIL" == "1" ]]; then
  log "done WITH FAILURES -- see the matrix above."
  exit 1
elif [[ -n "$DRY_RUN" ]]; then
  log "done: every selected cell preflighted clean or was skipped, no funds moved."
else
  log "done: every settling cell passed or was skipped, no hard failures."
fi
