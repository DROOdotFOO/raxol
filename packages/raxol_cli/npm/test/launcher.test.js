"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { BINARIES } = require("../bin/launcher");
const pkg = require("../package.json");

test("every launcher target has an exactly pinned optional package", () => {
  for (const { pkg: platformPackage } of Object.values(BINARIES)) {
    assert.equal(pkg.optionalDependencies[platformPackage], pkg.version);
  }

  assert.equal(
    Object.keys(pkg.optionalDependencies).length,
    Object.keys(BINARIES).length,
  );
});

test("platform package names and binary names are unique", () => {
  const entries = Object.values(BINARIES);
  assert.equal(new Set(entries.map(({ pkg }) => pkg)).size, entries.length);
  assert.equal(new Set(entries.map(({ bin }) => bin)).size, entries.length);
});
