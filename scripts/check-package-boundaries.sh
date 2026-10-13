#!/usr/bin/env bash
#
# Guard against packages reaching across the dependency graph.
#
# docs/PACKAGES.md declares `raxol --> raxol_core, raxol_terminal, ...` and
# never the reverse. Every package in CI compiles standalone with
# `--warnings-as-errors`, so a call into a module the package's mix.exs does
# not pull in is a compile error -- unless the file silences it with
# `@compile {:no_warn_undefined, Mod}`. That attribute is how four call sites
# in raxol_terminal came to raise `UndefinedFunctionError` the moment the
# package was used without main raxol on the code path: the comment
# next to each said "guarded at runtime", and nothing was.
#
# This check reads every `no_warn_undefined` under packages/*/lib, resolves
# each named `Raxol.*` module to the tree that defines it (main `lib/`, or
# `packages/<name>/lib`), and fails when that tree is not one the package
# declares in its mix.exs. External modules (Jason, Req, Mogrify, ...) are
# someone else's optional dependency and are not in scope. A module defined
# nowhere in the repo is reported too: the attribute is then either dead or
# pointing at a name that was renamed out from under it.
#
# Existing offenders are listed in scripts/.package-boundaries-allowlist,
# which only shrinks: an entry that no longer matches fails the check so the
# list cannot rot. Fix a new report by moving the module into the package
# that owns the concept, by reading the implementation from application
# config with an in-package default, or by deleting the dead call. Do NOT
# add `Code.ensure_loaded?/1`: that is the guard that hid the originals.
#
# Written for bash 3.2 (macOS default): no associative arrays.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

allowlist="scripts/.package-boundaries-allowlist"
if [[ ! -f "$allowlist" ]]; then
  printf 'allowlist not found at %s\n' "$allowlist" >&2
  exit 2
fi

defs_file=$(mktemp)
found_file=$(mktemp)
allowed_file=$(mktemp)
trap 'rm -f "$defs_file" "$found_file" "$allowed_file"' EXIT

# First-party .ex sources: tracked, plus untracked-but-not-ignored so a module
# added in the same change resolves; minus files deleted in the worktree,
# which `git ls-files` still lists. A bare `find` would also walk sibling git
# worktrees under .claude/worktrees/.
sources() {
  {
    git ls-files "$@"
    git ls-files --others --exclude-standard "$@"
  } | sort -u | while IFS= read -r f; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
}

# One `module<TAB>tree` line per defmodule in first-party code, where tree is
# `raxol` for main lib/ or the package name for packages/<name>/lib. Nested
# modules are indented, hence the leading-whitespace allowance.
sources 'lib/*.ex' 'packages/*/lib/*.ex' |
  xargs grep -HE '^[[:space:]]*defmodule Raxol(\.[A-Z][A-Za-z0-9_]*)+ do' |
  sed -E 's#^lib/[^:]*:[[:space:]]*defmodule ([^ ]+) do.*#\1	raxol#; s#^packages/([^/]+)/lib/[^:]*:[[:space:]]*defmodule ([^ ]+) do.*#\2	\1#' |
  sort -u >"$defs_file"

tree_of() {
  # Prints the owning tree(s) of a module, one per line; nothing if undefined.
  grep -E "^$1	" "$defs_file" | cut -f2 | sort -u
}

# raxol_* names a mix.exs declares directly. `raxol_dep(:x` is the
# local-or-Hex helper most mix.exs files use; `{:x,` is the plain form. The
# main app is "raxol" and its mix.exs sits at the repo root.
direct_deps() {
  local mixfile
  if [[ "$1" == "raxol" ]]; then mixfile="mix.exs"; else mixfile="packages/$1/mix.exs"; fi
  [[ -f "$mixfile" ]] || return 0
  { grep -oE '(raxol_dep\(|\{):raxol[a-z_0-9]*' "$mixfile" || true; } | sed -E 's/.*://'
}

# Transitive closure: a package that depends on `raxol` has raxol_core,
# raxol_terminal, raxol_mcp, ... on its code path too. Optional deps count as
# declared; the package has opted into guarding them.
declared_deps() {
  local todo="$1" seen="" next
  while [[ -n "$todo" ]]; do
    next="${todo%% *}"
    todo="${todo#"$next"}"
    todo="${todo# }"
    case " $seen " in *" $next "*) continue ;; esac
    seen="$seen $next"
    todo="$todo $(direct_deps "$next" | tr '\n' ' ')"
    todo="${todo# }"
  done
  printf '%s\n' $seen
}

# No `grep -q`: it exits on the first match, and under pipefail the SIGPIPE
# that hands the producer turns a hit into a miss.
declares() {
  declared_deps "$1" | grep -x "$2" >/dev/null
}

# Every `@compile {:no_warn_undefined, ...}` in a package, with newlines
# folded so multi-line lists are seen whole. The attribute never contains a
# `}` of its own (lists use `[]`), so `[^}]*` reads to its closing brace.
while IFS= read -r file; do
  pkg="${file#packages/}"
  pkg="${pkg%%/*}"

  # A file whose only silenced modules are external (Postgrex, Req) yields
  # nothing here; grep's exit 1 on no match must not end the script.
  mods=$(
    tr '\n' ' ' <"$file" |
      grep -oE '@compile[[:space:]]*\{:no_warn_undefined,[^}]*\}' |
      grep -oE 'Raxol(\.[A-Z][A-Za-z0-9_]*)+' |
      sort -u || true
  )
  [[ -z "$mods" ]] && continue

  while IFS= read -r mod; do
    trees="$(tree_of "$mod" || true)"
    if [[ -z "$trees" ]]; then
      printf '%s\t%s\t%s\n' "$file" "$mod" "undefined"
      continue
    fi
    while IFS= read -r tree; do
      if ! declares "$pkg" "$tree"; then
        printf '%s\t%s\t%s\n' "$file" "$mod" "$tree"
      fi
    done <<<"$trees"
  done <<<"$mods"
done < <(sources 'packages/*/lib/*.ex' | xargs grep -l 'no_warn_undefined' | sort) >"$found_file"

{ grep -vE '^[[:space:]]*(#|$)' "$allowlist" || true; } | sort -u >"$allowed_file"
sort -u -o "$found_file" "$found_file"

status=0

new=$(comm -23 "$found_file" "$allowed_file")
if [[ -n "$new" ]]; then
  printf 'ERROR: package references a module outside its declared dependencies:\n\n' >&2
  printf '%s\n' "$new" | awk -F'\t' '{ printf "  %-70s %-50s owned by %s\n", $1, $2, $3 }' >&2
  printf '\nThe package will raise UndefinedFunctionError there when used standalone.\n' >&2
  printf 'Move the module into the package that owns the concept, read the\n' >&2
  printf 'implementation from application config with an in-package default, or\n' >&2
  printf 'delete the call. See docs/PACKAGES.md ("Boundary rule").\n' >&2
  status=1
fi

stale=$(comm -13 "$found_file" "$allowed_file")
if [[ -n "$stale" ]]; then
  printf 'ERROR: allowlist entries no longer match any no_warn_undefined site:\n\n' >&2
  printf '%s\n' "$stale" | awk -F'\t' '{ printf "  %-70s %s\n", $1, $2 }' >&2
  printf '\nRemove them from %s.\n' "$allowlist" >&2
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  count=$(grep -c . "$found_file" || true)
  printf 'OK: package boundaries hold (%s grandfathered cross-package references)\n' "$count"
fi
exit "$status"
