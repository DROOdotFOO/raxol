#!/usr/bin/env bash
# install.sh -- install the `raxol` CLI from an immutable GitHub Release.
#
#   curl -fsSL https://raxol.io/install | bash
#   curl -fsSL https://raxol.io/install | bash -s -- --version 0.2.10
#   curl -fsSL https://raxol.io/install | bash -s -- --verify-provenance
#
# The binary is self-contained (Burrito wraps its own ERTS), so this installs
# one file and needs no Erlang, Elixir, or Node. npm remains an option.
#
# Every download is verified against the release manifest's SHA-256 digest.
# `--verify-provenance` additionally requires GitHub CLI and proves the binary
# was produced by the tagged Raxol release workflow. Verification fails closed.
#
# Environment:
#   RAXOL_VERSION             version to install (default: latest release)
#   RAXOL_INSTALL_DIR         install directory (default: ~/.local/bin)
#   RAXOL_VERIFY_PROVENANCE   1 to require GitHub artifact verification
set -euo pipefail

REPO="DROOdotFOO/raxol"
TAG_PREFIX="raxol-cli-v"
LATEST_MANIFEST_URL="https://raxol.io/releases/latest.json"
EXPECTED_SIGNER="$REPO/.github/workflows/release-raxol-cli.yml"
VERSION="${RAXOL_VERSION:-}"
INSTALL_DIR="${RAXOL_INSTALL_DIR:-$HOME/.local/bin}"
VERIFY_PROVENANCE="${RAXOL_VERIFY_PROVENANCE:-0}"

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
    --verify-provenance)
      VERIFY_PROVENANCE=1; shift
      ;;
    -h|--help)
      # Print the header comment, stopping at the first line that is not one.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) printf 'install: unknown option %s\n' "$1" >&2; exit 64 ;;
  esac
done

case "$VERIFY_PROVENANCE" in
  0|1) ;;
  *) printf 'install: RAXOL_VERIFY_PROVENANCE must be 0 or 1\n' >&2; exit 64 ;;
esac

die() { printf 'install: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

for tool in curl uname mktemp sed; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# -- platform ----------------------------------------------------------------

os=$(uname -s)
arch=$(uname -m)

case "$os-$arch" in
  Darwin-arm64)             platform="darwin-arm64"; binary="raxol_cli_macos" ;;
  Linux-x86_64)             platform="linux-x64"; binary="raxol_cli_linux" ;;
  Linux-aarch64|Linux-arm64) platform="linux-arm64"; binary="raxol_cli_linux_arm" ;;
  Darwin-x86_64)
    die "macOS on Intel is not published; build from source or use an arm64 machine"
    ;;
  *)
    die "unsupported platform $os-$arch (supported: macOS arm64, Linux x86_64/arm64)"
    ;;
esac

# -- manifest + verification -------------------------------------------------

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
manifest="$tmp/manifest.json"
requested_version="$VERSION"

if [[ -n "$requested_version" ]]; then
  [[ "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "invalid version $requested_version (expected MAJOR.MINOR.PATCH)"
  requested_tag="${TAG_PREFIX}${requested_version}"
  manifest_url="https://github.com/$REPO/releases/download/$requested_tag/raxol-cli-manifest.json"
else
  manifest_url="$LATEST_MANIFEST_URL"
fi

if ! curl -fsSL "$manifest_url" -o "$manifest"; then
  if [[ -n "$requested_version" ]]; then
    die "release manifest unavailable: $manifest_url"
  else
    die "latest release manifest unavailable: $manifest_url; pass --version"
  fi
fi

manifest_string() {
  local key="$1"
  local value
  value=$(sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\\([^\"]*\\)\"[,]*[[:space:]]*$/\\1/p" "$manifest")
  [[ -n "$value" && "$value" != *$'\n'* ]] ||
    die "manifest has invalid or duplicate $key"
  printf '%s' "$value"
}

schema_version=$(sed -n 's/^[[:space:]]*"schema_version":[[:space:]]*\([0-9][0-9]*\),*[[:space:]]*$/\1/p' "$manifest")
[[ "$schema_version" == "1" ]] || die "unsupported release manifest schema"

VERSION=$(manifest_string version)
tag=$(manifest_string tag)
repository=$(manifest_string repository)
signer_workflow=$(manifest_string signer_workflow)

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "manifest contains invalid version $VERSION"
[[ "$tag" == "${TAG_PREFIX}${VERSION}" ]] ||
  die "manifest tag $tag does not match version $VERSION"
[[ "$repository" == "$REPO" ]] || die "manifest repository is not $REPO"
[[ "$signer_workflow" == "$EXPECTED_SIGNER" ]] ||
  die "manifest signer workflow is not $EXPECTED_SIGNER"
[[ -z "$requested_version" || "$VERSION" == "$requested_version" ]] ||
  die "manifest version $VERSION does not match requested version $requested_version"

asset_block=$(sed -n \
  "/^[[:space:]]*\"${platform}\":[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}[,]*[[:space:]]*$/p" \
  "$manifest")
[[ -n "$asset_block" ]] || die "manifest has no asset for $platform"

asset_string() {
  local key="$1"
  local value
  value=$(printf '%s\n' "$asset_block" |
    sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\\([^\"]*\\)\"[,]*[[:space:]]*$/\\1/p")
  [[ -n "$value" && "$value" != *$'\n'* ]] ||
    die "manifest asset has invalid or duplicate $key"
  printf '%s' "$value"
}

asset_name=$(asset_string name)
asset_url=$(asset_string url)
expected=$(asset_string sha256)
attestation_url=$(asset_string attestation_url)
base="https://github.com/$REPO/releases/download/$tag"

[[ "$asset_name" == "$binary" ]] ||
  die "manifest asset $asset_name does not match platform binary $binary"
[[ "$asset_url" == "$base/$binary" ]] || die "manifest contains an invalid asset URL"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]] || die "manifest contains an invalid SHA-256 digest"
[[ "$attestation_url" == "$base/raxol-cli-attestation.sigstore.json" ]] ||
  die "manifest contains an invalid attestation URL"

note "raxol: installing $VERSION ($binary)"

curl -fsSL "$asset_url" -o "$tmp/$binary" ||
  die "download failed: $asset_url (is $tag a published release?)"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$binary" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$tmp/$binary" | awk '{print $1}')
else
  die "sha256sum or shasum is required; refusing an unverified install"
fi

[[ "$actual" == "$expected" ]] ||
  die "checksum mismatch for $binary (expected $expected, got $actual)"
note "raxol: checksum ok"

if [[ "$VERIFY_PROVENANCE" == "1" ]]; then
  command -v gh >/dev/null 2>&1 ||
    die "gh is required by --verify-provenance; refusing installation"
  curl -fsSL "$attestation_url" -o "$tmp/attestation.sigstore.json" ||
    die "attestation unavailable for $tag; refusing installation"
  gh attestation verify "$tmp/$binary" \
    --bundle "$tmp/attestation.sigstore.json" \
    --repo "$REPO" \
    --signer-workflow "$signer_workflow" \
    --source-ref "refs/tags/$tag" \
    --cert-oidc-issuer "https://token.actions.githubusercontent.com" \
    --deny-self-hosted-runners >/dev/null ||
    die "provenance verification failed for $binary"
  note "raxol: provenance ok"
fi

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
