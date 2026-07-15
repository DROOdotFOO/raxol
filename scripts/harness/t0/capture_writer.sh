#!/usr/bin/env bash
# T0 — capability capture writer.
#
# Writes one capture/<terminal>-<context>.json file conforming EXACTLY to
# the fixture schema in
# docs/proposals/in-flight/harness-ui-testing/04-capability.md §2
# (`raxol.capability.capture/1`) -- these files are what T1's
# `Raxol.Test.CapabilityFixtures.load!/1` will read once T1 lands (per
# that doc's §10.3: "T0 writes here"). Written under scripts/harness/t0/
# (this unit's write-set) rather than test/fixtures/capability/capture/
# directly -- T1's builder copies/symlinks these in when the loader exists;
# see t0-runbook.md.
#
# Usage:
#   capture_writer.sh TERMINAL CONTEXT TERM_VERSION QUERY_HEX REPLY_HEX \
#                      NOTES [ENV_JSON]
#   CONTEXT: bare | tmux | ssh | ssh+tmux
#   ENV_JSON: optional JSON object literal (default: minimal TERM-only env)
#
# Output: scripts/harness/t0/capture/<terminal>-<context>.json
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

terminal="${1:?terminal required}"
context="${2:?context required}"
terminal_version="${3:-unknown}"
query_hex="${4:-}"
reply_hex="${5:-}"
notes="${6:-}"
env_json="${7:-null}"
# Optional filename slug override -- used for synthetic edge fixtures where
# `context` must stay a valid enum (bare|tmux|ssh|ssh+tmux) but the file
# needs to name the constructed condition (04-capability.md §2: "hand-
# authored edge fixtures ... live in capture/synthetic-*.json").
slug="${8:-$context}"

out_dir="$HERE/capture"
mkdir -p "$out_dir"
out_file="$out_dir/${terminal}-${slug}.json"

jq -n \
  --arg schema "raxol.capability.capture/1" \
  --arg terminal "$terminal" \
  --arg terminal_version "$terminal_version" \
  --arg context "$context" \
  --arg query_hex "$query_hex" \
  --arg reply_hex "$reply_hex" \
  --arg notes "$notes" \
  --argjson env "$env_json" \
  '{
    schema: $schema,
    terminal: $terminal,
    terminal_version: $terminal_version,
    context: $context,
    env: $env,
    query_hex: $query_hex,
    reply_hex: $reply_hex,
    notes: $notes,
    expected: null,
    expected_tier: null
  }' > "$out_file"

echo "wrote $out_file" >&2
