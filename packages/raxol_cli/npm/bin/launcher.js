#!/usr/bin/env node
// Resolves the Burrito-built `raxol` binary for the current platform/arch and
// execs it, forwarding argv, stdio, and the environment. All subcommands
// (`raxol`, `raxol agent`, `raxol playground`, `raxol new`, `raxol help`) are
// handled inside the binary.
"use strict";

const { spawnSync } = require("node:child_process");
const { join } = require("node:path");
const { existsSync } = require("node:fs");
const os = require("node:os");

// Maps `${platform}-${arch}` to the Burrito output name (`raxol_cli_<target>`).
const BINARIES = {
  "darwin-arm64": "raxol_cli_macos",
  "linux-x64": "raxol_cli_linux",
  "linux-arm64": "raxol_cli_linux_arm",
};

function resolveBinary() {
  const key = `${os.platform()}-${os.arch()}`;
  const name = BINARIES[key];
  if (!name) {
    throw new Error(
      `raxol: unsupported platform ${key}. Supported: ${Object.keys(BINARIES).join(", ")}`,
    );
  }
  const path = join(__dirname, "..", "vendor", name);
  if (!existsSync(path)) {
    throw new Error(
      `raxol: binary missing for ${key} (expected ${path}). ` +
        "The package may have been built without this platform's binary.",
    );
  }
  return path;
}

function main() {
  let binary;
  try {
    binary = resolveBinary();
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  // `--no-halt --` tames Burrito's `-s elixir start_cli`: `--` makes it treat the
  // subcommand as argv rather than a script it reads from stdin (which would
  // starve the interactive agent), and `--no-halt` stops it halting the VM. The
  // binary strips the `--no-halt --` prefix when reading its arguments.
  const args = ["--no-halt", "--", ...process.argv.slice(2)];
  const result = spawnSync(binary, args, { stdio: "inherit" });

  if (result.error) {
    console.error(`raxol: failed to launch: ${result.error.message}`);
    process.exit(1);
  }
  if (result.signal) {
    process.exit(128 + (os.constants.signals[result.signal] || 0));
  }
  process.exit(result.status ?? 0);
}

main();
