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

# Evaluate the formatter config in a child process, as `mix format` does. The
# child validates loader options itself and communicates only through its exit
# status and stderr. Formatter files are executable Elixir and may write to
# stdout, so stdout cannot safely carry a line-oriented result protocol.
formatter_loader_error() {
  elixir scripts/check_formatter_loaders.exs "$1" >/dev/null
}

shopt -s nullglob
package_count=0

for dir in packages/*/; do
  pkg="$(basename "$dir")"

  # A package is defined by its mix.exs. A MISSING .formatter.exs is a failure
  # rather than a skip: the root config delegates `packages/*` by glob, so a
  # package without one silently falls back to the root's 80 columns -- and
  # skipping it would report that as a green check that checked nothing.
  if [[ ! -f "$dir/mix.exs" ]]; then
    continue
  fi

  package_count=$((package_count + 1))

  if [[ ! -f "$dir/.formatter.exs" ]]; then
    err "$pkg has no .formatter.exs, so the root glob formats it at 80 columns while its own gate expects 98. Add one (copy any sibling package's)."
    failed=1
    continue
  fi

  # This script's cheapness is the reason it is not in `package-tests`.
  # `import_deps:` and `plugins:` both make the formatter load compiled code,
  # while nothing here fetches or compiles package dependencies.
  if ! loader_error="$(formatter_loader_error "$dir/.formatter.exs" 2>&1)"; then
    err "$pkg $loader_error"
    failed=1
    continue
  fi

  if ! (cd "$dir" && mix format --check-formatted); then
    err "$pkg is not formatted. Run: (cd $dir && mix format)"
    failed=1
  fi
done

if [[ "$package_count" -eq 0 ]]; then
  err "no packages found; run this check from a checkout containing packages/*/mix.exs"
  failed=1
fi

if [[ "$failed" -eq 0 ]]; then
  echo "All packages formatted."
fi

exit "$failed"
