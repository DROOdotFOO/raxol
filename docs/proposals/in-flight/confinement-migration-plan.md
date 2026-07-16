# Migration Plan: Centralizing Boundary Confinement onto `Boundary.Path.confine/3` + `Boundary.TermText.sanitize/2`

**Status**: PROPOSED — migration half of the confinement seam. The contract half is
[confinement-seam-proposal.md](./confinement-seam-proposal.md) (do not re-litigate the
contract, must-reject tables, or dependency option (b) here — all ratified there).
Both functions are **implemented** in `packages/raxol_core` (PR #613,
`lib/raxol/core/boundary/{path,term_text}.ex` + shared conformance vectors at
`test/support/boundary_vectors/`). This document is the site-by-site plan for
V + Drew to approve and assign. No code lands from this doc directly.

**Date**: 2026-07-17 · **Origin**: PR #569 thread 2 ("same gap, four patches"),
V ruled "centralize it"; grounded in the 2026-07-17 full-tree discovery pass over the
`confinement` worktree (main `lib/` + all 14 `packages/*`).

---

## Context

`raxol_core` now owns both boundary functions and is the **publish root** (zero raxol
deps, published first in the Hex order). Every in-repo candidate package already reaches
it — directly (`raxol_terminal`, `raxol_symphony`, `raxol_speech`, main `raxol`) or
transitively (`raxol_agent` via `:raxol`/`:raxol_mcp`). The single package that cannot
take the dep is the external **Agent Client Protocol** package
(`raxol_agent_client_protocol`, deliberately zero-raxol-dep, jason-only), which under
ratified option (b) keeps its own `FsSandbox` copy bound to the shared vectors.

Discovery found the live gap is **four hand-rolled lexical-only path checks** (no
realpath/symlink re-check) plus **zero call sites for `TermText.sanitize/2`** — the
entire harness-transcript UI renders live LLM/tool bytes into `Components.text()`
unsanitized, relying on the "never embed raw ANSI" convention upstream.

Three of the four seam-proposal seed sites are **not in this worktree**: the Agent
Client Protocol `FsSandbox` is external; the PA-6 CAS `$blob`/`snapshot_ref` deref does
not exist yet (harness storage here is jsonl fixtures, no content-addressed store); the
#586 untrusted `:erl_tar.extract` path is absent (the only `:erl_tar.extract` in-tree
operates on a self-created trusted backup). Their rows below are ordering slots, not
immediate work.

---

## Decision

### 1. Triage

#### (A) Confirmed migration sites — 17 rows

**Path-confinement (4 in-repo + 1 external):**

| # | Site | Gap |
| - | ---- | --- |
| P1 | `packages/raxol_agent/lib/raxol/agent/actions/fs.ex:145` (`resolve/1`) | Lexical prefix check only (`Path.expand` + `starts_with?(cwd <> "/")`); LLM-supplied `path` for ReadFile/ListDir/FileStat; a symlink inside cwd pointing outside is not caught |
| P2 | `packages/raxol_symphony/lib/raxol/symphony/path_safety.ex:56` (`validate_inside_root/2`, `workspace_path/2` at :37) | Pure lexical `inside?/2`; MCP-supplied workspace identifiers; **feeds `File.rm_rf!` at `workspace.ex:93–96`** — a symlinked workspace dir could let rm_rf escape root. Migrating PathSafety fixes the workspace.ex sink transitively (one migration, two discovered rows) |
| P3 | `packages/raxol_terminal/lib/raxol/terminal/input/file_drop_handler.ex:524` (`validate_directories/2`) | Naive `String.starts_with?(file.path, allowed_dir)` — **missing trailing-`/` boundary** (`/foo/barbaz` passes for allowed `/foo/bar`), no normalization, and the allowlist is **not re-applied after** its own `resolve_symlinks_recursive/2` (depth 10, at :408). Untrusted drag-and-drop URIs |
| P4 | `packages/raxol_agent/lib/raxol/agent/skills/store.ex:395` (`read_view/2` + `safe_relative?/1` at :408) | Rejects absolute + `..` segments lexically, no realpath; skill dirs can originate from downloaded/imported skills, so a planted symlink escapes |
| P5 | Agent Client Protocol package (external repo) — `Raxol.AgentClientProtocol.Client.FsSandbox.resolve/2` | **No code change** (option b). Task = copy `path_reject_vectors.json` + `path_accept_vectors.json` VERBATIM into its test tree, assert `FsSandbox.resolve/2` agrees (map its Error `data.reason` onto the vector `expect` atom; SKIP vectors carrying `ref_format` — the ref-shape gate is `confine/3`-only), and add the duplicate-marker moduledoc line |

