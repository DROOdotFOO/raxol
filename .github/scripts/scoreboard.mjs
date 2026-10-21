#!/usr/bin/env node
// Scoreboard tooling for CI. Node 20+, no dependencies.
//
// Records come from CI artifacts built from pull request code, so every
// record, event file and stored history line is treated as untrusted data:
// size-capped, schema-checked, metric ids checked against the committed
// definitions, values checked to be finite non-negative numbers. Anything
// that ends up in markdown or $GITHUB_OUTPUT is restricted to safe characters.
//
// Subcommands:
//   validate --defs FILE --record FILE [--as fresh|candidate|stored] [--expect-commit SHA]
//   compare  --defs FILE --base FILE|- --head FILE [--base-label T] [--head-label T]
//            (head read as "candidate", base as "stored"; see validateRecord)
//   badges   --defs FILE --record FILE --out DIR
//   release  --defs FILE --records FILE --from SHA --to SHA [--from-label T] [--to-label T]
//   lookup   --defs FILE --records FILE --commit SHA   (prints the record, or nothing)
//   commits  --defs FILE --records FILE                (recorded commits, one per line)
//   publish  --defs FILE --record FILE --dir DIR --run-id N [--recorded-at ISO]
//   event    --file FILE                               (key=value lines for $GITHUB_OUTPUT)

import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

const MARKER = "<!-- raxol-scoreboard -->";
const RECORD_MAX_BYTES = 64 * 1024;
const RECORDS_MAX_BYTES = 64 * 1024 * 1024;
const ID_RE = /^[a-z0-9_.]+$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const TOOLCHAIN_RE = /^[A-Za-z0-9._+-]{1,64}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;
const TOOLCHAIN_KEYS = ["elixir", "otp", "system_arch"];
const RECORD_KEYS = new Set(["schema", "commit", "toolchain", "metrics", "recorded_at", "run_id"]);

class InvalidInput extends Error {}

const fail = (msg) => {
  throw new InvalidInput(msg);
};

const isPlainObject = (v) =>
  v !== null && typeof v === "object" && !Array.isArray(v) && Object.getPrototypeOf(v) === Object.prototype;

function readCapped(file, max, what) {
  let size;
  try {
    size = statSync(file).size;
  } catch (e) {
    fail(`${what} ${file}: cannot read (${e.code ?? e.message})`);
  }
  if (size > max) fail(`${what} ${file}: ${size} bytes exceeds the ${max} byte limit`);
  return readFileSync(file, "utf8");
}

function parseJson(text, what) {
  try {
    return JSON.parse(text);
  } catch (e) {
    fail(`${what}: not valid JSON (${e.message})`);
  }
}

// ---------------------------------------------------------------- definitions

function validateDefs(raw) {
  if (!isPlainObject(raw)) fail("defs: top level must be an object");
  if (raw.schema !== 1) fail(`defs: unsupported schema ${JSON.stringify(raw.schema)}`);
  if (!Array.isArray(raw.metrics) || raw.metrics.length === 0) fail("defs: metrics must be a non-empty array");
  const byId = new Map();
  for (const [i, m] of raw.metrics.entries()) {
    const where = `defs: metrics[${i}]`;
    if (!isPlainObject(m)) fail(`${where} must be an object`);
    if (typeof m.id !== "string" || !ID_RE.test(m.id)) fail(`${where}.id must match ${ID_RE}`);
    if (byId.has(m.id)) fail(`${where}.id ${m.id} is duplicated`);
    if (typeof m.label !== "string" || m.label.trim() === "") fail(`${where}.label must be a non-empty string`);
    if (typeof m.unit !== "string") fail(`${where}.unit must be a string`);
    if (m.better !== "lower" && m.better !== "higher") fail(`${where}.better must be "lower" or "higher"`);
    if (typeof m.tolerance !== "number" || !Number.isFinite(m.tolerance) || m.tolerance < 0) {
      fail(`${where}.tolerance must be a finite number >= 0`);
    }
    if (m.headline !== undefined && typeof m.headline !== "boolean") fail(`${where}.headline must be a boolean`);
    byId.set(m.id, {
      id: m.id,
      label: m.label,
      unit: m.unit,
      better: m.better,
      tolerance: m.tolerance,
      headline: m.headline === true,
    });
  }
  return { list: [...byId.values()], byId };
}

