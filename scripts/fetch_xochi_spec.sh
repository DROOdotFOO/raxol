#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 CACHE_DIR PACKAGE_ROOT" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
pin_dir="$repo_root/packages/raxol_payments/test/fixtures"
version="$(tr -d '\r\n' < "$pin_dir/XOCHI_SPEC_VERSION")"
expected_integrity="$(tr -d '\r\n' < "$pin_dir/XOCHI_SPEC_INTEGRITY")"
cache_dir="$1"
package_root="$2"
tarball="$cache_dir/xochi-spec-${version}.tgz"

[[ -n "$version" ]] || { echo "XOCHI_SPEC_VERSION is empty" >&2; exit 1; }
[[ "$expected_integrity" == sha512-* ]] || {
  echo "XOCHI_SPEC_INTEGRITY must contain a sha512 integrity value" >&2
  exit 1
}

mkdir -p "$cache_dir"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xochi-spec.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

candidate_tarball="$tarball"

if [[ ! -f "$tarball" ]]; then
  download_dir="$work_dir/download"
  mkdir -p "$download_dir"

  downloaded=false
  for attempt in 1 2 3; do
    rm -f "$download_dir/xochi-spec-${version}.tgz"
    if npm pack "@xochi/spec@${version}" \
      --ignore-scripts \
      --pack-destination "$download_dir" >/dev/null; then
      downloaded=true
      break
    fi
    echo "npm pack attempt ${attempt}/3 failed" >&2
  done

  [[ "$downloaded" == true ]] || {
    echo "failed to download @xochi/spec@${version} after 3 attempts" >&2
    exit 1
  }

  downloaded_tarball="$download_dir/xochi-spec-${version}.tgz"
  [[ -f "$downloaded_tarball" ]] || {
    echo "npm pack did not produce xochi-spec-${version}.tgz" >&2
    exit 1
  }
  candidate_tarball="$downloaded_tarball"
fi

actual_integrity="sha512-$(node -e '
  const fs = require("node:fs");
  const crypto = require("node:crypto");
  const bytes = fs.readFileSync(process.argv[1]);
  process.stdout.write(crypto.createHash("sha512").update(bytes).digest("base64"));
' "$candidate_tarball")"

if [[ "$actual_integrity" != "$expected_integrity" ]]; then
  echo "integrity mismatch for $candidate_tarball" >&2
  echo "expected: $expected_integrity" >&2
  echo "actual:   $actual_integrity" >&2
  exit 1
fi
if [[ "$candidate_tarball" != "$tarball" ]]; then
  mv "$candidate_tarball" "$tarball"
fi

extract_dir="$work_dir/extract"
mkdir -p "$extract_dir"
tar -xzf "$tarball" -C "$extract_dir"
extracted_root="$extract_dir/package"

node -e '
  const fs = require("node:fs");
  const path = require("node:path");
  const root = process.argv[1];
  const expectedVersion = process.argv[2];
  const manifestPath = path.join(root, "package.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (manifest.name !== "@xochi/spec" || manifest.version !== expectedVersion) {
    throw new Error("expected @xochi/spec@" + expectedVersion + ", got " + manifest.name + "@" + manifest.version);
  }
  for (const relative of ["conformance/conformance.json", "fee/schedule.json"]) {
    const file = path.join(root, relative);
    if (!fs.statSync(file).isFile()) throw new Error(relative + " is not a regular file");
  }
' "$extracted_root" "$version"

mkdir -p "$(dirname "$package_root")"
rm -rf "$package_root"
mv "$extracted_root" "$package_root"
printf '%s\n' "$package_root"
