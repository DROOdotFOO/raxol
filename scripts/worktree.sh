#!/usr/bin/env bash
# Parallel review/fix worktrees that do not pay for a full first compile.
#
# A fresh `git worktree add` recompiles the whole tree (~700 files, ~1 min at
# the root, plus every package suite you touch) because `_build` is not
# tracked and every manifest in it is keyed by absolute source path. That cost
# is paid per worktree, and review work routinely wants three or four at once.
#
# The fix is to seed the new worktree with a COPY of the caches from the
# checkout you already have warm: `_build` and `deps`, at the root and in
# every `packages/*`. On APFS (and Btrfs/XFS with reflink) the copy is a
# copy-on-write clone, so it costs neither time nor disk for the shared
# blocks.
#
# What that buys and what it does not: the dependency FETCH and the
# dependency BUILD disappear (measured at the root: 2m14s cold, 22s seeded,
# and no network), and a package suite runs without its own `deps.get`. The
# app's own modules still recompile, because Mix manifests are keyed by
# absolute source path and a second source root invalidates them -- the
# seeded root compile is still `Compiling 697 files`. Nothing can avoid that.
#
# Why not a SHARED build directory (`MIX_BUILD_PATH` pointing several
# worktrees at one `_build`):
#
#   * The manifests store absolute source paths. Compiling the same app from
#     a second source root invalidates them, so the recompile comes back --
#     the one thing the shared directory was meant to avoid.
#   * Two worktrees running `mix test` at the same time would write the same
#     beams and manifests. That is the normal case here (parallel agents),
#     and the failure is a corrupted build, not a slow one.
#
# So: one private cache per worktree, cheaply cloned. No shared mutable state.
#
# TRUST BOUNDARY. The seed is a COPY of whatever is in the source checkout,
# not a fetch: the seeded worktree never runs `deps.get`, so Hex's checksum
# verification never happens there. One hand-patched or stale artifact under
# this checkout's `deps`/`_build` propagates into every worktree created
# afterwards -- including a worktree created to review someone else's
# branch, where the reviewer's assumption is that they are running that
# branch against its locked dependencies.
#
# What IS checked is cheap and offline: `mix.lock` (root and every
# `packages/*/mix.lock`) must match between source and target, because a
# differing lock is exactly the case where the seeded artifacts do not
# describe the branch's dependencies. That is a staleness check, not an
# integrity one -- it says the two checkouts agree on what the dependencies
# should be, not that the copied bytes are what Hex published.
#
# So this is a single-user workstation helper. It is NOT for a shared box or
# a CI runner, where every worktree must fetch and verify its own
# dependencies: use `--fresh` there, or do not use this script.
#
# Usage:
#   scripts/worktree.sh add <branch> [path] [--from <ref>] [--fresh]
#   scripts/worktree.sh sync <path>
#   scripts/worktree.sh rm <path>
#   scripts/worktree.sh list
#
# `add` creates the branch if it does not exist (from --from, default HEAD;
# --from is refused when the branch already exists, rather than ignored).
# `--fresh` skips seeding entirely -- a plain cold `git worktree add`, whose
# first compile pays the full dependency fetch and build, and whose
# dependencies are therefore fetched and checksum-verified for that branch.
# That is the way to proceed when a seed is refused, and the way to use this
# script anywhere the trust boundary in this file's header does not hold.
# Default path: `mktemp -d "${TMPDIR:-/tmp}/raxol-<slug>.XXXXXXXX"`, i.e. a
# directory that already exists and is already 0700 by the time this script
# has a name for it. The old fixed `/tmp/raxol-<slug>` was derivable from a
# branch name that is public on the PR, and on a shared box a predictable
# name under a world-writable sticky directory belongs to whoever creates
# it first (CWE-377). An explicit path argument is used exactly as given,
# and is still refused if anything is already there.
#
# `sync <path>` re-seeds an EXISTING worktree of this repository -- after a
# dependency bump in this checkout, say. It refuses the source checkout
# itself and anything that is not a worktree of this repo: the target's
# caches are replaced, and replacing the source's caches with copies of
# themselves is never what a caller meant.
#
# Exit codes: 0 ok, 1 a usage error or a refused target, 2 the source
# checkout has no warm cache to clone (run `mix deps.get && mix compile` in
# it first), 3 `mix.lock` differs between the source checkout and the
# target, so the seed would describe the wrong dependencies (re-run with
# `--fresh`, or bring this checkout to that lock first). A failing `git`
# surfaces git's own status.
# ---8<---

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '/^# Usage:/,/^# ---8<---/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---8<---/d' -e 's/^# \{0,1\}//'
  exit "${1:-1}"
}

