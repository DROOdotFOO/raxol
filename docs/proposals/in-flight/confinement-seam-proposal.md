# Proposal: Centralized Boundary-Confinement Seam

**Status**: PROPOSED — design-only. Blocked on (1) V's pick of dependency option a/b/c
(recommendation below: **b**), and (2) Drew's sign-off on the UI-lane migration (#607).
Do NOT implement any site migration until both land.

**Date**: 2026-07-17 · **Origin**: DROOdotFOO, PR #569 thread 2 ("same gap, four patches").
V ruled "centralize it" (2026-07-17).

---

## Context

The same class of bug — *untrusted external bytes crossing a boundary without confinement* —
is currently patched (or unpatched) independently at four sites:

1. **#607 (UI lane)** — fenced-code-block info-string is rendered without stripping
   ESC/ANSI. Safe today only because upstream happens to sanitize; no local guarantee.
2. **#569 / PA-6 (harness)** — CAS `$blob` / `snapshot_ref` dereference has no *runtime*
   path confinement, only a fixture lint. An imported journal carrying
   `blobs/../../etc/...` dereferences outside the session directory.
3. **#586 (harness)** — self-containment red models `:erl_tar.extract` blind-into-cwd:
   member names are not validated, so a crafted archive writes outside the target dir.
4. **`raxol_agent_client_protocol`** — `fs_sandbox`
   (`Raxol.AgentClientProtocol.Client.FsSandbox`) already has a **tested, correct**
   confinement: lexical check, then full symlink resolution (leaf symlink AND
   symlinked-ancestor-dir, cycle-guarded), rejection *before* any syscall on the target.
   This is the best instance in the repo and the natural contract seed.

### These are TWO confinements, not one

Bundling them into a single "confinement util" would be a leaky abstraction — they share
a threat narrative but nothing else (no types, no algorithm, no failure modes):

- **Path-traversal confinement** (sites 2, 3, 4): *resolve a path and prove it stays
  under an allowed root.* Filesystem semantics: canonicalization, symlinks, prefix checks.
- **Terminal-injection confinement** (site 1): *neutralize ESC/ANSI/control bytes in
  untrusted text before it reaches the terminal renderer.* Byte-stream semantics: total
  function over binaries, no filesystem, never errors.

We centralize the **decision** (one contract each, one must-reject table each), and
propose **two functions in one boundary namespace**, not one function.

---

## Decision (proposed)

### Contract 1 — `Raxol.Core.Boundary.Path.confine/3` (path traversal)

Seeded from the ACP package's proven `FsSandbox.resolve/2` plus PA-6's ref-shape rule.

```elixir
@spec confine(root :: String.t(), requested :: String.t(), opts :: keyword()) ::
        {:ok, real_absolute_path :: String.t()} | {:error, reason :: atom()}
# opts:
#   ref_format: Regex.t()  — pattern `requested` must match BEFORE any resolution
#                            (PA-6: ~r{^(blobs|snapshots)/[0-9a-f]{64}(\.json)?$})
```

Rules, enforced in order, all **before any syscall on the target** (the only I/O is
`:file.read_link` during resolution):

1. **Ref-shape gate** (when `ref_format:` given): reject `requested` not matching the
   regex → `{:error, :malformed_ref}`. Refs are validated as *opaque tokens* before
   they are ever treated as paths.
2. **Lexical confinement**: `root = Path.expand(root)`;
   `lexical = Path.expand(Path.join(root, requested))`. Reject unless
   `lexical == root` or `lexical` starts with `root <> "/"` → `{:error, :path_traversal}`.
   (Absolute `requested` is jailed under `root` by `Path.join`, not honored.)
3. **Symlink resolution** of BOTH `root` and `lexical` via a hand-rolled `realpath`:
   follows a leaf symlink; recurses into the parent so a **symlinked ancestor
   directory** is caught too; a relative link target resolves against the symlink's
   own directory (POSIX); works for not-yet-existing leaves (the write case);
   depth-capped (40) → `{:error, :too_many_symlinks}` on cycles.
4. **Post-resolution re-check**: resolved path must still be within resolved root
   → `{:error, :symlink_escape}`.

**Must-reject table** (the conformance vector set; every implementation binds to it):

| Input (`requested`)                          | Rejection            |
| -------------------------------------------- | -------------------- |
| `../../etc/passwd`                            | `:path_traversal`    |
| `blobs/../../etc/x` (even with `ref_format`)  | `:malformed_ref`     |
| `a/../../x`                                   | `:path_traversal`    |
| leaf symlink inside root → outside root       | `:symlink_escape`    |
| symlinked ancestor dir escaping root          | `:symlink_escape`    |
| symlink cycle                                 | `:too_many_symlinks` |
| `snapshots/../blobs/<hex64>` (PA-6 mode)      | `:malformed_ref`     |
| uppercase / wrong-length hex (PA-6 mode)      | `:malformed_ref`     |

