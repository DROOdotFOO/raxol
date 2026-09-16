#!/usr/bin/env bash
#
# Guard against lagging inter-package version constraints.
#
# Every raxol_* package declares its sibling deps with a "~> X.Y" constraint.
# When the family is bumped (say 2.5 -> 2.6) but a dependent still says
# "~> 2.4", HEX_BUILD resolves the stale *published* sibling (2.4.0) instead of
# the new one, so the package is built and published against incompatible code.
# That is exactly how a 2.6.0 publish ended up compiling against raxol_core
# 2.4.0 and failing under Elixir 1.20.
#
# The same constraint appears in prose: every README and install snippet tells a
# reader which version to depend on, and those drift silently because nothing
# resolves them. A stale snippet points users at an old published package.
#
# This check fails if any raxol_* dependency constraint's minor version does not
# match the current version of the package it points at, in mix.exs files and in
# tracked Markdown. Run it in CI and before publishing.
#
# CHANGELOG and migration docs are exempt: they describe past versions on
# purpose.
#
# Written for bash 3.2 (macOS default): no associative arrays.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

minor_of() {
  [[ -f "$1" ]] || return 1
  grep -oE '@version "[0-9]+\.[0-9]+' "$1" | head -1 | grep -oE '[0-9]+\.[0-9]+$'
}

# mix.exs path that defines the given raxol package's @version.
mixfile_for() {
  if [[ "$1" == "raxol" ]]; then echo "mix.exs"; else echo "packages/$1/mix.exs"; fi
}

status=0
check_file() {
  local file="$1"
  while IFS= read -r match; do
    dep="$(printf '%s' "$match" | grep -oE ':raxol[a-z_]*' | tr -d ':')"
    cmin="$(printf '%s' "$match" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    want="$(minor_of "$(mixfile_for "$dep")" || true)"
    [[ -z "$want" ]] && continue
    if [[ "$cmin" != "$want" ]]; then
      printf 'LAG  %-46s %-30s "~> %s"  but %s is at %s\n' \
        "$file" "$dep" "$cmin" "$dep" "$want"
      status=1
    fi
  done < <(grep -oE ':raxol[a-z_]*, "~> [0-9]+\.[0-9]+' "$file")
}

# mix.exs: tracked files, plus untracked-but-not-ignored ones. A bare `find`
# also descends into sibling git worktrees (.claude/worktrees/*, other
# branches) and into the deliberately malformed mix.exs fixtures that
# Raxol.Release.PackageCheckTest leaves under tmp/, which made the verdict
# depend on whether the suite had run. `git ls-files` sees neither.
#
# `--others --exclude-standard` is unioned in because a NEW package's mix.exs
# is untracked until it is staged, and that file is the one most likely to
# carry a lagging `~> 2.6`: a developer adding a package otherwise got a green
# local run and a red CI one, which is the wrong way round for a gate whose
# whole job is to catch drift before it lands. CI is unaffected -- a checkout
# has no untracked files.
while IFS= read -r file; do
  check_file "$file"
done < <(
  {
    git ls-files 'mix.exs' '*/mix.exs'
    git ls-files --others --exclude-standard 'mix.exs' '*/mix.exs'
  } | sort -u
)

# Prose: install snippets in tracked Markdown. CHANGELOGs and migration guides
# cite older versions deliberately.
while IFS= read -r file; do
  case "$file" in
    *CHANGELOG.md | *MIGRATION*.md | *node_modules/*) continue ;;
  esac
  check_file "$file"
done < <(git ls-files '*.md')

# Dependency-graph drift across the 18 lockfiles.
#
# The sweep above compares only sibling `:raxol_*, "~> X.Y"` CONSTRAINTS, which
# is why nothing had ever reported that ex_doc was pinned at four different
# versions at once (0.40.1 in eleven packages, 0.40.2 in one, 0.40.3 in four
# and the root) or that mox sat at 1.2.0 in three packages while the root moved
# to 1.3.1. Runtime graph changes are equally important: an Nx/Complex major
# split or an APNS transport/JWT migration must not disappear inside a broad
# toolchain bump.
#
# Reported, not failed, and it has to be: packages intentionally resolve
# different compatible versions when their constraints differ, and a package
# with raxol siblings cannot have its lockfile regenerated at all while the
# family's new version is unpublished. The report makes drift reviewable
# without making the release window unsatisfiable.
for dependency in \
  ex_doc mox credo dialyxir excoveralls sobelow mix_audit \
  raxol_core nx complex mint finch joken pigeon; do
  versions=$(
    git ls-files 'mix.lock' '*/mix.lock' |
      xargs grep -ohE "\"$dependency\": \{:hex, :$dependency, \"[0-9][^\"]*\"" 2>/dev/null |
      sed -E 's/.*"([0-9][^"]*)".*/\1/' | sort -u
  )
  count=$(printf '%s\n' "$versions" | grep -c . || true)

  if [[ "$count" -gt 1 ]]; then
    printf 'DRIFT: %s is locked at %s different versions across the lockfiles: %s\n' \
      "$dependency" "$count" "$(printf '%s' "$versions" | tr '\n' ' ')"
  fi
done

if [[ "$status" -eq 0 ]]; then
  echo "OK: every raxol_* dependency constraint tracks its package version"
else
  echo "" >&2
  echo "Fix: bump the lagging \"~> X.Y\" constraints to match. For mix.exs, also" >&2
  echo "refresh each affected mix.lock (HEX_BUILD=1 mix deps.get)." >&2
fi
exit "$status"
