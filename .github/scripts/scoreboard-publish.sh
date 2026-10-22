#!/usr/bin/env bash
# Adds scoreboard records to the gh-pages branch and pushes, rebuilding on top
# of a concurrent push. Used by scoreboard.yml (one master record per CI run)
# and scoreboard-backfill.yml (records of older master commits).
#
#   scoreboard-publish.sh RUN_ID SUBJECT RECORD...
#
# Run from a checkout of the default branch with its full history, with
# DEFAULT_BRANCH and RUNNER_TEMP set. Validate each RECORD first
# (`scoreboard.mjs validate`); this only appends.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: scoreboard-publish.sh RUN_ID SUBJECT RECORD..." >&2
  exit 2
fi
run_id=$1
subject=$2
shift 2
records=("$@")

root=$(git rev-parse --show-toplevel)
scoreboard="$root/.github/scripts/scoreboard.mjs"
defs="$root/priv/scoreboard/metrics.json"
pages="$RUNNER_TEMP/gh-pages"
order="$RUNNER_TEMP/order.txt"

status=0
git ls-remote --exit-code --heads origin gh-pages > /dev/null || status=$?
if [ "$status" -eq 0 ]; then
  git fetch --no-tags origin +refs/heads/gh-pages:refs/remotes/origin/gh-pages
  git worktree add -B gh-pages "$pages" origin/gh-pages
elif [ "$status" -eq 2 ]; then
  echo "::notice::Creating orphan gh-pages branch"
  git worktree add --detach "$pages"
  git -C "$pages" checkout --orphan gh-pages
  git -C "$pages" rm -rf --quiet .
else
  echo "::error::git ls-remote failed with status $status"
  exit "$status"
fi

# Applies the records on top of whatever gh-pages holds now and sets
# changed=1 when that produced a commit to push. Called directly, never from
# a condition or $(...), so `bash -e` still stops on errors.
build() {
  changed=0
  cat > "$pages/README.md" <<'EOF'
# Scoreboard data

Written by `.github/workflows/scoreboard.yml` on master, and by
`scoreboard-backfill.yml` for master commits from before the scoreboard
existed; do not edit by hand.

- `scoreboard/records.jsonl`: one JSON record per published master commit, in
  the order they were published (not commit order). Each line holds the commit
  sha, the Elixir/OTP toolchain it was measured on, the metric values,
  `recorded_at` (UTC) and the `run_id` of the workflow run that measured it.
- `scoreboard/latest.json`: the record of the newest recorded commit on master.
- `scoreboard/badges/<metric>.json`: shields.io endpoint badges for headline metrics.

Metric ids, labels, units and noise tolerances are defined in
`priv/scoreboard/metrics.json` on master. The measurements are deterministic
counts (BEAM reductions, ANSI frame bytes, memory), not wall-clock timings.
EOF
  git fetch --no-tags origin "+refs/heads/$DEFAULT_BRANCH:refs/remotes/origin/$DEFAULT_BRANCH"
  git rev-list --first-parent --max-count=1000 "refs/remotes/origin/$DEFAULT_BRANCH" > "$order"
  for record in "${records[@]}"; do
    node "$scoreboard" publish --defs "$defs" --record "$record" \
      --dir "$pages/scoreboard" --run-id "$run_id" --order "$order"
  done
  git -C "$pages" add -A
  if git -C "$pages" diff --cached --quiet; then
    return 0
  fi
  git -C "$pages" \
    -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit --quiet -m "$subject" -m "Run $run_id"
  changed=1
}

build
if [ "$changed" -eq 0 ]; then
  echo "Nothing to publish; every record is already on gh-pages."
  exit 0
fi

# Another writer may have moved gh-pages since the fetch. Rebasing an append
# to records.jsonl onto another append conflicts, so on a rejected push
# re-fetch, reset to the new tip and rebuild instead.
for attempt in 1 2 3; do
  if git -C "$pages" push origin HEAD:refs/heads/gh-pages; then
    exit 0
  fi
  if [ "$attempt" -eq 3 ]; then
    break
  fi
  echo "::warning::Push rejected (attempt $attempt); refetching gh-pages"
  sleep $((attempt * 5))
  git fetch --no-tags origin +refs/heads/gh-pages:refs/remotes/origin/gh-pages
  git -C "$pages" reset --hard --quiet origin/gh-pages
  build
  if [ "$changed" -eq 0 ]; then
    echo "Nothing to publish after refetch; every record is already on gh-pages."
    exit 0
  fi
done
echo "::error::Could not push to gh-pages after 3 attempts"
exit 1
