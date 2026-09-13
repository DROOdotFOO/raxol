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
# blocks. Mix then finds its manifests where it expects them, notices only
# the files that actually differ on the new branch, and compiles those.
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
#   scripts/worktree.sh add <branch> [path] [--from <ref>]
#   scripts/worktree.sh sync <path>
#   scripts/worktree.sh rm <path>
#   scripts/worktree.sh list
#
# `add` creates the branch if it does not exist (from --from, default HEAD).
# Default path: /tmp/raxol-<branch with / and non-word chars as ->.
#
# Exit codes: 0 ok, 1 usage or git failure, 2 the source checkout has no
# warm cache to clone (nothing to seed from -- run `mix deps.get && mix
# compile` in it first).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

die() {
  printf 'worktree: %s\n' "$1" >&2
  exit "${2:-1}"
}

# One clone implementation, chosen once. `cp -c` is the APFS clone flag;
# `--reflink=auto` is the GNU coreutils equivalent that silently falls back to
# a full copy on filesystems without reflinks.
clone_dir() {
  local src="$1" dest_parent="$2"

  [[ -d "$src" ]] || return 0

  case "$(uname -s)" in
    Darwin) cp -Rc "$src" "$dest_parent/" ;;
    *) cp -R --reflink=auto "$src" "$dest_parent/" ;;
  esac
}

# Root caches plus every package's own (`packages/*/deps` and
# `packages/*/_build` are separate Mix projects and separately warm).
seed_caches() {
  local target="$1"
  local seeded=0

  for name in _build deps; do
    if [[ -d "$repo_root/$name" ]]; then
      rm -rf "${target:?}/$name"
      clone_dir "$repo_root/$name" "$target"
      seeded=$((seeded + 1))
    fi
  done

  if ((seeded == 0)); then
    die "no _build or deps in $repo_root to clone; run 'mix deps.get && mix compile' there first" 2
  fi

  shopt -s nullglob
  for pkg_dir in "$repo_root"/packages/*/; do
    local pkg
    pkg="$(basename "$pkg_dir")"

    for name in _build deps; do
      if [[ -d "$pkg_dir$name" && -d "$target/packages/$pkg" ]]; then
        rm -rf "${target:?}/packages/${pkg:?}/$name"
        clone_dir "$pkg_dir$name" "$target/packages/$pkg"
      fi
    done
  done
  shopt -u nullglob

  printf 'seeded %s from %s (root + packages/*)\n' "$target" "$repo_root"
}

slug() {
  printf '%s' "$1" | tr '/' '-' | tr -c '[:alnum:]._-' '-'
}

cmd_add() {
  local branch="${1:-}"
  shift || true
  local path="" from="HEAD"

  while (($# > 0)); do
    case "$1" in
      --from)
        from="${2:-}"
        [[ -n "$from" ]] || usage
        shift 2
        ;;
      *)
        [[ -z "$path" ]] || usage
        path="$1"
        shift
        ;;
    esac
  done

  [[ -n "$branch" ]] || usage
  path="${path:-/tmp/raxol-$(slug "$branch")}"

  [[ -e "$path" ]] && die "$path already exists"

  cd "$repo_root"

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add "$path" "$branch"
  else
    git worktree add -b "$branch" "$path" "$from"
  fi

  seed_caches "$path"

  printf 'cd %s\n' "$path"
}

cmd_sync() {
  local path="${1:-}"
  [[ -n "$path" ]] || usage
  [[ -d "$path" ]] || die "$path is not a directory"

  seed_caches "$path"
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
