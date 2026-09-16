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
# Usage:
#   scripts/worktree.sh add <branch> [path] [--from <ref>] [--fresh]
#   scripts/worktree.sh sync <path>
#   scripts/worktree.sh rm <path>
#   scripts/worktree.sh list
#
# `add` creates the branch if it does not exist (from --from, default HEAD).
# A supplied revision may not begin with `-` and is resolved to a commit with
# `git rev-parse --verify --end-of-options` before any directory is created.
# --from is refused when the branch already exists, rather than ignored.
# The branch name is the first argument and may not begin with `-`: a
# boolean flag is naturally written first, and `add --fresh feature/x`
# would otherwise bind the branch to `--fresh` and the path to `feature/x`.
# `--fresh` skips seeding entirely -- a plain cold `git worktree add`, whose
# first compile pays the full dependency fetch and build, and whose
# dependencies are therefore fetched and checksum-verified for that branch.
# That is the way to proceed when a seed is refused, and the way to use this
# script anywhere the TRUST BOUNDARY below does not hold.
# Default path: `mktemp -d "$TMPDIR/raxol-<slug>.XXXXXXXX"`, falling back to
# `/tmp` when TMPDIR is empty, cannot be resolved, or resolves to `/`. The
# property that buys is not an unguessable name -- how much entropy
# mktemp spends on those eight characters is libc's business, not a
# guarantee this script can make -- but an ATOMIC EXCLUSIVE CREATE: mktemp
# names and creates the directory in the same step, and it is 0700 from the
# moment it exists, so there is no window in which the path is known and
# unowned. Explicit paths get the same guarantee: one `mkdir -m 700` both
# refuses an existing entry (including a symlink) and claims the new directory
# atomically.
#
# `sync <path>` transactionally re-seeds an EXISTING worktree of this
# repository -- after a dependency bump in this checkout, say. It refuses the
# source checkout and anything that is not a worktree of this repo. Concurrent
# seeds of one target are serialized, and every old cache remains available
# for rollback until every replacement has landed.
#
# TRUST BOUNDARY. The seed is a COPY of whatever is in the source checkout,
# not a fetch: the seeded worktree never runs `deps.get`, so Hex's checksum
# verification never happens there. One hand-patched or stale artifact under
# this checkout's `deps`/`_build` propagates into every worktree created
# afterwards -- including a worktree created to review someone else's
# branch, where the reviewer's assumption is that they are running that
# branch against its locked dependencies.
#
# What IS checked is cheap and offline: `mix.lock` and `mix.exs` (root and
# every package) are compared between source and target. Locks cover fetched
# dependencies; mix.exs also catches path-dependency changes that do not alter
# a lock. This is a staleness check, not an integrity one -- it says the two
# checkouts agree on dependency manifests, not that the copied bytes are what
# Hex published. Symlinked manifest read paths, package directories, and
# `_build`/`deps` replacement destinations in the target are REFUSED rather
# than followed.
#
# `add` refuses the seed on manifest drift (exit 3): the worktree does not
# exist yet, so `--fresh` is a correct and cheap answer. `sync` warns and
# proceeds, because carrying NEW manifests and their caches from this checkout
# into an existing worktree is what `sync` is for.
#
# So this is a single-user workstation helper. It is NOT for a shared box or
# a CI runner, where every worktree must fetch and verify its own
# dependencies: use `--fresh` there, or do not use this script.
#
# Exit codes: 0 ok, 1 a usage error or refused target, 2 the source checkout
# has no warm cache to clone -- run `mix deps.get && mix compile` in it first
# -- and 3 means `add` refused a seed because dependency manifests differ
# between source and target. A failing `git` surfaces git's own status.
# ---8<---

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  local status="${1:-1}" output=/dev/stdout
  ((status == 0)) || output=/dev/stderr

  {
    printf 'Usage:\n'
    printf '  scripts/worktree.sh add <branch> [path] [--from <ref>] [--fresh]\n'
    printf '  scripts/worktree.sh sync <path>\n'
    printf '  scripts/worktree.sh rm <path>\n'
    printf '  scripts/worktree.sh list\n'
  } >"$output"

  exit "$status"
}