function loadDefs(file) {
  return validateDefs(parseJson(readCapped(file, RECORD_MAX_BYTES, "defs"), `defs ${file}`));
}

// -------------------------------------------------------------------- records

// `mode` says where the record came from, chosen by the caller, never by the
// record:
//   "fresh"     a CI artifact headed for history (publish): defined ids only,
//               and no `recorded_at`/`run_id`, which only publish adds.
//   "candidate" a CI artifact shown in a pull request comment: as "fresh",
//               except ids master does not define yet (the PR adds them) are
//               set aside in `unknown` instead of failing the comment.
//   "stored"    a line of the gh-pages history: ids retired from the defs
//               since it was written are dropped, so removing a metric never
//               orphans old history.
const MODES = new Set(["fresh", "candidate", "stored"]);

function validateRecord(raw, defs, what, mode) {
  if (!MODES.has(mode)) throw new Error(`unknown record mode ${mode}`);
  if (!isPlainObject(raw)) fail(`${what}: top level must be an object`);
  for (const key of Object.keys(raw)) {
    if (!RECORD_KEYS.has(key)) fail(`${what}: unexpected key ${JSON.stringify(key)}`);
  }
  if (mode !== "stored" && (raw.recorded_at !== undefined || raw.run_id !== undefined)) {
    fail(`${what}: recorded_at and run_id are set by the publish step, not by CI`);
  }
  if (raw.schema !== 1) fail(`${what}: unsupported schema ${JSON.stringify(raw.schema)}`);
  if (typeof raw.commit !== "string" || !SHA_RE.test(raw.commit)) fail(`${what}: commit must be a 40-character lowercase hex sha`);

  if (!isPlainObject(raw.toolchain)) fail(`${what}: toolchain must be an object`);
  for (const key of Object.keys(raw.toolchain)) {
    if (!TOOLCHAIN_KEYS.includes(key)) fail(`${what}: unexpected toolchain key ${JSON.stringify(key)}`);
  }
  const toolchain = {};
  for (const key of TOOLCHAIN_KEYS) {
    const v = raw.toolchain[key];
    if (typeof v !== "string" || !TOOLCHAIN_RE.test(v)) fail(`${what}: toolchain.${key} must match ${TOOLCHAIN_RE}`);
    toolchain[key] = v;
  }

  if (!isPlainObject(raw.metrics)) fail(`${what}: metrics must be an object`);
  const metrics = {};
  const unknown = [];
  for (const [id, value] of Object.entries(raw.metrics)) {
    if (!defs.byId.has(id)) {
      if (mode === "fresh" || !ID_RE.test(id)) {
        fail(`${what}: metric ${JSON.stringify(id)} is not defined in the metric definitions`);
      }
      if (mode === "stored") process.stderr.write(`warning: ${what}: dropping retired metric ${id}\n`);
      else unknown.push(id);
      continue;
    }
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
      fail(`${what}: metric ${id} must be a finite number between 0 and ${Number.MAX_SAFE_INTEGER}`);
    }
    metrics[id] = value;
  }

  const record = { schema: 1, commit: raw.commit, toolchain, metrics };
  if (unknown.length > 0) Object.defineProperty(record, "unknown", { value: unknown.sort(), enumerable: false });
  if (raw.recorded_at !== undefined) {
    if (typeof raw.recorded_at !== "string" || !ISO_RE.test(raw.recorded_at)) fail(`${what}: recorded_at must be an ISO-8601 UTC time`);
    record.recorded_at = raw.recorded_at;
  }
  if (raw.run_id !== undefined) {
    if (!Number.isSafeInteger(raw.run_id) || raw.run_id <= 0) fail(`${what}: run_id must be a positive integer`);
    record.run_id = raw.run_id;
  }
  return record;
}

function loadRecord(file, defs, mode) {
  const what = `record ${file}`;
  return validateRecord(parseJson(readCapped(file, RECORD_MAX_BYTES, "record"), what), defs, what, mode);
}

