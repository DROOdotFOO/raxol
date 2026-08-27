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
const { withTerminalRestore } = require("./tty");

// Maps `${platform}-${arch}` to the Burrito output name (`raxol_cli_<target>`)
// and the per-platform package that carries it. Burrito appends `.exe` on
// Windows.
//
// One package per platform, declared as optionalDependencies with `os`/`cpu`
// set, is the esbuild/swc arrangement: npm installs only the entry matching the
// host, so an install downloads one ~68MB binary instead of all four. The
// alternative -- a postinstall that downloads from GitHub Releases -- is worse
// here, because it breaks offline installs, air-gapped CI, and proxied
// registries, all of which a plain dependency handles for free.
const BINARIES = {
  "darwin-arm64": { pkg: "@raxol/cli-darwin-arm64", bin: "raxol_cli_macos" },
  "linux-x64": { pkg: "@raxol/cli-linux-x64", bin: "raxol_cli_linux" },
  "linux-arm64": { pkg: "@raxol/cli-linux-arm64", bin: "raxol_cli_linux_arm" },
  "win32-x64": { pkg: "@raxol/cli-win32-x64", bin: "raxol_cli_windows.exe" },
};

function resolveBinary() {
  const key = `${os.platform()}-${os.arch()}`;
  const entry = BINARIES[key];
  if (!entry) {
    throw new Error(
      `raxol: unsupported platform ${key}. Supported: ${Object.keys(BINARIES).join(", ")}`,
    );
  }

  // The published arrangement.
  try {
    return require.resolve(`${entry.pkg}/${entry.bin}`);
  } catch {
    // Fall through to the vendored layout.
  }

  // A locally built package (`scripts/pack.sh` without publishing) keeps the
  // binaries in vendor/, so a `npm pack` smoke test still works without the
  // per-platform packages existing on any registry.
  const vendored = join(__dirname, "..", "vendor", entry.bin);
  if (existsSync(vendored)) {
    return vendored;
  }

  throw new Error(
    `raxol: no binary for ${key}.\n` +
      `  Expected the optional dependency ${entry.pkg}, or ${vendored}.\n` +
      "  If you installed with --no-optional or --omit=optional, reinstall without it.",
  );
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
  // The interactive agent puts the tty in raw mode; if the BEAM child dies there
  // (crash, SIGSEGV), restore the shell's line settings so it isn't left wedged.
  const result = withTerminalRestore(() =>
    spawnSync(binary, args, { stdio: "inherit" }),
  );

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