die() {
  printf 'worktree: %s\n' "$1" >&2
  exit "${2:-1}"
}

# One clone implementation, chosen once. `cp -c` is the APFS clone flag and
# `--reflink=auto` the GNU coreutils equivalent; NEITHER is a superset of a
# plain copy. `cp -Rc` FAILS outright across devices (`clonefile failed:
# Cross-device link`) and a non-GNU `cp` rejects `--reflink` altogether, so a
# clone attempt that fails falls back to a plain recursive copy instead of
# aborting the seed under `set -e`.
clone_dir() {
  local src="$1" dest_parent="$2"

  [[ -d "$src" ]] || die "internal: clone source $src disappeared" 2

  case "$(uname -s)" in
    Darwin) cp -Rc "$src" "$dest_parent/" 2>/dev/null || cp -R "$src" "$dest_parent/" ;;
    *) cp -R --reflink=auto "$src" "$dest_parent/" 2>/dev/null || cp -R "$src" "$dest_parent/" ;;
  esac
}

# Copy beside the destination, then swap. The obvious order -- remove the old
# cache, then copy the new one in -- destroys the thing it is replacing
# BEFORE it knows the copy can succeed, so a cross-device `cp` failure, a
# full disk, or a target that happens to BE the source leaves the worktree
# with no cache at all and (for `sync .`) takes the repo's warm caches with
# it. Clone-then-swap cannot lose the old copy unless the new one is already
# in place.
replace_dir() {
  local src="$1" dest="$2"
  local staging="$dest.seeding.$$"

  rm -rf "${staging:?}"
  mkdir -p "$staging"
  clone_dir "$src" "$staging"

  local incoming
  incoming="$staging/$(basename "$src")"
  [[ -d "$incoming" ]] || die "internal: clone of $src produced nothing at $incoming" 2

  local previous="$dest.replaced.$$"
  [[ -e "$dest" ]] && mv "$dest" "$previous"
  mv "$incoming" "$dest"
  rm -rf "${staging:?}" "${previous:?}"
}

# The source checkout is never a valid seed TARGET: seeding it from itself
# would replace each cache with a copy of itself at best, and (before
# clone-then-swap) deleted them outright. Compared by resolved physical path
# so a symlink or `.` cannot route around it.
#
# Answers in the global `SEED_TARGET` rather than on stdout: inside
# `$(assert_seedable …)` a `die` would exit only the command substitution,
# the caller would continue with an empty target, and the checks would read
# as passed. That failure mode is the one this function exists to prevent.
SEED_TARGET=""

assert_seedable() {
  local target="$1" resolved

  resolved="$(cd "$target" 2>/dev/null && pwd -P)" ||
    die "$target is not a directory"

  [[ "$resolved" != "$(cd "$repo_root" && pwd -P)" ]] ||
    die "$target IS the source checkout; seeding it from itself would replace its caches with copies of themselves"

  # A seed target is a worktree of THIS repository. Anything else -- a home
  # directory, `/`, an unrelated project -- is a caller mistake, and the
  # mistake is destructive enough to be worth one `git` call. Resolved with
  # `cd`+`pwd -P` rather than `--path-format=absolute` (git >= 2.31) so the
  # comparison works on whatever git the caller has.
  local target_common source_common

  # Asked in two steps on purpose: an empty `--git-common-dir` (no
  # repository at all) fed straight into `cd` would succeed, leaving the
  # target's own path to fail the comparison below and be reported as "a
  # different repository" when the truth is "not a repository".
  target_common="$(git -C "$resolved" rev-parse --git-common-dir 2>/dev/null)" ||
    die "$target is not inside a git repository"

  target_common="$(cd "$resolved" && cd "$target_common" && pwd -P)"
  source_common="$(cd "$repo_root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"

  [[ "$target_common" == "$source_common" ]] ||
    die "$target belongs to a different repository ($target_common), not this one ($source_common)"

  SEED_TARGET="$resolved"
}

