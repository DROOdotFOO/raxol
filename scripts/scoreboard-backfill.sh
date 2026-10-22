#!/usr/bin/env bash
# Measures older commits with today's scoreboard, for the gh-pages history.
#
#   MIX_ENV=test scripts/scoreboard-backfill.sh OUT_DIR COMMIT...
#
# Run from a checkout of the default branch. For each COMMIT it checks the
# commit out in one scratch worktree (reused, so each step compiles
# incrementally; seeded from this checkout's deps and _build), copies today's
# scoreboard over it, and writes OUT_DIR/<full sha>.json, the record
# `mix raxol.scoreboard` would have made on that commit. A commit is skipped,
# with the reason appended to OUT_DIR/skipped.txt, when:
#
#   * the copied harness does not produce, frame by frame, the bytes that
#     commit's own rendering engine writes (test/raxol/scoreboard_test.exs,
#     run against that commit's engine), so it would measure a frame the
#     engine never drew;
#   * a scenario screen differs from priv/scoreboard/screens.refs: the commit
#     draws something else, so its numbers are a different benchmark; or
#   * it already has Raxol.Scoreboard (#1287 on), so CI records it.
#
# Commits from #1133 (4c26e69) on draw today's screens; nothing older does.
# Exits non-zero only when a commit could not be built or measured at all.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: scripts/scoreboard-backfill.sh OUT_DIR COMMIT..." >&2
  exit 2
fi

src=$(git rev-parse --show-toplevel)
out=$(mkdir -p "$1" && cd "$1" && pwd)
shift
work="${SCOREBOARD_BACKFILL_WORKTREE:-$src/../raxol-scoreboard-backfill}"

overlay=(
  lib/raxol/scoreboard.ex
  lib/mix/tasks/raxol.scoreboard.ex
  lib/raxol/core/runtime/rendering/pipeline.ex
  priv/scoreboard/metrics.json
  priv/scoreboard/screens.refs
  test/raxol/scoreboard_test.exs
  bench/core/buffer_gate.exs
)

# Backends.terminal_frame/2 is the first half of render_to_terminal/2, split
# out in #1287 without changes. Older commits get the same function body,
# calling their own private stages; the parity test then checks the result
# against their own engine.
read -r -d '' terminal_frame <<'EOF' || true

  @doc false
  def terminal_frame(cells, state) do
    updated_buffer = apply_cells_to_buffer(cells, state)
    renderer = Raxol.Terminal.Renderer.new(updated_buffer, %{}, %{}, true)

    {updated_buffer,
     build_terminal_frame(state.buffer, updated_buffer, renderer, state)}
  end
EOF
export TERMINAL_FRAME="$terminal_frame"

if [ ! -d "$work" ]; then
  git -C "$src" worktree add --quiet --detach "$work" "$1"
  for dir in deps _build; do
    if [ -d "$src/$dir" ]; then cp -R "$src/$dir" "$work/"; fi
  done
fi

skip() {
  echo "skip $1: $2" >&2
  echo "$1 $2" >> "$out/skipped.txt"
}

status=0
for commit in "$@"; do
  sha=$(git -C "$src" rev-parse --verify "$commit^{commit}")
  echo "== $sha" >&2

  if git -C "$src" cat-file -e "$sha:lib/raxol/scoreboard.ex" 2>/dev/null; then
    skip "$sha" "it has the scoreboard, so CI records it"
    continue
  fi

  git -C "$work" reset --quiet --hard
  git -C "$work" clean --quiet -fd -e deps -e _build -e .raxol_cache
  git -C "$work" checkout --quiet --detach "$sha"

  for path in "${overlay[@]}"; do
    mkdir -p "$work/$(dirname "$path")"
    cp "$src/$path" "$work/$path"
  done

  backends="$work/lib/raxol/core/runtime/rendering/backends.ex"
  perl -0pi -e 's/(\n  alias Raxol\.Terminal\.ScreenBuffer\n)/$1$ENV{TERMINAL_FRAME}\n/ or die "no ScreenBuffer alias in backends.ex\n"' "$backends"

  # `set -e` does not apply inside a subshell on the left of `||`, so every
  # step checks its own status.
  (
    cd "$work" || exit 4
    mix deps.get > /dev/null || exit 4
    # A path dependency whose version changed between commits (raxol_core
    # 2.7 -> 2.8 in #1262) keeps its old .app in _build, and mix refuses to
    # load it; rebuild the in-repo packages then.
    if ! mix compile > /dev/null 2>&1; then
      rm -rf "_build/${MIX_ENV:-dev}/lib/"raxol*
      mix compile > /dev/null || exit 4
    fi

    if ! mix test test/raxol/scoreboard_test.exs > "$out/$sha.parity.log" 2>&1; then
      skip "$sha" "the harness does not match this commit's engine (see $sha.parity.log)"
      exit 3
    fi
    rm "$out/$sha.parity.log"

    # Exit 1 is a breached budget (often a wall-clock one); the memory rows
    # are still written and are all the record takes from the gate.
    gate=$(mktemp) || exit 4
    gate_rc=0
    mix run --no-start bench/core/buffer_gate.exs --json "$gate" > /dev/null || gate_rc=$?
    if [ "$gate_rc" -gt 1 ] || [ ! -s "$gate" ]; then exit 4; fi
    if ! mix raxol.scoreboard --include "$gate" --commit "$sha" \
      --output "$out/$sha.json" > "$out/$sha.log" 2>&1; then
      skip "$sha" "$(grep -m1 -E '^\*\* ' "$out/$sha.log" || tail -1 "$out/$sha.log")"
      rm -f "$out/$sha.json"
      exit 3
    fi
    rm "$out/$sha.log" "$gate"
  ) || {
    rc=$?
    if [ "$rc" -ne 3 ]; then
      echo "error $sha: build or measurement failed (exit $rc)" >&2
      status=$rc
    fi
  }
done

git -C "$work" reset --quiet --hard
exit "$status"
