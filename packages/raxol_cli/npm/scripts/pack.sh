#!/usr/bin/env bash
# Build the per-platform npm packages from the Burrito-built binaries.
#
# Run after building the release targets
# (`mise exec -- env BURRITO_TARGET=<t> MIX_ENV=prod mix release`), from any dir.
#
# Each platform gets its own package (@raxol/cli-<platform>-<arch>) carrying one
# binary and declaring `os`/`cpu`. The `raxol` wrapper lists all four as
# optionalDependencies, so npm installs only the one matching the host: an
# install pulls ~68MB rather than ~270MB. This is the esbuild arrangement.
#
# Binaries are ALSO copied to vendor/ so a local `npm pack` of the wrapper still
# runs without the per-platform packages existing on a registry. vendor/ is not
# in the wrapper's `files`, so it never ships.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg_root="$(cd "$here/.." && pwd)"          # packages/raxol_cli/npm
cli_root="$(cd "$pkg_root/.." && pwd)"      # packages/raxol_cli
out="$cli_root/burrito_out"
vendor="$pkg_root/vendor"
platforms_dir="$pkg_root/platforms"

if [[ ! -d "$out" ]]; then
  printf 'error: %s not found; build a target first\n' "$out" >&2
  exit 1
fi

version=$(node -p "require('$pkg_root/package.json').version")

# binary name -> "<npm-scope-suffix> <os> <cpu>"
metadata_for() {
  case "$1" in
    raxol_cli_macos)       printf 'darwin-arm64 darwin arm64' ;;
    raxol_cli_linux)       printf 'linux-x64 linux x64' ;;
    raxol_cli_linux_arm)   printf 'linux-arm64 linux arm64' ;;
    raxol_cli_windows.exe) printf 'win32-x64 win32 x64' ;;
    *) return 1 ;;
  esac
}

mkdir -p "$vendor"
rm -rf "$platforms_dir"
mkdir -p "$platforms_dir"

shopt -s nullglob
built=0

for path in "$out"/raxol_cli_*; do
  binary="$(basename "$path")"

  if ! meta=$(metadata_for "$binary"); then
    printf 'warning: no package mapping for %s, skipping\n' "$binary" >&2
    continue
  fi

  read -r suffix os cpu <<<"$meta"
  dir="$platforms_dir/cli-$suffix"
  mkdir -p "$dir"

  cp "$path" "$dir/$binary"
  chmod +x "$dir/$binary"

  # `files` names the binary explicitly: a stray file in this directory must
  # never be published by accident.
  cat >"$dir/package.json" <<JSON
{
  "name": "@raxol/cli-$suffix",
  "version": "$version",
  "description": "raxol CLI binary for $os $cpu. Installed automatically by the \`raxol\` package.",
  "files": [
    "$binary"
  ],
  "os": [
    "$os"
  ],
  "cpu": [
    "$cpu"
  ],
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "git+https://github.com/DROOdotFOO/raxol.git",
    "directory": "packages/raxol_cli/npm"
  }
}
JSON

  cp "$path" "$vendor/$binary"
  chmod +x "$vendor/$binary"

  printf 'packaged @raxol/cli-%s (%s)\n' "$suffix" "$binary"
  built=$((built + 1))
done

if [[ "$built" -eq 0 ]]; then
  printf 'error: no raxol_cli_* binaries in %s\n' "$out" >&2
  exit 1
fi

# The wrapper pins its optional deps to its own version, so a mismatch would
# publish a wrapper that can never resolve a binary. Caught here rather than by
# a user's failed install.
for suffix in darwin-arm64 linux-x64 linux-arm64 win32-x64; do
  pinned=$(node -p "require('$pkg_root/package.json').optionalDependencies['@raxol/cli-$suffix'] || ''")
  if [[ "$pinned" != "$version" ]]; then
    printf 'error: wrapper pins @raxol/cli-%s at "%s" but version is %s\n' \
      "$suffix" "$pinned" "$version" >&2
    exit 1
  fi
done

printf 'done: %d platform package(s) in %s (version %s)\n' "$built" "$platforms_dir" "$version"