# The one provenance check this script can make offline and for free: the
# seeded caches are the dependencies the SOURCE checkout resolved, so if the
# target's `mix.lock` says something else, the seed describes the wrong
# dependencies -- and Mix will not notice, because it never re-fetches what
# it already considers built. Refusing is the honest answer; `--fresh` is
# how the caller proceeds.
#
# Root lock plus every package's, on BOTH sides: a package that exists in
# only one of the two checkouts is itself a lock difference. `cmp` rather
# than a checksum -- same answer, one process, and it stops at the first
# differing byte.
assert_locks_match() {
  local target="$1"
  local rels=(mix.lock) mismatched=() rel lock

  shopt -s nullglob
  for lock in "$repo_root"/packages/*/mix.lock "$target"/packages/*/mix.lock; do
    rel="packages/$(basename "$(dirname "$lock")")/mix.lock"
    [[ " ${rels[*]} " == *" $rel "* ]] || rels+=("$rel")
  done
  shopt -u nullglob

  for rel in "${rels[@]}"; do
    # Absent on both sides is not a difference (a package that vendors no
    # dependencies has no lock); absent on ONE side is.
    [[ -f "$repo_root/$rel" || -f "$target/$rel" ]] || continue

    if [[ ! -f "$repo_root/$rel" || ! -f "$target/$rel" ]] ||
      ! cmp -s "$repo_root/$rel" "$target/$rel"; then
      mismatched+=("$rel")
    fi
  done

  ((${#mismatched[@]} == 0)) ||
    die "mix.lock differs between $repo_root and $target (${mismatched[*]}); the caches here are not that branch's dependencies. Use 'add --fresh' for an unseeded worktree, or bring this checkout to that lock first." 3
}

# Root caches plus every package's own (`packages/*/deps` and
# `packages/*/_build` are separate Mix projects and separately warm).
#
# "Seeded" means a cache was CLONED, not that a directory existed: an empty
# `_build` next to a cold `deps` is a cold checkout, and reporting it as
# seeded is how a caller ends up blaming Mix for a two-minute compile. Both
# root caches are required, and the per-package count is reported so a
# partially warm source is visible rather than hidden behind one success
# line.
seed_caches() {
  local target="$1"
  local missing=()

  assert_locks_match "$target"

  for name in _build deps; do
    [[ -d "$repo_root/$name" ]] || missing+=("$name")
  done

  if ((${#missing[@]} > 0)); then
    die "no ${missing[*]} in $repo_root to clone; run 'mix deps.get && mix compile' there first" 2
  fi

  for name in _build deps; do
    replace_dir "$repo_root/$name" "$target/$name"
  done

  local packages=0 cold=0

  shopt -s nullglob
  for pkg_dir in "$repo_root"/packages/*/; do
    local pkg
    pkg="$(basename "$pkg_dir")"

    [[ -d "$target/packages/$pkg" ]] || continue

    if [[ -d "$pkg_dir/_build" && -d "$pkg_dir/deps" ]]; then
      replace_dir "$pkg_dir/_build" "$target/packages/$pkg/_build"
      replace_dir "$pkg_dir/deps" "$target/packages/$pkg/deps"
      packages=$((packages + 1))
    else
      cold=$((cold + 1))
    fi
  done
  shopt -u nullglob

  printf 'seeded %s from %s (root + %d package(s)' "$target" "$repo_root" "$packages"

  if ((cold > 0)); then
    printf ', %d package(s) cold in the source and left alone' "$cold"
  fi

  printf ')\n'
}

slug() {
  printf '%s' "$1" | tr '/' '-' | tr -c '[:alnum:]._-' '-'
}

cmd_add() {
  local branch="${1:-}"
  shift || true
  local path="" from="HEAD" from_given=0 fresh=0 created_path=0

  while (($# > 0)); do
    case "$1" in
      --from)
        from="${2:-}"
        [[ -n "$from" ]] || usage
        from_given=1
        shift 2
        ;;
      --fresh)
        fresh=1
        shift
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$path" ]] || usage
        path="$1"
        shift
        ;;
    esac
  done

  [[ -n "$branch" ]] || usage

  if [[ -z "$path" ]]; then
    # `mktemp -d` names AND creates in one step, so there is no window in
    # which the name is known and the directory is not yet ours, and 0700
    # keeps it that way afterwards. `git worktree add` refuses a non-empty
    # directory but accepts an existing EMPTY one (checked against git
    # 2.50), which is exactly what mktemp leaves -- so the checkout lands
    # inside the directory mktemp owns, rather than beside it.
    local tmpdir="${TMPDIR:-/tmp}"
    path="$(mktemp -d "${tmpdir%/}/raxol-$(slug "$branch").XXXXXXXX")"
    created_path=1
  else
    # `-e` follows symlinks, so a dangling link planted at a path an
    # attacker can guess would test false and `git worktree add` would then
    # materialise the checkout at whatever the link points at -- after
    # which this script's copies run there. `-L` is the case `-e` misses.
    [[ ! -e "$path" && ! -L "$path" ]] || die "$path already exists"
  fi

  cd "$repo_root"

  local created_branch=0 status=0

  # A `git worktree add` that fails must not leave the directory this
  # command created behind: `rmdir` (never `rm -rf`) because the only
  # directory this branch may remove is the empty one mktemp just made.
  # git's own exit status is still what the caller sees.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    ((from_given == 0)) ||
      die "$branch already exists; --from $from would be ignored. Drop --from, or pick a new branch name."

    git worktree add "$path" "$branch" || status=$?
  else
    git worktree add -b "$branch" "$path" "$from" || status=$?
    ((status != 0)) || created_branch=1
  fi

  if ((status != 0)); then
    ((created_path == 0)) || rmdir "$path" 2>/dev/null || true
    exit "$status"
  fi

  # Seeding is the reason this command exists, so a failed seed is a failed
  # `add`: unwind the worktree (and the branch, if this call created it)
  # rather than leaving behind exactly the unseeded worktree the refusal is
  # supposed to prevent. Run in a subshell, because `seed_caches` reports
  # failure by exiting (`die`) -- calling it directly would take this shell
  # down with it and skip the unwind.
  #
  # Which of the two a caller got is reported, because it decides both what
  # the first compile costs and where the dependencies in there came from.
  if ((fresh == 1)); then
    printf 'fresh %s (nothing seeded; its own deps.get fetches and verifies)\n' "$path"
  else
    (seed_caches "$path") || status=$?

    if ((status != 0)); then
      git worktree remove --force "$path" >/dev/null 2>&1 || true
      ((created_branch == 0)) || git branch -D "$branch" >/dev/null 2>&1 || true
      die "seeding failed; removed $path (and its new branch) again" "$status"
    fi
  fi

  printf 'cd %s\n' "$path"
}

cmd_sync() {
  local path="${1:-}"
  [[ -n "$path" ]] || usage

  assert_seedable "$path"
  seed_caches "$SEED_TARGET"
}

cmd_rm() {
  local path="${1:-}"
  [[ -n "$path" ]] || usage

  cd "$repo_root"
  git worktree remove "$path"
}

cmd_list() {
  cd "$repo_root"
  git worktree list
}

case "${1:-}" in
  add)
    shift
    cmd_add "$@"
    ;;
  sync)
    shift
    cmd_sync "$@"
    ;;
  rm)
    shift
    cmd_rm "$@"
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  *) usage ;;
esac