**TermText-sanitization (12, all main `raxol` lib, UI lane):**

| # | Site | Untrusted bytes |
| - | ---- | --------------- |
| T1 | `lib/raxol/ui/components/markdown_renderer.ex:60` (boundary) — covers text nodes :86, headings :94/107/118, earmark pre :171–172, link href :271, builtin fence body :379 | `markdown_text` prop: LLM/assistant message content. **This is the #607 family.** Sanitizing once at :60 transitively covers `harness/message_block.ex:58` and `playground/demo_helpers.ex` `markdown/2` |
| T2 | `lib/raxol/ui/components/harness/tool_result_block.ex:156` | Tool/subprocess stdout — explicitly modeled as tainted (`provenance.trust: :tainted`); the prime injection vector |
| T3 | `lib/raxol/ui/components/harness/reasoning_block.ex:108` (+ collapsed summary :98, `content_lines/1` :84) | LLM chain-of-thought content |
| T4 | `lib/raxol/ui/components/harness/diff_viewer.ex:466` (`highlight/3`; + `state.path` at :273, fallback token :477) | On-disk file content + agent-proposed edit + file path; `language: nil` path passes raw bytes straight to `text()` |
| T5 | `lib/raxol/ui/components/code_block.ex:28` (+ raw fallback :30) | Fence/code content; `strip_html_tags` removes HTML only — **ESC survives both paths** |
| T6 | `lib/raxol/ui/syntax_highlighter.ex:114` (nil-language + no-Makeup fallback, also :76) | Raw source lines become token `text` — defense-in-depth behind T4/T5 (token producer, not a direct emitter) |
| T7 | `lib/raxol/ui/components/harness/tool_call_block.ex:84` (name) + :113 (binary-args `truncate` path) | LLM-chosen tool name/args; map-args `inspect/1` path is already safe |
| T8 | `lib/raxol/ui/components/harness/approval_prompt.ex:166` (`action_description`) + :239 (`option_label`) | Agent-proposed action text in a **security-critical approval UI** — spoofing matters most here |
| T9 | `lib/raxol/ui/components/harness/blast_radius_preview.ex:228` (items) + :210 (group label) | Side-effect paths/identifiers in an irreversible-action warning surface |
| T10 | `lib/raxol/ui/components/harness/advisory_feed.ex:93` (`entry_line/1` at :99) | `entry.source` / `entry.text` (sensor/agent/retrieval-sourced) |
| T11 | `lib/raxol/ui/components/harness/toast.ex:60` | `state.message` (agent/external event text) |
| T12 | `lib/raxol/ui/components/harness/composer.ex:516` (queued steer banner) + MLI value render path (:492) | Pasted input echo — bracketed-paste can carry ESC/ANSI; classic local-echo injection |

#### (B) Trusted / internal — explicitly NOT migrating

Considered and dismissed; listed so a reviewer sees they were weighed:

