#!/usr/bin/env node
// Resolves the Burrito-built, self-contained runtime binary for the current
// platform/arch and execs it, forwarding argv, stdio, and the environment.
// The Console's acp-cli runs e.g. `raxol-console start`; RAXOL_CONSOLE_PACKAGE
// and the other RAXOL_CONSOLE_* env vars flow through untouched.
"use strict";

const { spawnSync } = require("node:child_process");
const { join } = require("node:path");
const { existsSync } = require("node:fs");
const os = require("node:os");

// Maps `${platform}-${arch}` to the Burrito output name (`raxol_console_<target>`).
const BINARIES = {
  "darwin-arm64": "raxol_console_macos",
  "linux-x64": "raxol_console_linux",
  "linux-arm64": "raxol_console_linux_arm",
};

function resolveBinary() {
  const key = `${os.platform()}-${os.arch()}`;
  const name = BINARIES[key];
  if (!name) {
    throw new Error(
      `raxol-console: unsupported platform ${key}. Supported: ${Object.keys(BINARIES).join(", ")}`,
    );
  }
  const path = join(__dirname, "..", "vendor", name);
  if (!existsSync(path)) {
    throw new Error(
      `raxol-console: runtime binary missing for ${key} (expected ${path}). ` +
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

  // A Burrito-wrapped release starts the runtime when invoked with no args and
  // reserves args for its own maintenance CLI. Accept a leading `start` (what a
  // caller expecting a release script would pass) as "start the runtime", and
  // forward anything else through to Burrito unchanged.
  let args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "start") {
    args = [];
  }

  const result = spawnSync(binary, args, { stdio: "inherit" });
  if (result.error) {
    console.error(`raxol-console: failed to launch runtime: ${result.error.message}`);
    process.exit(1);
  }
  // Mirror signal-terminated exits as 128+signal, matching shell convention.
  if (result.signal) {
    process.exit(128 + (os.constants.signals[result.signal] || 0));
  }
  process.exit(result.status ?? 0);
}

main();