Tar adoption note (#586): `:erl_tar` member names are `requested` values — `confine/3`
each member name against the extraction root **before** extraction; additionally reject
symlink/hardlink/device members outright (archive-member policy sits at the call site,
not in `confine/3`).

### Contract 2 — `Raxol.Core.Boundary.TermText.sanitize/2` (terminal injection)

```elixir
@spec sanitize(binary(), opts :: keyword()) :: String.t()
# opts: allow: [?\n, ?\t]  — C0 bytes permitted through (default [?\n])
```

A **total function** (never errors, never passes bytes through on failure):

1. Strip ESC (`0x1B`) and every escape sequence it introduces: CSI (`ESC [` … final
   byte), OSC (`ESC ]` … BEL/ST — kills title-set and OSC-8 hyperlink smuggling),
   DCS/APC/PM/SOS (… ST), and two-byte `ESC <c>` forms.
2. Strip C0 controls except the `allow:` list; strip DEL (`0x7F`); strip raw C1
   controls (`0x80–0x9F` when not valid UTF-8 continuation).
3. Replace invalid UTF-8 with U+FFFD (never emit broken sequences downstream).

Must-neutralize: `\e[31m`, `\e]0;evil\a`, OSC-8 links, cursor movement/alt-screen,
bracketed-paste terminators (`\e[201~`), bare `\e` at end-of-input (truncated sequence).

This enforces the existing repo rule ("never embed raw ANSI in strings passed to
`text()`") *at the untrusted boundary* instead of trusting upstream. The ACP package
does not need this function — its home is the UI/terminal lane only.

### Dependency-constraint resolution — **recommend (b)**

The crux: `raxol_agent_client_protocol` is deliberately zero-raxol-dep (standalone MIT,
jason-only runtime dep; CLAUDE.md boundary rule "no raxol back-dep"). A util in
`raxol_core` cannot be consumed by it.

| Option | Shape | Verdict |
| ------ | ----- | ------- |
| **(a)** new zero-dep leaf pkg (`raxol_boundary`) both sides depend on | Cleanest byte-level reuse | Rejected-for-now: one Hex package + publish-order slot + version-churn surface for ~70 LOC of *stable* path logic; and it breaks the ACP package's "jason-only" story anyway (its dep list grows). Revisit if a third standalone package needs confinement. |
| **(b)** util in `raxol_core`; ACP keeps its ~70-LOC `FsSandbox` as a **documented intentional duplicate**, bound to the shared conformance vectors | One contract, two implementations | **RECOMMENDED** |
| **(c)** ACP takes a `raxol_core` dep | — | Rejected: breaks the standalone-MIT story. `raxol_core` drags `telemetry` and the whole raxol release cadence into a package whose selling point is "drop into any Elixir project, one dep". The boundary rule exists precisely to keep this package adoptable outside the raxol graph. |

**Why (b)**: "centralize it" means centralize the *decision*, and the decision is the
contract + must-reject table above — decided once, here. The bytes are ~70 LOC of path
semantics that have not changed since POSIX; drift risk is handled structurally, not by
sharing code: the must-reject table lives in one fixture (proposed:
`test/fixtures/boundary/confine_vectors.exs`, mirrored verbatim into the ACP package's
test tree), and both implementations run the same vectors in CI. A divergence is a red
test, not a silent fork. The ACP `FsSandbox` moduledoc gains one line: *"intentional
standalone duplicate of `Raxol.Core.Boundary.Path` — bound to the shared confinement
vectors; change both or neither."* This keeps the already-tested seed untouched, adds
zero packages, and costs one fixture mirror.

`TermText.sanitize/2` has no constraint at all: it lives in `raxol_core`
(`raxol_terminal` and main-raxol UI both already depend on it), single implementation,
no duplicate.

---

## Migration table

| # | Site | Adopts | Lane / owner | Notes |
| - | ---- | ------ | ------------ | ----- |
| 1 | #607 fence info-string render | `TermText.sanitize/2` at render-prep, before the string enters the View tree | **UI lane — Drew** | **Cross-lane: requires Drew's sign-off**; ADR-shaped decision per his ask |
| 2 | #569 / PA-6 CAS `$blob`/`snapshot_ref` deref | `Path.confine/3` with `ref_format:` regex + session dir as root, at deref time (runtime, not lint) | harness — ours | Fixture lint stays as defense-in-depth |
| 3 | #586 `:erl_tar.extract` | `Path.confine/3` per member name against extraction root, pre-extract; reject link/device members at call site | harness — ours | Closes the self-containment red |
| 4 | ACP `fs_sandbox` | **No code change.** Stays canonical seed; binds to shared conformance vectors + duplicate-marker moduledoc line | ACP pkg — ours | Under option (b) |

---

## Consequences

- One contract per confinement class, four call sites, zero new packages.
- The must-reject table becomes the single source of truth; new boundary sites
  (future importers, new archive formats, new render surfaces) adopt by citing it.
- Accepted cost: one intentional ~70-LOC duplicate (ACP), drift-guarded by shared
  vectors rather than a dep edge.
- If option (a) is picked instead: everything above holds except the ACP duplicate is
  replaced by a dep on the new leaf package; migration rows 2-4 gain a deps.get step.

## Validation

- Shared vector fixture exercised by both `Boundary.Path` tests and the ACP
  `FsSandbox` tests (byte-identical vectors, CI-enforced).
- Property test: for random `requested` inputs, `confine/3` never returns an `{:ok, p}`
  where `p` is outside the resolved root (generator includes `..` segments, absolute
  paths, and planted symlinks).
- `sanitize/2` property: output contains no byte in `0x00–0x08, 0x0B–0x1F, 0x7F` (minus
  allow-list) and no `0x1B`; idempotence (`sanitize(sanitize(x)) == sanitize(x)`).
- Site-level regression tests land with each migration row (each lane owns its own).

## References

- PR #569 thread 2 (DROOdotFOO) — the four-site observation
- `packages/raxol_agent_client_protocol/lib/raxol/agent_client_protocol/client.ex`
  (`FsSandbox` — the seed implementation, branch `feat/agent-client-protocol`)
- PA-6 (harness proposals) — ref-shape rule `^(blobs|snapshots)/[0-9a-f]{64}(\.json)?$`
- #607 (UI), #586 (harness) — pending sites
- CLAUDE.md render rule: "Never embed raw ANSI codes in strings passed to `text()`"