| Site | One-line reason |
| ---- | --------------- |
| `packages/raxol_agent/lib/raxol/agent/curator.ex:232` (`:erl_tar.extract`) | Archive is a self-created backup written by the same module from its own root — trusted; not the #586 seed. Revisit only if backups become importable |
| `lib/raxol/commands/file_system.ex:313` (VFS `resolve_path`/`normalize_path`) | Pure in-memory map-backed VFS, zero real-filesystem syscalls — `confine/3`'s realpath is meaningless; `..` is contained by construction (stack-pop can't escape `/`). Revisit if a real-FS passthrough is ever added |
| `packages/raxol_core/lib/raxol/core/runtime/plugins/loader.ex:179/277` (`Code.compile_file`) | Arbitrary code load, not path traversal — `confine/3` is the wrong primitive; out of scope for this migration |
| `lib/raxol/config/loader.ex:264/376` | Loading a config file the user explicitly names is a feature; there is no root to confine under |
| `lib/raxol/themes.ex:210` | Theme-identifier-as-path has no root/base anchor; the confined variant is `style/colors/persistence.ex` (see C) |
| `lib/raxol/headless.ex:331` | CLI-argument file compile; trusted operator input, no boundary |
| `lib/raxol/plugins/examples/file_browser_plugin.ex:82` | A file browser's explicit purpose is unconfined real-FS traversal; example/demo code |
| `packages/raxol_terminal` renderer/emulator/parser, `ui/components/terminal.ex`, `core/renderer/*`, `protocols/*`, `style/colors/*` | Trusted framework ANSI **producers** — the framework's own output generation, not an untrusted-content boundary |
| Map/JSON "sanitize" false positives (`raxol_agent/contract.ex sanitize_payload`, `raxol_mcp/context_tree.ex sanitize_tree`, `raxol_payments/req/auto_pay.ex sanitize_error`) | Payload-shape sanitization, unrelated to either boundary |

#### (C) Uncertain — needs owner confirmation

| Site | Question | Ask |
| ---- | -------- | --- |
| `lib/raxol/core/runtime/plugins/api.ex:135` (`plugin_data_dir/1`) | Can `plugin_id` ever be third-party/attacker-influenced, or is it always a validated module-ish id? | If external: `confine(base_path, plugin_id, ref_format: ~r/^[\w.-]+$/)`. Owner: core runtime |
| `lib/raxol/style/colors/persistence.ex:49/101/221/223` (theme name → path) | Is `theme_name` ever user/UI-supplied, or always internal? Textbook confine shape (root = themes dir) | Cheap hardening; owner: UI lane |
| `lib/raxol/ui/components/harness/rules_panel.ex:89/97` | Can rules be agent-proposed, or operator-config only? | If agent-proposed: sanitize `when_clause`/`then_clause`. Owner: harness-ui |
| `lib/raxol/ui/components/harness/worktracks_panel.ex:99` | Do worktrack names derive from branch/task names (external)? | Owner: harness-ui |
| `lib/raxol/ui/components/harness/error_block.ex:72/81` | Fault payloads can embed tool output; only the `is_binary` branch leaks (inspect path is safe). Cheap to fold into the T-wave if owner agrees | Owner: harness-ui |
| `lib/raxol/repl/evaluator.ex:113/142` (captured stdout of evaluated code) | Data source, not the render site — locate the actual `text()` emission for REPL results and sanitize there | Owner: REPL |
| `packages/raxol_speech/lib/raxol/speech/tts/sanitize.ex` (`strip_control_chars/1`) | `TermText.sanitize/2` is a strict superset, and raxol_speech already has the direct dep — but the target is a TTS argv, not a terminal, and the vectors README scopes term_text to "raxol_core only (UI/terminal lane)". Reuse is **opportunistic, not required** | Owner: speech surface |

### 2. Migration rows (confirmed sites)

#### P1 — `raxol_agent` `Actions.Fs.resolve/1` (fs.ex:145)

- **Current**: `abs = Path.expand(path, working_dir())`; accept iff `abs == cwd or String.starts_with?(abs, cwd <> "/")`; else `{:error, :outside_cwd}`. Then `File.ls`/`File.read`/`File.stat`.
- **Target call**: `Raxol.Core.Boundary.Path.confine(working_dir(), path)`
- **Diff sketch**:
  ```elixir
  # before
  abs = Path.expand(path, cwd)
  if abs == cwd or String.starts_with?(abs, cwd <> "/"), do: {:ok, abs}, else: {:error, :outside_cwd}
  # after
  case Raxol.Core.Boundary.Path.confine(cwd, path) do
    {:ok, real} -> {:ok, real}
    {:error, _reason} -> {:error, :outside_cwd}   # keep the public reason stable
  end
  ```