// records.jsonl is only ever written by the publish job, but it still passes
// through validation. Lines are parsed lazily: only the lines that are asked
// for (by commit) have to be valid, so one corrupt line cannot hide the rest
// of the history, while a corrupt line that is asked for is an error.
function readHistory(file) {
  if (!existsSync(file)) return [];
  const text = readCapped(file, RECORDS_MAX_BYTES, "records");
  const lines = [];
  for (const [i, line] of text.split("\n").entries()) {
    if (line.trim() === "") continue;
    if (Buffer.byteLength(line) > RECORD_MAX_BYTES) fail(`records ${file}:${i + 1}: line exceeds ${RECORD_MAX_BYTES} bytes`);
    lines.push({ lineNo: i + 1, line });
  }
  return lines;
}

function lineCommit(entry) {
  try {
    const v = JSON.parse(entry.line);
    return isPlainObject(v) && typeof v.commit === "string" ? v.commit : null;
  } catch {
    return null;
  }
}

function findRecord(file, commit, defs) {
  if (!SHA_RE.test(commit)) fail(`commit ${JSON.stringify(commit)} is not a 40-character lowercase hex sha`);
  const hits = readHistory(file).filter((e) => lineCommit(e) === commit);
  if (hits.length === 0) return null;
  // Publishing is idempotent per commit, so there is at most one; take the first.
  const what = `records ${file}:${hits[0].lineNo}`;
  return validateRecord(parseJson(hits[0].line, what), defs, what, "stored");
}

function recordedCommits(file, defs) {
  const out = [];
  for (const entry of readHistory(file)) {
    const what = `records ${file}:${entry.lineNo}`;
    try {
      out.push(validateRecord(parseJson(entry.line, what), defs, what, "stored").commit);
    } catch (e) {
      if (!(e instanceof InvalidInput)) throw e;
      process.stderr.write(`warning: skipping ${e.message}\n`);
    }
  }
  return out;
}

// ----------------------------------------------------------------- formatting

function group(intDigits) {
  let out = "";
  for (let i = 0; i < intDigits.length; i++) {
    if (i > 0 && (intDigits.length - i) % 3 === 0) out += ",";
    out += intDigits[i];
  }
  return out;
}

// Deterministic, locale-free number formatting. Validation bounds values to
// [0, MAX_SAFE_INTEGER], so toFixed never switches to exponent notation.
function formatNumber(v) {
  const decimals = Number.isInteger(v) ? 0 : v >= 1 ? 2 : 4;
  const [int, frac = ""] = v.toFixed(decimals).split(".");
  const trimmed = frac.replace(/0+$/, "");
  return group(int) + (trimmed ? `.${trimmed}` : "");
}

function formatValue(v, def) {
  return def.unit ? `${formatNumber(v)} ${def.unit}` : formatNumber(v);
}

function formatPercent(abs) {
  if (abs >= 0.1) return abs.toFixed(1);
  const two = abs.toFixed(2);
  return two === "0.00" ? "<0.01" : two;
}

// One metric's change between base and head.
function classify(def, base, head) {
  if (head === undefined) return { kind: "missing" };
  if (base === undefined) return { kind: "new" };
  if (base === 0) {
    if (head === 0) return { kind: "unchanged", rel: 0 };
    return { kind: def.better === "higher" ? "better" : "worse", rel: null };
  }
  const rel = (head - base) / base;
  if (Math.abs(rel) <= def.tolerance) return { kind: "unchanged", rel };
  const improved = def.better === "lower" ? rel < 0 : rel > 0;
  return { kind: improved ? "better" : "worse", rel };
}

function changeCell(c) {
  switch (c.kind) {
    case "missing":
      return "not measured";
    case "new":
      return "new";
    case "unchanged":
      return "unchanged";
    default: {
      if (c.rel === null) return `from 0 (${c.kind})`;
      const sign = c.rel > 0 ? "+" : "-";
      return `${sign}${formatPercent(Math.abs(c.rel) * 100)}% (${c.kind})`;
    }
  }
}

// "Bytes sent per keystroke (table demo, 120x40)" -> "bytes sent per keystroke"
function shortLabel(label) {
  const s = label.replace(/\s*\([^)]*\)\s*$/, "").trim() || label;
  return /^[A-Z][a-z]/.test(s) ? s[0].toLowerCase() + s.slice(1) : s;
}

function joinClauses(parts) {
  if (parts.length <= 1) return parts.join("");
  return `${parts.slice(0, -1).join(", ")} and ${parts.at(-1)}`;
}

// Backslashes first: escaping only `|` would turn an input `\|` into `\\|`,
// an escaped backslash followed by a live pipe that splits the table cell.
const escapeCell = (s) =>
  s.replace(/\\/g, "\\\\").replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
const short = (sha) => sha.slice(0, 7);
// Code spans, so a toolchain string from an untrusted artifact (characters
// limited by TOOLCHAIN_RE) cannot autolink (`www.…`) or reference (`GH-12`).
const toolchainText = (t) => `Elixir \`${t.elixir}\`, OTP \`${t.otp}\`, \`${t.system_arch}\``;
// Ids master does not define yet; ID_RE limits them to [a-z0-9_.].
const unknownNote = (record) =>
  record.unknown?.length
    ? [`Not compared, not defined on master yet: ${record.unknown.map((id) => `\`${id}\``).join(", ")}.`, ""]
    : [];
const sameToolchain = (a, b) => TOOLCHAIN_KEYS.every((k) => a[k] === b[k]);

function summarize(rows, subject) {
  const changed = rows.filter((r) => r.change.kind === "better" || r.change.kind === "worse");
  const clauses = changed.map(({ def, change }) => {
    if (change.rel === null) return `${shortLabel(def.label)} up from zero (${change.kind})`;
    const dir = change.rel < 0 ? "lower" : "higher";
    return `${shortLabel(def.label)} ${formatPercent(Math.abs(change.rel) * 100)}% ${dir} (${change.kind})`;
  });
  const extras = [];
  const added = rows.filter((r) => r.change.kind === "new").length;
  const missing = rows.filter((r) => r.change.kind === "missing").length;
  if (added) extras.push(`${added} metric${added === 1 ? " is" : "s are"} new and not compared`);
  if (missing) extras.push(`${missing} metric${missing === 1 ? " was" : "s were"} not measured`);
  const tail = extras.length ? ` (${extras.join("; ")})` : "";
  if (clauses.length === 0) return `No measurable change: every metric is within its noise tolerance${tail}.`;
  return `${subject} makes ${joinClauses(clauses)}${tail}.`;
}

// Shared body for PR comments and release notes.
function renderComparison(defs, base, head, { baseLabel, headLabel, subject }) {
  const out = [];
  if (base === null) {
    out.push(`No ${baseLabel} measurements to compare against yet, so this shows ${headLabel} only.`, "");
    out.push(`| Metric | ${escapeCell(headLabel)} |`, "| --- | ---: |");
    for (const def of defs.list) {
      const v = head.metrics[def.id];
      if (v !== undefined) out.push(`| ${escapeCell(def.label)} | ${formatValue(v, def)} |`);
    }
    out.push("", ...unknownNote(head), `<sub>Measured at ${short(head.commit)} on ${toolchainText(head.toolchain)}.</sub>`);
    return out.join("\n");
  }

  const rows = [];
  for (const def of defs.list) {
    const b = base.metrics[def.id];
    const h = head.metrics[def.id];
    if (b === undefined && h === undefined) continue;
    rows.push({ def, b, h, change: classify(def, b, h) });
  }
  out.push(summarize(rows, subject), "");
  out.push(`| Metric | ${escapeCell(baseLabel)} | ${escapeCell(headLabel)} | Change |`, "| --- | ---: | ---: | --- |");
  for (const { def, b, h, change } of rows) {
    const cell = (v) => (v === undefined ? "-" : formatValue(v, def));
    out.push(`| ${escapeCell(def.label)} | ${cell(b)} | ${cell(h)} | ${changeCell(change)} |`);
  }
  out.push("", ...unknownNote(head));
  if (!sameToolchain(base.toolchain, head.toolchain)) {
    out.push(
      `> **Warning:** ${baseLabel} and ${headLabel} were measured on different toolchains, ` +
        "so some of the difference may come from the toolchain rather than the code.",
      "",
    );
  }
  out.push(
    `<sub>${escapeCell(baseLabel)}: ${short(base.commit)} on ${toolchainText(base.toolchain)}. ` +
      `${escapeCell(headLabel)}: ${short(head.commit)} on ${toolchainText(head.toolchain)}. ` +
      "Changes within a metric's noise tolerance count as unchanged.</sub>",
  );
  return out.join("\n");
}

function renderComment(defs, base, head, { baseLabel = "base", headLabel = "head" } = {}) {
  const body = renderComparison(defs, base, head, { baseLabel, headLabel, subject: "This change" });
  return `${MARKER}\n### Scoreboard\n\n${body}\n`;
}

