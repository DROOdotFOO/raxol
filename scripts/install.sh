#!/usr/bin/env bash
# install.sh -- install the `raxol` CLI from GitHub Releases.
#
#   curl -fsSL https://raxol.io/install | bash
#   curl -fsSL https://raxol.io/install | bash -s -- --version 0.2.6
#
# The binary is self-contained (Burrito wraps its own ERTS), so this installs
# one file and needs no Erlang, Elixir, or Node. npm remains an option; this
# exists so Node is not a prerequisite for a terminal tool that does not
# otherwise need it.
#
# Every download is checksum-verified against the release's SHA256SUMS. The
# installer fails closed when either the checksum file or a SHA-256 utility is
# unavailable.
#
# Environment:
#   RAXOL_VERSION       version to install (default: latest release)
#   RAXOL_INSTALL_DIR   install directory (default: ~/.local/bin)

set -euo pipefail

REPO="DROOdotFOO/raxol"
TAG_PREFIX="raxol-cli-v"
VERSION="${RAXOL_VERSION:-}"
INSTALL_DIR="${RAXOL_INSTALL_DIR:-$HOME/.local/bin}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 && -n "$2" ]] || { printf 'install: --version requires a value\n' >&2; exit 64; }
      VERSION="$2"; shift 2
      ;;
    --dir)
      [[ $# -ge 2 && -n "$2" ]] || { printf 'install: --dir requires a value\n' >&2; exit 64; }
      INSTALL_DIR="$2"; shift 2
      ;;
    -h|--help)
      # Print the header comment, stopping at the first line that is not one.
      # A fixed line range goes stale the moment the header is edited.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) printf 'install: unknown option %s\n' "$1" >&2; exit 64 ;;
  esac
done

die() { printf 'install: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

for tool in curl uname mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# -- platform ----------------------------------------------------------------

os=$(uname -s)
arch=$(uname -m)

case "$os-$arch" in
  Darwin-arm64)          binary="raxol_cli_macos" ;;
  Linux-x86_64)          binary="raxol_cli_linux" ;;
  Linux-aarch64|Linux-arm64) binary="raxol_cli_linux_arm" ;;
  Darwin-x86_64)
    die "macOS on Intel is not published; build from source or use an arm64 machine"
    ;;
  *)
    die "unsupported platform $os-$arch (supported: macOS arm64, Linux x86_64/arm64)"
    ;;
esac

# -- version -----------------------------------------------------------------

if [[ -z "$VERSION" ]]; then
  # Resolve the newest raxol-cli-v* tag. The releases list is used rather than
  # /releases/latest, which reports the newest release of ANY tag family in the
  # repo and would happily hand back a non-CLI tag.
  VERSION=$(
    curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" |
      grep '"tag_name"' |
      sed -n "s/.*\"${TAG_PREFIX}\([^\"]*\)\".*/\1/p" |
      head -n 1
  ) || true
  [[ -n "$VERSION" ]] || die "could not resolve the latest ${TAG_PREFIX}* release; pass --version"
fi

tag="${TAG_PREFIX}${VERSION}"
base="https://github.com/$REPO/releases/download/$tag"

note "raxol: installing $VERSION ($binary)"

# -- download + verify -------------------------------------------------------

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$base/$binary" -o "$tmp/$binary" ||
  die "download failed: $base/$binary (is $tag a published release?)"

curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null ||
  die "no SHA256SUMS for $tag; refusing an unverified install"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$binary" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$tmp/$binary" | awk '{print $1}')
else
  die "sha256sum or shasum is required; refusing an unverified install"
fi

expected=$(awk -v b="$binary" '$2 == b || $2 == "*" b {print $1}' "$tmp/SHA256SUMS" | head -n 1)
[[ -n "$expected" ]] || die "no checksum for $binary in SHA256SUMS"
[[ "$actual" == "$expected" ]] ||
  die "checksum mismatch for $binary (expected $expected, got $actual)"
note "raxol: checksum ok"

# -- install -----------------------------------------------------------------

mkdir -p "$INSTALL_DIR" || die "could not create $INSTALL_DIR"
target="$INSTALL_DIR/raxol"

# Replace by rename so a running `raxol` is not corrupted mid-write, and so a
# failed copy cannot leave a truncated binary on PATH.
chmod +x "$tmp/$binary"
mv -f "$tmp/$binary" "$target" || die "could not install to $target"

note "raxol: installed $target"

# Burrito unpacks its payload on first run; do it now so the first real
# invocation is not mistaken for a hang.
if ! "$target" --help >/dev/null 2>&1; then
  die "installed binary did not run -- report this with your platform ($os-$arch)"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    note "raxol: run 'raxol doctor' to check providers and config"
    ;;
  *)
    note ""
    note "raxol: $INSTALL_DIR is not on your PATH. Add it:"
    note ""
    note "    export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac
