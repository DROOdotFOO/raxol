#!/usr/bin/env bash
# Format-check every package under packages/ using that package's OWN
# .formatter.exs.
#
# The root `mix format --check-formatted` cannot do this. Its `inputs` stop at
# the repo root, so it only ever reaches package files a caller names
# explicitly -- which is how nine packages accumulated ~145 files of drift while
# every gated package stayed clean.
#
# Deliberately not part of the `package-tests` matrix: that job compiles a
# package and runs its suite. `mix format` reads .formatter.exs and the source
# and compiles nothing, so gating all 17 there would buy a whitespace check at
# the price of 17 full suites.
#
# Exit codes: 0 all clean, 1 at least one package failed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

failed=0

# GitHub Actions renders `::error::` as an annotation; elsewhere it is just a
# prefix on stderr, which is why the message stands on its own without it.
err() {
  printf '::error::%s\n' "$1" >&2
}

# The deps a package's formatter config would make `mix format` LOAD.
#
# Evaluated rather than grepped. `import_deps: []` and `import_deps: [:phoenix]`
# differ by one character and a multi-line list defeats a line-based match
# entirely, so a regex here is a gate that reports clean for the shape it exists
# to catch. A .formatter.exs is a literal term; evaluating it is what `mix
# format` itself does.
import_deps_of() {
  elixir -e '
    [path] = System.argv()
    {opts, _bindings} = Code.eval_file(path)
    opts |> Keyword.get(:import_deps, []) |> Enum.join(", ") |> IO.write()
  ' "$1"
}

for dir in packages/*/; do
  pkg="$(basename "$dir")"

  # A package is defined by its mix.exs. A MISSING .formatter.exs is a failure
  # rather than a skip: the root config delegates `packages/*` by glob, so a
  # package without one silently falls back to the root's 80 columns -- and
  # skipping it would report that as a green check that checked nothing.
  if [[ ! -f "$dir/mix.exs" ]]; then
    continue
  fi

  if [[ ! -f "$dir/.formatter.exs" ]]; then
    err "$pkg has no .formatter.exs, so the root glob formats it at 80 columns while its own gate expects 98. Add one (copy any sibling package's)."
    failed=1
    continue
  fi

  # This script's cheapness is the reason it is not in `package-tests`, and
  # `import_deps:` is the one option that would cost it: the formatter loads the
  # named deps, and nothing here runs `mix deps.get` inside a package. Caught by
  # name so the failure does not arrive as an unrelated "could not find dep".
  deps="$(import_deps_of "$dir/.formatter.exs")"
  if [[ -n "$deps" ]]; then
    err "$pkg sets import_deps: [$deps], which makes mix format load those deps. This check does not fetch them. Either drop it, or move this package into the package-tests matrix where deps are available."
    failed=1
    continue
  fi

  if ! (cd "$dir" && mix format --check-formatted); then
    err "$pkg is not formatted. Run: (cd $dir && mix format)"
    failed=1
  fi
done

if [[ "$failed" -eq 0 ]]; then
  echo "All packages formatted."
fi

exit "$failed"