- **Rejection mapping**: collapse `:path_traversal | :symlink_escape | :too_many_symlinks` → existing `:outside_cwd` (the LLM-facing tool error contract is unchanged; optionally log the granular reason).
- **Tests**: bind to shared path vectors (small harness in raxol_agent tests running `path_reject/accept_vectors.json` through `resolve/1`); PLUS one new red: symlink inside cwd → outside must now reject (this is the hardening).
- **Dep**: add explicit `raxol_dep(:raxol_core, ...)` to `packages/raxol_agent/mix.exs` (today reachable only transitively via `:raxol`/`:raxol_mcp`). Cycle-free: raxol_core publishes step 1, raxol_agent step 4. **No publish-order change.**

#### P2 — `raxol_symphony` `PathSafety` (path_safety.ex:56, :37) → fixes `workspace.ex:93` rm_rf sink

- **Current**: `workspace_path/2` = `sanitize_key` (regex `[^A-Za-z0-9._-]` → `_`) + `Path.join(root, key) |> Path.expand()` + `validate_inside_root/2` (lexical `inside?/2`). Result feeds `File.rm_rf!(abs_path)`.
- **Target call**: `Raxol.Core.Boundary.Path.confine(root, key, ref_format: ~r/^[A-Za-z0-9._-]+$/)` — the `ref_format` gate replaces the assertion half of `sanitize_key`; keep the *rewriting* half (`_`-substitution) upstream where a normalized key is desired, then confine the normalized key.
- **Diff sketch**: `validate_inside_root(path, root)` body becomes a delegation to `confine(root, Path.relative_to(path, root))` — or better, refactor callers to pass the raw key so `confine/3` does the join itself (absolute inputs are jailed by design). `workspace.ex:93` (`remove/2`) is unchanged apart from the error shape flowing through.
- **Rejection mapping**: map `:malformed_ref | :path_traversal | :symlink_escape | :too_many_symlinks` onto PathSafety's existing error return (keep its public shape; log granular reason).
- **Tests**: bind PathSafety to the shared vectors (including `ref_format` vectors — this consumer uses the gate); NEW red: symlinked workspace dir → `remove/2` must reject before `rm_rf`.
- **Dep**: direct `raxol_core` dep already present (mix.exs:37). Pre-alpha/unpublished — no publish impact.

#### P3 — `raxol_terminal` `FileDropHandler.validate_directories/2` (file_drop_handler.ex:524)

