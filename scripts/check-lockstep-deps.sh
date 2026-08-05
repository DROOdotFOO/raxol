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

while IFS= read -r file; do
  check_file "$file"
done < <(find . -name mix.exs -not -path '*/deps/*' -not -path '*/_build/*')

# Prose: install snippets in tracked Markdown. CHANGELOGs and migration guides
# cite older versions deliberately.
while IFS= read -r file; do
  case "$file" in
    *CHANGELOG.md | *MIGRATION*.md | *node_modules/*) continue ;;
  esac
  check_file "$file"
done < <(git ls-files '*.md')

if [[ "$status" -eq 0 ]]; then
  echo "OK: every raxol_* dependency constraint tracks its package version"
else
  echo "" >&2
  echo "Fix: bump the lagging \"~> X.Y\" constraints to match. For mix.exs, also" >&2
  echo "refresh each affected mix.lock (HEX_BUILD=1 mix deps.get)." >&2
fi
exit "$status"
