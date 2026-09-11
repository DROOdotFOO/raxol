#!/usr/bin/env node

import {readFile, writeFile} from "node:fs/promises";

const repository = "DROOdotFOO/raxol";
const signerWorkflow =
  "DROOdotFOO/raxol/.github/workflows/release-raxol-cli.yml";
const assets = {
  "darwin-arm64": "raxol_cli_macos",
  "linux-x64": "raxol_cli_linux",
  "linux-arm64": "raxol_cli_linux_arm",
  "win32-x64": "raxol_cli_windows.exe",
};

function fail(message) {
  throw new Error(`release manifest: ${message}`);
}

function parseChecksums(contents) {
  const checksums = new Map();

  for (const line of contents.trim().split("\n")) {
    const match = line.match(/^([a-f0-9]{64})\s+\*?(\S+)$/);
    if (!match) fail(`invalid checksum line: ${line}`);

    const [, checksum, name] = match;
    if (checksums.has(name)) fail(`duplicate checksum for ${name}`);
    checksums.set(name, checksum);
  }

  const expectedNames = new Set(Object.values(assets));
  for (const name of checksums.keys()) {
    if (!expectedNames.has(name)) fail(`unexpected release asset ${name}`);
  }
  for (const name of expectedNames) {
    if (!checksums.has(name)) fail(`missing checksum for ${name}`);
  }

  return checksums;
}

async function main() {
  const [version, checksumsPath, outputPath] = process.argv.slice(2);
  if (!version || !checksumsPath || !outputPath) {
    fail("usage: build_cli_release_manifest.mjs VERSION SHA256SUMS OUTPUT");
  }
  if (!/^\d+\.\d+\.\d+$/.test(version)) fail(`invalid version ${version}`);

  const publishedAt = process.env.RAXOL_RELEASED_AT || new Date().toISOString();
  if (Number.isNaN(Date.parse(publishedAt))) {
    fail(`invalid RAXOL_RELEASED_AT ${publishedAt}`);
  }

  const tag = `raxol-cli-v${version}`;
  const base = `https://github.com/${repository}/releases/download/${tag}`;
  const bundleUrl = `${base}/raxol-cli-attestation.sigstore.json`;
  const checksums = parseChecksums(await readFile(checksumsPath, "utf8"));

  const manifest = {
    schema_version: 1,
    version,
    tag,
    published_at: publishedAt,
    repository,
    signer_workflow: signerWorkflow,
    assets: Object.fromEntries(
      Object.entries(assets).map(([platform, name]) => [
        platform,
        {
          name,
          url: `${base}/${name}`,
          sha256: checksums.get(name),
          attestation_url: bundleUrl,
        },
      ]),
    ),
  };

  await writeFile(outputPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