- **Current**: `String.starts_with?(file.path, allowed_dir)` only — no boundary `/`, no normalization, allowlist not re-checked after `resolve_symlinks_recursive/2` (:408, depth 10).
- **Target call**: `Enum.any?(allowed_dirs, fn dir -> match?({:ok, _}, Path.confine(dir, Path.relative_to(file.path, dir))) end)` — or the simpler shape: confine the *raw* dropped path per allowed root and accept on first `{:ok, real}`, using `real` downstream.
- **Diff sketch**: delete the prefix check; run `confine/3` per allowed_dir; on success, **replace `file.path` with the returned `real` path** so all downstream stat/read uses the resolved path. Retire `resolve_symlinks_recursive/2` (confine's realpath supersedes it: depth 40 vs 10, ancestor-dir coverage, post-resolution re-check).
- **Rejection mapping**: fold confine errors into the handler's existing validation-failure reporting.
- **Tests**: bind to shared vectors; NEW reds: (a) `/foo/barbaz` vs allowed `/foo/bar` must reject (the prefix bug), (b) dropped symlink inside allowed dir → outside must reject.
- **Dep**: direct `raxol_core` dep already present (mix.exs:46).

#### P4 — `raxol_agent` `Skills.Store.read_view/2` (store.ex:395, safe_relative? :408)

- **Current**: `safe_relative?(path)` (reject absolute + any `..` segment via `Path.split`) then `File.read(Path.join(entry.dir, path))`.
- **Target call**: `Raxol.Core.Boundary.Path.confine(entry.dir, path)` then `File.read(real)`.
- **Diff sketch**: replace the `safe_relative?` guard + join with the confine call; delete `safe_relative?/1` if unused elsewhere.
- **Rejection mapping**: map any confine error onto the function's existing not-found/invalid return (confirm exact shape at implementation time).
- **Tests**: shared vectors optional here (same impl as P1); required NEW red: symlink planted in an imported skill dir → outside must reject.
- **Dep**: same mix.exs change as P1 (one change covers both sites).

#### P5 — Agent Client Protocol `FsSandbox` (external repo)

- **Current**: the proven seed `confine/3` was ported from — already correct (leaf + ancestor symlink resolution, cycle-guarded, reject-before-syscall).
- **Change**: no code. Copy `path_reject_vectors.json` + `path_accept_vectors.json` verbatim into its test tree; conformance test maps `Error` `data.reason` → vector `expect` atom; skip `ref_format` vectors; add the duplicate-marker moduledoc line ("intentional standalone duplicate of `Raxol.Core.Boundary.Path` — bound to the shared confinement vectors; change both or neither").
- **Tests**: the vector binding IS the test. Divergence = red test, never a silent security fork.

#### T1–T12 — TermText sites (all: same call shape)

- **Target call**: `Raxol.Core.Boundary.TermText.sanitize(untrusted_binary)` (default `allow: [?\n]`; add `?\t` where tab-indented content matters, e.g. code blocks T4/T5/T6).
- **Placement rule**: sanitize **once at the ingestion boundary** (the single content prop), not per-`text()`-emitter:
  - T1: `markdown_text` at `MarkdownRenderer` init/render entry (:60) — one call covers every emitter in the module and transitively covers MessageBlock + demo_helpers.
  - T2: `state.output` in `output_lines/1` (:84) before join/emit.
  - T3: `state.content` in `content_lines/1` (:84).
  - T4: `state.old`/`state.new`/`state.path` at init or entry of `highlight/3` (:466).
  - T5: `state.content` before both the Makeup path (:28) and raw fallback (:30).
  - T6: source at `highlight_lines/3` entry for the nil-language/no-Makeup fallbacks (:76/:114) — defense-in-depth behind T4/T5.
  - T7: `state.name` (:84) + the `is_binary` clause of `compact_args/1` (:113) only (inspect path already safe).
  - T8–T11: the specific untrusted fields named in the triage rows.
  - T12: the steer `text` (:516) and the MLI value line-split feed (:492).
- **Diff sketch** (representative, T1):
  ```elixir
  # before
  markdown_text = props[:markdown_text] || ""
  # after
  markdown_text = Raxol.Core.Boundary.TermText.sanitize(props[:markdown_text] || "")
  ```
- **Rejection mapping**: n/a — `sanitize/2` is total, never errors.
- **Tests**: the shared `term_text_vectors.json` binding lives in raxol_core only (per the vectors README scope). Each site gets a **per-component regression**: render with `\e[31m` / `\e]0;t\a` / `\e[201~` / bare trailing `\e` in the untrusted field, assert no `0x1B` (and no stripped C0) in the produced cell/content strings. Build one shared test helper (`assert_no_control_bytes/1`) in main-lib test support and reuse across all 12.

### 3. Grouping: (owner lane) × (dependency class)

| Lane / owner | direct-raxol_core-dep (just call it) | needs-new-raxol_core-dep (mix.exs change) | zero-raxol-dep (local copy + shared vectors) |
| ------------ | ------------------------------------ | ------------------------------------------ | --------------------------------------------- |
| **harness-agent (us)** | P2 (raxol_symphony) | P1 + P4 (raxol_agent — one mix.exs edit, cycle-free, no publish-order change) | — |
| **UI / terminal (Drew / parallel UI agent)** | P3 (raxol_terminal) + T1–T12 (main raxol lib already depends on raxol_core) | — | — |
| **Agent Client Protocol pkg (us, external repo)** | — | — (MUST NOT take the dep, ratified option b) | P5 |

The `raxol_agent` mix.exs addition is the only dependency-graph change in the whole
migration, and it only makes an existing transitive edge explicit.

### 4. Ordering (dependency-aware)

1. **PR #613** — `raxol_core` boundary functions + vectors. Lands first; everything below depends on it. (Already implemented.)
2. **Wave A — harness-agent lane (us), immediately after #613 merges**: P1 + P4 (one PR: raxol_agent mix.exs dep + both sites + vector binding + symlink reds), P2 (separate PR: symphony PathSafety + workspace rm_rf red). Independent of each other; can run in parallel.
3. **Wave B — UI/terminal lane (cross-lane, needs Drew / the parallel UI agent)**:
   - B1: P3 (file_drop_handler) — highest-severity path fix in the UI lane (prefix bug + rm of the redundant symlink resolver).
   - B2: TermText high-confidence wave T1–T5 (+T6 defense-in-depth). **T1/T5 close #607** (already-identified; the builtin fence path drops the info-string but still leaks the code body — sanitizing the boundary covers both).
   - B3: TermText medium wave T7–T12 (T8/T9 first — approval/blast-radius are the security-critical spoofing surfaces).
   - Cross-lane note: the seam proposal already requires **Drew's sign-off** for the UI-lane migration; this plan is the ADR-shaped artifact he asked for.
4. **Wave C — Agent Client Protocol repo (us, anytime after #613)**: P5 vector copy + conformance test + moduledoc marker. No ordering dependency on Waves A/B.
5. **Blocked / slots reserved (do NOT start)**:
   - **PA-6 CAS `$blob`/`snapshot_ref` deref** → `confine/3` with `ref_format: ~r{^(blobs|snapshots)/[0-9a-f]{64}(\.json)?$}` at deref time. **PA-6 is proposed-not-frozen — this migration cannot land until PA-6 freezes**, and the CAS itself does not exist in this worktree yet. The fixture lint stays as defense-in-depth meanwhile.
   - **#586 tar-extract red** → per-member `confine/3` + reject link/device members at the call site. The untrusted-extract path is absent from this worktree (curator's extract is trusted); the slot activates when/if an untrusted archive import lands.
6. **Owner-confirmation pass (C-list)**: fold confirmed items into the matching wave (C-path items → Wave A/B1 style; C-text items → B3).

---

## Consequences

- Four hand-rolled lexical path checks collapse onto one vetted implementation; the
  file-drop handler additionally sheds its private 10-deep symlink resolver.
- `TermText.sanitize/2` goes from zero call sites to enforcing the "never raw ANSI into
  `text()`" rule *at the untrusted boundary* across the whole harness transcript UI.
- One mix.exs edit (raxol_agent), zero publish-order changes, zero new packages.
- Every migrated path site becomes **stricter** — that is the point, but it is also the
  risk surface (below): inputs previously accepted will be rejected.

## Risk + Validation

**Proof strategy per class:**

- **Path sites (P1–P4)**: bind to the shared vectors (`path_reject/accept_vectors.json`)
  through the site's own public function, plus one site-specific NEW red exercising the
  gap being closed (symlink escape / prefix bug). Property test already lives in
  raxol_core (`confine/3` never returns `{:ok, p}` outside resolved root).
- **P5**: verbatim vector copy is the proof; drift = red test.
- **TermText sites (T1–T12)**: shared vector binding stays in raxol_core; each site gets
  a rendered-output regression via the shared `assert_no_control_bytes/1` helper, plus
  the raxol_core idempotence/no-control-byte properties as the base guarantee.

**Behavior-CHANGE flags (previously-accepted inputs now rejected — review each):**

| Rank | Site | Change to review |
| ---- | ---- | ---------------- |
| 1 | **P2 symphony workspace `remove/2`** | Workspaces containing symlinks that point outside root (checked-out repos with symlinked deps, `node_modules` links, macOS `/tmp`→`/private/tmp` ancestry) may now be rejected at removal — a workspace could become un-removable by the orchestrator. Mitigation to decide at review: confine the workspace *root path itself* (the rm_rf target), not every interior entry; `confine/3` resolving both root and target handles the macOS `/tmp` ancestry case correctly, but the policy for interior symlinks needs an explicit call |
| 2 | **P1 agent `Actions.Fs`** | LLM `read_file` on a symlink inside cwd pointing outside (legit dev setups: symlinked configs, `.asdf` shims, monorepo package links) returned content before; now returns `:outside_cwd`. This is the intended hardening but WILL change observable agent behavior on real repos — needs a release-note line and possibly an opt-out policy knob decision |
| 3 | **P3 file-drop allowlist** | (a) `/foo/barbaz` no longer passes for allowed `/foo/bar` — pure bug fix, but any workflow accidentally relying on it breaks; (b) files dropped via symlinks resolving outside allowed dirs now reject; (c) downstream consumers start receiving the *resolved* real path instead of the as-dropped path — audit consumers of `file.path` for display-vs-access assumptions |

Honorable mention: T1/T5 mean markdown/code content that legitimately *contains* raw ESC
bytes (e.g. a doc demonstrating ANSI codes) will render with those bytes stripped rather
than interpreted — correct per the contract, but visibly different; call it out in the
UI-lane PR description.

## Migration checklist

| Site | Fn | Lane / owner | Dep-class | Blocked-by | Test strategy |
| ---- | -- | ------------ | --------- | ---------- | ------------- |
| P1 `raxol_agent/actions/fs.ex:145` | `Path.confine/3` | harness-agent / us | new raxol_core dep (mix.exs) | #613 | shared vectors + symlink-escape red |
| P2 `raxol_symphony/path_safety.ex:56` (+`workspace.ex:93`) | `Path.confine/3` + `ref_format:` | harness-agent / us | direct dep | #613; risk-1 policy call | shared vectors (incl. ref_format) + rm_rf symlink red |
| P3 `raxol_terminal/.../file_drop_handler.ex:524` | `Path.confine/3` per allowed_dir | UI-terminal / Drew | direct dep | #613; Drew sign-off | shared vectors + prefix-bug red + symlink red |
| P4 `raxol_agent/skills/store.ex:395` | `Path.confine/3` | harness-agent / us | new raxol_core dep (same edit as P1) | #613 | planted-symlink red |
| P5 Agent Client Protocol `FsSandbox` | none — vector binding | Agent Client Protocol / us | zero-raxol-dep (option b) | #613 | verbatim vector copy (skip ref_format) |
| T1 `markdown_renderer.ex:60` | `TermText.sanitize/2` | UI / Drew | direct (main lib) | #613; Drew sign-off (#607) | component red + no-control-bytes helper |
| T2 `harness/tool_result_block.ex:156` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | component red |
| T3 `harness/reasoning_block.ex:108` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | component red |
| T4 `harness/diff_viewer.ex:466` | `TermText.sanitize/2` (allow `?\t`) | UI-harness / Drew | direct | #613; Drew sign-off | component red |
| T5 `code_block.ex:28/30` | `TermText.sanitize/2` (allow `?\t`) | UI / Drew | direct | #613; Drew sign-off (#607) | component red |
| T6 `syntax_highlighter.ex:114/76` | `TermText.sanitize/2` (allow `?\t`) | UI / Drew | direct | T4/T5 (defense-in-depth) | token-output red |
| T7 `harness/tool_call_block.ex:84/113` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | component red |
| T8 `harness/approval_prompt.ex:166/239` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | component red (spoofing-focused) |
| T9 `harness/blast_radius_preview.ex:228/210` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | component red (spoofing-focused) |
| T10 `harness/advisory_feed.ex:93` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | component red |
| T11 `harness/toast.ex:60` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | component red |
| T12 `harness/composer.ex:516/492` | `TermText.sanitize/2` | UI-harness / Drew | direct | #613; Drew sign-off | paste-echo red |
| PA-6 CAS deref (future) | `Path.confine/3` + `ref_format:` | harness / us | n/a yet | **PA-6 freeze** (proposed-not-frozen) + CAS existing | ref_format vectors + deref red |
| #586 tar extract (future slot) | `Path.confine/3` per member | harness / us | n/a yet | untrusted-extract path existing | per-member vectors + link/device-member red |

## References

- [confinement-seam-proposal.md](./confinement-seam-proposal.md) — the contract half (do not duplicate)
- PR #613 — `Raxol.Core.Boundary.{Path,TermText}` + `packages/raxol_core/test/support/boundary_vectors/{path_reject,path_accept,term_text}_vectors.json` + README (scoping: Path vectors → raxol_core + Agent Client Protocol client; TermText vectors → raxol_core only, UI/terminal lane)
- PR #569 thread 2 (DROOdotFOO) — "same gap, four patches"
- #607 — fence/info-string family (closed by T1/T5); #586 — tar-extract red (slot); PA-6 — ref-shape rule (blocked on freeze)
- 2026-07-17 discovery pass over the `confinement` worktree (this plan's ground truth)
- CLAUDE.md render rule: "Never embed raw ANSI codes in strings passed to `text()`"