help() {
  sed -n '/^# Usage:/,/^# ---8<---/p' "${BASH_SOURCE[0]}" |
    sed -e '/^# ---8<---/d' -e 's/^# \{0,1\}//'
  exit 0
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

# A seed is one transaction, not a sequence of independent directory swaps.
# Every old cache stays in a private staging directory until all replacements
# have landed. EXIT (including an explicit signal exit) restores them in
# reverse order; a successful commit only then removes the retained copies.
SEED_TXN_ACTIVE=0
SEED_TXN_COMMITTING=0
SEED_TXN_DESTS=()
SEED_TXN_STAGES=()
SEED_TXN_HAD_DEST=()
SEED_LOCK=""
SEED_PENDING_SIGNAL=0

defer_seed_signals() {
  SEED_PENDING_SIGNAL=0
  trap 'SEED_PENDING_SIGNAL=129' HUP
  trap 'SEED_PENDING_SIGNAL=130' INT
  trap 'SEED_PENDING_SIGNAL=143' TERM
}

resume_seed_signals() {
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ((SEED_PENDING_SIGNAL == 0)) || exit "$SEED_PENDING_SIGNAL"
}

report_seed_residue() {
  local context="$1"
  shift
  (($# == 0)) ||
    printf 'worktree: %s; manual cleanup required: %s\n' "$context" "$*" >&2
}

rollback_seed_transaction() {
  local residue=() i dest stage previous

  for ((i = ${#SEED_TXN_DESTS[@]} - 1; i >= 0; i--)); do
    dest="${SEED_TXN_DESTS[$i]}"
    stage="${SEED_TXN_STAGES[$i]}"
    previous="$stage/previous"

    if [[ "${SEED_TXN_HAD_DEST[$i]}" == 1 ]]; then
      if [[ -e "$previous" || -L "$previous" ]]; then
        if [[ -e "$dest" || -L "$dest" ]]; then
          rm -rf -- "$dest" || residue+=("replacement $dest")
        fi

        if [[ ! -e "$dest" && ! -L "$dest" ]]; then
          mv -- "$previous" "$dest" ||
            printf 'worktree: could not restore %s from %s\n' "$dest" "$previous" >&2
        fi

        if [[ -e "$previous" || -L "$previous" ]]; then
          residue+=("original $dest retained in $previous")
        fi
      elif [[ ! -e "$dest" && ! -L "$dest" ]]; then
        residue+=("missing destination $dest")
      fi
    elif [[ -e "$dest" || -L "$dest" ]]; then
      rm -rf -- "$dest" || residue+=("new destination $dest")
    fi

    # A failed restore leaves the only retained original under staging.
    # Never delete that evidence while reporting where the caller can find it.
    if [[ ! -e "$previous" && ! -L "$previous" ]] &&
      [[ -e "$stage" || -L "$stage" ]]; then
      rm -rf -- "$stage" || residue+=("staging $stage")
    fi
  done
  SEED_TXN_ACTIVE=0
  if ((${#residue[@]} > 0)); then
    report_seed_residue "cache seed rollback was incomplete" "${residue[@]}"
    return 1
  fi
}

finish_seed_commit() {
  local residue=() stage

  SEED_TXN_COMMITTING=1
  SEED_TXN_ACTIVE=0

  for stage in "${SEED_TXN_STAGES[@]}"; do
    if [[ -e "$stage" || -L "$stage" ]]; then
      rm -rf -- "$stage" || residue+=("staging $stage")
    fi
  done

  SEED_TXN_COMMITTING=0
  if ((${#residue[@]} > 0)); then
    report_seed_residue "cache seed committed but cleanup was incomplete" "${residue[@]}"
    return 1
  fi
}

release_seed_lock() {
  local residue=()

  [[ -n "$SEED_LOCK" ]] || return 0

  if [[ -e "$SEED_LOCK/owner" || -L "$SEED_LOCK/owner" ]]; then
    rm -f -- "$SEED_LOCK/owner" || residue+=("lock owner $SEED_LOCK/owner")
  fi

  if [[ -d "$SEED_LOCK" ]]; then
    rmdir -- "$SEED_LOCK" || residue+=("lock $SEED_LOCK")
  fi

  if ((${#residue[@]} > 0)); then
    report_seed_residue "could not release the cache seed lock" "${residue[@]}"
    return 1
  fi
}

seed_exit_handler() {
  local status="$1" cleanup_status=0
  trap - EXIT HUP INT TERM

  if ((SEED_TXN_ACTIVE == 1)); then
    rollback_seed_transaction || cleanup_status=1
  elif ((SEED_TXN_COMMITTING == 1)); then
    finish_seed_commit || cleanup_status=1
  fi

  release_seed_lock || cleanup_status=1
  ((status != 0 || cleanup_status == 0)) || status=1
  exit "$status"
}

acquire_seed_lock() {
  local target="$1" git_dir candidate lock_status=0

  git_dir="$(git -C "$target" rev-parse --git-dir)" ||
    die "cannot locate the git directory for $target"
  git_dir="$(cd "$target" && cd "$git_dir" && pwd -P)"
  candidate="$git_dir/raxol-cache-seed.lock"

  # Defer signals across the mkdir/state-record boundary. Otherwise a signal
  # delivered after mkdir succeeds but before SEED_LOCK is assigned can leave
  # an unowned lock that every later sync mistakes for an active one.
  defer_seed_signals
  mkdir -m 700 -- "$candidate" || lock_status=$?
  ((lock_status != 0)) || SEED_LOCK="$candidate"
  resume_seed_signals

  if ((lock_status != 0)); then
    if [[ -d "$candidate" ]]; then
      die "another cache seed is already active for $target (lock: $candidate)"
    fi

    die "could not acquire the cache seed lock for $target at $candidate"
  fi

  printf '%s\n' "$$" >"$SEED_LOCK/owner" ||
    die "created $SEED_LOCK but could not record its owner"
}

replace_dir() {
  local src="$1" dest="$2" parent stage="" incoming had_dest=0 stage_status=0

  [[ ! -L "$dest" ]] ||
    die "refusing to replace symlinked cache destination $dest"

  parent="$(dirname "$dest")"
  [[ -d "$parent" && ! -L "$parent" ]] ||
    die "cache destination parent is not a real directory: $parent"

  # Like lock acquisition, staging creation and transaction registration are
  # one signal-safe state transition: once the directory exists, EXIT knows
  # its name and can remove or preserve it.
  defer_seed_signals
  stage="$(mktemp -d "$parent/.raxol-seed.$(basename "$dest").XXXXXXXX")" ||
    stage_status=$?

  if ((stage_status == 0)); then
    [[ ! -e "$dest" ]] || had_dest=1
    SEED_TXN_DESTS+=("$dest")
    SEED_TXN_STAGES+=("$stage")
    SEED_TXN_HAD_DEST+=("$had_dest")
  fi

  resume_seed_signals
  ((stage_status == 0)) ||
    die "could not create cache staging directory beside $dest"

  clone_dir "$src" "$stage" ||
    die "could not clone $src into $stage" 2

  incoming="$stage/$(basename "$src")"
  [[ -d "$incoming" && ! -L "$incoming" ]] ||
    die "internal: clone of $src produced no real directory at $incoming" 2

  if ((had_dest == 1)); then
    mv -- "$dest" "$stage/previous" ||
      die "could not retain the existing cache $dest for rollback"
  fi

  mv -- "$incoming" "$dest" ||
    die "could not install the cloned cache at $dest"
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

# Manifest comparisons and cache replacement must not follow paths planted by
# the target branch. Refuse every read path and replacement destination that
# can redirect outside the worktree.
assert_no_symlinked_seed_paths() {
  local target="$1" entry rel offenders=()

  for rel in mix.lock mix.exs _build deps; do
    [[ ! -L "$target/$rel" ]] || offenders+=("$rel")
  done

  if [[ -L "$target/packages" ]]; then
    offenders+=("packages")
  else
    shopt -s nullglob
    for entry in "$target"/packages/*; do
      rel="packages/$(basename "$entry")"

      if [[ -L "$entry" ]]; then
        offenders+=("$rel")
        continue
      fi

      [[ ! -L "$entry/mix.lock" ]] || offenders+=("$rel/mix.lock")
      [[ ! -L "$entry/mix.exs" ]] || offenders+=("$rel/mix.exs")
      [[ ! -L "$entry/_build" ]] || offenders+=("$rel/_build")
      [[ ! -L "$entry/deps" ]] || offenders+=("$rel/deps")
    done
    shopt -u nullglob
  fi

  ((${#offenders[@]} == 0)) ||
    die "symlinked seed path under $target (${offenders[*]}); manifests and cache destinations must be real paths inside the worktree"
}

# The copied caches describe both locked external dependencies and path
# dependencies declared in mix.exs. Compare both manifests at the root and in
# every package, on both sides. A file present on only one side is drift too.
check_dependency_manifests() {
  local target="$1" policy="$2"
  local rels=(mix.lock mix.exs) mismatched=() rel manifest

  shopt -s nullglob
  for manifest in \
    "$repo_root"/packages/*/mix.lock \
    "$repo_root"/packages/*/mix.exs \
    "$target"/packages/*/mix.lock \
    "$target"/packages/*/mix.exs; do
    rel="packages/$(basename "$(dirname "$manifest")")/$(basename "$manifest")"
    [[ " ${rels[*]} " == *" $rel "* ]] || rels+=("$rel")
  done
  shopt -u nullglob

  for rel in "${rels[@]}"; do
    [[ -f "$repo_root/$rel" || -f "$target/$rel" ]] || continue

    if [[ ! -f "$repo_root/$rel" || ! -f "$target/$rel" ]] ||
      ! cmp -s "$repo_root/$rel" "$target/$rel"; then
      mismatched+=("$rel")
    fi
  done

  ((${#mismatched[@]} > 0)) || return 0

  local edited_here=() differs_there=() detail=() advice=""

  for rel in "${mismatched[@]}"; do
    if [[ -n "$(git -C "$repo_root" status --porcelain -- "$rel" 2>/dev/null)" ]]; then
      edited_here+=("$rel")
    else
      differs_there+=("$rel")
    fi
  done

  if ((${#edited_here[@]} > 0)); then
    detail+=("uncommitted in this checkout: ${edited_here[*]}")
    advice+=" This checkout is the side that moved; commit or stash ${edited_here[*]} here, or carry it into the worktree with 'sync', rather than reverting anything."
  fi

  if ((${#differs_there[@]} > 0)); then
    detail+=("committed differently in the target: ${differs_there[*]}")
    advice+=" The target is the side that moved; check its manifests out here and run 'mix deps.get' so these caches describe it."
  fi

  local joined="${detail[0]}"
  ((${#detail[@]} < 2)) || joined="${detail[0]}; ${detail[1]}"

  if [[ "$policy" == warn ]]; then
    printf 'worktree: dependency manifests differ from %s (%s) -- re-seeding anyway, which is what sync is for; run `mix deps.get` there if it keeps its own manifests.\n' \
      "$target" "$joined" >&2
    return 0
  fi

  die "dependency manifests differ between $repo_root and $target ($joined); the caches here do not describe that branch.$advice Or use 'add --fresh' for an unseeded worktree that fetches and verifies its own dependencies." 3
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
#
# `_build`/`deps` cannot seed anything at all, whatever the manifests say, so
# the cold-source error is reported before provenance drift.
seed_caches() {
  local target="$1" manifest_policy="${2:-refuse}"
  local missing=() name pkg_dir

  for name in _build deps; do
    [[ -d "$repo_root/$name" ]] || missing+=("$name")
  done

  if ((${#missing[@]} > 0)); then
    die "no ${missing[*]} in $repo_root to clone; run 'mix deps.get && mix compile' there first" 2
  fi

  assert_no_symlinked_seed_paths "$target"
  check_dependency_manifests "$target" "$manifest_policy"

  for name in _build deps; do
    replace_dir "$repo_root/$name" "$target/$name"
  done

  local packages=0 cold=0 pkg

  shopt -s nullglob
  for pkg_dir in "$repo_root"/packages/*/; do
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

run_seed() {
  local target="$1" manifest_policy="$2"

  SEED_TXN_ACTIVE=1
  SEED_TXN_COMMITTING=0
  SEED_TXN_DESTS=()
  SEED_TXN_STAGES=()
  SEED_TXN_HAD_DEST=()
  SEED_LOCK=""

  trap 'seed_exit_handler $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  acquire_seed_lock "$target"
  seed_caches "$target" "$manifest_policy"
  finish_seed_commit ||
    die "cache replacement succeeded, but retained-cache cleanup did not"
}

slug() {
  printf '%s' "$1" | tr '/' '-' | tr -c '[:alnum:]._-' '-'
}

path_identity() {
  case "$(uname -s)" in
    Darwin) stat -f '%d:%i' -- "$1" ;;
    *) stat -c '%d:%i' -- "$1" ;;
  esac
}

# Undo only the directory instance this call atomically created, and report
# every residue. In particular, never hand an unverified caller path to
# `git worktree remove --force`, because that command deletes recursively.
# A newly created branch is also removed when git created the ref before a
# later checkout failure.
unwind_add() {
  local path="$1" branch="$2" created_path="$3" branch_existed="$4"
  local expected_identity="$5" current_identity="" path_owned=0
  local registration_failed=0 target_common="" source_common residue=()

  if ((created_path == 1)) && [[ -e "$path" && ! -L "$path" ]]; then
    if current_identity="$(path_identity "$path")" &&
      [[ "$current_identity" == "$expected_identity" ]]; then
      path_owned=1
    else
      residue+=("directory $path (identity changed; preserved)")
    fi
  fi

  source_common="$(cd "$repo_root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"

  if ((path_owned == 1)) && [[ -f "$path/.git" ]]; then
    if target_common="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null)"; then
      if ! target_common="$(cd "$path" && cd "$target_common" 2>/dev/null && pwd -P)"; then
        target_common=""
      fi
    else
      target_common=""
    fi

    if [[ "$target_common" == "$source_common" ]]; then
      if ! git worktree remove --force -- "$path"; then
        residue+=("registered worktree $path")
        registration_failed=1
      fi
    else
      residue+=("directory $path (not proven to be this repository's worktree)")
      registration_failed=1
    fi
  fi

  if ((path_owned == 1 && registration_failed == 0)) &&
    [[ -e "$path" || -L "$path" ]]; then
    if ! rmdir -- "$path"; then
      residue+=("directory $path")
    fi
  fi

  if ((branch_existed == 0)) && git show-ref --verify --quiet "refs/heads/$branch"; then
    if ! git branch -D -- "$branch"; then
      residue+=("branch $branch")
    fi
  fi

  if ((${#residue[@]} > 0)); then
    printf 'worktree: could not finish undoing the failed add; still there: %s\n' "${residue[*]}" >&2
    return 1
  fi
}

cmd_add() {
  local branch="${1:-}"
  shift || true
  local path="" from="HEAD" from_commit="" created_identity=""
  local from_given=0 fresh=0 created_path=0

  case "$branch" in
    -h | --help) help ;;
    -*)
      die "the first argument is the branch name, and '$branch' is an option; options come after it"
      ;;
  esac

  while (($# > 0)); do
    case "$1" in
      --from)
        from="${2:-}"
        [[ -n "$from" ]] || die "--from requires a revision"
        case "$from" in
          -*) die "--from revision may not begin with '-': $from" ;;
        esac
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
        [[ -z "$path" ]] || die "only one worktree path may be supplied"
        path="$1"
        shift
        ;;
    esac
  done

  [[ -n "$branch" ]] || usage
  git -C "$repo_root" check-ref-format --branch "$branch" >/dev/null 2>&1 ||
    die "invalid branch name: $branch"

  local branch_existed=0

  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
    branch_existed=1

    ((from_given == 0)) ||
      die "$branch already exists; --from $from would be ignored. Drop --from, or pick a new branch name."
  else
    from_commit="$(git -C "$repo_root" rev-parse --verify --end-of-options "${from}^{commit}" 2>/dev/null)" ||
      die "invalid --from revision: $from"
  fi

  if [[ -z "$path" ]]; then
    local requested_tmpdir="${TMPDIR:-/tmp}" tmpdir=""

    if [[ "$requested_tmpdir" != "/" ]]; then
      if ! tmpdir="$(cd "$requested_tmpdir" 2>/dev/null && pwd -P)"; then
        tmpdir=""
      fi
    fi

    if [[ -z "$tmpdir" || "$tmpdir" == "/" ]]; then
      tmpdir="$(cd /tmp 2>/dev/null && pwd -P)" ||
        die "neither TMPDIR nor /tmp is a usable worktree parent"
    fi

    [[ "$tmpdir" != "/" ]] ||
      die "refusing to create a worktree directly under /"

    path="$(mktemp -d "$tmpdir/raxol-$(slug "$branch").XXXXXXXX")" ||
      die "could not create a private worktree directory under $tmpdir"
    created_path=1
  else
    # Create the explicit destination ourselves with its final permissions.
    # The single mkdir is both the existence check and the atomic claim.
    mkdir -m 700 -- "$path" ||
      die "cannot atomically create private worktree directory $path"
    created_path=1
  fi

  created_identity="$(path_identity "$path")" ||
    die "created $path but could not verify its identity; preserved it for inspection"

  cd "$repo_root"

  local status=0 cleanup_status=0

  if ((branch_existed == 1)); then
    git worktree add -- "$path" "$branch" || status=$?
  else
    git worktree add -b "$branch" -- "$path" "$from_commit" || status=$?
  fi

  if ((status != 0)); then
    unwind_add "$path" "$branch" "$created_path" "$branch_existed" "$created_identity" ||
      cleanup_status=$?
    ((cleanup_status == 0)) ||
      printf 'worktree: add failed and cleanup left reported residue\n' >&2
    exit "$status"
  fi

  if ((fresh == 1)); then
    printf 'fresh %s (nothing seeded; its own deps.get fetches and verifies)\n' "$path"
  else
    (run_seed "$path" refuse) || status=$?

    if ((status != 0)); then
      cleanup_status=0
      unwind_add "$path" "$branch" "$created_path" "$branch_existed" "$created_identity" ||
        cleanup_status=$?

      if ((cleanup_status == 0)); then
        die "seeding failed; undid $path and the branch created for it" "$status"
      fi

      die "seeding failed; cleanup is incomplete for $path as reported above" "$status"
    fi
  fi

  printf 'cd %s\n' "$path"
}

cmd_sync() {
  local path="${1:-}"

  case "$path" in
    -h | --help) help ;;
    -*) die "unknown option: $path" ;;
  esac

  [[ -n "$path" ]] || usage
  (($# == 1)) || die "sync accepts exactly one worktree path"

  assert_seedable "$path"

  # A mkdir lock in this worktree's private git directory serializes syncs
  # without relying on non-portable flock(1). The seed transaction retains
  # every prior cache until all replacements have succeeded.
  (run_seed "$SEED_TARGET" warn)
}

cmd_rm() {
  local path="${1:-}"

  case "$path" in
    -h | --help) help ;;
  esac

  [[ -n "$path" ]] || usage
  (($# == 1)) || die "rm accepts exactly one worktree path"

  cd "$repo_root"
  git worktree remove -- "$path"
}

cmd_list() {
  case "${1:-}" in
    -h | --help) help ;;
    "") ;;
    *) die "list accepts no arguments" ;;
  esac

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
  -h | --help | help)
    help
    ;;
  *) usage ;;
esac
