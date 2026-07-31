#!/usr/bin/env bash
# Copy the Burrito-built runtime binaries into the npm package's vendor/ dir so
# `npm pack`/`npm publish` ships them. Run after building the release targets
# (`mise exec -- env BURRITO_TARGET=<t> MIX_ENV=prod mix release`), from any dir.
#
# Linux binaries must be built on Linux (see mix.exs: the termbox NIF Makefile
# keys its macOS-only link flag off the build host's uname); a full multi-arch
# package is assembled in CI by running this on each host and merging vendor/.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg_root="$(cd "$here/.." && pwd)"          # packages/raxol_console/npm
console_root="$(cd "$pkg_root/.." && pwd)"  # packages/raxol_console
out="$console_root/burrito_out"
vendor="$pkg_root/vendor"

if [[ ! -d "$out" ]]; then
  printf 'error: %s not found; build a target first\n' "$out" >&2
  exit 1
fi

mkdir -p "$vendor"
shopt -s nullglob
copied=0
for bin in "$out"/raxol_console_*; do
  cp "$bin" "$vendor/"
  chmod +x "$vendor/$(basename "$bin")"
  printf 'vendored %s\n' "$(basename "$bin")"
  copied=$((copied + 1))
done

if [[ "$copied" -eq 0 ]]; then
  printf 'error: no raxol_console_* binaries in %s\n' "$out" >&2
  exit 1
fi
printf 'done: %d binary(ies) in %s\n' "$copied" "$vendor"