function badgeFor(def, value) {
  return { schemaVersion: 1, label: def.label, message: formatValue(value, def), color: "informational" };
}

// Rewrites DIR to hold exactly one badge per headline metric present in the
// record, so a metric that is retired, renamed or no longer a headline stops
// being served instead of freezing at its last value.
function writeBadges(defs, record, dir) {
  mkdirSync(dir, { recursive: true });
  const wanted = new Map();
  for (const def of defs.list) {
    if (def.headline && record.metrics[def.id] !== undefined) wanted.set(`${def.id}.json`, def);
  }
  for (const name of readdirSync(dir)) {
    if (name.endsWith(".json") && !wanted.has(name)) rmSync(join(dir, name));
  }
  const written = [];
  for (const [name, def] of wanted) {
    const file = join(dir, name);
    writeFileSync(file, `${JSON.stringify(badgeFor(def, record.metrics[def.id]))}\n`);
    written.push(file);
  }
  return written;
}

// ------------------------------------------------------------------------ CLI

function args(argv, spec, required) {
  const { values } = parseArgs({ args: argv, options: spec, strict: true, allowPositionals: false });
  for (const name of required) if (values[name] === undefined) fail(`missing --${name}`);
  return values;
}

const str = { type: "string" };

const commands = {
  validate(argv) {
    const a = args(argv, { defs: str, record: str, as: str, "expect-commit": str }, ["defs", "record"]);
    const mode = a.as ?? "fresh";
    if (!MODES.has(mode)) fail(`--as must be one of ${[...MODES].join(", ")}`);
    const record = loadRecord(a.record, loadDefs(a.defs), mode);
    if (a["expect-commit"] !== undefined && record.commit !== a["expect-commit"]) {
      fail(`record ${a.record}: commit ${record.commit} does not match expected ${a["expect-commit"]}`);
    }
  },

  compare(argv) {
    const a = args(argv, { defs: str, base: str, head: str, "base-label": str, "head-label": str }, ["defs", "base", "head"]);
    const defs = loadDefs(a.defs);
    const head = loadRecord(a.head, defs, "candidate");
    const base = a.base === "-" ? null : loadRecord(a.base, defs, "stored");
    process.stdout.write(renderComment(defs, base, head, { baseLabel: a["base-label"], headLabel: a["head-label"] }));
  },

  badges(argv) {
    const a = args(argv, { defs: str, record: str, out: str }, ["defs", "record", "out"]);
    const defs = loadDefs(a.defs);
    for (const file of writeBadges(defs, loadRecord(a.record, defs, "fresh"), a.out)) process.stdout.write(`${file}\n`);
  },

  release(argv) {
    const a = args(argv, { defs: str, records: str, from: str, to: str, "from-label": str, "to-label": str }, ["defs", "records", "from", "to"]);
    const defs = loadDefs(a.defs);
    const from = findRecord(a.records, a.from, defs);
    const to = findRecord(a.records, a.to, defs);
    if (from === null || to === null) return;
    const body = renderComparison(defs, from, to, {
      baseLabel: a["from-label"] ?? short(a.from),
      headLabel: a["to-label"] ?? short(a.to),
      subject: "This release",
    });
    process.stdout.write(`## Scoreboard\n\n${body}\n`);
  },

  lookup(argv) {
    const a = args(argv, { defs: str, records: str, commit: str }, ["defs", "records", "commit"]);
    const record = findRecord(a.records, a.commit, loadDefs(a.defs));
    if (record !== null) process.stdout.write(`${JSON.stringify(record)}\n`);
  },

  commits(argv) {
    const a = args(argv, { defs: str, records: str }, ["defs", "records"]);
    for (const commit of recordedCommits(a.records, loadDefs(a.defs))) process.stdout.write(`${commit}\n`);
  },

  // Appends the record to DIR/records.jsonl unless its commit is already
  // there, then rewrites DIR/latest.json and DIR/badges from the last line.
  publish(argv) {
    const a = args(argv, { defs: str, record: str, dir: str, "run-id": str, "recorded-at": str }, ["defs", "record", "dir", "run-id"]);
    const defs = loadDefs(a.defs);
    const runId = Number(a["run-id"]);
    if (!/^[1-9][0-9]*$/.test(a["run-id"]) || !Number.isSafeInteger(runId)) fail(`--run-id ${a["run-id"]} is not a positive integer`);
    const recordedAt = a["recorded-at"] ?? new Date().toISOString();
    const stored = validateRecord({ ...loadRecord(a.record, defs, "fresh"), recorded_at: recordedAt, run_id: runId }, defs, "new record", "stored");

    mkdirSync(a.dir, { recursive: true });
    const historyFile = join(a.dir, "records.jsonl");
    if (findRecord(historyFile, stored.commit, defs) === null) {
      const existing = existsSync(historyFile) ? readFileSync(historyFile, "utf8") : "";
      const sep = existing === "" || existing.endsWith("\n") ? "" : "\n";
      writeFileSync(historyFile, `${existing}${sep}${JSON.stringify(stored)}\n`);
      process.stdout.write(`recorded ${stored.commit}\n`);
    } else {
      process.stdout.write(`already recorded ${stored.commit}\n`);
    }

    const history = readHistory(historyFile);
    const last = history.at(-1);
    const what = `records ${historyFile}:${last.lineNo}`;
    const latest = validateRecord(parseJson(last.line, what), defs, what, "stored");
    writeFileSync(join(a.dir, "latest.json"), `${JSON.stringify(latest, null, 2)}\n`);
    writeBadges(defs, latest, join(a.dir, "badges"));
  },

  // event.json from the artifact -> validated key=value lines, safe to append
  // to $GITHUB_OUTPUT (every value is restricted to [0-9a-z_] characters).
  event(argv) {
    const a = args(argv, { file: str }, ["file"]);
    const raw = parseJson(readCapped(a.file, RECORD_MAX_BYTES, "event"), `event ${a.file}`);
    if (!isPlainObject(raw)) fail("event: top level must be an object");
    if (raw.event !== "pull_request" && raw.event !== "push") fail("event: event must be pull_request or push");
    if (typeof raw.head_sha !== "string" || !SHA_RE.test(raw.head_sha)) fail("event: head_sha must be a 40-character hex sha");
    if (raw.base_sha !== null && raw.base_sha !== undefined && (typeof raw.base_sha !== "string" || !SHA_RE.test(raw.base_sha))) {
      fail("event: base_sha must be a 40-character hex sha or null");
    }
    if (raw.pr_number !== null && raw.pr_number !== undefined && (!Number.isSafeInteger(raw.pr_number) || raw.pr_number <= 0)) {
      fail("event: pr_number must be a positive integer or null");
    }
    const lines = [
      `event=${raw.event}`,
      `head_sha=${raw.head_sha}`,
      `base_sha=${raw.base_sha ?? ""}`,
      `pr_number=${raw.pr_number ?? ""}`,
    ];
    process.stdout.write(`${lines.join("\n")}\n`);
  },
};

async function main(argv) {
  const [name, ...rest] = argv;
  const command = Object.hasOwn(commands, name ?? "") ? commands[name] : null;
  if (!command) {
    process.stderr.write(`usage: scoreboard.mjs <${Object.keys(commands).join("|")}> [options]\n`);
    return 2;
  }
  try {
    await command(rest);
    return 0;
  } catch (e) {
    if (e instanceof InvalidInput || e?.code?.startsWith?.("ERR_PARSE_ARGS")) {
      process.stderr.write(`scoreboard ${name}: ${e.message}\n`);
      return 1;
    }
    throw e;
  }
}

process.exitCode = await main(process.argv.slice(2));
