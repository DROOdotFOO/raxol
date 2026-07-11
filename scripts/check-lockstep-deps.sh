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
# This check fails if any raxol_* dependency constraint's minor version does not
# match the current version of the package it points at. Run it in CI and
# before publishing.
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
while IFS= read -r file; do
  while IFS= read -r match; do
    dep="$(printf '%s' "$match" | grep -oE ':raxol[a-z_]*' | tr -d ':')"
    cmin="$(printf '%s' "$match" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    want="$(minor_of "$(mixfile_for "$dep")" || true)"
    [[ -z "$want" ]] && continue
    if [[ "$cmin" != "$want" ]]; then
      printf 'LAG  %-34s %-16s "~> %s"  but %s is at %s\n' \
        "$file" "$dep" "$cmin" "$dep" "$want"
      status=1
    fi
  done < <(grep -oE ':raxol[a-z_]*, "~> [0-9]+\.[0-9]+' "$file")
done < <(find . -name mix.exs -not -path '*/deps/*' -not -path '*/_build/*')

if [[ "$status" -eq 0 ]]; then
  echo "OK: every raxol_* dependency constraint tracks its package version"
else
  echo "" >&2
  echo "Fix: bump the lagging \"~> X.Y\" constraints to match, then refresh" >&2
  echo "each affected mix.lock (HEX_BUILD=1 mix deps.get)." >&2
fi
exit "$status"
