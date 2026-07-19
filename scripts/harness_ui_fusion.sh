#!/usr/bin/env bash
# Harness UI fusion rebuild (methodology R3/R5). Idempotent, throwaway output.
# Usage: harness_ui_fusion.sh <fusion-worktree-path> <fusion-set-file>
# fusion-set-file: one branch name per line (the in-flight changeset branches).
set -euo pipefail

FUSION_WT="${1:?fusion worktree path}"
SET_FILE="${2:?fusion set file}"

git -C "$FUSION_WT" fetch origin
git -C "$FUSION_WT" checkout -B harness-ui-fusion origin/master

while IFS= read -r b; do
  [ -z "$b" ] && continue
  case "$b" in \#*) continue;; esac
  git -C "$FUSION_WT" checkout mix.lock 2>/dev/null || true
  if ! git -C "$FUSION_WT" merge --no-ff --no-edit "$b"; then
    echo "FUSION CONFLICT: $b — fix the changeset, not the merge (R3)" >&2
    exit 1
  fi
  if ! git -C "$FUSION_WT" merge-base --is-ancestor "$b" HEAD; then
    echo "MERGE DID NOT LAND: $b (R5)" >&2
    exit 1
  fi
done < "$SET_FILE"

if grep -rn '^<<<<<<<' --include='*.ex' --include='*.exs' "$FUSION_WT/lib" "$FUSION_WT/test" 2>/dev/null | head -5 | grep -q .; then
  echo "CONFLICT MARKERS PRESENT (R4)" >&2
  exit 1
fi

echo "fusion OK: $(git -C "$FUSION_WT" rev-parse --short HEAD)"
