# Drew (DROOdotFOO) Adversarial Review Findings — Last 24h

- Date range: 2026-07-16 06:00 UTC through 2026-07-17 06:30 UTC (approx.)
- Repo: DROOdotFOO/raxol
- PRs surveyed: 39 (#587-#629)
- PRs with at least one Drew review/comment: 27
- PRs surveyed with ZERO Drew activity found: 12 -> #596, #599, #600, #601, #602, #603, #612, #624, #626, #627, #628, #629
- Total Drew review/comment entries collected: 48
- Inline (file/line) review comments via the PR review-comments API: 0 across all PRs — all findings are posted as review bodies or PR-level comments (Drew's adversarial-review bot posts consolidated markdown, not line comments).

Legend: **REVIEW** = formal GitHub PR review (has a review state: COMMENTED/APPROVED/CHANGES_REQUESTED). **PR COMMENT** = plain issue-style comment on the PR (used for the same consolidated adversarial-review markdown format, and for cross-PR notes / fix-push notes). Round numbering is per-PR, in chronological order of Drew's own postings (re-reviews are explicit 'Adversarial Re-review' rounds against a stated commit range).

---

## PR #587 — feat(harness): U8 BlastRadiusGate + approvals — reds + impl (AD-6b/14)
State: MERGED (merged 2026-07-16T13:42:51Z)
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T12:10:54Z

## Adversarial Review (automated)

Scope: the landed implementation in this unit — `blast_radius_gate.ex`, `meta.ex`, `meta/registry.ex`, `emit_bridge.ex`, `contract.ex`. Reviewed the full gate + folds; tests read for intent, not audited for style.

### HIGH

- **[Security Auditor] blast_radius_gate.ex:475, :502 — the approver is never authenticated; `actor` is accepted then discarded.** The gate's whole purpose is "a destructive call requires a *human* decision." Yet `apply_decision(state, decision, _actor)` ignores the actor entirely, and `rebuild/1` folds `{decision, _actor}` with the actor discarded too. Nothing in the gate (nor `Meta.validate/1`, which only checks required keys) verifies `actor.kind == :human`. Failure scenario: an agent (or any producer that can emit a `family: :meta, type: :approval_decided` with `decision: :approved` naming a live `request_ref`) self-approves its own escalated write — the confirmation step is defeated. The moduledoc defers actor auth "upstream / on the journal envelope," but there is no upstream wiring in this PR, and a security gate that never inspects the approver is fail-open by construction. At minimum `apply_decision`/`rebuild` should reject a non-`:human` approving actor (or the contract must state the trust boundary that guarantees only humans can journal an `approval_decided`).

- **[Security Auditor + New Hire] blast_radius_gate.ex:375/:531 vs :518 — deny and grant use asymmetric keys (deny-bypass / over-block).** `denied` stores and is checked by the **bare `call_id`** (`MapSet.member?(state.denied, cid)` at :375; `grant(:denied)` puts `cid` at :531). But `:once` grants are keyed by the **full tool+call_id ref** (`ref_encode` at :518), and the `:once` branch is evaluated *before* the deny branch (:372 before :375). Failure scenario, when `call_id` is reused across tools within a session (the gate offers no uniqueness guarantee): approve `(toolA, c1)` `:once` → `once = {ref(A,c1)}`; deny `(toolB, c1)` → `denied = {c1}`, and `grant(:denied)` only deletes `ref(B,c1)` from `once`, leaving `ref(A,c1)`. A re-issued `(toolA, c1)` hits the `:once` branch first and **proceeds despite `denied` containing `c1`** — a deny that the code otherwise treats as blocking all of `c1`. The inverse reading (deny is meant to be per-request) makes :375 over-block unrelated tools that share a `call_id` (availability). Either way the keying is internally inconsistent; pick one identity and use it in all four sites. (Promoted per the 2-persona rule; exploitability is conditional on `call_id` reuse.)

### MEDIUM

- **[Saboteur] blast_radius_gate.ex:514-533, :436 — `apply_decision`/`rebuild` crash on out-of-domain journal input (replay DoS).** `grant/5` has heads only for `:approved`/`:denied` and scopes `:once|:session|:root`; there is no catch-all. A journaled decision with `decision: :corrupt` or `scope: :global` (a legal meta scope elsewhere) raises `FunctionClauseError`, and `parse_ref/1` (:436) raises on any `request_ref` not shaped `"req:<len>:..."`. Failure scenario: a version-skewed or partially-corrupt journal makes `rebuild/1` crash on resume — the session cannot reconstruct enforcement state and fails to start. This directly contradicts the reader-tolerant doctrine the sibling `Meta.decode/1` upholds (unknown tokens preserved raw, never raised). The gate's fold should degrade fail-closed (treat an unparseable/unknown decision as no-grant or a deny marker), not crash.

- **[Security Auditor] blast_radius_gate.ex — gate has zero call sites; "locked by default" is not enforced at runtime.** `grep` across `packages/` and `lib/` finds no invocation of `BlastRadiusGate.authorize/3` or `evaluate/2` outside the module and its tests (the only other `blast_radius` hit is an unrelated UI preview component). The module is a correct library with a passing suite, but no tool-dispatch path routes through it, so no write/destructive tool is actually gated by this PR. Acceptable if wiring is a declared follow-up unit — but the PR body's "write/destructive tools are LOCKED by default" reads as a live control and it is not one yet. State the deferral explicitly so a reviewer doesn't merge believing protection is active.

- **[Saboteur] blast_radius_gate.ex:411, :517-531 — unbounded state growth.** `pending` grows on every escalation and is pruned only by `apply_decision`; `denied` grows on every deny and is never pruned; `once`/`session` likewise. A long-lived session (or an agent that spams escalating write calls that are never decided) leaks these MapSets without any TTL or cap. Bounded only by session lifetime, but there is no back-pressure.

### LOW

- **[Saboteur] blast_radius_gate.ex:236-242 — `escalate?/1` uses dot access on `call.effect_class`/`call.egress`.** A call map missing a "required" field raises `KeyError` inside `evaluate/2` rather than failing closed to escalation. `tainted_lineage?/1` already uses `Map.get` with defaults; `escalate?` should be equally defensive given it sits on the authorization path.

- **[New Hire] blast_radius_gate.ex:346-354, :372 — the `:once`-before-taint ordering is a fragile invariant.** A consumed one-shot grant proceeds without re-running the taint fold (:372 precedes :378). The ordering comment claims intent, but "a grant for exactly this request was already vetted" silently assumes `call_id` uniquely and stably identifies the same arguments/lineage — an assumption the type contract does not enforce. Reuse of a `call_id` with newly-tainted lineage would proceed on the standing `:once` grant.

- **[New Hire] blast_radius_gate.ex:433-441 — the `"req:<len>:<tool><cid>"` encoding is a hand-rolled, undocumented wire format parsed by binary-size matching.** It is injective and clever, but it is the load-bearing link between a journaled decision and the grant key, with no round-trip test guard visible in the impl module and a hard crash (:439 binary match) if a `request_ref` ever originates from outside the gate.

### Cross-Persona Overlaps

- **Actor-not-authenticated** reached independently by Security (missing `:human` check) and Saboteur (forged/agent-authored `approval_decided` folded into a grant on rebuild) — kept HIGH.
- **Deny/grant keying asymmetry** flagged by Security (deny-bypass) and New Hire (maintainer will assume symmetric keying) — promoted MEDIUM → HIGH.

### Verdict: CONCERNS

Two HIGH findings (approver never authenticated; asymmetric deny/grant keying) plus several MEDIUM. Not a BLOCK: the gate is an unwired library unit with a green suite, so nothing is live-breaking today. But the actor-authentication gap is a design-level fail-open in a control whose entire reason to exist is "a human must approve," and it should be closed (or the trust boundary contractually pinned) before this gate is wired into any tool-dispatch path.

---

## PR #588 — test(harness): TP-PTY :skip_on_ci + T28a destale (unskip the fixed graceful-stop guarantee)
State: MERGED (merged 2026-07-16T13:42:24Z)
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T12:09:34Z

## Adversarial Review (automated)

Scope: 3 files (2 test, 1 moduledoc). I verified the load-bearing claim first: T28a is real and the unskipped test is deterministic.

- `Lifecycle` traps exits and `terminate/2` is the single teardown path (lifecycle.ex:206, 435-463); it stops the driver FIRST via `Shutdown.stop_process` -> synchronous `GenServer.stop(pid, :shutdown, timeout)` (shutdown.ex:15).
- `InlineDriver.terminate(_reason, %State{})` matches ANY reason and calls `emit_teardown/2` (inline_driver.ex:295) — so the `:shutdown` reason Lifecycle uses still emits.
- Therefore, by the time the unskipped test receives `{:DOWN, ...}` for the Lifecycle pid, the driver's teardown bytes are already in the `StringIO`. The unskip is SOUND — it enforces a real structural guarantee, it does not mask a flake.

### HIGH
- [Saboteur / Security Auditor / New Hire] `test/harness/tp_pty_test.exs:22` — the new blanket `@moduletag :skip_on_ci` removes ALL CI coverage of `PtyHarness`. This module is the ONLY test that exercises the harness (confirmed: `grep -rl PtyHarness test/` returns just this file), and the harness spawns subprocesses, injects bytes into pty masters, delivers real signals, and asserts cleanup — orphan-death in the process-group test, `{:error, :wrapper_exited}` after stop, capture-file removal. After this change, a regression or resource leak in `PtyHarness` (leaked pty fds, orphaned `sleep`, stale TMPDIR capture files) leaves CI green. The moduledoc itself calls this the foundation "before any T2d/T2a/T25 test builds on it," so the foundation now has zero CI guard. Only a subset of these tests are actually signal-timing-flaky; the deterministic ones (spawn/exit round-trip:143, winsize/env/cwd:299, dead-wrapper guard:332, availability guard:348) are dropped needlessly. Prefer per-test `:skip_on_ci` on the timing-sensitive cases (signal/drain-barrier/job-control), not a module-wide skip. (Base severity MEDIUM; promoted for 3-persona overlap.)

### MEDIUM
- [New Hire] `test/harness/tp_pty_test.exs:9-13` (moduledoc) — states the suite "runs locally / watched," but `:skip_on_ci` is excluded whenever `SKIP_TERMBOX2_TESTS=true` (`test/test_helper.exs:22`), and per CLAUDE.md the repo sets `SKIP_TERMBOX2_TESTS=true` automatically for local runs via `.claude/settings.json`. So a developer's default `mix test` will ALSO skip these; they only run if the dev unsets that env or passes `--include skip_on_ci`. The moduledoc overstates local coverage — a maintainer will assume these run locally when by default they do not.

### LOW
- [New Hire] `test/harness/t2d_teardown_positive_test.exs:191` — the still-skipped SIGTERM test's `skip:` message and comments were re-attributed to "T28b," but the tag atom stays `:pending_t28` (both facets share it). Grepping for `T28b` will not surface the tracking tag; the tracking key and the prose now disagree.
- [New Hire] `test/harness/t2d_teardown_positive_test.exs:159-167` — the PR body defends the unskip with a "30/30 across seeds, ~1e-9" sweep, but the committed test runs the shutdown exactly ONCE. The sibling drain-barrier test loops 20x (`tp_pty_test.exs:174`) precisely because a single shot can miss a residual timing race. The T28a structural guarantee (verified above) makes a single run acceptable here, so this is a convention nit, not a correctness bug — but it is worth a one-line note that the single run relies on the structural guarantee, not on repetition.
- [Saboteur] `test/harness/t2d_teardown_positive_test.exs:160` — `assert_receive {:DOWN, ...}, 2_000` now runs on CI and wraps a full in-process Lifecycle boot + teardown (plugin manager, dispatcher, rendering engine, driver). 2s is generous for a `StringIO`-only path, but it is a wall-clock bound on a loaded runner. Non-blocking; flag only if this test ever flakes.

### Cross-Persona Overlaps
- The CI-coverage loss from the blanket `:skip_on_ci` (tp_pty_test.exs:22) was independently reached by Saboteur (undetected harness regressions/leaks), Security Auditor (subprocess/signal/resource-hygiene assertions no longer run on CI), and New Hire (over-broad exclusion drops deterministic tests). Promoted MEDIUM -> HIGH.

### Verdict: CONCERNS
No CRITICAL and fewer than 3 HIGH, so not BLOCK. The T28a destale and the unskip are correct and verified deterministic. The blocking-adjacent issue is the module-wide `:skip_on_ci` on the sole PtyHarness test plus the moduledoc's inaccurate "runs locally" claim. Recommend: narrow `:skip_on_ci` to the timing-sensitive tests and correct the moduledoc's local-run wording before merge.

---

## PR #589 — Harness UI: printed-history append path (seal-once, immutable-prefix keystone) [T2b]
State: MERGED (merged 2026-07-16T17:41:20Z)
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T12:07:48Z

## Adversarial Review (automated)

Scope: `lib/raxol/ui/rendering/paint_authority/inline_authority.ex` (+2 property suites). Three adversarial personas, grounded in code. Base modules cross-checked against `origin/feat/harness-ui-T2b` (`ScrollRegionManager`, `PaintAuthority` behaviour, `Dialect`).

### HIGH
- [Security Auditor] `inline_authority.ex` `seal/2` and `append_sealed/2` (~L199-226) write `iodata` to the device verbatim — no escape stripping, no validation. Every invariant this module advertises ("never emits `\e[2J`", "immutable prefix", "no row is ever re-addressed") is true only for the module's *own* bytes. A producer whose block text contains ANSI (`\e[2J`/`\e[3J` in agent stdout, an LLM transcript, or remote/tool output routed into printed history) injects those bytes straight into the terminal: `\e[2J`/`\e[3J` wipes native scrollback — the exact N06 disaster the moduledoc claims to prevent — and `\e[<r>;1H...` inside a "sealed" block repaints an already-sealed row. Both defeat seal-once from *inside* content that the oracle treats as trusted. The property/adversarial suites only ever feed `string(:alphanumeric)` and hand-authored clean blocks, so this surface is never exercised. Either the append path must reject/escape control bytes in `iodata`, or the "sealed content is trusted" precondition must be enforced at the seam, not assumed.

### MEDIUM
- [Saboteur] `append_sealed/2` + `count_lines/1` (~L210-226, L305-310): `next_row` advances by the count of `"\n"` bytes. A seal whose `iodata` is not newline-terminated (e.g. `"partial"`) yields `count_lines == 0`, so `next_row` does not advance; the *next* `seal/2` CUPs to the same `target_row` and overwrites the partially written row — a direct seal-once / immutable-prefix violation. The "whole `\r\n`-terminated lines" contract is stated only in the `seal/2` docstring (~L198-202) and enforced nowhere in code (`seal/2` does no validation). `block_gen` always appends `\r\n`, so no test can catch a caller that forgets. This is the same root cause as the HIGH: `iodata` is trusted without validation.
- [Saboteur + New Hire] `with_cursor/3` (~L246-263) is documented as the "SOLE owner" of the `\e7`/`\e8` register, but nothing enforces non-nesting. The struct carries no depth field; if any caller invokes `seal/2` (or another `with_cursor/3`) *inside* a `with_cursor` fun — e.g. T2c's footer path the moduledoc explicitly anticipates as a caller — the inner `\e7` clobbers the single hardware DECSC register and the outer restore lands on garbage, corrupting cursor position for every subsequent seal. `SealOracle.save_restore_balance/1` checks `decsc_max_depth <= 1` in tests, but production has no guard. "Sole owner" is a prose guarantee with a runtime hole. (Promoted: Saboteur + New Hire.)
- [New Hire] Moduledoc (~L8-111) is ~100 lines of lane-id shorthand — `T2a/T2b/T2c/T2d`, `D-PA (A)`, `INV-5-A`, `R8`, `N06`, "RB's C-4 probe", "RULING §0" — undecodable without the external roadmap. This directly contradicts the repo's own recorded doc preference (strip `Phase N`/meta-narration and lane ids from docstrings). A new maintainer cannot learn what the module *does* without three other documents; the load-bearing 3-line "fill-down then scroll" rule is buried under provenance narration.

### LOW
- [New Hire] `bottom = ScrollRegionManager.region_top(region)` (~L211): a function named `region_top` returns the value the code binds as `bottom` (the history region's last/split row). Inherited upstream naming, but at this call site it reads as a contradiction and invites off-by-one edits.
- [New Hire] `cup/1` (~L303) hand-rolls raw `"\e[#{row};1H"` while save/restore route through `Dialect.cursor_save/0`/`cursor_restore/0`. The module calls `Dialect` "the shared wire vocabulary" yet positioning bypasses it — the one place a future terminal-dialect quirk in CUP would need to live is off the seam.
- [Saboteur] `resize/3` telemetry metadata (~L282-283) reads `old_region.region_top`/`new_region.region_top` as raw struct fields while the rest of the module uses the `ScrollRegionManager.region_top/1` accessor — couples to struct internals inconsistently.
- [Saboteur] `new/5` (~L151) guards only `width > 0`; `rows`/`footer_rows` are spec-only (`pos_integer`/`non_neg_integer`), unenforced. A `footer_rows >= rows` caller silently produces a degenerate 1-row region rather than an error. No crash (ScrollRegionManager's `region_top/2` clamps `>= 1`), but the failure is silent and only visible as squashed output.

### Cross-Persona Overlaps
- Unvalidated `iodata` is the shared root of the HIGH (Security: escape injection wipes scrollback / repaints sealed rows) and the top MEDIUM (Saboteur: unterminated line overwrites a sealed row). One fix — validate/reject control bytes and require newline-termination in `seal/2` before emit — closes both. The `with_cursor` nesting hole is an independent second class of unenforced-prose-contract.

### Verdict: CONCERNS
One HIGH (terminal escape injection through unvalidated sealed content) plus three MEDIUM. No CRITICAL and fewer than 3 HIGH, so not a BLOCK, but the immutable-prefix keystone this unit exists to guarantee is only as strong as its untrusted `iodata`, and the newline/nesting contracts are enforced only in prose. Recommend validating `iodata` (control-byte rejection + newline-termination) and adding a nesting guard to `with_cursor/3` before this substrate is built on.

---

## PR #590 — Harness UI: pinned footer viewport (footer-scoped diff, no \e[2J keyframe) [T2c]
State: MERGED (merged 2026-07-16T17:51:35Z)
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T12:08:36Z

## Adversarial Review (automated)

Scope: `lib/raxol/ui/rendering/paint_authority/inline_authority.ex` (+207/-7) plus the two new property suites. Read in full against the T2a `ScrollRegionManager` it composes on. The footer geometry math (CUP row = `region_top+1+idx`, bounded by `footer_range/1`) checks out for the normal and degenerate geometries. The findings below are about what the diff logic does NOT defend against.

### HIGH
- [Security Auditor / Saboteur / New Hire] `inline_authority.ex:398` (`footer_row_bytes/2`), reached via `repaint/2:357` and `keyframe/2:385`, emitted at `repaint_footer/2:305` / `keyframe_footer/2:311` — **the footer content `line` is written to the device verbatim, with no control-sequence sanitization.** The entire PR's headline invariant ("every emitted CUP lands in `footer_range`, never a history row; `\e[2J` is never emitted") is enforced only over the bytes THIS module generates (`cup/1` + `\e[K`). It is not enforced over the caller's content. The footer is documented as "live tail + status strip + composer" — the live tail is streamed agent/LLM/tool output, which is untrusted and routinely contains ANSI. Concrete failure: a footer line `"tail: \e[1;1Hpwned"` executes the embedded CUP at emit time, moving the cursor to row 1 (inside the sealed history region) and writing "pwned" there — a direct INV-2 confinement break and an immutable-prefix (seal-once) violation. A line containing `\e[2J` wipes native scrollback on wezterm/kitty — the exact outcome N06 and this whole module exist to prevent — defeated through content rather than through an emitted clear. This needs no malice: ordinary colored CLI/tool output (embedded SGR is fine, but embedded cursor moves / `\e[K` / erase sequences are common) corrupts the layout. The "Caller contract" moduledoc section (`inline_authority.ex:150-166`) addresses only line *width* (wrap) and points callers at `TextMeasure` — display-width truncation does not strip escapes and would not catch this, so a diligent caller who follows the documented contract still ships the bug. Untested: every property/adversarial test drives alphanumeric-only content (`line_gen` = `string(:alphanumeric, ...)`, `renderer_footer_property_test.exs:120`), so the O1 `cup_rows` confinement scanner never sees an escape smuggled through legitimate `repaint/2`. Fix: strip/neutralize C0/C1 and CSI/OSC sequences from each `line` before `footer_row_bytes/2` (or assert the caller contract as a hard, documented, tested precondition), and add an adversarial content generator that injects `\e[...H`/`\e[2J` into footer lines. Promoted (3 personas, same root, defeats the core PR guarantee).

### MEDIUM
- [Saboteur] `resize/3:447-478` updates `region`, `width`, and `next_row` but deliberately does NOT reset `footer_lines`. The on-screen footer content is not moved by resize (only the DECSTBM split is re-emitted), so after a geometry change the previously-painted rows sit at their OLD absolute positions while `footer_range/1` now points at DIFFERENT rows. The only protection is the documented `resize |> keyframe` composition. Failure: a caller that does `resize |> repaint` (documented as needing `keyframe`, but nothing enforces it) diffs the new lines against stale `footer_lines`; unchanged rows emit zero bytes and are never repainted at their new positions, leaving ghost rows / stale history-adjacent residue. This is a one-line safety improvement: setting `footer_lines: []` in `resize/3` turns the next `repaint/2` into an automatic full repaint (all rows diff as changed) without touching the "resize emits only DECSTBM" byte-count regression test (resize still emits no footer bytes). A silent-ghost footgun becomes a self-healing full redraw.

### LOW
- [New Hire] `footer_diff/2:322-324` is a public, `@doc`'d function whose clause guard requires `length(old_lines) == length(new_lines)`. Called with mismatched lengths it raises a cryptic `FunctionClauseError` rather than a clear contract error. Internal callers always pre-pad, but the function is exported as if it were a general-purpose diff; a `raise ArgumentError` with a message, or explicit docs that it is internal-only, would be kinder to the next caller.
- [New Hire] `keyframe/2:388-389` always opens the `with_cursor` save/restore bracket even when `footer_row_count/1` is 0 (degenerate `rows=1/footer=2` geometry), emitting `\e7`/`\e8` with nothing between. Harmless, but contradicts the "footer-scoped, zero bytes when nothing to do" mental model the `repaint/2` no-op path (`:349`) establishes; a maintainer reasoning about byte output will be briefly surprised.
- [Saboteur] `repaint/2:349-350` no-op branch returns `t` without writing back `padded_new` to `footer_lines`. After a resize-induced count change, `footer_lines` can retain the old length; because `pad_rows/2` is deterministic subsequent diffs stay consistent, so this is benign today, but it means `footer_lines` does not always equal "what is on screen at the current count" — an implicit invariant a future reader may over-trust.

### Cross-Persona Overlaps
- The escape-injection gap (`footer_row_bytes:398`) was reached independently by all three personas: Saboteur (benign ANSI tool output corrupts layout / cascading render breakage), Security Auditor (untrusted live-tail content escapes footer confinement and wipes scrollback), New Hire (the confinement guarantee rests on an undocumented "content is escape-free" assumption that the documented `TextMeasure` width contract does not cover). Same root, promoted to HIGH.

### Verdict: CONCERNS
One HIGH (footer confinement is not enforced over caller content — the PR's central invariant is bypassable through the footer's own untrusted live-tail data, and untested) plus a MEDIUM resize/footer_lines ghost footgun. Neither is a correctness bug in the byte-generation math, which is sound; both are missing defenses at the content boundary. Recommend: sanitize control sequences from footer lines (or make it a hard, tested caller precondition) and add an escape-injection content generator to the adversarial suite before merge.

---

## PR #591 — Harness UI: status strip (stage+elapsed, needs-input, missing-data honesty) [T10]
State: MERGED (merged 2026-07-16T17:30:09Z)
Drew entries: 2

### Round 1 — PR COMMENT — 2026-07-16T12:08:16Z

## Adversarial Review (automated)

Scope: `lib/raxol/harness/status_strip.ex` (+ two test files). Pure `state -> [footer_line]` projection. Reviewed against idiomatic Elixir/OTP and the repo's own pinned-region / TextMeasure contracts.

### HIGH

- **[Saboteur] status_strip.ex:277 (`render_stage_elapsed` warn branch) + :298 (`fit_to_width`)** — the warn-state glyph `⏳` (U+23F3, HOURGLASS WITH FLOWING SAND) is measured as **1 column** by `TextMeasure.display_width`, but renders as **2 columns** in every modern terminal (iTerm2/kitty/wezterm/gnome-terminal; U+23F3 has `Emoji_Presentation=Yes` -> UAX#11 Wide). `Raxol.Terminal.CharacterHandling.wide_char?/1` (character_handling.ex:17-49) has no range covering 0x2300–0x23FF — its widest low range is `0xFF01–0xFF60` / `0x1F300–0x1FAFF`, so `get_char_width(0x23F3)` falls through to `1`. `fit_to_width` measures every candidate with this undercount, so during the 15s–60s window the emitted footer is **1 column wider than the requested width**, overflowing the pinned region T2c writes byte-level (wrap/corruption of the pinned strip). This directly defeats the module's headline guarantee and contradicts the moduledoc's own claim (status_strip.ex:~168) that it uses TextMeasure *because* "naive `String.length` would overflow" on ⏳ — TextMeasure returns exactly the same wrong `1` that `String.length` would. Failure scenario: turn at 20s elapsed, terminal width == full-strip width -> strip renders `width+1` columns -> pinned region overflows by one cell every render tick.

- **[Security] status_strip.ex:259 (`stage_label/1` -> `to_string(stage)`)** — `turn_stage` (`@type turn_stage :: atom() | String.t()`) is interpolated verbatim into the footer line with zero sanitization, then handed to T2c's byte-level pinned-region writer. A stage string containing an ANSI/control sequence (`"\e[2J\e[H"`, `"x\e[31m"`) or a newline (`"a\nb"`) is written straight into the terminal: escape sequences corrupt/clear the screen (classic terminal-escape injection, CWE-150) and a `\n`/`\r` breaks the single-line pinned-region contract. `TextMeasure.display_width` counts ESC and each following byte as width 1 (character_handling.ex `get_char_width` returns 1 for all control chars), so the width bound *passes* while the real byte stream both overflows and injects. In an agent harness, `turn_stage` plausibly derives from tool names or model-emitted event labels, i.e. it can carry adversarial bytes. (Promoted to HIGH: shares the "display_width does not guarantee safe/real column output" root with the ⏳ finding above.)

### MEDIUM

- **[New Hire] t10_status_strip_test.exs:~205 (`without_cost_width = full_width - 12`)** — the drop-Cost-first test hardcodes the magic constant `12` tied to the exact rendered length of `" | Cost: $1.23"`. Any change to the cost format, separator, or the `@wide_state` cost value silently shifts the boundary and the test no longer exercises "just barely too narrow for Cost," yielding false-green coverage of the degradation edge. Derive the width from the actual rendered segments instead.

- **[New Hire] t10_status_strip_property_test.exs:~63 (`maybe_add_turn_completed/1`)** — the generator force-injects `turn_completed: true` whenever `context_pct` is present, so the "each present field renders its slot" property *never* generates the real producer state (`context_pct` present, `turn_completed` false/absent). The whole "never a stale %" gate — the unit's most safety-relevant branch — is therefore covered only by hand-picked example tests, and the property gives false confidence that "context_pct present => renders a number." Property space and the structural gate are silently decoupled.

### LOW

- **[Saboteur] status_strip.ex:249 (`cost_value`)** — `:erlang.float_to_binary(cost / 1, decimals: 2)` has no domain guard: a negative `cost` renders `"$-1.23"` and a non-finite/huge value renders oddly; `cost` is trusted numeric today so impact is cosmetic, but the "honest slot" intent argues for a guard.
- **[Saboteur] status_strip.ex:192 (`render/2` guard)** — `when is_map(state) and is_integer(width)`; a non-integer `width` (e.g. a float from an upstream layout calc) matches no clause -> `FunctionClauseError`, despite the moduledoc promising "never raises." Minor given callers pass integer columns.
- **[New Hire] status_strip.ex:1-186** — ~130 lines of moduledoc prose (open-question essays, cross-unit rationale) before any code. Thorough, but the ⏳ width claim in it is now factually wrong (see HIGH #1); at minimum that paragraph must be corrected.

### Cross-Persona Overlaps

- Saboteur (⏳ undercounted) and Security (control bytes undercounted + injected) are the same root defect: `TextMeasure.display_width` / `CharacterHandling.get_char_width` is an incomplete, non-sanitizing width oracle, and this module treats its output as a hard safety bound for a byte-level pinned region. The module's entire value proposition (width discipline, no raw ANSI in the pinned region — a CLAUDE.md hard rule) is not actually enforced against real terminal bytes. This overlap is why the Security injection finding is promoted to HIGH.

### Verdict: CONCERNS

Two HIGH findings, both undermining the module's central width/safety contract, plus two MEDIUM test-integrity gaps. Not a BLOCK (no CRITICAL, fewer than 3 HIGH), but the ⏳ overflow and unsanitized `turn_stage` should be fixed before merge: (1) add U+2300–U+23FF emoji-wide handling (or special-case the emitted glyph set) and (2) strip control/ANSI bytes from `stage_label/1` before interpolation.

### Round 2 — PR COMMENT — 2026-07-16T14:18:19Z

still failing CI

---

## PR #592 — Harness UI: keybind layer (canonical events → typed commands, composer-safe) [T12]
State: MERGED (merged 2026-07-16T14:48:20Z)
Drew entries: 2

### Round 1 — PR COMMENT — 2026-07-16T12:07:08Z

## Adversarial Review (automated)

Scope: `lib/raxol/ui/harness/keymap.ex` (+199) and its test. Pure keymap, no process state, well-tested against the real T27 emitters. The findings below are real defects/traps, not a rejection of the design.

### HIGH
- [Saboteur + Security Auditor] `keymap.ex:167` (`resolve(norm, context \\ %{})`) + `keymap.ex:186-187` (`Map.get(context, :composing?, false)`) — **the default fails open toward the exact bug this unit exists to fix.** A missing/omitted `composing?` is treated as *not composing*, so `z`/`j`/`k` resolve to `:fold_toggle`/`:jump_next`/`:jump_prev`. The whole raison d'etre (moduledoc + `harness-ui-STATE.md`: "the demo's flat keymap steals j/k/s/z from typing") is defeated the moment a caller forgets to thread composer-focus state — which is precisely the fragile part deferred to T13a's wiring. Failure scenario: T13a dispatches keymap-first (its own stated precondition #1) but a code path building `context` drops `composing?` (e.g. `%{focused_block_id: id}` with no focus flag) → the user typing `j` mid-message gets a jump instead of a character. The safe default for a key-stealing guard is "assume composing (passthrough)", not "assume free to steal". The test at `keymap_test.exs` ("composing?: unset defaults to the guarded (non-composing) behavior") codifies the fail-open default rather than flagging it. Base MEDIUM, promoted (2 personas, same root cause).

### MEDIUM
- [Saboteur / New Hire] `keymap.ex:176-177` (`matches?(%{key: key}...)` → `InputEvent.key(norm) == key`) — **key binds are modifier-blind; the "tui-steal rule" claim is aspirational.** `InputEvent.key/1` returns the bare atom (`:tab`, `:escape`) regardless of `mods`, so `Ctrl+Tab`, `Alt+Tab`, and `Shift+Tab` (via `Event.key_event(:tab, :pressed, [:ctrl])`, a shape T27 supports) all resolve to `:steer`. Meanwhile the `char` binds *are* modifier-safe, but only as an accidental side effect of `printable_char/1`'s internal `text?` check (`ctrl/alt/meta` held → `nil`). This asymmetry is undocumented and load-bearing. The moduledoc promises a future chord "grows a `mods:` requirement, the walking loop does not change" — but `matches?/3` has **no** code path that inspects `mods`, so adding a chord *does* require restructuring `matches?`. A maintainer trusting the doc will ship `Ctrl+Tab` = steer.

### LOW
- [New Hire] `keymap.ex:155` (`command_types, do: Enum.map(@binds, & &1.command_type)`) — spec'd and documented as "the exact **set** … can ever emit", but returns a plain list that would contain duplicates if two binds ever shared a `command_type`. The parity test itself calls `Enum.uniq` on it, revealing the author already knows it is not a set. `Enum.map |> Enum.uniq` (or `MapSet`) here would make the name honest for T15's palette consumer.
- [Saboteur] `keymap.ex:186-187` — `resolve/2` promises totality ("never raises on a well-formed `InputEvent.t()`") but `resolve(norm, nil)` raises `BadMapError` inside `guard_passes?(%{guard: :not_composing}, nil)` (`Map.get(nil, ...)`), while an `:always` bind with the same `nil` context returns fine. Inconsistent crash surface; an `is_map(context)` guard or a normalizing clause would restore the totality guarantee. Easy to hit since `context` is optional and a caller may compute it as `nil` when no block is focused.
- [New Hire / Security Auditor] `keymap.ex:189-194` (`build_command(:fold_toggle)`) — `focused_block_id` is passed straight from context into `payload.block_id` as opaque `term()` with no shape check. Benign at this pure layer, but it is an unvalidated trust boundary: downstream fold/jump handlers (T13a/T15) must not assume it references a live block. Worth a `@type` narrowing or a note that consumers validate.
- [New Hire] moduledoc "Command shape" — `command()` is hand-kept field-identical to `Raxol.Agent.Command` with the real conversion (`struct(Command, cmd)`) deferred to T13b, and nothing (test or type) enforces parity across the package boundary. Silent drift risk: if `Raxol.Agent.Command` gains a required field, `struct/2` fills a default and the mismatch surfaces only at the live wiring seam, far from this file.

### Cross-Persona Overlaps
- Fail-open default context (HIGH) surfaced independently as a production-correctness regression (Saboteur) and a safe-default/least-surprise violation where a lost UI-focus signal escalates typed keys into privileged transcript commands (Security Auditor). Promoted per the 2-persona rule.
- Modifier handling recurs: Saboteur sees `Ctrl/Shift+Tab` mis-firing `:steer`; New Hire sees the undocumented mechanism asymmetry between the two bind classes. Same underlying gap in `matches?/3`.

### Verdict: CONCERNS
One HIGH (fail-open default re-opens the named key-stealing regression) plus a MEDIUM (modifier-blind key binds contradicting the stated extensibility contract). No CRITICAL and not 3+ HIGH, so not a BLOCK — but the HIGH should be addressed (invert the `composing?` default to fail safe, or require the flag) before T13a wires this in, since T13a is exactly where the missing-context failure mode lives.

### Round 2 — PR COMMENT — 2026-07-16T14:18:05Z

still failing CI

---

## PR #593 — Harness UI: degradation ladder (mode select + flat authority) [T3]
State: MERGED (merged 2026-07-16T17:51:53Z)
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T12:09:53Z

## Adversarial Review (automated)

Reviewed against `feat/harness-ui-T2b` (the stacked base, which supplies `InlineAuthority`, `ScrollRegionManager.degenerate?/2`, and the `PaintAuthority` behaviour). Three files, all additive. Findings grounded in the actual seam contracts.

### HIGH

- [Saboteur / New Hire / Security] `flat_authority.ex:96-98` (`append_sealed/2`) — **the module's central "zero escape bytes, full stop" guarantee is unenforced; it is a property of the caller, not this module.** `append_sealed` does `IO.write(device, iodata)` verbatim. The moduledoc promises flat output "never writes ANY byte in the `0x1B` (ESC) family... the screen-reader answer, the CI/pipe answer" and calls this "PROVABLY true." It is only true for escape-free input. Every other `PaintAuthority` (Inline) routes SGR-styled content through the identical `(t, iodata)` seam; nothing in this PR guarantees the sealed blocks handed to `FlatAuthority` are plain text (the moduledoc itself defers that to "T7's journal-fold projection... T13a's job to bridge" — future work). Failure scenario: colored assistant/tool output (or crafted escape sequences from untrusted remote-agent/tool content) is sealed and routed to flat at a `TERM=dumb` / pipe / screen-reader / CI sink — `FlatAuthority` faithfully forwards the raw ANSI, corrupting screen-reader output and passing terminal-injection sequences straight through to whatever consumes the flat stream. The mechanical test (`t3_degradation_ladder_test.exs`, `@fixture_blocks`) only proves purity for a hand-picked plain-text fixture, so the acceptance criterion "flat output contains no cursor-move/CUP/scroll sequences" is validated only for clean input. The module makes an absolute safety claim it cannot itself hold. (3-persona overlap; base MEDIUM promoted.)

- [Saboteur / Security Auditor] `mode_select.ex:112-127` (`select/3` -> `override/1` before `select_without_override`) — **`RAXOL_HARNESS_MODE=inline` defeats the degenerate-geometry safety floor and silently reintroduces the exact data-loss bug this PR exists to fix.** Rule 1 (override) runs before rule 3 (degenerate geometry). The test even pins this: `override=inline wins over ... degenerate geometry -> :inline_log`. But per this PR's own byte-trace, `InlineAuthority.append_sealed` positions at `min(next_row, region_top)`, and at degenerate geometry `region_top` pins at ≤1, so every seal CUPs to row 1 and clobbers the prior block before it scrolls (verified: `InlineAuthority` moduledoc confirms it always CUPs to `min(next_row, region_top)`). Failure scenario: an operator who prefers inline and exports `RAXOL_HARNESS_MODE=inline` in their shell profile (a reasonable, documented-as-honored choice) then runs the harness in a 2-row split pane — transcript blocks are silently overwritten, never reaching scrollback. If that transcript is an agent/tool audit trail, this is silent integrity/observability loss with no error and no warning. There is no safety floor (override could still clamp to `:flat` when `degenerate?` is true) and no log. (2-persona overlap; base MEDIUM promoted.)

### LOW

- [Saboteur] `mode_select.ex:185-192` (`degenerate_geometry?/1`) — `:rows` is guarded (`is_integer and > 0`, else skipped), but `:footer_rows` from `Keyword.get(opts, :footer_rows, 0)` is passed straight into `ScrollRegionManager.degenerate?/2`, whose guard requires `footer_rows >= 0` and integer. `select(caps, env, rows: 5, footer_rows: -1)` (or a non-integer) raises `FunctionClauseError` instead of the documented fail-open-to-`:inline_log`. Caller-controlled, so low, but the moduledoc claims "purely a function of its three arguments" with a uniform fail-open default that this path violates.

- [New Hire] `mode_select.ex:130-137` (`override/1`) — a misspelled explicit override (`RAXOL_HARNESS_MODE=Flat`, `flatt`, uppercase) matches the `_other -> nil` catch-all and silently falls through to auto-detection. The moduledoc bills the override as the signal that "wins over every other signal," so an operator who typo'd it gets the opposite of what they set with zero feedback (no log/warn). The PR treats "garbage override ignored, no crash" as a feature; for an explicit operator directive, silent no-op is a footgun.

- [New Hire] `flat_authority.ex` / `mode_select.ex` (moduledocs) — ~100 lines of rationale prose per ~40 lines of code, and the "why degenerate outranks tmux" essay is duplicated near-verbatim across the mode_select moduledoc, the PR description, and two test comments (`t3_degradation_ladder_test.exs` table row + regression test). Three-plus copies of the same byte-trace argument to keep in sync as the ordering evolves.

### Cross-Persona Overlaps

- **Verbatim passthrough** (HIGH #1) independently surfaced by all three personas: Saboteur (data corruption at the safe sink), New Hire (moduledoc asserts a guarantee the code doesn't keep), Security (unsanitized ANSI/terminal-injection passthrough at the tier advertised as the safe one). Strongest finding.
- **Override safety floor** (HIGH #2) surfaced by Saboteur (reintroduced clobber/data loss) and Security (env-controlled integrity loss of transcripts/audit trail).

### Verdict: CONCERNS

Two HIGH findings (both promoted via multi-persona overlap), no CRITICAL and fewer than three HIGH, so not a BLOCK. Both are addressable without a redesign: (1) either sanitize/assert escape-free content in `FlatAuthority.append_sealed` or soften the moduledoc's absolute guarantee to state the caller owns escape-freedom and add a mechanical test with styled input; (2) add a degenerate-geometry safety floor (or at minimum a one-line warning) so `RAXOL_HARNESS_MODE=inline` cannot silently drop transcript blocks on a terminal too short to pin a footer.

---

## PR #594 — Harness UI: block bodies (BodyProvider contract + fold-aware component mount) [T5]
State: MERGED (merged 2026-07-16T13:42:03Z)
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T12:07:33Z

## Adversarial Review (automated)

Scope: `block.ex` (`:diff`/`extract_diff_content`, `blast_radius || %{}`), new `BlockBody`, new `BodyProvider`, plus tests. Read in full; BlastRadiusPreview/ApprovalPrompt (unchanged) read for context.

### HIGH
- [Security + Saboteur] `block.ex` `extract_approval_content` (diff L43, `blast_radius = find_in_events(...) || %{}`) — This "fix" is a fail-open regression on the highest-stakes surface. An `approval_requested` event with no `blast_radius` (the PR itself confirms this is reachable from a **real** producer) now defaults to `%{}`. `BlastRadiusPreview.render/2` then reads `reversible = Map.get(br, :reversible, true)` (blast_radius_preview.ex:100) → no `IRREVERSIBLE` marker (blast_radius_preview.ex:155), all groups empty → it renders the authoritative-looking line **"No tracked effects."** (blast_radius_preview.ex:112). Failure scenario: a buggy/adversarial agent emits an approval for `rm -rf /` with `blast_radius` omitted; the operator is shown a clean approval prompt asserting "No tracked effects.", actively contradicting the danger, instead of the pre-change fail-loud crash → plain fallback summary. The PR's own RED test (`block_body_test.exs:743-766`) encodes exactly this: `action: "rm -rf /"`, no blast_radius, asserting "No tracked effects." renders. Trading a fail-safe crash for a reassuring-but-false safety claim on an approval prompt is the wrong direction. Distinguish "no effects declared" from "no effects" (e.g. render an explicit "blast radius unknown — treat as unsafe" state, or keep the fallback for approvals specifically).

### MEDIUM
- [Saboteur] `block_body.ex:129-171` — `render/2` is on the per-frame hot path and `emit_recovered/2` fires a `Logger.warning` + `:telemetry.execute` on **every** failing render with no dedup / rate-limit / already-warned guard. Failure scenario: one persistently-raising block (latent component bug on otherwise-valid input) floods logs and telemetry at frame rate (e.g. 60/s) indefinitely, and the user silently sees a degraded folded summary forever with no crash to force a fix. The logging avoids "silent swallow," but the unbounded volume + permanent silent degradation is its own production hazard.
- [Saboteur + New Hire] `body_provider.ex:344-356, 407-410` — `mount/3`'s `@spec` promises `{:ok, map()} | {:error, String.t()}`, but `mount_one/3` does `{:ok, state} = component.init(props)` (hard match → `MatchError` if any component ever returns non-`{:ok, _}`) and calls `component.render/2`, which can raise. Only `BlockBody.mount_body/2`'s rescue (block_body.ex:156-160) makes this safe. The moduledoc bills `BodyProvider` as a "pure, independently test-facing schema seam" and explicitly the direct-call surface — yet a direct caller (a test, or any future non-`BlockBody` caller) gets no total-safety and a spec that lies about raising. Two personas flag → promoted. Either the spec should admit it can raise, or the match should be softened to an `{:error, _}` path.
- [New Hire] `block_body.ex:77-104`, `body_provider.ex:180-234`, `block.ex` comment (diff L49-56) — Moduledocs/comments are saturated with undefined internal shorthand: `T4`/`T5`/`T7`/`T13a`, `M1 leaf`, `Y1 default`, `W1 collision lesson`, `D-PA (A)`, `R9`. None are defined in-repo; a new hire cannot decode them. This also directly violates the project's own documented voice rule (strip roadmap phase codes / review-iteration labels / dev meta-narration from comments). Replace with plain descriptions of behavior.

### LOW
- [New Hire] `body_provider.ex:466-476` `tool_status/2` — the catch-all clause is named `_present` but also matches `{present_result, nil_exit_code}` and `{present_result, 0}`; the name reads like it means "result present" while it really means "present-and-not-failed." Minor readability trap given the three-way `:pending/:failed/:done` semantics live entirely in the guard ordering.
- [New Hire] `block.ex` `extract_diff_content` (diff L57-64) plus `summary/2` `:diff` clause (diff L9-14) — a `:diff` block whose events carry no `:old`/`:new` yields `old: ""`/`new: ""` (via `to_display_text/1`), so `DiffViewer` renders an empty proposed change with no signal that data was absent, mirroring the approval blind spot at lower stakes.

### Cross-Persona Overlaps
- blast_radius default: Security (misleading safety claim) + Saboteur (fail-open on safety-critical path) → promoted to HIGH.
- `BodyProvider.mount/3` raising vs its `{:ok}|{:error}` spec: Saboteur (uncaught raise for direct callers) + New Hire (spec/contract mismatch, implicit cross-module rescue dependency) → promoted to MEDIUM.

### Verdict: CONCERNS
One HIGH (approval fail-open) plus multiple MEDIUM. The total-safety rescue in `BlockBody` is well-executed and the tests genuinely drive real producers/components; the blocking concern is that the same PR relaxes the approval-content path to fail *open* on the one surface where fail-*safe* matters most.

---

## PR #595 — Harness UI: S1 fixture assembly — the assembled harness (M1) [T13a]
State: MERGED (merged 2026-07-16T18:33:45Z)
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T12:07:48Z

## Adversarial Review (automated)

Reviewed all changed source: `surface.ex`, `view_text.ex`, `status_strip.ex`, `keymap.ex`, `mode_select.ex`, `flat_authority.ex`, `block_body.ex`, `body_provider.ex`, the `block.ex` diff-kind extension, `agent_stream.ex`, and the demo. Three independent personas (Saboteur, New Hire, Security Auditor).

### HIGH
- [Saboteur + Security, promoted MEDIUM->HIGH] `lib/raxol/harness/surface/view_text.ex:1362-1414` (and its callers `surface.ex` `seal_block/2`, `pending_preview_lines/1`, `notice_line/2`) — `ViewText.lines/3` performs display-width truncation but does **no control-byte or newline sanitization** on arbitrary content before that content is written to the terminal / sealed into scrollback. The moduledoc only *assumes* "every harness Component already builds its multi-line bodies as one text child per line," but nothing enforces it. Two concrete failures: (1) any `%{type: :text, content: ...}` whose content contains an embedded `\n` (tool-call results, diff `old`/`new`, agent messages, or composer-submitted text echoed in the stub notice) is emitted as a single iodata row that actually spans multiple physical lines, desyncing `InlineAuthority`'s one-binary-per-row footer/scroll-region accounting -> corrupted pinned region and clobbered history; (2) embedded ESC (`\x1B`) bytes in that same untrusted content pass straight through to the terminal as an escape-injection vector (also miscounts `TextMeasure` width). `Composer.value/1` returns the raw MultiLineInput buffer with no stripping seam, so submitted/steered text flows in unsanitized too. Fixture-only mode limits *today's* blast radius to curated golden data, but this is the assembled production harness path and the invariant is load-bearing and unchecked.

### MEDIUM
- [Security] `packages/raxol_payments/lib/raxol/payments/xochi/agent_stream.ex:2820-2822` — `validate_base_url!/1` is a prefix match: `defp validate_base_url!("http://localhost" <> _)` and `"http://127.0.0.1" <> _`. `http://localhost.evil.com/...` and `http://127.0.0.1.evil.com/...` (or `http://127.0.0.1@evil.com`) all satisfy the guard, defeating the HTTPS-only control and sending the signed announce over plaintext to an attacker-controlled host. The signed payload deliberately omits the human wallet, so exposure is bounded, but a security guard that is trivially bypassable by a crafted hostname is a real defect. Anchor on exact host equality (`localhost`, `localhost:`, `127.0.0.1`, `127.0.0.1:`) instead of a bare prefix.
- [Saboteur] `agent_stream.ex:2573-2586` + `2732-2738` — `announce/2` runs `announce_sync -> build_req -> validate_base_url!` inside an unlinked `Task.start`. The moduledoc promises "Any failure -- config, signing, network, or rate limit -- is logged and dropped; it never propagates," and `announce_sync/2`'s `@spec` is `{:ok, 202} | {:error, term()}`. But a bad base_url makes `validate_base_url!` **raise** after `build_body` has already succeeded, so the `case announce_sync(...)` never matches — the Task dies with an unhandled crash report (noisy SASL), not the clean logged drop the contract states, and the spec is violated. Either return `{:error, :bad_base_url}` from the sync path, or wrap the Task body so config failures degrade to a `Logger` line.
- [New Hire] `surface.ex`, `keymap.ex`, `mode_select.ex`, `status_strip.ex` moduledocs/comments — saturated with private-roadmap jargon (`T13a`, `T2b/T2c`, `T7`, `D-PA (A)`, `AD-1`, `AD-U2`, `R10`, `R11`, `N06`, `SESSION LESSONS #4`, `harness-ui-STATE.md`) and AI meta-narration ("this is not a defect... worth naming honestly", "OPEN QUESTION for T13a"). None of it resolves without the unpublished in-flight docs, and it directly violates this repo's own recorded convention against dev jargon / meta-narration in comments. A new maintainer cannot follow the fold/seal invariants without the private lane state.

### LOW
- [Saboteur] `surface.ex:896-914` — `advance/2` calls `Projection.project(events_so_far, ...)` over a growing prefix on every step, plus repeated `length/1` over `events`/`projection.blocks` lists per call, giving O(n^2) replay cost. Fine for the small golden fixtures; degrades on a long session.
- [New Hire / Saboteur] `examples/harness_fixture_demo.exs:105,134` — the loop hard-intercepts `"q"` before `handle_input`, so the letter `q` can never be typed into the composer during the demo. Confusing dead key for anyone trying to compose.
- [Security] `agent_stream.ex:2577` — jitter uses non-crypto `:rand.uniform/1` and defaults to only 250 ms. The moduledoc sells jitter as a timing-correlation privacy defense; a 0-250 ms predictable-PRNG delay is negligible against network round-trips and is weak as a privacy control (acceptable as defense-in-depth, but do not oversell it).
- [New Hire] `status_strip.ex:499-508` and `view_text.ex:1394-1403` carry a near-identical `truncate`/`truncate_to_width` helper (ellipsis at `width-1`). Duplicated width logic is a drift risk; extract one.

### Cross-Persona Overlaps
- ViewText unsanitized-content-to-terminal was flagged independently by the Saboteur (row desync / pinned-region corruption from embedded newlines) and the Security Auditor (ESC-byte escape injection from untrusted tool/agent content). Promoted MEDIUM -> HIGH.

### Verdict: CONCERNS
One HIGH (promoted) plus three MEDIUM. Not a BLOCK — the HIGH is bounded to curated fixture data in the current fixture-only mode — but the ViewText sanitization gap should be closed before the live agent lane (T13b) feeds real tool output through this path, and the `validate_base_url!` prefix bypass + raise-in-Task contract break are quick, worthwhile fixes.

---

## PR #597 — payments: gate agent-stream announce host + topic format
State: CLOSED
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T13:26:49Z

Closing as superseded by the base branch `feat/wire-agent-stream-announce-578`.

Base already carries a more complete host-gate + topic-format implementation. Diffing this branch against the **current** base is `+43 / -177`: merging would tear out base's implementation and replace it with this earlier, smaller design — dropping the Mandate-binding trust boundary and `announce_stranded`, and renaming the config key (`:agent_stream_hosts` vs base's `:xochi_announce_hosts`) and reason atoms (`:bad_topic_id` vs `:invalid_topic_id`). The host-gate + topic-format goal of this PR is fully met on base.

Nothing is lost functionally. Reopen if the `:agent_stream_hosts` naming/config approach is worth revisiting on its own.

---

## PR #598 — raxol_payments: gate announce host + bind topic to Mandate (#3)
State: CLOSED
Drew entries: 1

### Round 1 — PR COMMENT — 2026-07-16T13:26:46Z

Closing as superseded by the base branch `feat/wire-agent-stream-announce-578`.

Diffing this branch against the **current** base (not the stale merge-base), the only net change here is `-29 / +0`: this branch is *missing* `announce_stranded/2`. The entire host-gate + topic-format + Mandate-binding implementation this PR proposes is already on base, byte-identical — base is effectively `this PR's lineage + #599's stranded-row`. Merging would regress base by deleting the `announce_stranded` feature (#599) and add nothing.

Nothing is lost: base is a strict superset of this branch. Reopen if I'm missing something.

---

## PR #604 — Harness UI: polarity-aware 16-color salience mapping (semantic roles survive degradation)
State: MERGED (merged 2026-07-16T21:27:26Z)
Drew entries: 1

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T19:41:48Z

## Adversarial Review (automated)

Reviewed `ansi16_salience.ex` (new, 220 LOC), the doc pointer in `colors.ex`, and the
test. Verified against `salience.ex` (`resolve_polarity/2` threshold), `salience_theme.ex`
(8 seeds), and the ANSI palette in `colors.ex:318`. The mapping design is genuinely sound
where it is tested (no cross-category collisions at any single prominence, polarity
threshold matches the solver at `ground < 0.5`). The findings below are what the tripwires
do NOT cover.

### HIGH
- **[Saboteur + New Hire] legibility is never asserted anywhere** `ansi16_salience.ex:216-219`, test whole file -- The module's entire purpose is "survive degradation *and stay legible*", yet no test asserts any contrast floor against the ground; the audit only checks gray-collapse and category. The polarity flip `chromatic_slot(:light, :soft, base) -> base + 8` (line 219) sends every receded chromatic role to a **bright** slot on a light canvas: soft `warning` -> slot 11 (bright yellow `#FFFF00`) and soft `success`/`diff_add` -> slot 10 (bright green `#00FF00`). On a near-white ground (`0.97`) bright-yellow-on-white is ~1.05:1 contrast -- effectively invisible, not merely "receded". `warning`'s own seed tier is `:differentiate` (`salience_theme.ex:29`), i.e. it naturally resolves to the soft tier, so on a light terminal a warning can render unreadable. Fix: add a contrast-ratio assertion (WCAG floor, e.g. >= 3:1) per role against the polarity's canonical ground, and clamp/re-pin the light-soft yellow/green slots that fail it.

### MEDIUM
- **[Saboteur] the module has zero callers -- the behavioral claim is not delivered** `ansi16_salience.ex:1` -- Nothing in `lib/` or `packages/` references `Ansi16Salience`; `find_closest_basic_color/1` is still the only live 16-color path (`colors.ex:425`, `convert_to_basic`). The PR title asserts "semantic roles survive degradation" but no render/capability-gate path consumes the table, so today they still don't. Additive scaffolding is fine as a seam, but the title/body over-claim relative to what is wired. Confirm a follow-up wires it, or soften the claim.
- **[Saboteur] undocumented neutral distinction-loss on dark @ receded** `ansi16_salience.ex:122-138` -- At soft tier on dark, `foreground` (8), `chrome` (8), `muted` (8) and `border` (8) all collapse to slot 8. The moduledoc only documents the `:muted`/`:border` fold as the "recede floor"; it never says `foreground` and `chrome` also merge into that floor when receded. The `@cross_category_collision_budget` test can't catch this (all `:neutral`), and the tier-separation test exempts only `:muted`/`:border`. So four distinct semantic roles become indistinguishable, silently. Either document this merge explicitly or move `foreground`/`chrome` soft off slot 8.

### LOW
- **[Security Auditor] the degradation path itself crashes on its own fallback input** `ansi16_salience.ex:154` -- `polarity/1` guards `is_number`, so a `nil` ground (the exact case the moduledoc names: "no OSC 11 detection") raises `FunctionClauseError` instead of defaulting to `reference_ground()`. Likewise `slot/3`/`category/1` raise on any role atom outside the closed set. Fail-loud on unknown roles is defensible (and correctly avoids `String.to_atom`), but a 16-color path is a *fallback*; crashing the harness when its background probe is unavailable is fragile. Add a `polarity(nil)` clause (or a documented caller contract enforced by a guard) that lands on `reference_ground()`.
- **[New Hire] "11 fields" vs 12 roles is unexplained** `ansi16_salience.ex:11` -- Docs and tests repeatedly say "8 of 11" / "11 harness-painted fields", but `roles/0` returns 12. `:running` is a role with no RGB seed, so it is excluded from the naive-collapse count -- correct, but never stated. A maintainer updating the table can't reconcile 11 vs 12 without reverse-engineering it. One sentence naming `:running` as the count-exempt reserved role fixes it.

### Cross-persona overlaps
- Saboteur and New Hire independently landed on legibility: illegible slots can ship (Saboteur) *because* no contrast/legibility floor is asserted (New Hire). Promoted to HIGH.

### Verdict: CONCERNS

The design is careful and the tripwires are real, but two gaps keep it short of CLEAN: the
mapping can emit invisible chromatic slots on light grounds with no test guarding contrast,
and the whole module is currently unwired so the headline behavior is not yet delivered.
Neither is a hard production break (nothing calls it yet), so not BLOCK.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #605 — Harness UI: shared seal-frontier classifier (one committability decision, every consumer)
State: MERGED (merged 2026-07-16T21:30:41Z)
Drew entries: 1

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T19:42:21Z

## Adversarial Review (automated)

Scope: `Raxol.Harness.SealFrontier` (new shared classifier) + its two live consumers in
`Raxol.Harness.Surface` (`paint_pending_blocks/1` via `commit_walk/5`, `pending_block/1` via
`frontier_scan/1`). Behavior-identity with the old inline arithmetic checks out: the detach
target and the committed range both map to the same indices the old `target`/`slice`
arithmetic produced, so nothing regresses functionally today. The issues below are a hot-path
scalability regression that contradicts the module's own stated design, plus two documented
"single source of truth" seams that are not actually wired and whose docs overstate coverage.

### HIGH
- **[Saboteur] HIGH** `lib/raxol/harness/seal_frontier.ex:292` and `:352` -- the walks are
  O(n^2), directly contradicting the moduledoc's own guarantee. Lines 129-134 claim the walks
  are "implemented over the suffix list carrying the absolute index along (to avoid `length/1`
  and `Enum.at/2` costing O(n) per step, which would make a full walk O(n^2))". The actual
  `scan_walk`/`commit_step` do the opposite: they keep the FULL `entries` list and re-index it
  with `Enum.at(entries, index)` every step -- O(index) on a linked list, so O(n^2) over a
  walk. This is on the hot path: `frontier_scan/1` runs from cursor 0 on every footer render
  (`surface.ex:1011`) and `paint_pending_blocks/1` runs a cursor-0 scan on every advance
  (`surface.ex:644`), while `model.projection.blocks` accumulates every completed block for the
  whole session. A long agent run degrades quadratically per frame. This is exactly the cliff
  the PR says it is avoiding, and the PR's own framing is "before live traffic." Fix: walk the
  suffix by pattern-matching `[entry | rest]` and carrying the absolute index as a counter (as
  the docstring already describes), never `Enum.at` the full list; `classify/3` similarly should
  not `length/1` + `Enum.at/2` the whole list per call.

- **[Saboteur + Security] HIGH (promoted)** `lib/raxol/harness/surface.ex:610` vs
  `seal_frontier.ex:64-77` -- the pending-input gate's only real feed does not implement the
  semantics the gate documents. The moduledoc motivates step 1 with "an entry awaiting a user
  answer (e.g. a permission prompt) ... committing it now (print-once) would freeze the
  'waiting' form forever" and makes the check unconditional precisely for that case. But the
  sole producer sets `pending_input?: not reveal_finished? and index == total - 1` -- purely the
  newest-block-during-reveal window, with no relationship to any block actually awaiting input.
  A real `:approval`/permission block that is not the newest entry, or any pending block once
  the reveal finishes, gets `pending_input? = false` and seals into print-once scrollback while
  still live -- the exact failure the gate exists to prevent (frozen "waiting" form / a
  human-facing prompt committed mid-question). Dormant today (no approval/permission producer
  emits these yet), but the classifier ships the gate with a feed that cannot honor its
  contract. Fix: derive `pending_input?` from the block's actual awaiting-input lifecycle, or
  explicitly scope approval/permission blocks out of frontier eligibility until that feed
  exists, and stop using the reveal window as a proxy for "awaiting the human."

### MEDIUM
- **[New Hire + Security] MEDIUM** `lib/raxol/harness/seal_frontier.ex:435-438` and `:250` --
  two APIs documented as the canonical single place are unwired dead code, with docs that
  overstate their status. (1) `seal_display_mode/1` is called only by tests; no seal-path code
  (`seal_block/2`, `render_block_lines/3`, `BlockBody`) consults it, yet the moduledoc says the
  per-kind fidelity policy "lives here, in one place." Its `:tool_call -> :truncated` rule is
  the only documented bound on tool output reaching permanent scrollback, and it is never
  applied -- unbounded, tool-controlled content (which can carry raw ANSI/control sequences) is
  committed verbatim. (2) `classify/3` has ZERO callers and ZERO test coverage, yet the
  moduledoc calls it "the public single-step primitive" and claims (line 134) its equivalence to
  the walks "is covered by the scan/walk-agreement property test" -- the property test
  (`seal_frontier_test.exs:992`) never calls `classify/3`; it only ties `scan_frontier`<->
  `commit_walk`. So `classify/3` is a third, independent copy of the committability step order
  whose asserted test coverage does not exist, free to drift from the walks undetected. A new
  hire trusting these docs would wire a consumer to the "canonical, tested" primitive and get an
  untested path. Fix: either wire them for real (have `seal_block` consult `seal_display_mode`;
  route the walks through `classify/3`, or add a direct `classify/3` equivalence property) or
  delete them and correct the moduledoc's "one place" / "covered by the property test" claims.

### LOW
- **[New Hire] LOW** `lib/raxol/harness/seal_frontier.ex:232` -- `committable?(entry,
  turn_running?, is_last?)` takes two adjacent positional booleans with no compile-time
  protection; transposing them silently miscomputes the frontier. The wrapper naming also
  invites confusion: `Surface.frontier_scan/1` vs `SealFrontier.scan_frontier/3` are
  near-homographs for wrapper-vs-impl. Consider a keyword/struct for the flags and a distinct
  wrapper name.

### Cross-persona overlaps
- The `pending_input?` feed gap is raised by both Saboteur (mis-seal / frontier correctness) and
  Security (a block awaiting the human sealed into print-once history); same root cause ->
  promoted to HIGH above.
- The unwired-policy finding is shared by New Hire (dead code + false single-source docs) and
  Security (the only tool-output truncation bound is never applied); consolidated into one
  MEDIUM.

### Verdict: CONCERNS

Nothing here breaks correctness for today's traffic (running flags always false, no
approval/background-task producer, behavior-identical to the prior arithmetic). But the module's
central design claim -- avoiding an O(n^2) walk -- is factually violated on a per-frame hot path
that grows unboundedly over a session, and two of the classifier's documented "one place"
policies (`classify/3`, `seal_display_mode/1`) are unwired with docs that overstate their
coverage/authority. Given the PR's explicit "before live traffic" goal, fix the O(n^2) walk and
reconcile the docs before merge.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #606 — Harness UI: streaming render cadence layer (input-first backpressure for live sessions)
State: MERGED (merged 2026-07-16T21:31:47Z)
Drew entries: 2

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T19:40:32Z

## Adversarial Review (automated)

Reviewed `lib/raxol/harness/cadence_policy.ex` (pure policy) and `lib/raxol/harness/stream_cadence.ex` (GenServer). The pure policy is clean, well-tested, and deterministic. The GenServer is where the risk lives: for a layer sold as "backpressure," it applies none toward the producer and caps nothing.

### HIGH

- **[Saboteur + Security Auditor] HIGH** `stream_cadence.ex:84` (`ingest/2` cast) + `handle_manager_cast({:ingest, delta}, ...)` + moduledoc section 4 -- **Unbounded pending queue / mailbox, no backpressure despite the name.** `ingest/2` is a fire-and-forget `GenServer.cast` that by design "never blocks the producer," and the internal `:queue` (`pending` / `pending_count`) has no cap anywhere in the diff. Egress is ceiling-bounded at ~2,000 deltas/sec (32 per 16ms); ingress is unbounded. The moduledoc's own section 4 poses "what happens when the consumer stalls" and section 2 admits "this server has no timeout protection against a slow sink" -- but neither path bounds `pending`. If ingest rate exceeds the egress ceiling, or the owner/sink stalls (slow paint, blocked owner mailbox), the queue and the process heap grow without bound -> OOM. This is the security DoS surface too: a hostile or compromised token source (the LLM endpoint the harness streams from) floods `ingest` casts and exhausts memory. "Input-first backpressure" is a misnomer -- there is no backpressure. Fix: add a `:max_pending` bound with an explicit overflow policy (block via `call`-based ingest above the watermark, or drop-oldest with a telemetry event + a documented loss guarantee that then contradicts the "no delta ever dropped" claim in section 3 -- pick one and state it). At minimum emit telemetry and cap heap.

### MEDIUM

- **[Saboteur] MEDIUM** `stream_cadence.ex` `decide_and_act/1` `:yield_to_input -> schedule_flush(state, state.input_yield_retry_ms)` (1ms) -- **Render starvation + 1ms busy-repoll under persistent input-pending.** When `input_check.()` stays true (continuous typing, or a buggy/hostile owner whose input gate never clears), every decision returns `:yield_to_input` and reschedules a 1ms `:flush_due`. There is no maximum-yield bound and no "flush at least once per N ms regardless of input." Consequences: (a) visible output freezes indefinitely while `pending` grows (compounds the HIGH above), and (b) a ~1000 wakeups/sec poll loop burns CPU for as long as input is pending. The policy guarantees "input waits at most one bounded batch"; the inverse -- render waiting on input -- is unbounded. Fix: bound consecutive yields (force a flush after K yields or T ms) so rendering makes forward progress and the poll loop terminates.

- **[New Hire] MEDIUM** `stream_cadence.ex` moduledoc section 5 ("Not wired yet") + `init_manager` default `input_check = fn -> false end` -- **The headline "input-first" guarantee is aspirational and unenforced.** Section 2 states input priority is "the owner's responsibility" via selective receive, and section 5 admits the owning live-session loop "does not exist yet." The only in-module mechanism (`:input_check`) defaults to always-false, so out of the box the "belt-and-suspenders" source-side hold is OFF and the module provides zero input prioritization. A maintainer wiring this up has no compile-time or runtime guardrail that the contract is honored -- the PR title's central promise ("input always ahead of paint") rests entirely on a consumer that isn't in this diff. Fix: either land a minimal owner/reference consumer that exercises the contract, or make the doc state plainly that this module provides no input priority on its own and the `input_check` seam is mandatory (not optional) for the advertised behavior.

### LOW

- **[New Hire] LOW** `stream_cadence.ex` `flush_one_batch/2` vs `full_drain_loop/2` -- Near-identical drain bodies (`drain_count` -> `:queue.split` -> `to_list` -> `sink` -> update `pending`/`pending_count`/`last_flush_ms`) duplicated across the cadence path and the forced-drain path. Two copies of the money logic drift apart under maintenance (e.g. a future bound/telemetry added to one and not the other). Fix: extract a single `drain_one_batch/2`.

- **[New Hire] LOW** `cadence_policy.ex:@input_yield_retry_ms 1` / moduledoc -- The 2,000 deltas/sec ceiling is derived in prose, but the 1ms recheck constant ships without noting its cost (a ~1kHz timer loop while yielding, per the MEDIUM above). Document the CPU implication next to the constant.

### Cross-persona overlaps

- The unbounded-queue / no-backpressure finding was reached independently by the Saboteur (production OOM under stall or ingress > egress) and the Security Auditor (DoS via token-source flood, no resource limit). Same root cause -> promoted MEDIUM to **HIGH**.
- The Saboteur's render-starvation finding and the Security Auditor's input-flood angle share the `:yield_to_input` mechanism; they compound the HIGH (starvation keeps the unbounded queue growing) but are reported once as MEDIUM.

### Verdict: CONCERNS

The pure `CadencePolicy` is solid and the ordering/no-loss tests are genuine. But a module whose stated purpose is "backpressure" ships with an unbounded internal queue, an unbounded ingest cast, no consumer-stall protection, and an unbounded render-yield loop -- the one property it is named for is the one it does not provide. Not a merge-blocker for standalone/unwired code, but the queue bound and the yield bound must land before this is wired to a live session.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-16T21:37:00Z

## Adversarial Re-review (automated)

Since last review: cb59fb82..53bf559b

Single new commit `53bf559b` ("Bound the stream cadence layer: overflow shedding, yield budget, honest contract"). Re-read `cadence_policy.ex`, `stream_cadence.ex`, and both test files at the new head.

### Resolved since last review

- **HIGH (unbounded pending queue -> OOM/DoS) -- RESOLVED for retained state.** `shed_overflow/1` now runs on every ingest (`stream_cadence.ex:200`) and drops from the OLDEST end via `CadencePolicy.drop_count/2` (`cadence_policy.ex:200-201`, `max(pending_count - max_pending, 0)`). After each cast the in-state `:queue` is pinned at exactly `:max_pending` (default 10_000). Loss is observable twice: a `[:raxol, :harness, :stream_cadence, :overflow]` telemetry event at drop time and an in-band `{:cadence_dropped, n}` marker on the next batch. Off-by-one check: at `pending == max_pending` `drop_count` returns 0, at `max_pending + 1` returns 1 -> watermark inclusive, no fencepost error. Tested (`stream_cadence_test.exs` overflow describe block). The moduledoc no longer claims backpressure it does not provide -- it explicitly says "load-shedding, not backpressure" (`stream_cadence.ex:18,129`). The dishonest "no timeout protection" framing is replaced by a stated shed-on-overflow contract (section 3).
- **MEDIUM (1ms yield repoll starves renders indefinitely) -- RESOLVED.** `@max_consecutive_yields 16` (`cadence_policy.ex:66`) caps consecutive `:yield_to_input` verdicts; once `yields_since_flush >= max_yields` the `cond` falls through to the cadence rules (`decide/5`, `cadence_policy.ex:150-152`). Confirmed forward progress: `drain_one_batch` resets `yields_since_flush` to 0 per flush, so permanent input yields ~16x1ms then forces one bounded flush, repeating -- throttled, never starved. Tested ("forced progress under permanent input").

### MEDIUM

- **Security Auditor -- the DoS is narrowed, not closed: the bound is on retained queue state, the mailbox ingress is still unbounded.** `ingest/2` remains a fire-and-forget `GenServer.cast` (`stream_cadence.ex:132-134`), and shedding happens only *after* a `{:ingest, delta}` cast is dequeued and processed (`handle_manager_cast`, `stream_cadence.ex:195-200`). A producer that casts faster than the server drains its mailbox grows the process mailbox without bound -> heap OOM, exactly the failure `:max_pending` is advertised to prevent. The moduledoc asserts "The pending queue is therefore always bounded" (`stream_cadence.ex:89`) -- true, but the *process* is not: the unbounded buffer moved from the `:queue` to the mailbox. For the intended SSE producer this is network-rate-limited and low-risk, but the "always bounded" claim overstates what is actually guaranteed.
- **Security Auditor -- `:max_pending` bounds item COUNT, not bytes.** `delta` is `term()` (`stream_cadence.ex:132`) and the watermark counts elements, not payload size. 10_000 retained deltas x an adversarially large per-delta binary (a hostile/buggy endpoint streaming a multi-MB "token") is unbounded heap under a count-based cap. Same root as above (the bound guards the wrong quantity); two findings, same root -> the residual DoS surface is real even though narrowed. Not exploitable via the current real producer, so MEDIUM not HIGH.

### LOW

- **Saboteur -- drop-oldest is correct for a snapshot sink but corrupts an append-only token stream.** The shed justification is "the queue head is history, the queue tail is the live view" (`cadence_policy.ex:185`, `stream_cadence.ex:263`). That holds for a footer/state repaint where only the latest snapshot matters. But section 1 describes the consumer as "apply deltas to the live tail" -- LLM text deltas are *additive*, not snapshots. Dropping the oldest un-rendered deltas leaves a permanent gap in the middle of the rendered transcript; there is no "latest full state" to catch up to. The `{:cadence_dropped, n}` marker makes the loss observable (good, and the crash-on-naive-join is deliberate), but the transcript is still torn, not merely "trimmed to the live tail". The moduledoc conflates the snapshot model (where drop-oldest is lossless-of-meaning) with the append model (where it is content-corrupting-with-a-flag). Worth stating the semantic explicitly so the future owner picks the sink type knowingly.
- **New Hire -- the input-first guarantee is now honestly documented but still unwired end-to-end.** Section 2 concedes "Out of the box this module enforces NO input priority" (`stream_cadence.ex:34-37`, default `input_check` returns `false`) and section 5 concedes the owning live-session loop "does not exist yet". The prior "aspirational guarantee" finding is thus addressed by *honesty*, not by *enforcement*: the yield mechanism exists and is tested, but no real caller exercises the source-side hold or the mandatory selective-receive half. Credit for the candor; the guarantee remains unproven against a real owner. Magic numbers (16/32/1/10_000/16) are all now documented with rationale (`cadence_policy.ex:40-66`) -- that half of "honest contract" is genuinely delivered.
- **New Hire -- batch-size contract has a sharp edge.** Section 3 first states "Each batch carries at most `max_drain_per_flush` deltas" then later "at most `max_drain_per_flush + 1` elements" when a marker rides along. A consumer that reads the first sentence and asserts `length(batch) <= 32` breaks on the first loss (the `marker prepends without displacing a delta` test proves a 33-element batch). Documented, but the two statements are 20 lines apart; lead with the +1.

### Verdict: CONCERNS

The promoted HIGH (unbounded pending queue) is genuinely resolved for retained state, both prior MEDIUMs are addressed (yield starvation fully; input-first honestly documented), and the contract doc no longer claims backpressure it does not provide. Remaining items are residual and non-blocking for a not-yet-wired standalone module: the ingress DoS is narrowed but not eliminated (unbounded mailbox + count-not-bytes cap), and drop-oldest on an append-only token stream is a semantic the moduledoc should name outright. Fix the "always bounded" overstatement and the drop-oldest/append semantics before the live-session owner wires this in.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #607 — Harness UI: wire message bodies through the streaming-safe markdown path
State: MERGED (merged 2026-07-16T21:31:13Z)
Drew entries: 2

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T19:40:59Z

## Adversarial Review (automated)

Scope: the diff wires `BlockBody -> BodyProvider.mount(seal:) -> MessageBlock -> MarkdownBody`, and
adds a fenced-code language label to the shared `MarkdownRenderer` (plus a reversed-accumulator fix).
The streaming-safe machinery in `MarkdownBody` itself (provisional close, control/ESC sanitization,
never-raise, UTF-8 recovery) is pre-existing (#563) and is correctly reused here.

### HIGH
- **[Security + Saboteur] HIGH** `lib/raxol/ui/components/markdown_renderer.ex:299-306` (builtin), `:238` (AST `pre`), helper `:276-283` -- the fence info string, which this PR previously *discarded* (`"```" <> _`), is now rendered as a `text()` label via `lang_word/1`. `MarkdownRenderer` does not sanitize its input: it relies on callers. The message path is safe because `MarkdownBody.to_text/1` strips C0/C1/DEL/ESC *before* the parse -- but `MarkdownRenderer` is a shared component with direct, un-sanitized callers today: `lib/raxol/playground/demo_helpers.ex:76-83` calls `MarkdownRenderer.init/render` with raw content. `lang_word/1` splits on `~r/\s+/`, and ESC (`0x1B`) is not whitespace, so a fence like ` ```elixir<ESC>[2J ` yields the label `elixir<ESC>[2J`, smuggling a raw escape sequence into `text()` for any non-`MarkdownBody` caller -- exactly the "never embed raw ANSI in text()" boundary this codebase enforces. Saboteur angle on the same root: `lang_word/1` takes the entire first non-whitespace run with no length bound, and `MarkdownRenderer` has no byte cap of its own (only `MarkdownBody` caps at 256KB), so a fence with a megabyte-long no-whitespace info string renders one unbounded dim label line for direct callers. Two personas, one root -> promoted. Fix: sanitize control/ESC bytes and clamp length inside `lang_word/1` (or `code_label_elements/1`) so the new label surface is safe regardless of caller, since `MarkdownRenderer`'s contract is "callers may pass untrusted text."

### MEDIUM
- **[New Hire] MEDIUM** `lib/raxol/ui/components/harness/body_provider.ex:108`, `message_block.ex:167`, `block.ex:610-611` -- the same binary distinction carries two names: block-level `seal` is `:live | :sealed`, but `MessageBlock`'s render `mode` is `:streaming | :sealed`, glued by `if(seal == :live, do: :streaming, else: :sealed)`. `:sealed` is shared across both vocabularies while the "not sealed" state is `:live` in one place and `:streaming` in another, and the mapping is duplicated (BodyProvider and Block both re-derive it). A maintainer must hold "`:live` == `:streaming`" in their head. It is documented, but the split is a standing trip-hazard. Suggest a single named helper (e.g. `mode_for_seal/1`) reused by both call sites, or aligning the vocabulary.

### LOW
- **[Saboteur] LOW** `lib/raxol/ui/components/harness/markdown_body.ex:121-129` -- the stable-prefix optimization is deferred, so every render frame re-parses the *entire* accumulated body for every live block (the 256KB cap is the only ceiling). `MessageBlock` already re-parsed per frame, so this is not new cost, but routing live blocks additionally through `provisional_close/1` per frame widens it. With many concurrent live blocks in a transcript this is O(blocks x buffer) per frame. Fine for demos; worth the follow-up (or a concurrent-live-block ceiling) before sustained high-throughput streams.
- **[New Hire] LOW** `lib/raxol/ui/components/markdown_renderer.ex:259-268` -- `code_language_from_attrs/1` is `@doc false` yet `def` (public) solely so the test can call it; and `code_label_elements("")` at `:352` is dead, since `lang_word/1`'s `String.split(..., trim: true)` can never return `""` (it returns `nil` for absent tags). Harmless but adds noise to a "streaming-safe contract" a new hire is trying to learn.
- **[Security] LOW** PR body claims "Defaults are `:sealed` everywhere -- existing callers see zero change." Not strictly true: `MessageBlock.render` moved from a raw `MarkdownRenderer.init/render` to `MarkdownBody.render(mode: :sealed)`, which now runs `to_text/1` (control/ESC strip + UTF-8 recovery). For control-char-bearing content the sealed output is no longer byte-identical to pre-PR. This is a net security improvement, but the "zero change" claim is inaccurate and could mask a real behavioral diff for a downstream snapshot test.

### Cross-persona overlaps
- The fenced-code **info-string label surface** (`markdown_renderer.ex:299-306`, `lang_word/1`) is flagged independently by Security (ESC smuggling for direct callers) and Saboteur (unbounded label length, no cap in `MarkdownRenderer`). Promoted to HIGH.

### Verdict: CONCERNS

The reversed-accumulator fix is correct (verified: `fenced_code_elements/2` returns reading order; the builtin path reverses it, the AST path uses it directly -- consistent) and well-pinned. The message streaming wire-up is sound and the primary untrusted path (`MessageBlock -> MarkdownBody`) is sanitized. Not a BLOCK because the HIGH is a defense-in-depth gap on a shared component rather than an active break on the path this PR ships. But the new label surface should sanitize/clamp at the `MarkdownRenderer` boundary before merge, since that module's own contract is "callers may pass untrusted text," and it already has one un-sanitized direct consumer.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-16T21:39:54Z

## Adversarial Re-review (automated)

Since last review: afd87f2c..139a5b5b

### Resolved since last review

- **[HIGH] Fence-language label ESC smuggling -- RESOLVED.** The label is now sanitized at the renderer's OWN boundary, so every caller (including the un-sanitized playground path `DemoHelpers.markdown/2`, `demo_helpers.ex:76-83`) is covered, not just `MarkdownBody`. `lang_word/1` (`markdown_renderer.ex:341-350`) strips controls BEFORE word extraction: `String.replace(~r/[\x00-\x1F\x7F\x{0080}-\x{009F}]/u, "")` (`:332,344`). Verified end-to-end: `"elixir\e[31m"` -> `"elixir[31m"` (ESC gone); the full C0 range, DEL 0x7F, backspace, CR, tab, and the proper-UTF-8 C1 CSI (U+009B = `<<0xC2,0x9B>>`) all strip. Both entry points are covered -- the builtin `parse_blocks` clauses (`:377,383`) and the Earmark AST attr path `code_language_from_attrs/1` (`:315`). The label is length-bounded via `TextLayout.truncate(lang, 32, :ellipsis)` (`:354`), which clips on grapheme/display-width boundaries (`split_at_display_width`), so the Saboteur "cap splits a multibyte char" and "no length bound" concerns are both closed.
- **[MEDIUM] `:live`/`:streaming`/`:sealed` vocabulary drift -- RESOLVED.** Single bridge `MarkdownBody.mode_for_seal/1` (`markdown_body.ex`), now the only mapping used by both `BodyProvider` and `Block` (`block.ex:614`).

### Medium

- **[Saboteur] The new sanitizer itself CRASHES on invalid UTF-8, on the exact untrusted caller the fix was written for.** `lang_word/1` calls `String.replace/3` with a `/u` regex (`markdown_renderer.ex:344`). A `/u` (PCRE-unicode) match over a binary containing an invalid byte raises `ArgumentError`. Reproduced: a fence info string `<<0x9B, "31m">>` (a lone 8-bit C1 CSI byte, invalid UTF-8) raises `ArgumentError` from `lang_word`. There is NO rescue in `MarkdownRenderer.render/2` (`:81-95`) nor in `DemoHelpers.markdown/2` (`demo_helpers.ex:76-83`), so on the playground path this is an unhandled crash. This is a NEW crash path introduced by this commit: before the PR the fence info string was discarded (`"```" <> _`) and never processed, so malformed bytes there were inert. The module's own contract is "callers may pass untrusted text" -- untrusted text can contain invalid UTF-8. The harness path is safe only because `MarkdownBody.render_to_text` runs `ensure_valid_utf8/1` (`markdown_body.ex:196`) upstream; the direct caller the trust note cites has no such recovery. Fix options: run `lang_word`'s replace on a validity-checked/scrubbed binary (reuse `ensure_valid_utf8`), or use a byte-class regex without `/u`, or wrap the label derivation in a rescue.

- **[Security Auditor] Same boundary, sibling surface left raw: the code BODY is not sanitized.** The fix sanitizes the label line but the code-body lines produced one function over -- `fenced_code_elements/2` maps each line to `Components.text(content: "  " <> line, style: @code_style)` (`markdown_renderer.ex:647-652`) with NO control/ESC stripping. So an ESC byte inside a fenced code body still reaches `text()` on the identical un-sanitized `DemoHelpers.markdown/2` path the label fix targets. This is pre-existing behavior, but the PR's new moduledoc trust note ("a new output surface ... inherits the component's OWN trust contract ... so the label is control/ESC-sanitized here, at the boundary that produces it, regardless of which caller supplied the input") now reads as applying to the whole fenced block while in fact it protects only the label. Same root as the Saboteur finding -- boundary sanitization is applied narrowly (label only, valid-UTF-8 only) rather than to the surface the trust note describes. Two findings, one root -> promoted to Medium.

### Low

- **[New Hire] Two independently-maintained control-char regexes with divergent ranges and no shared source of truth.** `markdown_renderer.ex:332` uses `~r/[\x00-\x1F\x7F\x{0080}-\x{009F}]/u` (strips ALL C0 incl. tab/LF/CR); `markdown_body.ex:264` uses `~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{0080}-\x{009F}]/u` (deliberately PRESERVES tab 0x09 / CR 0x0D for body prose). The divergence is defensible per-surface, but the boundary contract lives in moduledoc prose while the enforcement is duplicated in two modules. There is no shared `text()`/ViewText sanitizer helper the two derive from, so a future "newly-dangerous codepoint" fix must be remembered in both places. Consider extracting one canonical `sanitize_controls/1` (with a `preserve_whitespace?` flag) so the two surfaces can't drift.

### Verdict: CONCERNS

The specific HIGH (ESC in fence label reaching `text()` for the un-sanitized caller) is genuinely resolved at the correct boundary, with a bounded, grapheme-safe cap and red-first tests -- clean content renders identically. But the fix's own sanitizer introduces an unhandled `ArgumentError` on invalid-UTF-8 info strings on that same un-sanitized caller, and the sibling code-body surface at the same boundary is still raw, so the "sanitized at the boundary regardless of caller" claim is not yet fully true. Neither is a leak of a live escape sequence for well-formed input, so this is CONCERNS, not BLOCK.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #608 — Harness UI: byte-golden snapshots per degradation tier
State: MERGED (merged 2026-07-16T22:36:14Z)
Drew entries: 4

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T19:40:19Z

## Adversarial Review (automated)

Reviewed the full diff (789 additions: `Golden`, `GoldenDiff`, the bless mix task, 6 golden blobs, 2 test files, `.gitattributes`) against the assembled `Raxol.Harness.Surface` (`new/2`, `advance/2`) it drives. The determinism argument (explicit `mode:`, `env: %{}`, `capabilities: nil`, fixed geometry, `now` never passed) holds up against the source. Findings below are the gaps.

### MEDIUM
- **[Saboteur] `lib/raxol/harness/surface/golden.ex:287`** -- `drive_to_completion/1` is unbounded recursion with no iteration cap and no timeout. Termination depends entirely on `Surface.advance/2` converging (`revealed >= len(events) and painted_count >= len(blocks)`). That holds for today's fixed fixtures, but this is a golden *generator*: a future `Surface`/`Projection` change or a malformed fixture where `painted_count` never catches `blocks` turns every `render/2` call into a silent hang -- CI and `mix ...bless` block with no diagnostic. Add a cap derived from event count (e.g. `2 * length(events) + footer_rows`) and raise loudly on overflow instead of spinning.
- **[Security + New Hire, promoted] `.gitattributes:12` + `lib/raxol/harness/surface/golden.ex:369`** -- The PR's thesis is "a *reviewable* byte-golden," but `test/fixtures/harness/goldens/*.golden binary` makes every golden show as "Binary files differ" in `git diff`/PR review, and the non-check bless path (`compare_or_write(_, _, false)`) prints the same `bless <name> -> <path>` line whether it *created* a new golden or *silently clobbered a drifted one*. Together the two mechanisms that are supposed to catch an unintended rendering regression -- reviewer eyeballs on the diff, and a signal from the bless tool -- are both defeated. A dev who accidentally blesses a regression gets no louder signal than a fresh checkout, and the reviewer can't see the byte delta. At minimum: have bless distinguish `create` vs `overwrite (was N bytes, now M)`, and/or keep a textual, `inspect`-escaped sidecar so the escape-stream delta is reviewable.

### LOW
- **[Saboteur] `lib/raxol/harness/surface/golden.ex:190-201`** -- Determinism moduledoc claims the single-VM "render twice" tripwire "catches iteration-order ... nondeterminism within a single VM run." It cannot: identical maps iterate identically within one VM, and OTP map iteration order is a deterministic function of the keys (sorted for <=32 entries, fixed-hash HAMT above) and is platform-stable -- so neither the single-run pin nor the cross-machine golden actually exercises the map-ordering class the doc credits them with. The tripwire *does* catch unseeded randomness / process-dictionary / clock leakage; just fix the map-ordering claim so a maintainer doesn't over-trust a guard that doesn't cover that case.
- **[New Hire] `lib/raxol/harness/surface/golden.ex:369-377`** -- The `_missing_or_stale ->` catch-all also swallows genuine `File.read` failures (EACCES, EISDIR) and treats them as "absent," then unconditionally `File.write!`. A real IO error is masked as a normal bless write. Match `{:error, :enoent}` (and `{:ok, ^rendered}` / `{:ok, _stale}`) explicitly and let other errors surface.
- **[Security] `test/harness/golden_snapshot_test.exs:798-812`** -- The inline/tmux semantic guards only forbid `\e[2J`/`\e[3J`; the goldens are otherwise unconstrained control-byte blobs marked non-diffable. A tampered/poisoned fixture emitting OSC 52 (clipboard write) or OSC 8 (hyperlink) would pass every guard and be invisible in review. Consider asserting the golden's sequence set against an allowlist of the CSI/SGR types this surface is actually expected to emit (via `SequenceScanner`) rather than only blocklisting full-clear.
- **[Saboteur] `lib/raxol/harness/surface/golden.ex:269`** -- `StringIO.open("")` device is never `StringIO.close/1`d, leaking a StringIO process per render for the caller's lifetime. Harmless in ExUnit (per-test process exit reaps it) and it matches the existing `t3_degradation_ladder_test.exs` precedent, but the bless task drives the whole matrix + per-drift re-renders in one long-lived process; close the device after `StringIO.contents/1`.

### Cross-persona overlaps
- `*.golden binary` (Security: defeats review surface) and the silent bless overwrite (New Hire: no create-vs-clobber signal) are the same root weakness -- the regression-catching net the PR is built to provide has two independent holes that compound. Promoted LOW -> MEDIUM.

### Verdict: CONCERNS

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-16T21:37:53Z

## Adversarial Re-review (automated)

Since last review: 9694d013..a41e12b8

Scope: `e78e1037` (harden bless flow) + `a41e12b8` (strip ContentGuard `[K` residue). Re-verified all four prior findings and reviewed the new residue fix through the Saboteur / New Hire / Security Auditor personas.

### Resolved since last review

- **MEDIUM (binary gitattribute defeats review) -- RESOLVED.** The `.golden` files stay `binary` by design (justified: `\r\n` are sealed-line protocol bytes, eol-normalizing them corrupts the golden), but every golden now gets a reviewable, `inspect/1`-escaped `.golden.txt` sidecar pinned `text eol=lf`. Verified with `git check-attr -a`: `simple-chat.inline_log.golden` -> `binary: set / diff: unset`; `.golden.txt` -> `text: set / eol: lf`. The `*.golden` pattern provably does not also capture `*.golden.txt`. The PR-diff review surface is restored (`.gitattributes`; `golden.ex` `escape_lines/1` + `write_sidecar!/2`; sidecar staleness is `:drift` in `--check` at `golden.ex` `check_sidecar/2`).
- **MEDIUM (bless create-vs-clobber emits identical output) -- RESOLVED.** `:written` is split into `:created` and `:overwritten` (`golden.ex` `bless_pair/2`); the task prints `bless (new)` vs `bless (overwrote) ... (was N bytes, now M bytes)` followed by the `GoldenDiff` report (`raxol.harness.goldens.bless.ex` `report/1`). A silent regression-bless is no longer possible. Demonstrated live by `a41e12b8` itself (reported offset 664, 866 -> 862 bytes).
- **MEDIUM (unbounded `drive_to_completion`) -- RESOLVED.** Now step-budgeted: `max_steps/1 = 2 * event_count + 32`, and `drive_step/4` raises a named `RuntimeError` on non-convergence instead of hanging (`golden.ex`). Covered by `test/harness/golden_snapshot_test.exs` "bounded drive_to_completion" (raise path, convergence-within-budget, and `max_steps/1` arithmetic all asserted).
- **LOW (moduledoc mis-credits the double-render tripwire) -- RESOLVED.** Determinism-audit point 5 (`golden.ex`) now attributes map-iteration determinism to the runtime's own key-stable layout and credits the double-render test only with what it structurally can catch: unseeded randomness, process-dictionary / `persistent_term` leakage, and clock leakage within one VM.

### MEDIUM (new -- test-only, non-blocking; three personas converge)

**`escless_residue/1` is a two-sided heuristic that both under- and over-matches the residue class it advertises** (`test/harness/golden_snapshot_test.exs`, regex `@escless_residue ~r/\[(?:\d{1,3}(?:;\d{1,3})*[A-Za-z]|[A-HJKST])/`). The `[K` fix itself is correct -- dropping the embedded EL from `Surface.seal_block/2` is right, and Security Auditor confirms it drops nothing that mattered (the EL's ESC was already neutralized by `ContentGuard.sanitize_line/1`, `content_guard.ex:88-96,104-106`, so it never functioned as an erase on a real terminal; `\r\n` per-line boundaries are preserved, so no sealed lines merge). The problem is the *guard* written to pin it:

- **Saboteur -- false negatives on the exact siblings of `[K`.** The empty-param branch `[A-HJKST]` catches paramless `[K`/`[J`/`[H` but MISSES the paramless line/char editors most likely to be wrongly embedded next to an EL. Verified against the live regex: `[P` (DCH), `[L` (IL), `[M` (DL), `[I`, `[N`, `[O`, `[Q`, `[X`, `[@` all -> MISSED. A future seal path that embeds `\e[P`/`\e[L`/`\e[M` produces `[P`/`[L`/`[M` residue that this "catch the ContentGuard-stripped `[K` class" guard sails straight past.
- **Security Auditor / New Hire -- false positives on ordinary uppercase bracket labels.** The comment claims the branch is "deliberately uppercase-only so the fixtures' legitimate lowercase bracket labels never false-positive" -- but that protects only *lowercase*. Verified flagged as residue: `[ERROR]`, `[DONE]`, `[FAIL]`, `[KEY]`, `[SKIP]`, `[TODO]`, `[BUILD]`, `[HELP]`, `[Kernel panic]`. All are plausible LLM/agent output. The current fixtures contain only `[assistant]` (grep of the sidecars confirms it, so the guard is green today), but the first fixture line carrying an uppercase bracket label will fail the residue guard as a false positive and block a legitimate `bless`.

Root cause (shared): a fixed letter-set regex cannot distinguish "ESC-stripped CSI residue" from "bracket label" in already-tokenized, ESC-free text -- `[K` as EL-residue and `[K` as the start of `[KEY]` are byte-identical post-strip. The honest containment is upstream (`ContentGuard` neutralizing at content ingress, which is intact), so this is defense-in-depth on a tripwire, not a production hole -- hence non-blocking. Suggest either (a) narrow to residue that is unambiguous (require a params run: `[` + digits + final, dropping the empty-param branch entirely, accepting that a paramless stripped final is indistinguishable from a label and is better caught at the `ContentGuard`/seal seam), or (b) at minimum document that the empty-param branch trades false negatives on `[L]`/`[M]`/`[P]` for false positives on uppercase labels, so a future re-blesser understands why a `[ERROR]` line trips it.

### Verdict: CONCERNS

All four prior findings are resolved with evidence, and the core `[K` fix is sound. The single new concern is a fragile, two-sided test guard (false negatives on `[L]`/`[M]`/`[P]` residue, false positives on common uppercase labels) -- test-only and non-blocking, but it undercuts the very tripwire the fix commit was written red-first to establish.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 3 — REVIEW | review_state=COMMENTED — 2026-07-16T22:04:23Z

## Adversarial Re-review (automated)

Since last review: a41e12b8..be42e7bd

One new commit (`be42e7bd`, test-only, `test/harness/golden_snapshot_test.exs`) narrows the red-first ESC-less residue guard from the two-sided heuristic `~r/\[(?:\d{1,3}(?:;\d{1,3})*[A-Za-z]|[A-HJKST])/` to the parameterized-only form `~r/\[\d{1,3}(?:;\d{1,3})*[A-Za-z]/`, dropping the empty-param branch and documenting the paramless class as owned upstream by the ContentGuard/seal seam.

### Resolved since last review

- **False-positive on common uppercase labels (MEDIUM, one of two sides) -- RESOLVED (reproduced).** I re-ran the exact new regex against the labels my prior finding named. All pass clean now: `[ERROR]`, `[DONE]`, `[FAIL]`, `[KEY]`, `[WARN]`, `[SKIP]`, plus `[Kernel panic]` and the pre-existing `[assistant]`/`[reasoning]`. The empty-param `[A-HJKST]` branch that would have tripped `[ERROR]`/`[KEY]` is gone. The falsifiability test grew the corresponding uppercase pass-clean cases and a `[12;24H` trip case; the three real-residue inputs (`[1;14r`, `[2J`, `[12;24H`) all still trip. The parameterized regression net works.

### Low / Nit (test-only tooling, modest ceiling)

- **The paramless false-negative I originally flagged persists -- now accepted, not fixed (reproduced).** `[K`, `[L`, `[M`, `[P` (the exact ESC-stripped erase/insert/delete-line siblings my finding named) all pass clean under the new regex. This is the honest half of the trade: the fix bought the false-positive relief by keeping the false-negative. The commit documents it and defers ownership to the ContentGuard/seal seam ("content handed to `InlineAuthority.seal/2` must never carry escapes"). Fair reasoning, but note the owner is a *source* fix (`seal_block/2` dropped its one `\e[K`), not an enforced invariant -- there is no assertion at the seam that seal content is ESC-free. The original bug this whole tripwire was born to catch was a paramless `\e[K`; if `seal_block` (or any future seal caller) re-embeds `\e[K`/`\e[L`, ContentGuard strips it to a text token with no ESC, so neither the sequence-vocabulary allowlist (keys on ESC presence) nor this narrowed guard flags it. The compensating catch is the byte-golden diff + escaped sidecar eyeball (which is in fact how the original bug was found) -- but the automated semantic net for that exact class is now blind. Belt intact, suspenders removed.

- **"Unambiguous / provably not text" is overstated -- a narrower false-positive class remains (reproduced).** Digit-leading bracket labels are byte-identical in shape to real residue after ESC-strip, so the regex cannot distinguish them either. Confirmed trips on plausible agent output: `[4K] video`, `[8K]`, `[2FA] enabled`, `[3D] printer`, `[1st] place`, `[2nd] run`, `[100x] speedup`. (`[200 OK]`, `[1080p]` pass -- the digit run must be immediately followed by a letter and capped at 3 digits.) So the class of false-positives shrank from "any uppercase-led label" to "1-3 digits then a letter," but it is not empty, and the moduledoc/commit claim that this shape is one "prose never produces" / "provably not text" is not quite true. Undocumented residual. Practically harmless -- the current chat fixtures carry lowercase labels -- but a future fixture line rendering e.g. `[4K]` would wrongly block a legitimate bless, which is the same failure mode the narrowing set out to remove, just rarer.

### Verdict: CONCERNS

The flagged MEDIUM is materially improved: the common-label false-positive that would have blocked a legitimate bless is genuinely fixed, verified against every label case I named. What remains is low-severity for test-only tooling: the paramless false-negative is now honestly documented and deferred upstream (though the upstream owner is a source fix, not an enforced ESC-free-content invariant, leaving the original `\e[K` bug class without an automated semantic net on recurrence), and a residual digit-leading-label false-positive (`[4K]`/`[2FA]`/`[8K]`) contradicts the "provably not text" framing. No blocker.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 4 — REVIEW | review_state=COMMENTED — 2026-07-16T22:41:56Z

## Adversarial Re-review (automated)

Since last review: be42e7bd..c1d3f790

Scope: one new commit, `c1d3f790` ("Enforce the seal-seam ingress invariant;
document the residual label class"). Diff is test-only (+195/-14 in
`test/harness/golden_snapshot_test.exs`); no production change in this delta.
The `\e[K`-removal from `Surface.seal_block/2` was a PRIOR commit on this branch
(verified: `git show c1d3f790:lib/raxol/harness/surface.ex` inline path is now
`&[&1, "\r\n"]`, with an explanatory comment; the erase is the authority's job,
not content's).

### Resolved since last review

**The paramless-residue gap is now genuinely ENFORCED, not merely documented.**
Round-2's CONCERN was that the paramless class (`[K]/[L]/[M]/[P]` after ESC
strip) was deferred "to the ContentGuard/seal seam" as prose, with nothing
automated to catch a re-embed. This commit turns that seam into a two-part
test-side invariant, and both parts have teeth:

- Fixed point at ingress: for every `fixture x {inline_log, tmux_conservative}`
  it reconstructs the per-block content handed to `InlineAuthority.seal/2`
  (`BlockBody.render |> ViewText.lines(:styled)`) and asserts
  `ContentGuard.sanitize_line(bin) == bin`. Verified the enforcement mechanism
  directly: `sanitize_line("\e[Khello") -> "[Khello"` (identity? = false), while
  `sanitize_line("\e[1;31mred\e[0m")` is the identity. So a non-SGR escape
  arriving via CONTENT makes the assertion trip; legit SGR passes. This is a
  real invariant, not "goldens happen to be clean today."
- Anti-drift replay pin (inline_log): reconstructed-ingress plain text vs.
  emulator-replayed sealed history, row-for-row. This is the guard that catches
  a `seal_block` re-embed (the exact regression class the residue regex is blind
  to); commit red-proved it by re-embedding `\e[K` and reverting. Confirmed a
  leading `[K` cannot hide: `plain_lines`/`row_text` trim trailing only, so
  leading residue diverges the comparison.

Net: the residue class is owned by an enforced invariant at ingress, materially
stronger than the prior "documentation + same regex." Geometry constants (60/20/6)
match `Golden.render/2`, so the reconstruction mirrors the real golden path; all
referenced helpers (`Golden.fixtures/drive_to_completion/max_steps`,
`SealOracle.replay/history`, `ViewText.lines`, `BlockBody.render`, `Fixture.load`,
`Surface.new`) exist on the branch.

**Digit-leading-label LOW: addressed honestly as documented+pinned (not fixed).**
The regex claims are exact (reproduced standalone): `[200 OK]` and `[1080p]`
pass clean; `[4K]`, `[2FA]`, `[8K]`, `[3D]`, `[1st]`, `[100x]` false-positive;
`[2J`/`[1;14r`/`[12;24H` caught; `[K]/[L]/[M]/[P]` NOT caught. The falsifiability
corpus now pins `[200 OK]`/`[1080p]` clean and `[4K]`/`[2FA]` as deliberate
false positives, and the comment states the accepted residual class plainly.
The "provably not text" overclaim from Round-2 is withdrawn. Accepting rather
than widening the tripwire is the right call for a residue guard.

### Low / Informational

**ContentGuard does not neutralize 8-bit C1 controls (reproduced).** The
fixed-point invariant equates "sanitize is the identity" with "no escape would
be stripped into residue" -- true only for 7-bit ESC-introduced sequences.
Verified: `sanitize_line` is the IDENTITY on `<<0x9B>>"2J"` (8-bit CSI),
`<<0x9D>>"8;;..."` (8-bit OSC), and `<<0x84>>` (IND), because every byte
`>= 0x80` is treated as opaque UTF-8. So a non-SGR control introduced in C1
form would (a) survive ContentGuard into a golden, (b) satisfy the fixed-point
assertion (identity), and (c) evade the `[...`-shaped residue regex -- all three
nets miss it. This is pre-existing ContentGuard behavior, out of this test-only
commit's scope, and practically low-risk (0x9B is invalid UTF-8 in a UTF-8
terminal), but the harness explicitly models degraded/legacy tiers where 8-bit
C1 can be honored, so it is worth an explicit note behind the "fixed point ==
safe" confidence.

**Enforced-invariant coverage is asymmetric across tiers.** The fixed-point test
alone is blind to a `seal_block` framing re-embed -- its reconstruction is
hardcoded `&[&1, "\r\n"]` and never reads `seal_block`, so only the anti-drift
replay pin re-anchors reconstruction to reality. That pin runs `:inline_log`
ONLY. For `:tmux_conservative`, a re-embedded escape's actually-emitted bytes
are re-anchored by the pre-existing byte-golden, not by this new invariant. Not
blocking (byte-goldens backstop every tier), but the "enforced invariant" for
the framing class is inline_log-only; a one-line loop over both modes in the
replay pin would close it.

**Minor (New Hire):** the replay pin has no non-empty guard analogous to the
fixed-point test's `assert binaries != []`; if a fixture reduced both sides to
`[]` the `history_lines == expected_lines` assertion passes vacuously. Fixtures
are non-empty in practice; low.

### Verdict: CLEAN

Test-only tooling (modest ceiling). The Round-2 CONCERN is resolved: the
paramless-residue class is now enforced by a real ingress invariant
(ContentGuard fixed-point + anti-drift replay pin, red-proven), not merely
documented, and the digit-leading LOW is honestly documented and falsifiability-
pinned. Remaining items are pre-existing (C1 gap) or modest polish (inline_log-
only replay pin, vacuity guard) and do not block a test-only commit.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #609 — Harness UI: overlay picker primitive (footer-region, substrate-safe)
State: MERGED (merged 2026-07-16T21:23:21Z)
Drew entries: 1

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T20:01:30Z

## Adversarial Review (automated)

Reviewed the substrate-critical footer-growth path (`InlineAuthority.set_footer_rows/2`,
`ScrollRegionManager.set_footer_rows/2`), the keymap/routing seam, and the pure
`OverlayPicker` against the actual diff and surrounding source. The core substrate math
(grow-scrolls-into-scrollback via index-at-region-boundary, shrink-clears-vacated-rows,
the `grow_reclaim_count` conservative branch, the `>=2` history / `>=2` overlay thresholds,
`needs_keyframe` reuse, immutable-prefix nets, ViewText + ContentGuard double-sanitization of
untrusted labels) holds up under scrutiny -- I could NOT find a scrollback-overpaint. The
blocking issue is in input routing, not the substrate.

### CRITICAL
- **[Saboteur + Security Auditor] (promoted from HIGH)** `lib/raxol/ui/harness/keymap.ex:185-187` + `:267` -- **The overlay filter silently loses `z`/`j`/`k` and mutates hidden transcript state whenever the overlay is opened from transcript-browse mode.** The design contract (OverlayPicker moduledoc; Surface handle_input doc) is "printable characters stay `:passthrough` and get routed to `OverlayPicker.handle_key/2` while an overlay is open." But `z`/`j`/`k` are `char:` binds (`fold_toggle`/`jump_next`/`jump_prev`) guarded by `:not_composing`, and `guard_passes?(%{guard: :not_composing}, ctx)` reads ONLY `composing?` -- it never consults `overlay_open?`. `open_overlay/3` does not touch `composing?`. So the sequence `focus_transcript/1` (sets `composing?: false`, the documented mode that "enables jump/fold" and the natural mode to open a jump/search/palette picker from) then `open_overlay/3` leaves `composing? == false` AND `overlay != nil`. Pressing `z`/`j`/`k` then resolves to a *command* (guard passes), NEVER reaches `route_passthrough`, so it (a) is dropped from the picker's filter query and (b) toggles a fold / moves the transcript jump cursor behind the open overlay. `j`/`k` are extremely common in search text, so the picker is functionally broken in its primary open-path, and the side effects are invisible. **Masking:** the new keymap test `"only ESC gains an overlay meaning..."` asserts `resolve_from(Event.key("a"), %{overlay_open?: true, composing?: true})` -- it pins `composing?: true` (where `:not_composing` fails anyway) and tests `"a"` (unbound), so it never exercises `z`/`j`/`k` with `composing?: false` and gives false confidence. **Fix:** make `:not_composing` also fail when an overlay is open -- `not (Map.get(ctx, :composing?, true) or Map.get(ctx, :overlay_open?, false))` -- or have `open_overlay/3` assert a routing context that suppresses these binds; then add the `composing?: false` case to the test matrix.

### MEDIUM
- **[New Hire] `lib/raxol/harness/surface.ex` (`open_overlay/3`, `do_open_overlay/4`, `force_close_overlay?/2`)** -- The 2-row history minimum is re-encoded as a bare literal in two places (`model.rows - 2 - model.footer_rows` in the capacity check, `new_rows - 2 - footer_rows` in force-close), duplicating `ScrollRegionManager.degenerate?/2`'s own `history_bottom < 2` definition instead of calling it; and the `max_visible` default `8` in `do_open_overlay`'s `Keyword.get(opts, :max_visible, 8)` duplicates `OverlayPicker`'s `@default_max_visible 8`. If either threshold ever changes, these silently drift and the substrate-capacity guard is exactly where drift is most dangerous. Route both through named helpers / the module attribute. (Also flagged: the moduledocs are very heavy on undefended jargon -- DECSTBM / substrate law / seal frontier / index-at-region-boundary -- with no single glossary anchor for a new maintainer.)

### LOW
- **[New Hire] `lib/raxol/ui/harness/keymap.ex:182` (`@binds` order)** -- "table order is load-bearing for escape only" is defended by exactly one test (`ESC with overlay_open?: true -> :overlay_dismiss`). Nothing structural stops a future editor from inserting another `:escape` entry or reordering; the invariant "no two entries can both match one event" that made order incidental is now false for the escape pair. Consider a structural guard (assert at compile time that the `:overlay` escape precedes the `:always` escape) rather than relying on prose + a single behavioral test.
- **[Security Auditor / Saboteur] `lib/raxol/ui/rendering/paint_authority/inline_authority.ex` (`grow_reclaim_count/3`, `scroll_history_up/3`)** (PLAUSIBLE) -- The grow scroll count is derived from `next_row` as the occupancy high-water mark. `resize/3` (seal-time-only) clamps `next_row` DOWN on a shrink without moving on-screen content, so after a shrink-resize `next_row` can under-report the rows physically occupied on some terminals. An `open_overlay` immediately after such a resize could then under-scroll and let the overlay paint over a still-occupied row. This is the same latent assumption `append_sealed/2` already makes (so not new to this PR), but the overlay grow is the first path that reclaims a *range* rather than appending one line, which widens the blast radius. Worth an explicit test: shrink-resize with a full history region, then `open_overlay`, assert immutable-prefix.

### Cross-persona overlaps
- The CRITICAL routing desync was reached independently by the **Saboteur** (production break: filter drops keystrokes + corrupts fold/jump state) and the **Security Auditor** (input routing desynchronized -- keys leak to the wrong handler, a confused-deputy over `overlay_open?` vs `composing?`). Per the promotion rule, HIGH -> **CRITICAL**.
- No other overlaps; the substrate-overpaint hypotheses (grow off-by-one, shrink clearing wrong rows, degenerate-refusal bypass) were investigated and did NOT survive verification against the code.

### Verdict: BLOCK

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #610 — Harness UI: hand the composer draft to $EDITOR with a suspend/resume bracket
State: MERGED (merged 2026-07-16T22:18:27Z)
Drew entries: 3

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T20:20:13Z

## Adversarial Review (automated)

Reviewed the full diff and the surrounding substrate (`InlineDriver.start_stdin_reader/0`,
`Driver.Stty`, `ScrollRegionManager`, `InlineAuthority`, `Surface`). The pure state
machine, the compensation ledger fold, the suspend/teardown byte kinship
(`teardown_bytes == suspend_bytes <> "\r\n"`), the geometry-gated resize vs unconditional
`reassert`, and the `:user_drv_reader` handle (InlineDriver arms the SAME registered reader
the gate targets, so that coupling is at least internally consistent) all check out against
the code. The findings below are where prose and code diverge.

### CRITICAL
- **[Saboteur + New Hire] (promoted from HIGH)** `lib/raxol/harness/editor_session.ex` `interpret(:enable_reader)` (~L241-245) -- the reader re-enable result is **swallowed**: `_ = ctx.gate.enable(ctx.reader); {:ok, ctx}`. `ReaderGate.enable/2` can return `{:error, {:reader_down, reason}}` (reader died under the editor) or `{:error, :timeout}`. On the `:reader_down` path the prim_tty stdin reader is gone and never rearmed -- **the tty is permanently deaf** -- yet the step reports `:ok`, the resource ledger records `reader: :enabled` (a lie -- `editor_suspend.ex` `apply_step(_, :enable_reader)` models enable as infallible, ~L259), the outcome is `{:ok, text}` / `{:kept, ...}`, and the composer happily shows the edited draft with **no notice and no telemetry**. The moduledoc claims "an enable failure leaves input degraded... the caller may notify rather than crash" -- but the failure never reaches the caller: `Surface.run_editor`'s `{:ok, ...}` branch has no channel for "resumed but input dead." The exhaustive compensation property in `editor_suspend_test.exs` is *vacuous over this case* because the ledger model assumes `:enable_reader` cannot fail. This is exactly the "leaked reader gate / tty permanently deaf" failure the ledger is advertised to prevent. Two personas, one root -> promoted. Fix: propagate the gate result into the outcome (add an `{:ok_degraded, ...}` / notice channel) and telemetry-emit on enable failure; do NOT let the ledger assert `:enabled` on a failed enable.

### HIGH
- **[Security Auditor]** `lib/raxol/harness/editor_session.ex` temp-file creation (path build ~L95-99, `File.write` ~L184) -- the draft is written with plain `File.write/2` (default mode, honors umask -> typically `0644`, world-readable) into `System.tmp_dir!` (the shared, world-writable, sticky `/tmp`). The draft is a composer prompt and can contain secrets / API keys / private text. For the whole time the editor is open any local user can read it. There is no `0600`, no O_EXCL/O_NOFOLLOW, no per-user `0700` subdir. The name `raxol_draft_<monotonic_int>_<microsecond>.md` is only weakly unpredictable, so `File.write` following a **pre-planted symlink** is a live race (truncate/redirect of an arbitrary file the harness user can write, or feeding attacker content back as the "edited" draft). Fix: create in a `0700` per-process subdir, open with `[:exclusive]` (O_EXCL) and chmod `0600`, or use an mkstemp-equivalent.

### MEDIUM
- **[Saboteur]** `lib/raxol/harness/editor_session.ex` `default_spawn/1` (~L303-315) -- the `receive` awaiting `{:exit_status, ...}` / `:DOWN` has **no timeout**. A wedged/daemonizing `$EDITOR`, or one that never exits after the reader-gate race ate its only keystroke, blocks this synchronous call **forever**. Because `run_editor` runs inline in the TEA `handle_input/2` loop, the entire harness UI freezes with the terminal in the editor's mode and no escape hatch from the BEAM side. Fix: bound the receive (configurable), and on timeout kill the port and run compensation -> `{:kept, :editor_timeout, geo}`.
- **[Security Auditor]** `lib/raxol/harness/editor_session.ex` `interpret(:spawn_editor)` (~L218) builds `ctx.editor <> " " <> shell_quote(ctx.path)` and hands it to `Port.open({:spawn, cmd})` = `/bin/sh -c`. Only the path is quoted; `$VISUAL`/`$EDITOR` is interpolated **unquoted and unvalidated** by design (arg-splitting for `"code -w"`). Draft content correctly never reaches the shell (good). But the moduledoc frames this as safe; it is only safe under the assumption that env is fully trusted. In any context where env is attacker-influenceable (SSH `ForceCommand`/`AcceptEnv`, sudo `env_keep`, a service manager's environment) a hostile `$EDITOR` is arbitrary command execution **on the real controlling tty**. There is no allowlist, no basename check, no `[:args]`-form spawn. Fix: at minimum document the trust boundary at the call site; consider rejecting `$EDITOR` values containing shell metacharacters, or spawn via argv where the editor string is a single non-arg token.
- **[New Hire]** `packages/raxol_terminal/lib/raxol/terminal/inline_driver/reader_gate.ex` (`call/2`, ~L80) -- the gate speaks a **reverse-engineered private OTP wire protocol** (`monitor(..., alias: :reply_demonitor)` + `{ref, :disable | :enable}` against a hardcoded `:user_drv_reader`, "verified against OTP kernel prim_tty.erl's reader_loop/2"). The version-coupling risk is admitted in prose but pinned/guarded **nowhere** -- no OTP version assertion, no dep constraint, no runtime capability probe. When OTP changes the reader message shape or registration, `disable` degrades to a silent 2s timeout on every Ctrl-E (best case) or sends a stray message to whatever now holds that name (worse). Fix: add an OTP-version guard or a feature-probe that fails the bind cleanly, and pin the tested OTP range.

### LOW
- **[New Hire]** The suspend park sequence `"\e[#{rows};1H"` is hand-inlined in `sequences.ex suspend_bytes/1` while every sibling uses a named builder (`modes_off/0`, `release_region/0`, `autowrap_cursor/0`). Extract a `park_bottom/1` for parity and to keep the "magic byte" in one place.
- **[Saboteur]** The ledger treats `:release_screen`'s `IO.write(suspend_bytes)` as all-or-nothing; a real device that partially writes before raising would leave modes/region in a state the ledger doesn't model. Narrow window, real device only; noting for completeness alongside the CRITICAL.

### Cross-persona overlaps
- **enable_reader swallow** -- Saboteur (permanent tty-deaf leak) + New Hire (the "exhaustive compensation" safety claim is unsound because the ledger models enable as infallible). Same root -> promoted HIGH -> CRITICAL.
- Temp-file handling is touched by both Security (world-readable/symlink) and, tangentially, Saboteur (leftover-on-crash -- but the `try/after File.rm` genuinely covers the leak side, so only the disclosure/symlink angle stands). No further promotion.

### Verdict: BLOCK

One CRITICAL (silent permanent input death on reader re-enable failure, with the compensation
proof not covering it) plus a HIGH world-readable/symlink-prone temp file. The pure machine,
byte vocabulary, and resume composition are genuinely well-built and well-tested; the blockers
are on the impure edges the ledger model does not actually observe.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-16T21:39:15Z

## Adversarial Re-review (automated)
Since last review: 5f910ed1..c0e709e0

Re-reviewed the two new commits against the actual source at HEAD `c0e709e0`
(`editor_session.ex`, `editor_suspend.ex`, `reader_gate.ex`, `surface.ex`,
`surface/view_text.ex`), not the commit messages. The two prior BLOCK-level
findings are genuinely addressed; the safety property behind the CRITICAL is
now only PARTIALLY closed at the render layer, and two doc/behavior gaps
surfaced.

### Resolved since last review

- **CRITICAL (reader re-enable swallow) -- resolved at the machine + telemetry
  layer.** `:enable_reader` is now a real DEGRADABLE step, not a swallow.
  `editor_session.ex` `interpret(:enable_reader, ...)` returns `{:degraded,
  reason}` and emits `[:raxol, :harness, :editor, :reader_enable_failed]`
  telemetry before returning; the machine records it (`editor_suspend.ex:260`
  degradable clause, `:340` a degraded completion applies NO ledger
  transition so `reader` stays `:disabled`, `:297` `degradations/1` exposes
  it), and a `{:degraded, _}` on any non-degradable step raises
  (`editor_suspend.ex:265`). Surface surfaces it (`surface.ex:924-940`). The
  old vacuous "infallible enable" is gone. (But see MEDIUM below on the
  footer render.)

- **HIGH (world-readable temp file / symlink race) -- resolved.**
  `write_draft_file/2` opens with `[:write, :exclusive, :binary, :raw]`
  (`O_CREAT|O_EXCL`; POSIX does not follow the final component as a symlink
  under `O_EXCL`) then `chmod 0600`; the per-run parent dir is `File.mkdir`
  (exclusive-create) + `chmod 0o700` in `interpret(:write_tmp, ...)`; cleanup
  is `try/after File.rm_rf(dir)` in `run/1` plus the `:cleanup_tmp` step plus
  the compensation clause -- removed on ok/kept/error/raise. Confidentiality
  window is confined. Symlink-planting into the draft path is refused with
  `:eexist`.

- **LOW (OTP user_drv version coupling) -- resolved.** `reader_gate.ex:104-112`
  pins the verified range (OTP 26-29, `@min_otp 26`) and refuses below the
  floor with `{:error, {:unsupported_otp, release}}` instead of speaking an
  unverified protocol; the drift failure mode is documented fail-closed
  (`reader_gate.ex:59-77`).

- **MEDIUM ($EDITOR word-splitting) -- accepted as documented WONTFIX.** The
  generated path is single-quote escaped (`shell_quote/1`); the editor token
  itself stays sh-word-split by design, with the trust boundary spelled out
  (`editor_session.ex` "Trust boundary" moduledoc: same contract as
  git/crontab/OTP, embedders across a privilege boundary must inject a vetted
  `:env`). Reasonable.

- **MEDIUM (unbounded spawn receive) -- addressed, opt-in.** `default_spawn/2`
  now has an `after timeout` arm that SIGTERMs + closes the port and returns
  `:timeout`. Default is `:infinity` by deliberate policy (a human edits for
  arbitrary time); the bound is threaded through `Surface`'s `:editor_opts`.
  See LOW below for a residual edge.

### MEDIUM

- **The reader-dead warning can still be render-truncated away -- same safety
  property as the original CRITICAL, relocated from machine-swallow to
  footer-truncate.** `apply_degraded_notice/2` (`surface.ex:926-940`) APPENDS
  ` · input reader failed to re-enable` to the END of an existing kept
  notice. `ViewText.lines/3` end-truncates a notice to the width budget with
  an ellipsis (`surface/view_text.ex` `truncate/2`, lines ~230-243:
  `split_at_display_width(width-1)` + ellipsis) -- it does not wrap. So the
  warning, being last, is the first casualty of truncation. On an 80-col
  terminal a long kept notice makes it partially or fully vanish, e.g.
  `$EDITOR="code --wait --user-data-dir=/tmp/x"` yields
  `"» editor not found: code --wait --user-data-dir=/tmp/x — draft kept"`
  (~65 cols) + the 35-col warning = ~100 cols, truncated to 79 -> the entire
  `input reader failed to re-enable` substring is gone. The new test
  (`editor_surface_test.exs:176`) only exercises `:editor_nonzero` (the
  SHORTEST kept notice, ~72 cols combined), so the overflow the commit claims
  to defend ("width-budgeted so truncation cannot eat it -- a real overflow
  the new test caught") is NOT actually pinned; the code comment at
  `surface.ex:928` asserting the warning "must survive ... on an 80-column
  terminal" is contradicted by the append-at-end ordering. Mitigation that
  keeps this MEDIUM not HIGH: `[:raxol, :harness, :editor,
  :reader_enable_failed]` telemetry fires unconditionally regardless of the
  footer, so a wired embedder still sees it -- but an interactive operator
  reading only the footer would not. (Saboteur + New Hire converge on this
  root: behavior loses the message, and the in-code contract comment claims
  it does not.) Fix: prepend the warning, or render it as its own notice line
  exempt from the shared truncation, and add an overflow test with a long
  kept notice.

### LOW

- **Temp-dir name is not the cryptographic random the docs claim.** The
  moduledoc (`editor_session.ex:71`) and both fix commits say "unpredictable
  `:crypto.strong_rand_bytes`-suffixed name" / "strong-random-suffixed
  per-run directory", but `unique/0` (`editor_session.ex:472`) is
  `:erlang.unique_integer([:positive, :monotonic]) <> "_" <>
  System.os_time(:microsecond)` -- a monotonic counter plus a timestamp, i.e.
  predictable, NOT cryptographic. Impact is bounded because `File.mkdir` is
  exclusive-create: a correctly-predicted pre-planted directory causes an
  abort (DoS), not disclosure, and `O_EXCL` + `0700` still hold for the
  secret window. So this is a documentation-integrity / missing
  defense-in-depth finding, not a disclosure hole -- but the confidentiality
  section makes a specific crypto claim the code does not honor, and a future
  reader/auditor would trust it. (Security Auditor + New Hire, same root.)
  Fix: either use `:crypto.strong_rand_bytes(...) |> Base.url_encode64` as the
  suffix, or correct the doc to describe what `unique/0` actually does.

- **`default_spawn/2` timeout can strand a port message and does not bound the
  default wedge.** On the `after timeout` arm, `kill_editor/2` demonitors
  (flushing only the `:DOWN`) and closes the port, but a `{port,
  {:exit_status, N}}` delivered in the race window just before close is not
  drained; `default_spawn` runs in the harness dispatcher / TEA-loop process,
  so a stray message can land in that mailbox. Minor. Separately, with the
  default `:infinity` a genuinely wedged (non-interactive) editor -- the
  original MEDIUM's scenario -- still freezes the loop forever unless an
  embedder opts into `:editor_timeout_ms`; the interactive-human rationale is
  sound but the default leaves the automation case unprotected. Consider
  draining the port mailbox after close, and documenting that non-interactive
  embedders should set a bound.

### Verdict: CONCERNS

Both prior blockers are genuinely fixed (O_EXCL/0600/0700 confinement; the
enable-reader swallow is now a recorded, telemetry-emitting degradation with a
non-vacuous compensation ledger). What remains is one MEDIUM where the
resolved CRITICAL's safety message can still be truncated out of the footer
for long kept notices on narrow terminals (telemetry mitigates; the claimed
test does not cover it), plus two LOW doc/edge gaps. Not a BLOCK -- the tty is
no longer left silently deaf at the machine layer -- but the footer-truncation
and the strong-random doc claim should be corrected before merge.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 3 — PR COMMENT — 2026-07-16T21:59:54Z

have conflicts here

---

## PR #611 — test: order-of-magnitude bound on the 1M-grapheme scorer guard (CI flake)
State: MERGED (merged 2026-07-16T21:56:18Z)
Drew entries: 1

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T21:38:04Z

## Adversarial Review (automated)

Scope: test-only change, single commit `b367f976`, raising the 1M-grapheme scorer guard's wall-clock assert from `16.0ms` to `200.0ms` in `test/raxol/ui/list_scorer_test.exs`. Reviewed against `lib/raxol/ui/list_scorer.ex` (the `@max_score_graphemes` clamp under test).

### Medium

- **[Saboteur] medium** test/raxol/ui/list_scorer_test.exs:~289 (new `assert millis < 200.0`) -- The fix keeps the exact mechanism the PR body itself names as the repo's #1 flake class: an absolute wall-clock assert on a shared CI runner. It only swaps one magic number for a larger one. It does not switch to a deterministic proxy, so it still measures runner load, not the scorer. Worse, on the *correct* (clamped) path `rank/4` touches at most `@max_key_bytes` (~4096 bytes) via the O(1) `bounded_key_prefix/1` sub-binary -- real scorer work is sub-millisecond, yet the flaking run measured ~25ms, i.e. the assertion is dominated by scheduling/GC noise, not the code under test. Fix: assert the actual invariant the clamp provides -- input-size independence -- by ranking a 1M-grapheme label and a 2M-grapheme label and asserting their times are within a small ratio (post-cap work is O(1) in label length). A ratio bound is far more robust to shared-runner noise than any absolute millisecond number.

- **[Saboteur] medium** lib/raxol/ui/list_scorer.ex:115 (`@max_score_graphemes 1024`) -- An order-of-magnitude bound only catches *removal* of the clamp (unclamped: `String.graphemes` over 1M plus the `O(query * key)` DP = well over 1s, so 200ms does separate correct from catastrophic here). It does not catch a *weakening* of the clamp: raise `@max_score_graphemes` from 1024 to, say, 50_000 and the DP + grapheme split cost stays comfortably under 200ms while the guard has silently regressed 50x. The test therefore does not pin the value it exists to protect. Fix: additionally assert against the clamp constant directly (e.g. that `positions` never exceed `@max_score_graphemes`, or drive two labels straddling the cap and assert equal work), so a loosened cap fails a test rather than sliding through.

- **[Security Auditor] medium** lib/raxol/ui/list_scorer.ex:153 (`query_graphemes = normalize_string_graphemes(query, ...)`) -- The guard this test defends is a real DoS control on untrusted input (pasted labels / log lines used as keys), and the key axis is clamped. But the *query* axis is not: `query` is grapheme-split with no cap before use. The subsequence gate + key clamp bound the DP itself (a query longer than the 1024-grapheme clamped key fails `subsequence?/2` at list:312 and never reaches `align/3`), so the quadratic blowup is contained -- but `normalize_string_graphemes/2` still does unbounded O(query) `String.downcase` + `String.graphemes` on the raw query on every keystroke. A user pasting a multi-MB string into the filter box pays linear-in-paste work with no ceiling. This PR touches only the key-side adversarial test; the query-side DoS axis has no clamp and no test. Fix: cap the normalized query length (mirror `@max_score_graphemes`) and add a large-query adversarial test.

### Low

- **[New Hire] low** test/raxol/ui/list_scorer_test.exs:~283 (new comment) -- The comment justifies `200.0` as "matching the sibling test's convention above," but the sibling bound (list_scorer_test.exs:263) is 200ms for a *different* scenario -- 10,000 full Smith-Waterman DP runs -- not a single 1M-grapheme label. The two `200`s are numerically coincidental, not a shared derivation, so "same convention" overstates the link. The comment records the correct-path flake (~25ms) but not what a *regressed* run costs, leaving the reader unable to confirm 200ms sits safely between correct and broken. The margin is only ~8x over the observed 25ms flake; a comment that the earlier target flaked at 1.5x over (16 -> 25) without bounding the loaded-runner worst case does not establish 8x is enough. Fix: record the measured regressed-path number (or the observed p99 correct-path time) so the threshold's safety margin is auditable.

### Cross-persona overlaps

- Saboteur ("cannot distinguish clamp-works from clamp-loosened") and Security Auditor ("query axis untested") share one root: the test under-covers the guard's real invariant surface (it pins neither the clamp value nor the second DoS axis). Promotes the "this test proves less than it appears to" concern to the strongest theme of the review.
- Saboteur ("still wall-clock") and New Hire ("unexplained magic 200") share the fragility-of-absolute-thresholds root; both are resolved by the same move to a ratio/invariant assertion.

### Verdict: CONCERNS

The immediate change is a defensible flake mitigation -- 200ms does separate the correct path from a full clamp removal, so it is not vacuous for that one failure mode. But it perpetuates the exact absolute-wall-clock pattern the project has repeatedly flagged as its top flake source instead of asserting the deterministic input-size-independence invariant the clamp actually provides, it cannot detect a loosened (vs removed) clamp, and it leaves the unbounded-query DoS axis untested. Not a BLOCK; the residual issues are substantive enough to warrant follow-up before this is treated as the guard's real protection.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #613 — feat(core): centralized boundary-confinement seam [thread-2]
State: MERGED (merged 2026-07-16T23:32:55Z)
Drew entries: 3

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T22:06:10Z

## Adversarial Review (automated)

Scope: the two confinement primitives in `raxol_core` (`Path.confine/3`, `TermText.sanitize/2`), their tests, and the shared conformance vectors. Empirical probes run in an isolated worktree against the compiled PR branch. `TermText.sanitize/2` held up well under hostile probing (reassembly cannot produce a live sequence, because the only bytes that ever reach output are `>= 0x20`, non-DEL, non-C1, which cannot introduce a sequence; OSC BEL+ST, unterminated OSC, 8-bit C1 introducers, and idempotence are all handled). The findings below are all in `Path.confine/3` and its test/vector coverage.

### CRITICAL

- **[Security Auditor] CRITICAL (reproduced)** `packages/raxol_core/lib/raxol/core/boundary/path.ex:126-136` (specifically the relative-target join at line 134) -- **symlink-escape confinement bypass**. `real_path/2` reads the leaf symlink first and resolves its POSIX-relative target against the *lexical* parent `Path.dirname(path)` instead of the *resolved-real* parent. When a symlinked ancestor changes the path's real depth, the `..` count is under-applied, so the computed "real" path stays inside root while the OS actually resolves the requested path to a file *outside* root. `escape_gate` then blesses the wrong path.
  - Reproduced: root `R`; `R/a/link` -> `R` (symlink, inside root); `R/leaf` -> `../secret` (relative). `confine(R, "a/link/leaf")` returns `{:ok, ".../R/a/secret"}` (in-root), but `File.read(".../R/a/link/leaf")` returns `"OUTSIDE-SECRET"` from `.../secret`, *outside* root. The primitive's core claim ("the fully symlink-resolved target provably stays inside root") is false.
  - Blast radius: every consumer. For #586 tar-extract (confine used as a per-member gate while `:erl_tar` writes the member's own path) and any caller that opens the requested path rather than the returned one, this is a live write/read escape. Even callers that open the returned path get a *different* file than the OS would -- a correctness break on top of the security break.
  - Fix: resolve path components left-to-right, resolving each ancestor symlink *before* descending, so a relative leaf target is anchored to the already-resolved parent directory (resolve `dirname` first, then read the leaf link relative to the resolved dir). The current leaf-first + lexical-anchor order is the classic realpath bug.

### HIGH

- **[Saboteur] HIGH (reproduced)** `packages/raxol_core/lib/raxol/core/boundary/path.ex:123-124` and `:144` -- **depth cap conflates directory nesting with symlink-follow depth**. `depth` is incremented on every parent recursion (line 144), not only on symlink follows (line 136), so a path merely 41+ components deep with **zero symlinks** trips `depth > @max_symlink_depth` and returns `{:error, :too_many_symlinks}`.
  - Reproduced: a 45-level-deep directory tree, no symlinks, `confine/3` -> `{:error, :too_many_symlinks}`. Fail-closed (not a bypass), but it wrongly rejects legitimate deep paths (deep tar members, nested CAS/snapshot dirs) and reports a misleading reason. `@max_symlink_depth 40` also bounds total path depth, which is not what "too many symlinks" means.
  - Fix: increment `depth` only on the symlink-follow branch (line 136); guard parent recursion with a separate, generous structural bound or none.

- **[New Hire] HIGH** `packages/raxol_core/test/raxol/core/boundary/path_test.exs:185-213` -- the "accepted paths never escape root" property **cannot catch the CRITICAL bug and gives false confidence**. It asserts only that the *returned string* `real` is under `real_root` (which is itself produced by `confine`, so it validates `confine` against itself), and its random generator (`segments` at line 194) never creates symlinks -- so it structurally never exercises symlink escape at all. That is exactly why finding #1 passes CI green. The shared vectors also miss the whole class: no relative-symlink-under-symlinked-ancestor case (accept or reject), no sibling-prefix case, no deep-nesting case. The Agent Client Protocol `FsSandbox` copy inherits every blind spot verbatim.
  - Fix: add an independent oracle (compare the returned path, and the *requested* path, against the OS's own realpath / an `openat`+`O_NOFOLLOW` component walk); add a symlink-generating generator; add reject vectors for the relative-symlink-under-symlinked-ancestor escape and an accept/reject vector for deep nesting and sibling-prefix.

### MEDIUM

- **[Security Auditor / New Hire] MEDIUM** `packages/raxol_core/lib/raxol/core/boundary/path.ex:1-45` (moduledoc) -- **TOCTOU caller obligation is undocumented**. The doc claims the resolved target "provably stays inside the resolved root" but never states that resolution is point-in-time and that the caller MUST open the returned path without re-resolving symlinks (`openat`/`O_NOFOLLOW`), nor that a symlink swapped between `confine` and the caller's open defeats it. Given finding #1 (returned path already diverges from OS truth), a caller re-opening the original requested path is doubly exposed. Document the obligation as part of the contract the four consumers adopt.

### Cross-persona overlaps

- Findings #1 (Security Auditor, CRITICAL) and #3 (New Hire, HIGH) share one root: symlink-resolution correctness and the property that was supposed to prove it. Two personas, same defect -> already at CRITICAL; the promotion is moot but reinforces severity. #4 (TOCTOU) is the same primitive's under-specified contract.

### Verdict: BLOCK

One reproduced CRITICAL confinement bypass (relative symlink resolved against the lexical parent) plus two HIGH findings (depth-cap conflation, a self-referential safety property that cannot catch the bypass). Because this is the decide-once seam four sites will adopt, the bypass and the blind-spot vector set must be fixed here before any consumer migrates.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — PR COMMENT — 2026-07-16T22:35:22Z

## Cross-cutting: pause the #586 and #569/PA-6 migrations until the CRITICAL here is fixed

This note is a merge-order flag, not a new finding -- it follows from the CRITICAL in the review above.

#613 is the decide-once seam. Its own migration table lists four adopters, and two of them are
security-load-bearing consumers that turn `Path.confine/3` into a real filesystem write/deref gate:

- **Migration #3 -- #586 `:erl_tar.extract` per member** confines each member path against the
  extraction root, then extracts. With the reproduced symlink-escape bypass (`path.ex:126-136`),
  a crafted archive member (`a/link/leaf` where `link` is a symlinked ancestor) passes `confine`
  as in-root while the OS writes it OUTSIDE root -- a classic tar-slip, now with a green gate in
  front of it. Adopting #613 as-is would make #586 *look* hardened while shipping a live escape.
- **Migration #2 -- #569 / PA-6 CAS `$blob`/`snapshot_ref` deref** confines an imported journal's
  content-addressed pointer before dereferencing it. Same primitive, same bypass: an imported
  journal with a symlinked-ancestor ref reads a file outside the CAS root. PA-6 is the amendment
  that is supposed to *close* the traversal hole; wiring it to this confine would ratify a hole
  as a fix.

The shared-vector drift guard does not save either consumer here: the CRITICAL ships green because
the "never escape root" property validates `confine` against itself and its generator plants no
symlinks (review finding #3), and the copied `path_*_vectors.json` miss the
relative-symlink-under-symlinked-ancestor class -- so the Agent Client Protocol `FsSandbox` that
binds to the same vectors (migration #4) inherits the identical blind spot rather than catching it.

Suggested sequencing:
1. Fix `real_path/2` to resolve relative symlink targets against the *resolved-real* parent, not the
   lexical parent; separate the symlink-depth counter from parent-recursion depth.
2. Add a red vector + a property test whose "escape" oracle is an independent OS realpath (not
   confine's own output) and whose generator actually plants leaf and ancestor symlinks. Only when
   that test is red-then-green does the vector set become trustworthy for the ACP copy.
3. THEN land the #586 and PA-6 migrations against the fixed seam. Until then, hold both -- a confine
   that returns `{:ok, escaping_path}` is worse than the un-migrated per-site checks, because each
   site stops doing its own validation once it trusts the seam.

`TermText.sanitize/2` is unaffected -- it held up under hostile probing -- so migration #1 (#607's
fenced-code render adopting `TermText.sanitize`) does NOT need to wait on this; it can proceed
independently of the path fix.

---
_Cross-PR sequencing note from the adversarial review of #613 (thread-2 seam)._

### Round 3 — PR COMMENT — 2026-07-16T23:06:30Z

## Pushed a fix for the CRITICAL (symlink-escape) + the depth-cap HIGH

Commit `715417b1` rewrites `real_path/2` in `packages/raxol_core/lib/raxol/core/boundary/path.ex`.

**Root cause of the CRITICAL:** the old `real_path/2` resolved a symlink's relative target against
`Path.dirname(path)` -- the *lexical* parent -- instead of the symlink's *resolved-real* parent. Under
a depth-inflating ancestor, the `..` count under-applied, so a link escaping root still resolved to an
interior path and `confine/3` returned `{:ok, <interior>}` for a target the OS resolves outside root.

**The fix:** `real_path/2` now walks components left-to-right from the filesystem root, carrying a
fully-resolved real `base`. A symlink is followed against `base` (its real parent), so relative
targets -- including `..` -- resolve against where the link actually lives. `.`/`..` adjust `base`
directly; non-symlink / not-yet-existing components are accepted literally (write-leaf case preserved).
This also fixes the depth-cap HIGH: only symlink hops increment the counter now, so deep symlink-free
nesting is no longer misreported as `:too_many_symlinks`.

**Teeth (addresses the "property test validates confine against itself" HIGH):** added two regression
tests that assert the outcome directly, with no confine-derived oracle:

- `relative leaf symlink under a depth-inflating ancestor cannot under-apply ..` -- plants
  `loop -> .` (inflates lexical depth) + `esc -> ../secret.txt`, requests `loop/loop/esc`, asserts
  `{:error, :symlink_escape}`. This is the reproduced CRITICAL.
- `deep symlink-free nesting is not mistaken for a symlink cycle` -- 80-level symlink-free tree,
  asserts it resolves.

Verified red-then-green: **both fail against the pre-fix `real_path` (31/33), pass after (33/33)**;
full `raxol_core` suite **871 passed**, format + `--warnings-as-errors` clean.

Not addressed here (still open from the review): the shared vector set / ACP-copied
`path_*_vectors.json` still don't cover the relative-symlink-under-symlinked-ancestor class, and the
TOCTOU caller obligation (open the returned path with `O_NOFOLLOW`, do not re-resolve) is still
undocumented. Those, plus re-gating the #569 migration plan on this fix, are worth folding in before
the #586 / PA-6 path migrations adopt the seam.

_Fix pushed by the adversarial-review lane._

---

## PR #615 — Harness UI: unread divider (live-region attention boundary)
State: MERGED (merged 2026-07-17T05:25:10Z)
Drew entries: 3

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T23:14:58Z

## Adversarial Review (automated)

Scope: the unread-divider commit (29e09232) only -- `lib/raxol/harness/unread_divider.ex` (pure policy), the `Surface` integration in `lib/raxol/harness/surface.ex`, and the two test files. Findings are verified against code; the pure machine was replayed against crafted transition sequences in an isolated scratch dir (marked "reproduced").

### Medium

- **[Saboteur] medium** `lib/raxol/harness/unread_divider.ex:180-186` (`viewed/2`) + `surface.ex:1340-1343` (`move_focus`) -- **stuck divider under a post-`focus` block-count shrink (reproduced).** Once `focus/2` freezes a span at `%{from: F, count: C}`, the ONLY navigation clear-path is `viewed/2` gated on `block_index >= F`, and `move_focus` can only ever feed `viewed/2` an index in `0..length(projection.blocks)-1`. If `projection.blocks` shrinks below `F` after the span opens (session replay / reattach / truncation -- the exact case the moduledoc's "Defensive boundaries" claims to cover), no reachable index can ever reach `F`, so navigation can NEVER retire the divider. It sits in the footer forever asserting "C new since you looked" while fewer than `F` blocks exist. Reproduced: `new() |> blur(5) |> focus(8)` -> `%{from: 5, count: 3}`; blocks shrink to 4 so the highest navigable index is 3; `viewed(3)` is a no-op -> divider still `%{from: 5, count: 3}`, `STUCK? true`. The module advertises non-monotone defense but only samples it once, at `focus`. Fix: reconcile in `viewed/2` (also clear when `block_index >= offset - 1`, i.e. the operator reached the last extant block), or clamp `boundary`/`from` to the current offset on the offset feed, or document a hard monotonicity precondition at the `unread_offset/1` callsite.

- **[New Hire] medium** `surface.ex:1384-1398` (`blur/1`) -- **the feature is dormant at runtime.** `Surface.blur/1` is the ONLY path that drives `UnreadDivider` into `:away`, and it has ZERO callers anywhere in `lib/` or `packages/` (only docs and tests reference it). `input_activity/2` (fed on every keystroke at `surface.ex:1022`) only transitions `:away -> :attending`; it never sets `:away`. So with no `blur/1` caller the attention machine never leaves `:attending`, `divider/1` stays `nil`, and the "N new since you looked" rule can never render in the running harness -- all 976 lines are exercised only by tests that call `blur/1` directly. The terminal already parses focus events (`packages/raxol_terminal/lib/raxol/terminal/advanced_features.ex:282-283`, `{:focus_in}`/`{:focus_out}`, mode 1004 at `mode_state.ex:42`) but nothing routes them to `Surface.blur/focus`. A maintainer reading the tests would reasonably assume the divider works. Fix: either wire the existing `parse_focus_event` output to `blur/1`/`focus/1` now, or state plainly in the moduledoc that the divider is inert until the mode-1004 unit lands (the current prose calls it "today's fallback," implying it is live).

### Low

- **[Saboteur] low** `lib/raxol/harness/unread_divider.ex:135-147` (`focus/2`) -- **"Defensive boundaries" overstates protection; count silently under-reports (reproduced).** The defensive clause only rejects the single-sample case `offset <= boundary`. A shrink-then-regrow that stays above `boundary` passes the `offset > boundary` guard and produces a too-small count, even though the blocks between the shrink floor and the new offset are entirely different content. Reproduced: `new() |> blur(5) |> focus(6)` (blocks silently went 5 -> 3 -> 6 while away) -> `%{from: 5, count: 1}` -- "1 new" when up to 3 blocks are actually new. The moduledoc should scope its non-monotone claim to "a single decreased sample at focus-time," not general non-monotonicity.

- **[New Hire] low** `surface.ex:1340-1343` + `unread_divider.ex:175-186` -- **`from` silently doubles as both a block COUNT and a block INDEX.** `boundary`/`from` is set from `length(projection.blocks)` (a count) but compared in `viewed/2` against `focused_index` (a 0-based index). Correctness rests on the unstated identity "count of seen blocks == index of first unseen block," which holds only while `focused_index` is 0-based and blocks are densely indexed from 0. Neither the `viewed/2` doc nor the `move_focus` callsite states this load-bearing assumption; a future change to 1-based focus indexing or sparse block ids would silently break clearing. Add a one-line note at the callsite.

- **[Security Auditor] low** `lib/raxol/harness/unread_divider.ex:216-220` (`pad_with_rule/2`) + `surface.ex:950-957` (`resize/3`) -- **unbounded `String.duplicate` driven by unclamped terminal width.** `line/2` builds `String.duplicate("─", left)` with `left ~ width/2`, and `width` flows straight from `resize/3` with no upper clamp. A terminal (or spoofed resize event) reporting an enormous width forces an O(width) allocation on every footer repaint. Shared with the other footer units (`StatusStrip`), so not unique to this PR, but the divider adds a second such allocation on the same hot path; a `min(width, sane_max)` clamp at the width boundary would cap it. Reassuringly, the divider's *content* is safe: it renders only an integer count plus a compile-time label, and goes through the same `ViewText` `:styled` sanitize/truncate seam (`surface.ex:1573-1582`) as every other footer line -- no agent-controlled block text ever reaches it, so there is no smuggle/injection surface, and over-width output is truncated to `model.width`.

### Cross-persona overlaps

- **Frozen count never reconciled against current reality** is hit from two sides: Saboteur (finding A -- stuck + wrong count under shrink) and the Security integrity angle (a footer the operator trusts to report "what the agent did while I was away" can assert a count that no longer matches the actual block set). Same root as finding A; promotion already reflected in its Medium rating. A single fix -- reconcile `from`/`count` against the live offset when clearing or rendering -- closes both.

### Verdict: CONCERNS

No hard blocker: the divider is dormant at runtime (New Hire medium), so the stuck-divider (Saboteur A) cannot regress a live surface today, and the content path is injection-safe. But before mode-1004 wiring makes this reachable, the frozen-count/shrink reconciliation (A + overlap) and the width clamp should land, and the moduledoc's "defensive"/"fallback" prose should stop implying the feature is live.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-16T23:43:45Z

## Adversarial Re-review (automated)

Since last review: 29e09232..0f003b67

Scope: one new commit, `0f003b67` ("reconcile the unread divider against the live
block count"), targeting the stuck-divider MEDIUM. Verified the shipped pure
clauses in isolation (extracted `reconcile/focus/blur/viewed/divider` verbatim,
no TextMeasure needed, run under `elixir`).

### Resolved since last review

- **Stuck divider under post-focus shrink (MEDIUM, prior finding) -- genuinely fixed.**
  The reviewer's exact repro `new() |> blur(5) |> focus(8)` freezes `%{from: 5, count: 3}`;
  the OLD `viewed/2` gate (`index >= 5`) is still unreachable because navigation only
  feeds indices `0..offset-1`. But `reconcile/2` now retires it: `reconcile(state, 4)`
  -> `span: nil`, and the render read `divider/2` at offset 4 -> `nil`. Fix is threaded
  in BOTH places -- `Surface.reconcile_unread/1` on every `advance/2` (the only projection
  rebuild) mutates state, and `unread_divider_lines/1` reads through the read-only
  `divider/2`. So even a rebuild that bypasses `advance/2` (reattach) still cannot PAINT
  a stale span: `divider(stuck_state, 2)` returned `nil` while the underlying state was
  still `%{from: 5}`; the next `advance/2` then clears the phantom. Both the common case
  and the reattach/render case are covered. Tests lock it (`unread_divider_test.exs:212`
  the exact repro, `:228` reachability invariant, `:285` reconciled read;
  `unread_divider_surface_test.exs:263` end-to-end shrink drop).
- **Unclamped `String.duplicate` in `line/2` (prior LOW) -- fixed for the divider.**
  `min(width, @max_rule_width)` (1024) caps the O(width) allocation on the repaint hot
  path. Residual: `StatusStrip` still shares the unclamped pattern, honestly filed as
  backlog in the moduledoc rather than fixed here.
- **Dormancy (prior MEDIUM) -- documented, NOT wired.** Still test-only (reproduced):
  `parse_focus_event/1` has zero non-doc callers, `Surface.blur/1` has zero production
  callers, `InlineDriver` has no mode-1004 / focus-byte routing. This commit does not
  wire it (correctly out of scope) but both moduledocs now state plainly the divider is
  "INERT at runtime until that unit lands" -- the honesty gap is closed.

### Low

- **Saboteur -- reconcile corrupts the count in BOTH directions under a non-monotone
  offset (reproduced).** `reconcile/2` clamps against a raw block COUNT it cannot
  semantically interpret, so any projection wobble (the exact replay/reattach shapes this
  feature exists to serve) silently corrupts the frozen count:
  - UNDER-count on a transient dip while attending: start `%{from: 5, count: 3}`;
    `reconcile(_, 6)` clamps to `count: 1`; a later `reconcile(_, 8)` regrow leaves it
    frozen at `count: 1` ("N new" now lies low). Documented as "growth never inflates a
    frozen count," but the practical effect is a legitimately-unread divider shrinking on
    a momentary blip.
  - OVER-count / mis-anchor via the away-boundary pull: `blur(5)` (operator had read
    blocks 0..4), projection shrinks to 3 while away so `reconcile(_, 3)` pulls
    `boundary: 3`, then regrow + `focus(8)` yields `%{from: 3, count: 5}` -- re-marking
    blocks 3-4 the operator already read. This over-report direction is NOT documented
    (the moduledoc only warns about the under-report shape). Both are only reachable under
    the future producer that doesn't exist yet, hence LOW, but the boundary-pull
    over-count deserves the same honest one-line caveat the under-count got.
- **New Hire -- layering is sound, one question.** `reconcile` runs on EVERY `advance/2`
  even under fixture mode's monotone growth (a proven no-op there). Given `divider/2`
  already clamps read-only at paint time and is what the renderer uses, the state
  mutation in `reconcile_unread/1` mainly exists to restore `viewed/2` reachability. That
  is a real reason (a stuck state would otherwise never clear via navigation), so it is
  justified -- but it is also the exact mechanism that bakes the transient-dip under-count
  into state permanently. If the read-only clamp is the source of truth for painting,
  consider whether the state clamp should be gated to only-shrink-below-`from` (retire)
  rather than also clamping counts, to avoid permanently freezing a dipped count.
- **Security Auditor -- width DoS closed on this surface.** Confirmed no unbounded
  `String.duplicate` remains reachable through the divider: `line/2` clamps to 1024 before
  `pad_with_rule/2`. The adversarial-fixture smuggle test (no `\e[2J`, row matches
  `^─+ \d+ new since you looked ─+$`) and CJK width-exactness remain. No new external
  input surface introduced.

### Verdict: CONCERNS

Down from prior CONCERNS and materially improved: the blocking-class stuck-divider MEDIUM
is genuinely fixed on both the advance and reattach/render paths, the width DoS is bounded,
and the dormancy is now honestly documented. Remaining items are LOW: reconcile clamping
against a semantically-opaque count introduces a two-directional count corruption under
non-monotone offsets (one direction undocumented), reachable only by a producer that does
not yet exist. Not blocking; recommend documenting the boundary-pull over-count and
reconsidering whether the state-level count clamp is worth its transient-dip cost.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 3 — REVIEW | review_state=COMMENTED — 2026-07-17T00:09:00Z

## Adversarial Re-review (automated)

Since last review: 0f003b67..ef75ef55

Scope: one new commit, `ef75ef55` ("unread-divider reconcile is retire-only;
counts clamp at display time"), targeting the residual round-2 LOW (two-directional
count corruption under non-monotone offsets). Verified against `lib/raxol/harness/unread_divider.ex`,
`lib/raxol/harness/surface.ex`, and both test suites; ran the pure policy suite
(33 passed) and the surface integration suite (15 passed) in an isolated worktree.

### Resolved since last review

- **`reconcile/2` is genuinely retire-only on the span now.** The count-clamp
  clause (old `when offset < from + count -> %{state | span: %{from: from, count: offset - from}}`)
  is DELETED. The three surviving clauses (`unread_divider.ex:245-262`) can only:
  (1) clear the whole span when `offset <= from` (retire), (2) pull an away
  `boundary` down when `boundary > offset` (span is always `nil` while `:away`,
  so this never touches a span), or (3) return state verbatim. No clause moves
  `span.from` forward or grows `span.count` -- confirmed by the "growth never
  inflates the frozen count" test (`unread_divider_test.exs:303`) and by direct
  trace: `blur(2)|>focus(8)` = `%{from:2,count:6}`, then `reconcile(_, 9)` still
  `%{from:2,count:6}`. Re-marking of already-read blocks via a *forward-moving*
  span is now structurally impossible in reconcile.

- **The under-count-on-transient-dip artifact is fixed.** Because state is never
  count-clamped, a dip is display-only: `blur(5)|>focus(8)|>reconcile(6)` keeps
  `%{from:5,count:3}` in state; `divider/2` paints `count:1` at offset 6 and
  recovers `count:3` at offset 8 (`unread_divider.ex:280-286`, pinned by
  `unread_divider_test.exs:259` and `:243`). The old bug (freezing `count:1`
  forever, lying low after regrowth) is gone.

- **Display clamp (`divider/2`) is correct and total.** Three clauses:
  `offset <= from -> nil`; `from < offset < from+count -> %{from, count: offset-from}`
  (always `pos_integer`, since `offset > from` strictly in this branch); else the
  frozen span. Bounds render to reality without mutating stored state, and
  `viewed/2`'s gate keeps using the unclamped `span.from`, so navigation and
  display stay consistent. Reconcile and display share the same `offset <= from`
  retire threshold and the same per-advance offset (`length(projection.blocks)`),
  so no render-vs-state divergence: `surface.ex:1600-1626` reads
  `divider(model.unread, unread_offset(model))` with the identical offset that
  `reconcile_unread/1` threaded in `advance/2`.

### Low

- **The `blur(5)+shrink-to-3+regrow+focus(8) -> %{from:3,count:5}` over-report
  is NOT fixed -- it is now accepted and documented as intentional (reproduced).**
  Traced and confirmed still live: `new()|>blur(5)|>reconcile(3)|>focus(8)|>divider()`
  == `%{from:3,count:5}`, pinned as a *passing* test at `unread_divider_test.exs:277`.
  The away-boundary pull (`reconcile/2` clause 2, `unread_divider.ex:255-260`)
  drags `boundary` from 5 down to 3, so the next `focus` re-marks indices 3..4 as
  new. This is now argued as the deliberate fail-safe direction: for an unread
  marker, over-reporting (re-marking read content) is safe, under-reporting
  (hiding unread content) is not. The reasoning is principled -- without the pull,
  a shrink-then-regrow with genuinely new low-index content would UNDER-report,
  which is the worse direction -- and the caveat is now honestly documented
  (moduledoc "Defensive boundaries", `unread_divider.ex:97-104`) and pinned.
  I accept it as a documented tradeoff rather than an open defect, but flag that
  the task's "no longer re-marks read blocks" bar is met only in the reconcile
  path, not the away-pull path; the over-report remains reachable by construction.

- **Feature still DORMANT at runtime (honest).** `Surface.blur/1` still has zero
  production callers; `input_activity/2` fed on every keystroke can only CLOSE an
  away state, never open one, so the machine never leaves `:attending` in the
  running harness and the divider never renders outside the test suites. Documented
  plainly in both moduledocs ("DORMANT TODAY", "INERT at runtime until that unit
  lands"). Out of scope to wire; noted for honesty, no dishonesty found.

### New Hire

- No render/state desync introduced by moving the clamp to display time.
  `viewed/2` (`unread_divider.ex:227-233`) gates on `span.from` from *state*, which
  is never mutated by the display clamp, so a dipped paint (`count:1`) and a
  navigation-to-boundary still agree on the same `from`. Post-reconcile the
  surviving-span invariant `from < offset` holds (retire fires at `offset <= from`),
  so `viewed/2` reachability is preserved -- no stuck-divider regression. Verified
  green by `unread_divider_test.exs:228` ("reconciliation restores viewed/2's
  reachability invariant").

### Security Auditor

- No new attack surface. The only externally-influenced quantity remains the
  render width, still clamped to `@max_rule_width` (1024) before any
  `String.duplicate/2` (`unread_divider.ex:315`, `pad_with_rule/2`), unchanged by
  this commit. `divider/2`'s new arithmetic (`offset - from`) is bounded to
  `(0, count)` by its own guards, no overflow/negative path. Output still routes
  through the `ViewText` sanitize/truncate seam (`surface.ex:1610`), and the
  no-C0/no-escape property test (`unread_divider_test.exs:382`) still passes.

### Verdict: CLEAN

The commit does exactly what it claims: `reconcile/2` is retire-only on the span
(no forward `from`, no `count` growth -- structurally verified), the transient-dip
under-count is fixed by moving the clamp read-only into `divider/2`, and the
display clamp is correct with no render-vs-state divergence. The one residual
item -- the away-boundary-pull over-report -- is a principled, documented,
test-pinned fail-safe rather than an open defect, and the feature's runtime
dormancy is disclosed honestly. 48/48 divider tests pass locally.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #617 — Harness UI: grade transcript blocks by turn recency into prominence
State: MERGED (merged 2026-07-17T05:25:19Z)
Drew entries: 4

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T23:22:55Z

## Adversarial Review (automated)

Scope: the single PR commit `2787ede8` -- `lib/raxol/harness/recency_policy.ex` (new pure policy), the 10-line `surface.ex` wiring, and `test/harness/recency_policy_test.exs`. The pure module is well-guarded: every branch resolves toward `1.0`, output is always in `{1.0, 0.8, 0.6, 0.4}`, and `grade_block/2` never raises on empty/missing/non-map/nil input (verified by running the module against crafted inputs). The findings below are correctness-intent and quality concerns, not crashes.

### Medium

- **[Saboteur] medium** `lib/raxol/harness/recency_policy.ex:225-231` (`block_turn_of/2`) + `test/harness/recency_policy_test.exs:169` -- The ladder INVERTS for the oldest blocks. A block whose `event_refs` resolve to nothing in `source_events` grades `1.0` (loudest). But `Projection` deliberately strips events: `projection.ex:207` rejects every `:ephemeral`-tier event from `source_events`, and the moduledoc itself calls these the "retained durable events" (a bounded set). So a block that references only ephemeral/aged-out events -- precisely the OLDEST content the fade is meant to dim -- renders at full prominence on any full re-render / reattach rebuild (the exact "multiple turns painted in one pass" path the moduledoc says the ladder is visible on). Reproduced: `grade_block(%{event_refs: [100]}, [%{id:1,turn_id:"t9"},%{id:2,turn_id:"t9"}]) => 1.0` (reproduced). The PR's own test at line 169 codifies this as intended. "Uncertainty never darker" is a reasonable principle, but here it produces the opposite of the feature's goal for the blocks it matters most on. Fix: distinguish "unknown turn" (grade 1.0) from "turn known to be older than the retained window" (grade at floor) -- e.g. when `current_turn` resolves but the block turn does not, treat it as maximally-behind rather than current.

### Low

- **[Saboteur] low** `recency_policy.ex` (whole module) + `lib/raxol/ui/components/harness/block.ex:483` -- The unqualified claim "approvals never buried" (PR title/description) overstates the code. This policy has zero approval handling; it grades an approval purely by recency. The floor is entirely downstream and engages ONLY for a LIVE approval (`block.kind == :approval and block.seal == :live`, block.ex:483) and only floors to `0.6` (not "loud"). A resolved/sealed approval fades to `0.4` like any other block. So the true guarantee is "PENDING approvals render no dimmer than 0.6." The moduledoc is accurate (it consistently says "live"/"pending"); the PR-description phrasing is not. Fix: qualify the claim, or state that resolved approvals fade by design.

- **[New Hire] low** `recency_policy.ex:16-24` (moduledoc ladder) -- The four magic tiers (`1.0/0.8/0.6/0.4`) and the "3+ floor" have documented WHAT but no documented WHY: why 0.2 perceptual steps, why the floor sits at 0.4 rather than 0.3/0.5, and why exactly three tiers of fade. A maintainer tuning these has no rationale to reason against. One sentence on the perceptual basis (or a pointer to the #604 salience mapping that consumes them) would close it.

- **[New Hire] low** `recency_policy.ex:169-180` (`grade/2`) -- `grade/2` trusts that `turn_ids` list order == chronological order ("first-seen position"), with no validation. A caller that passes turns in any other order silently mis-grades. Reproduced: `grade([:t3,:t1,:t2], :t2) => [0.6, 0.8, 1.0]` -- `:t3` is graded OLDEST purely because it appears first (reproduced). `grade_block/2` inherits the same trust in `source_events` order via `current_turn_of/1` (last non-nil = "newest"): with events newest-first, `grade_block(%{event_refs:[1]}, [%{id:2,turn_id:"t2"},%{id:1,turn_id:"t1"}]) => 1.0` (reproduced). This is safe only because `source_events` happens to be ingest-ordered; the load-bearing assumption is undocumented at the wiring call site (`surface.ex:923`).

- **[Security Auditor] low** `recency_policy.ex:196-204` (`grade_block/2`) + `lib/raxol/harness/surface.ex:923` -- Unbounded re-scan per seal. `grade_block/2` walks ALL of `source_events` three times (`Enum.filter` + `turn_order`'s map/uniq + `Enum.find` for the block turn), and it is invoked once per block from `render_block_lines/3` inside `paint_pending_blocks/1`. Since `source_events` retains every durable event for the whole session (only ephemeral rejected) and grows without bound, sealing the Nth block costs O(retained events so far). Over a long session that is roughly O(turns^2); a single full repaint/reattach rebuild is O(blocks x durable_events). Not a security hole (range-safe, no user-controlled unbounded allocation), but a scaling concern on the hot paint path. Fix: compute the turn `order` + `current_turn` once per paint pass and pass them into a per-block grade, instead of re-deriving from the full event list for every block.

### Cross-persona overlaps

The Saboteur "reversed/aged-out events mis-grade" finding and the New Hire "grade/grade_block trusts list order" finding share one root: **the chronological ordering (and completeness) of `source_events` is load-bearing but neither validated nor documented at the wiring point.** Both the ladder-inversion (medium) and the order-trust footgun (low) collapse if `source_events` is ever reordered or windowed. Promoting the shared root: the policy should either assert its input-ordering contract or derive recency from an explicit turn timeline rather than incidental list position.

### Verdict: CONCERNS

No blocker: the pure module is defensively written, cannot crash on the probed inputs, and produces only in-range prominence values that the downstream `Prominence.resolve/3` additionally clamps. But the feature's central intent is undercut at its edges -- the oldest blocks can grade loudest when their events age out or are ephemeral (medium), the headline "approvals never buried" claim is broader than the code guarantees (low), the tier values lack rationale (low), and the seal path re-scans unbounded history per block (low). Address the ladder-inversion and the ordering contract before relying on this in long or reattached sessions.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — PR COMMENT — 2026-07-16T23:37:24Z

pls address above

### Round 3 — REVIEW | review_state=COMMENTED — 2026-07-17T00:10:35Z

## Adversarial Re-review (automated)

Since last review: 2787ede8..bee31eff

Scope: `bee31eff Address adversarial review: input contract, ladder rationale, one-pass grading`. Verified against `lib/raxol/harness/recency_policy.ex`, `lib/raxol/harness/surface.ex`, `lib/raxol/harness/projection.ex`, `projection/block_builder.ex`, `ui/components/harness/block.ex`, `ui/harness/prominence.ex`, and the new `test/harness/recency_policy_test.exs`. The pure module was extracted and run standalone to reproduce the disputed scenarios.

### Resolved since last review

- **The MEDIUM inversion is genuinely neutralized (not just documented).** I traced the invariant the rebuttal rests on and it holds end to end:
  - `projection.ex:207` retains `source_events` as `Enum.reject(id_ok, tier == :ephemeral)` -- every durable event, **un-windowed**. Grepped the whole `lib/raxol/harness/` tree: there is no `take`/`slice`/`window`/`drop`/cap applied to `source_events` anywhere.
  - Block `event_refs` are durable-only: `block_builder.ex:349` `source_events/1` flat-maps only `group.started`/`group.completed` (item_started/completed, approval_requested, error), never `item_delta`; `block.ex:743` sets `event_refs` to exactly those events' `:id`s. So `item_delta` (ephemeral, stripped at 207) never enters a block's refs -- the claim "ephemeral events never enter event_refs" checks out.
  - `surface.ex:676-679` re-projects over a growing **prefix** (`Enum.take(model.events, revealed)`), so `source_events` grows monotonically and never drops an older durable event.
  - Empirical (pure module, standalone run): a 5-turn full re-render where all refs resolve grades `[0.4, 0.4, 0.6, 0.8, 1.0]` -- oldest **dim**, newest **loud**, the correct direction. This is exactly the "reattach / full re-render" case the prior MEDIUM said would invert; it does not. Test E asserts the same over real `projection.blocks`.
- **Input-contract / ordering LOW resolved (documented).** `grade/2` now states "Caller contract (load-bearing): `turn_ids` must be in transcript order"; `grade_block/2` documents the journal-order + durable-completeness precondition and ties it to `Recovery.filter_ids/1` id-monotonicity. The prior "load-bearing source_events ordering undocumented" is addressed.
- **Ladder-rationale LOW resolved (documented).** New "Why these values (the ladder's provenance)" moduledoc section pins the tiers to the existing `Prominence` ladder under a no-new-tiers fence.
- **"Approvals never buried" overstatement corrected in code/commit.** The moduledoc "Composition with the needs-input floor" section and `block.ex:110-111` now state it accurately: the floor engages only for a **live** `:approval` (`needs_input: true`) and floors to 0.6; "a sealed approval is an answered question and fades free." Test F proves the composition at the `Prominence` layer. My prior objection (policy has no approval logic; the floor is downstream, live-only, 0.6 not loud) is now explicitly acknowledged.

### LOW

- **The inversion is safe only by an unenforced invariant (reproduced, downgraded).** The `grade_block/2` function itself is unchanged: an unresolvable/ephemeral-referencing block still returns `1.0` (loud) -- I reproduced this directly (`grade_block(%{event_refs: [9991,9992]}, events) => 1.0`). It is unreachable today *only* because `source_events` is un-windowed and refs are durable-only. Nothing asserts that at runtime. The day someone bounds `source_events` for memory on long sessions (line 207 is the obvious spot), or a partial/suffix refold feeds a windowed list while older blocks persist, the inversion returns silently as loud old scrollback -- the exact original failure. A cheap defense (e.g. grade `nil`-block-turn-from-nonempty-events toward the floor rather than 1.0 when the current turn *is* resolvable, or a debug assertion that graded blocks' refs are a subset of `source_events` ids) would make correctness independent of the retention policy. Documented contract is not the same as an enforced one.
- **"One-pass" collapses the constant factor, not the asymptotic cost (reproduced).** `scan_events/2` is now a single reduce (3 walks -> 1) -- confirmed, and the commit message is honest that this is "constant-factor." But `grade_block/2` is still called once per newly-sealed block from `render_block_lines/3`, and each call re-scans **all** of `source_events` to recompute `order` + `current_turn` -- which are **identical for every block in a given projection**. Only `block_turn` is block-specific. So the prior "O(blocks x durable_events)" finding stands asymptotically; the real fix is a batch `grade_blocks(projection.blocks, source_events)` that walks events once (O(events + total_refs)) and then indexes per block. The one-pass change did not capture that larger win. Minor amplifier: `Map.get(event, :id) in refs` is an O(refs) list scan inside the per-event reduce.
- **The live-approval guarantee is forward-looking at the sole wiring point.** `BlockBuilder` builds every projection block `seal: :sealed` (`block_builder.ex:334`); the only grade wiring point, `render_block_lines/3`, runs from `seal_block/2` over those sealed blocks, and `live?/1` is false for them. So the needs-input floor never engages on the path recency actually feeds -- live approvals live in the tail, which this policy does not grade. The composition is real at the `Prominence` layer (Test F) but is not exercised end-to-end through the shipped wiring; the guarantee is a promise for a future live-rendering surface, not this fixture-replay one. Worth a one-line scope note alongside the existing "Coverage today" caveat.

### Security notes (no findings)

Pure prominence arithmetic: grade only selects one of four fixed floats, downstream-clamped by `Prominence`; the SGR hex comes from a fixed palette, not from `turn_id`. `turn_id`s are compared with `==` only -- no `String.to_atom` on wire data, no atom-table growth. The one cost-side observation ties to the LOW above: the un-windowed `source_events` that makes the inversion safe is the same thing that makes each grade call O(durable_events) in time and build an O(distinct-turns) MapSet -- on a long adversarial transcript, grading is unbounded-cost by construction. Correctness and cost are coupled to the same retention decision.

### Verdict: CONCERNS (LOW only -- effectively shippable)

The MEDIUM inversion is genuinely resolved: verified by the un-windowed/durable-only invariant and demonstrated correct-direction by the shipped 5-turn test, not merely re-documented. The two documentation LOWs are closed and the "approvals never buried" overstatement is corrected in code. Remaining items are non-blocking residuals -- an unenforced safety invariant, an asymptotic-cost opportunity the one-pass change left on the table, and a forward-looking approval guarantee -- none of which need to gate merge. Recommend a follow-up to make the anti-inversion invariant self-defending (assertion or floor-on-known-current) before `source_events` ever gains a retention bound.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 4 — REVIEW | review_state=COMMENTED — 2026-07-17T00:34:42Z

## Adversarial Re-review (automated)

Since last review: bee31eff..f4c5caa0

Scope: verified the three LOW residuals from my prior re-review against commit
`f4c5caa0` ("Address re-review residuals"). Ran the pure module + full test file
in an isolated worktree at the PR head (removed after); main checkout untouched
on master. All 19 tests green as shipped.

### Resolved since last review

- **Unenforced anti-inversion invariant -> now an ENFORCED tripwire.**
  `test/harness/recency_policy_test.exs:306` walks every shipped fixture and
  asserts each block's `event_refs` resolve in `projection.source_events`, with
  `:322` a negative control proving a windowed tail degrades an old block to
  `1.0` (loud). I reproduced the regression it guards: patching
  `lib/raxol/harness/projection.ex:207` to window `source_events`
  (`|> Enum.take(-3)`) turns the tripwire **red** with the exact documented
  message -- `"long-folds: block [2, 3, 4, 5] resolves no ref in source_events
  -- the un-windowed durable retention invariant broke ... recency grading would
  silently return 1.0 (loud) for this block"` (7 tests fail total). (reproduced)
  This is a genuine assertion, not a comment: the day someone bounds
  `source_events` for memory, CI goes red before old scrollback can silently
  grade loud. Resolved.

- **"Approvals never buried" now correctly scoped (live-only 0.6 floor).**
  The moduledoc's "Composition with the needs-input floor" section now states
  the floor lives one layer below (`Raxol.UI.Harness.Prominence.resolve/3`,
  `needs_input_floor/0` = 0.6 at `prominence.ex:149`), engaged only by a *live*
  `:approval` block, and adds an honest scope note that on today's sole wiring
  point (the fixture-replay seal path) the composition is dormant -- a live
  approval is held in the repaintable footer by the seal frontier and never
  reaches the graded seal path. Test F (`recency_policy_test.exs:~558`) verifies
  the floor byte-exact at the Prominence layer. Fair and accurate. Resolved.

- **One-pass batch API added, equivalence-law tested.** `grade_blocks/2`
  derives turn order + current turn + an id->{pos,turn} index in a SINGLE walk
  (`index_events/1`), then resolves each block in `O(its refs)`; the equivalence
  law `grade_blocks == Enum.map(&grade_block/2)` is asserted at
  `recency_policy_test.exs:703` and passes. I checked `index_events` vs
  `scan_events` for semantic drift (duplicate ids, arbitrary ref order): both
  select the minimum-event-position turn whose id is in `refs`, so they are
  equivalent regardless of ref order -- no new bug from the refactor, and no
  stale-order risk (order is recomputed fresh per call, never cached).

### Low

- **The batch API is currently dead code -- the wired path's complexity is
  unchanged.** `grep` for `grade_blocks` finds no in-tree caller; the only
  render-path call is still per-block `grade_block/2` at
  `lib/raxol/harness/surface.ex:930`. This is defensible and documented (the
  incremental seal path seals a bounded number of blocks per `advance/2`, so it
  was never `O(blocks x events)` per pass), but a reader expecting the "batch
  grading" fix to have dropped the *wired* path's cost will not find it: the
  batch form is a correct-but-unconsumed seam awaiting the full-re-render /
  reattach-rebuild caller the moduledoc names. Not blocking; flagging so the
  seam is wired (or the "batch grading fixes the rescan" framing is scoped to
  "for the future bulk consumer") rather than bit-rotting.

- **Security/DoS note: the honest-grading invariant now forbids the natural
  memory bound.** `projection.ex:207` retains EVERY durable event un-windowed
  for the session lifetime, and `grade_block/2` re-walks that whole list on each
  seal (`surface.ex:930`, `O(events)` per sealed block). The tripwire correctly
  makes bounding `source_events` a red-CI decision, but there is no bound today,
  so a long session grows `source_events` monotonically and the per-seal grade
  cost grows with it -- and the one lever that would soften the re-walk
  (`grade_blocks/2`) is unwired. Correctness is fine; this is a memory-pressure /
  amortized-cost seam to keep on the radar, not a vuln.

### Verdict: CLEAN

All three prior LOW residuals are resolved or made honest: the anti-inversion
tripwire genuinely enforces the invariant (reproduced red under a windowed
`source_events`), the approval floor is correctly scoped to the live-only 0.6
Prominence tier, and the batch API is a correct, equivalence-tested one-pass
seam. The two remaining items are LOW and non-blocking: `grade_blocks/2` is an
unconsumed seam (wired path unchanged, per a documented bounded-per-advance
argument), and the un-windowed retention it depends on is an unbounded-growth
seam the tripwire now protects but does not cap. Nothing blocking; shippable.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #618 — Harness UI: stable-prefix streaming markdown (O(N^2) -> O(N))
State: OPEN
Drew entries: 3

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T23:30:23Z

## Adversarial Review (automated)

Reviewed the stable-prefix boundary logic in `lib/raxol/ui/components/harness/markdown_body.ex` against its full-re-parse oracle. Headline result up front: **no stable-prefix-vs-full-reparse divergence was found.** I streamed 20 hand-crafted non-local inputs byte-by-byte (setext-shaped `text\n===`, a later link-reference definition, lazy continuations, blockquote/list continuation, list tightness, tables with header/separator/growing-column-width across the freeze boundary, pipe-in-prose then separator, fence-then-table, indented fences, emphasis spanning a fence, CRLF tables, consecutive tables) and every prefix compared equal to `render(text, %{mode: :streaming})`. The PR's own suite is 23/23 in the test env, and I confirmed it is non-vacuous there (EarmarkParser is absent under `MIX_ENV=test`, so the `frozen_offset > 0` assertions genuinely exercise the incremental branch).

Why the central non-locality risk does not materialize: the correctness oracle is itself the deliberately line-local builtin grammar (`MarkdownRenderer.render_with_builtin/2`). It does not implement setext headings, link reference definitions, lazy continuation, or list tightness at all -- a `---` line is always a thematic break, `[id]: url` is always a paragraph, each line parses independently. The only multi-line constructs are fenced code blocks and GFM tables, and the boundary rule (both fence machines closed + pipe-free last line + empty inline stack) correctly severs both. The "per-construct immutability proof" is therefore sound *for this oracle* -- but its validity rests on the oracle's weakness, not on general Markdown immutability, and the moduledoc frames it in full-CommonMark terms without saying so (see New Hire below).

### HIGH

- **[Saboteur + Security Auditor] HIGH (reproduced)** markdown_body.ex:411 (`find_safe_boundary/3`) + :459 (`safe?` requires both fence machines closed) -- The optimization is fully defeated by two common, content-controlled shapes, restoring O(N^2) parse-per-delta for the whole message:
  - An unclosed fenced code block: streaming ```` ``` ```` + 200 code lines (2695 chars) kept `frozen_byte_offset = 0` at every prefix (reproduced). Until the closing fence arrives, every delta re-parses the entire growing buffer. This is exactly the most common large streamed payload (an LLM typing out a big code block) and exactly when quadratic cost bites.
  - Newline-free content: a 2500-char single line with no `"\n"` (200 complete lines == 0) kept `frozen_byte_offset = 0` throughout (reproduced) -- `find_safe_boundary/3` returns `nil` whenever there is no committed newline.
  Because the streamed body is untrusted (LLM / remote) content, a caller can hold the render path at O(N^2) with a trivially-shaped message; on this streaming transcript surface (which ships a stall/doom-loop detector) that is a client-driven CPU-amplification lag vector. Two personas, same root -> promoted. Caveat stated honestly: this degrades to the *pre-PR* behavior, never worse, so it is a "the fix does not help precisely when it is needed" finding rather than a regression. Fix: freeze *inside* a still-open fence up to the last committed fence-content line (a closed fence's prefix bytes are immutable; the content lines already parsed are equally immutable), and add a boundary candidate at a hard-wrap point / max-tail-length so a newline-free tail cannot grow unbounded before the first freeze.

### MEDIUM

- **[New Hire] MEDIUM** markdown_body.ex:313 (`if Code.ensure_loaded?(EarmarkParser)`) -- The entire subject feature is silently inert whenever the `EarmarkParser` module is loadable. That is the case in `:dev` (ex_doc pulls `earmark_parser`, confirmed `_build/dev/lib/earmark_parser` present) and in any downstream consumer of the `raxol` hex package that has earmark loaded for its own reasons (ubiquitous). In those environments `render_streaming_incremental/3` always returns a fresh checkpoint and a full re-parse. The gate is *correct* (the frozen elements come from `render_with_builtin/2`, but the oracle's `render_via/2` prefers Earmark, so their outputs would not match), and prod is fine because ex_doc is `only: :dev, runtime: false` so earmark is absent there. But keying activation on global module presence is surprising and untested on the "present" side: the property test only runs where earmark is absent, so the branch a docs-tooling dev actually hits (plain full-reparse) is never asserted, and nothing documents that the optimization is off in dev. At minimum document this; better, make the streaming oracle and the incremental frozen render use the *same* renderer unconditionally so the two can never disagree by construction.

- **[New Hire] MEDIUM** markdown_body.ex (moduledoc "checkpoint rule", lines 139-169) -- The immutability proof is written in general-CommonMark vocabulary (fences, tables, "single-line constructs ... this grammar nests only via fences and tables") but its soundness depends entirely on the oracle being the weak line-local builtin grammar. A reader could reasonably conclude the boundary logic is safe against a real Markdown parser; it is not (setext/ref-defs/lazy-continuation would each break a frozen prefix). The doc should state that the invariant is "equals the builtin full re-parse," and that this is precisely why the EarmarkParser gate at :313 exists -- the two facts are presented pages apart and never connected.

- **[Saboteur] MEDIUM** markdown_body.ex:366 (`cp.frozen_elements ++ tail_elements`) and :394 (`cp.frozen_elements ++ seg_elements`) -- The PR title's "O(N^2) -> O(N)" holds only for *parse* work. View assembly appends the whole frozen-elements list on every delta (O(E) per delta -> O(E*N) over a turn), and each freeze copies the whole accumulator again; asymptotically the render path is still quadratic in element count. The measured 46.5x win is real because a list cons is far cheaper than regex parsing, but the asymptotic label overstates it. Prepend-and-reverse or an iodata/rope accumulator would make the claim true.

### Checked and clean (Security Auditor)

- Frozen-prefix sanitization is NOT bypassed. Streaming `"hello \e]0;pwned\a world\n..."` froze the ESC/OSC line (`frozen_byte_offset = 53`) yet the rendered frozen output contained no ESC (`\e`) and no BEL (`\a`) byte -- the frozen segment is a byte-slice of `to_text(raw_tail)`, so `sanitize_controls/1` has already run before anything is frozen. No ANSI-injection escape via the stable prefix. The 256KB cap is applied to the sanitized total at both sites and resets the checkpoint above it, so the frozen-elements list cannot grow unbounded.

### Cross-persona overlaps

- The O(N^2)-restoration via unclosed-fence / newline-free content was reached independently by Saboteur (resource exhaustion / cascading lag) and Security Auditor (untrusted-content-controlled CPU amplification). Same root at markdown_body.ex:411/:459 -> promoted MEDIUM -> HIGH.

### Verdict: CONCERNS

No CRITICAL and no correctness divergence: the stable-prefix view is byte-for-byte equal to the full re-parse oracle across every probe and the PR's non-vacuous property suite. Merge-blocking-wise this is safe. The concerns are (1) the optimization silently disengaging to O(N^2) for the most common large streamed payload (an unclosed/streaming code block) and for newline-free content -- a content-controllable lag vector that should at least be documented and ideally mitigated by freezing committed fence-content lines, and (2) the environment-dependent activation gate plus the overstated asymptotic claim, both of which are documentation/coupling smells rather than defects. Address the HIGH before relying on this in the streaming path.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-16T23:43:27Z

## Adversarial Re-review (automated)

Since last review: baa0f3c3..f816adab

Scope: `f816adab` touches ONLY the perf test file (46+/31-, `git show --stat`); `markdown_body.ex` is byte-identical to the prior review. So this pass judges the re-instrumentation, and re-checks which prior findings the test change does (not) close. Reproduced in a worktree off `f816adab` with `deps`/`_build` symlinked; full `markdown_body_stable_prefix_test.exs` is green (23 passed, 2 properties).

### Resolved since last review

- **MEDIUM (wall-clock flakiness) — resolved, and improved.** The cumulative 2000-delta test dropped the `elapsed_us < 2_000_000` assert for a deterministic work metric: per delta it sums `byte_size(acc) - cp.frozen_byte_offset` (the live tail past the checkpoint) and bounds the total at `4 * byte_size(doc)` (test lines ~488-525). This is runner-independent (a byte count cannot flake under CI load) and NON-vacuous: I confirmed the same metric separates the happy path (~2x, well inside 4x) from a quadratic shape by 100x+ (see reproduction below). The lone remaining wall-clock assert is the `:slow`-tagged before/after receipt, excluded from default runs. Test-group labels de-codenamed (SP-* -> plain English). Good change.

### HIGH (carried, unchanged by this commit)

- **Oracle-contingency caveat still unstated.** The equivalence "proof" holds only because the correctness oracle is the deliberately line-local builtin grammar (no setext headings, ref-defs, lazy continuation, list-tightness). The moduledoc still never states this contingency, so a future grammar that adds any cross-line block construct would silently break the freeze rule. `f816adab` is test-only and does not touch this.

### MEDIUM

- **Unclosed-fence / newline-free-line O(N^2) degradation — NOT addressed, only the happy path was re-instrumented. (reproduced)** The new work metric is exactly the right lens to expose this degradation, but the perf suite only ever feeds it a well-formed doc (`perf_doc/0`: 1000 blank-line-separated paragraphs) where every blank line is a safe boundary, so it lands ~2x and passes. Applying the PR's OWN metric to a 1000-line never-closed fence streamed line-by-line:
  ```
  [UNCLOSED FENCE] doc=23897B  total_tail=11912892B  ratio=498.5x  final_offset=0
  ```
  498.5x vs the 4x bound, with `frozen_byte_offset` pinned at 0 for the entire stream — fully quadratic, on the single most common streamed payload (an LLM typing a code block). Root cause unchanged: `find_safe_boundary` refuses any boundary while either fence machine is open (`markdown_body.ex:448-449`), so an open fence freezes nothing. The regression is thus neither fixed nor documented by a test; the new metric makes it trivially measurable but is pointed only at the case that never triggers it. Adding one degenerate-stream case to the perf describe (asserting it stays no *worse* than pre-fix, i.e. bounded reparse) would at least document the ceiling honestly.

- **`Code.ensure_loaded?(EarmarkParser)` gate still makes the optimization inert whenever earmark is loaded — NOT addressed.** `markdown_body.ex:313`: when `EarmarkParser` is loaded, `render_streaming_incremental` does a full `render(text)` every delta and returns `new_checkpoint()` (offset stays 0) — O(N^2) fully preserved. `ex_doc` (which pulls `earmark_parser`, confirmed present in `deps/`) is `only: :dev` (`mix.exs:297`), so the fast path runs in `:test`/`:prod` but is dead in `:dev`. Consequence: every test in this PR validates only the earmark-absent branch; the earmark-loaded (dev) branch — where a developer watching the harness stream gets the quadratic path — has zero coverage. No test asserts which branch is taken.

- **Title overstatement persists.** "O(N^2) -> O(N)" is stated unconditionally; it holds only for well-formed streams in non-dev envs. The 498.5x reproduction and the dev gate above are both live counterexamples.

### LOW (Saboteur)

- **The work metric is self-reported, not independently observed.** It reads the checkpoint's own `frozen_byte_offset` — the very field the implementation both emits and uses to slice the reparse tail — rather than instrumenting actual parser input size (e.g. counting bytes handed to the tail parser). It is a self-consistency check: an implementation bug where the reported offset diverges from the real reparse extent would sail through the perf gate. The equivalence oracle guards correctness, not this, so the gap is narrow, but the metric is circular w.r.t. the field it validates.

### Verdict: CONCERNS

`f816adab` does exactly what its title claims and does it well: the perf pin is now deterministic and meaningfully tight. But it is a test-hardening commit, not a fix — the two substantive MEDIUMs from the prior review (unclosed-fence O(N^2) degradation; dev-inert earmark gate) and the title overstatement are all untouched, and the degradation is now demonstrably 498x under the PR's own metric while sitting outside the perf suite's inputs. Net position is unchanged from the prior review: correct, but overclaimed and with a known quadratic path left in for the commonest streamed payload.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 3 — REVIEW | review_state=COMMENTED — 2026-07-17T00:35:15Z

## Adversarial Re-review (automated)

Since last review: f816adab..ea006a80 (`Freeze committed content lines inside a still-open fence`).

Verified in an isolated worktree at `ea006a80`, `MIX_ENV=test` (confirmed `Code.ensure_loaded?(EarmarkParser) == false` in the test env, so the incremental path is genuinely exercised rather than delegating to the full re-parse). All 28 stable-prefix tests pass (2 properties, 26 tests).

### Resolved since last review

- **MEDIUM (was reproduced twice) -- open-fence O(N^2) blow-up on streaming code blocks is FIXED. (reproduced)** Re-ran the 1000-line never-closed fence under the PR's own parse-work metric (cumulative live-tail bytes re-parsed): prior review measured ~498x the doc size; this commit measures **1.0x** (52913 re-parsed bytes vs 52903 doc bytes), with `frozen_byte_offset` tracking to the final byte (52903 of 52903). The quadratic PARSE term is gone for the commonest streamed payload.
- **No stable-prefix-vs-full-reparse correctness divergence introduced by freezing inside an open fence.** This was the primary new risk. The structural precondition holds: `MarkdownRenderer.fenced_code_elements/2` (markdown_renderer.ex:647-658) maps each code line independently to `"  " <> line` with no cross-line width normalization -- unlike the table renderer, a later/longer content line cannot rewrite an earlier one, so committed fence-content lines are genuinely immutable. Evidence:
  - 15 directed adversarial cases at char granularity -- all pass: close-then-reopen with differing info strings, ``` -> ```` growth, ```` -> ``` , indented fence under a list, blank lines inside an open fence, mismatched `~~~` inside a ``` fence, tilde fence, weird info attrs, pipes/table-shaped/heading/hr/blockquote lines inside a fence, zero-content close, empty reopen, CRLF-inside-fence, indented-content-then-dedent-close, adjacent fences.
  - **4000 randomized fence-heavy runs** with byte-granular chunking (cuts mid-grapheme / mid-marker): **0 divergences** against the full-reparse oracle at every prefix.
  - The `{opener, drop_count}` reconstruction (`opener <> "\n" <> tail`) is sound because the frozen content lines provably contain no closer (else the fence would have closed and `open_fence` cleared), so `take_until_fence` over the identical tail yields identical elements; the leading blank+label are emitted once (drop_count=0 on the opening segment, dropped on later ones) and the zero-content phantom guard is exercised and correct.

### Low

- **Title still overstates; API is unwired, so no runtime path yet benefits.** `grep` for `render_streaming_incremental` / `new_checkpoint` finds **no caller outside markdown_body.ex** -- the moduledoc names wiring `BodyProvider` as "the follow-up seam this module leaves open." The live harness still calls `render_streaming/2` fresh each delta, so the product-level O(N^2) the title advertises is unchanged in the running app until a follow-up wires the checkpoint. The PR delivers correct, well-tested machinery; the title "(O(N^2) -> O(N))" describes a capability nothing consumes yet.
- **Two residual degradations remain O(N^2) (documented, correct, cap-bounded).** (reproduced) Newline-free content: streamed a 1500B single-line doc -> work 225750 == naive 225750, `frozen_byte_offset` stays 0 (150.5x), but output never diverges from the oracle. Correctly justified as semantically un-freezable (a line's own wrapping/emphasis/table detection changes as it grows) and pinned by a named test to `work == naive_work`, never worse, bounded by the 256KB cap. Garbage-byte content degrades likewise. Both are honest residuals, not defects.
- **Earmark-inert caveat now documented, scope confirmed narrow.** `ex_doc` (hence `EarmarkParser`) is `only: :dev, runtime: false` (mix.exs:297), so a release/production harness does not load it and the optimization is live there. The inert path only bites in dev or in a downstream consumer that itself loads earmark at runtime -- now explicitly documented in the "Scope of the immutability proof" moduledoc section with a sound rationale (avoids streaming/sealed reformat disagreement). Prior MED note effectively addressed.

### Verdict: CONCERNS

The commit does exactly what it targets: the streaming-code-block O(N^2) is eliminated (498x -> 1.0x, reproduced) and freezing inside an open fence introduces **no** correctness divergence across directed cases, a 4000-run fence fuzz, and the PR's property suite. Non-blocking concerns stand: the incremental API has no runtime caller (title advertises an unrealized product win), and the newline-free/garbage residuals plus the downstream-earmark-inert path remain -- all documented and correct, none a defect in this commit.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #619 — Harness UI: evidence-rendered done (a completion claim is only as good as its refs)
State: OPEN
Drew entries: 2

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-16T23:47:54Z

## Adversarial Review (automated)

Scope: the completion-evidence feature only (commit 1de5b335). Reviewed against the
producer it grounds against (`DoneGate` / `Contract.gated_done_payload/4` in
`packages/raxol_agent`) plus the block/block_body render path. One positive up front:
the untrusted-content ANSI vector IS handled -- `sanitize_completion_label/1`
(`block_builder.ex:447`) strips ESC/0x1B and every C0 byte + DEL byte-wise, then
`TextLayout.truncate/3` clamps to 32 display columns, so no ANSI/escape injection reaches
a block through a ref label. No crash/raise paths found. The findings below are about the
*honesty guarantee*, which is materially weaker than the framing claims.

### HIGH

- **[Security Auditor] high** `lib/raxol/harness/projection/block_builder.ex:333-341,349-361` --
  Ref resolution re-validates NONE of the gate's acceptance rules. `resolve_completion_entry/3`
  and `ref_type/2` do a single `Map.get(session_index, ref)` (existence-only) and render whatever
  the id resolves to as proven evidence. The producer's `DoneGate.gate/3`
  (`packages/raxol_agent/lib/raxol/agent/done_gate.ex:257-267`) rejects `:not_evidence`,
  `:foreign_turn`, `:stale_evidence`, and `:mutation_echo`; the renderer enforces none of them.
  Failure scenario: any journal the harness renders (a crafted `.jsonl`, a replayed session, or a
  future producer) that carries `refs` the gate would reject renders them verbatim as
  completion evidence -- a turn the gate calls UNPROVEN renders as proven-done.
  "Evidence rendered" is not "evidence gate-accepted." (reproduced) `completion_evidence_test.exs:194`
  ("cross-turn") passes (21/21 in an isolated worktree): a t2 done citing t1's tool_result
  `refs:[5]` renders `1 evidence ref: 1 tool result / mix_test - 42 tests, 0 failures`, which is
  exactly the input `DoneGate.gate/3` returns `{:error, {:foreign_turn, 5}}` for.
  Fix: resolve refs through the same evidence-class + same-turn + ordering predicate the gate
  uses (or render gate-rejected refs distinctly), so the transcript cannot display as proof a ref
  the authority rejects.

### CONCERNS

- **[Saboteur] concern** `test/fixtures/harness/goldens/simple-chat.flat.golden.txt:4` (and the
  inline_log / tmux_conservative siblings) -- fail-open conflates three distinct states into one
  row. `gated_done_payload/4` (`contract.ex:269`) always emits `final: true` and omits `refs` on
  reject; the renderer then yields `%{evidence: :none}` -> `"no evidence provided"`. (reproduced)
  the greeting fixture `simple-chat` ("Hello!", a `final:true` turn with no refs) now renders
  `no evidence provided`. With the live v0 producer (DoneGate is observe-only and fully
  fail-closed on v0 journals, per its own moduledoc -> most candidates resolve to `:mutation_echo`
  -> no refs) essentially EVERY done renders this row. It cannot distinguish (i) a gate-REJECTED
  evidence attempt, (ii) a done that cited nothing, and (iii) a trivial chat turn where evidence
  is irrelevant. "Absence is information" collapses to "absence is everywhere" -- the row is noise
  on the common path, so a genuinely suspicious unproven-done looks identical to a greeting. The
  PR's cross-lane note admits (i) vs (ii); the greeting golden shows (iii) makes it worse.
  Fix: only attach the absence row where evidence is expected (e.g. the turn had tool activity),
  or carry a rejection marker so (i) reads differently from (ii)/(iii).

- **[Saboteur] concern** `lib/raxol/harness/projection/block_builder.ex:326-331` -- refs are
  absolute session offsets; compaction is a staleness vector. If the cited `tool_result` is
  compacted out of the id-recovered stream (`id_ok`), `session_index` loses the key and a
  legitimately-proven done renders `unresolvable evidence ref` -- indistinguishable from a
  fabricated/bogus ref. Note: the offsets are stable ids (counter-derived, `contract.ex:296`),
  NOT array indices, so reattach does NOT shift them (that hypothesis is refuted); compaction is
  the real staleness path. Fix: document that evidence refs do not survive compaction, or resolve
  against a retained evidence sidecar rather than the live id-recovered set.

### LOW

- **[New Hire] low** `lib/raxol/harness/projection/block_builder.ex:139-148` (moduledoc "Refs are
  SESSION-scoped") -- the doc states a ref "may legitimately point at an earlier turn's
  `tool_result`," which directly contradicts the contract it names as ground truth: `DoneGate`
  rejects a cross-turn ref as `:foreign_turn`. A maintainer reading both cannot tell which is
  authoritative -- "what must a ref point at?" has two conflicting answers in the same feature.
  Fix: state that the honest producer only emits same-turn refs and that session-scope is a
  deliberate super-set (and why), or align the renderer to same-turn.

- **[New Hire] low** `test/fixtures/harness/goldens/` -- no byte-golden pins the evidence-PRESENT
  arm. The only `.golden.txt` files touched (simple-chat, multi-tool-turn) show the ABSENCE arm
  only; the rendered summary line, the `/ label` entry rows, and `+N more` are pinned solely by
  unit tests + the structural `evidence-done.t7blocks.json`, never by a byte-golden in any of the
  three tiers. The visual the PR headline promises ("N evidence refs: 2 tool results, 1 message")
  is unverified at the byte/ANSI level. Fix: add an `evidence-done` byte-golden per tier so the
  evidence arm's rendered bytes are frozen like the absence arm's.

- **[New Hire] low** `lib/raxol/ui/components/harness/block_body.ex:88-90` --
  `wrap_with_completion/2` wraps the mounted view in a `Components.column/1` whenever the
  `:completion` key is present, even if `Block.completion_rows/2` returns `[]` for an unrecognized
  shape. That contradicts the moduledoc's "byte-identical, no wrapping" claim for that case (minor;
  not reachable from the current builder, which never emits an unrecognized shape). Fix: guard on
  `completion_rows/2` returning a non-empty list before wrapping.

### Cross-persona overlaps

The HIGH (Security), the fail-open CONCERN (Saboteur), and the first LOW (New Hire) share one
root: the renderer treats wire-presence of `refs` as proof and never re-derives the gate's
acceptance semantics. The producer is the authority on "a completion claim is only as good as its
refs," yet the render path neither validates against it nor surfaces its verdict. Promoted: the
single highest-leverage fix is to make the renderer agree with `DoneGate` on what a valid,
citable ref is (and to make a gate rejection legible), which resolves all three at once.

### Verdict: CONCERNS

Not a BLOCK: the trusted live producer only ever emits gate-accepted same-turn refs, so the
false-evidence render path is not reachable through the honest path today; the ANSI/control-byte
sanitize+truncate boundary is sound; and no raise/crash paths were found. But for a feature whose
thesis is completion honesty, "rendered evidence" is not "validated evidence," and the absence row
is near-universal on the common path -- the guarantee is weaker than the PR frames it. The two
teeth: (1) a crafted/replayed/foreign-turn journal renders false evidence as proven-done because
the renderer skips every gate check (reproduced via the author's own passing cross-turn test),
and (2) fail-open makes a rejected done, an evidence-less done, and a plain greeting all render
identically.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-17T00:33:18Z

## Adversarial Re-review (automated)

Since last review: 1de5b335..069a4efe

Scope: the follow-up commit `069a4efe` ("Disclose cross-turn evidence refs and pin the evidence arm byte-golden"). I re-ran the prior HIGH's exact reproduction and probed the three sibling rejection classes.

### Resolved since last review

- **Prior HIGH, cross-turn (foreign_turn) arm -- FIXED.** The exact case my last review reproduced (a `t2` done citing `t1`'s `tool_result`) now renders differently instead of as clean proven-done. `resolve_completion_entry/4` (`block_builder.ex:722-747`) compares the resolved event's `turn_id` against the claiming `turn_completed`'s `turn_id`, stamps `cross_turn: true`, and `block.ex:781-782` suffixes the line with `" [cross-turn]"` plus a session-wide `"(N cross-turn)"` summary tally. Verified against the shipped test at `completion_evidence_test.exs:193-224`.
- **Cross-turn tally survives the entry cap.** `cross_turn_total` is counted over ALL refs, not just the shown `@max_completion_entries` (`block_builder.ex:660-664`) -- a cross-turn ref pushed past the cap is still disclosed in the summary. Sound and tested (`completion_evidence_test.exs:244-269`).
- **BlockBody unrecognized-shape byte-identity -- FIXED (latent bug).** `wrap_with_completion/2` now computes `completion_rows/2` FIRST and branches on `[]` (`block_body.ex:88-93`) rather than pattern-matching the mere presence of the `:completion` key. Since `completion_rows(%Block{}, _)` falls through to `[]` (`block.ex:773`) for any unrecognized completion shape, an unknown shape now renders byte-identical to the unwrapped mount. The prior key-presence match would have wrapped (and shifted bytes) for an unrecognized shape.
- **Two prior limits now documented (not fixed).** The moduledoc now openly states the fail-open conflation and the compaction-staleness gap (`block_builder.ex` "Known conflation" / "Staleness under compaction" sections).

### High

- **False-evidence surface only PARTIALLY closed: `:stale_evidence` and `:mutation_echo` still render as clean proven-done. (reproduced)** The gate (`packages/raxol_agent/lib/raxol/agent/done_gate.ex:250-273`) rejects five classes: `:missing_ref`, `:not_evidence`, `:foreign_turn`, `:stale_evidence`, `:mutation_echo`. The renderer now discloses exactly two of them out of band (`:missing_ref` -> `unresolvable evidence ref`; `:foreign_turn` -> `[cross-turn]`) and one via the type breakdown (`:not_evidence` -> renders "1 message", not "1 tool result"). But **`:stale_evidence` and `:mutation_echo` are same-turn refs, so the `turn_id`-only cross-turn check never fires and they render as clean, unmarked evidence.**

  Reproduced on the renderer side (worktree at `069a4efe`): a single turn `t1` with a `tool_result` at id 5 (`mix_test`), then a LATER mutation (`rm_rf` `tool_use` at id 7), then `turn_completed final:true refs:[5]`. The renderer output:

  ```
  %{total: 1,
    evidence: [%{label: "mix_test — 42 tests, 0 failures", type: :tool_result, ref: 5}],
    type_counts: [%{count: 1, type: :tool_result}]}
  ```

  No `cross_turn`, no marker -- byte-identical to honest fresh evidence. The gate on the same journal rejects `refs:[5]` as `{:error, {:stale_evidence, 5}}` (deterministic from `done_gate.ex:263-264`: `last_mut = 7` because the `rm_rf` `tool_use` is mutating, and the cited event id `5 <= 7`). So a done whose only evidence predates a subsequent destructive mutation renders as a clean checkmark-equivalent -- exactly the honesty-creed violation the feature exists to prevent, for two of the five classes. The `mutation_echo` class is the same shape (same-turn, unmarked).

  I do not dispute the architectural stance (the gate is the security boundary; the renderer is display-side and cannot depend on `raxol_agent`). The residual is bounded to a dishonest/buggy producer or a replayed/tampered journal. But the PR advertises "a completion claim is only as good as its refs" while two rejection classes silently render clean, so I keep this at High-but-not-blocking.

### Medium

- **The "cannot re-validate" justification is partly a false constraint.** The moduledoc argues the renderer "could not call back into the gate even if it wanted to" (dependency direction). True for a direct call -- but the gate's staleness/echo predicates are PURE functions over the journal the renderer already holds, and the renderer already re-derives the `turn_id` comparison locally for cross-turn (`block_builder.ex:735`). `last_mutation`/`<=` staleness is the same kind of local derivation over `session_index`, needing no dependency inversion. The chosen scope (turn_id only) is a decision, not a dependency limitation, and the moduledoc frames it as the latter. Either widen the local disclosure to cover stale/echo, or state plainly that these two classes are knowingly left unmarked.

- **Prior MED (absence-row conflation) documented but NOT fixed.** A viewer still cannot distinguish gate-REJECTED-done vs honest-no-evidence vs plain-greeting: all three render the single unconditional `"no evidence provided"` row (`block.ex:738-743`). The moduledoc now says so and defers disambiguation to a producer-side wire change "tracked cross-lane." Acceptable as a documented deferral, but the "rejected done laundered into a benign absence row" information loss is real and unaddressed in this PR.

### Low

- **Summary/line disclosure can be internally inconsistent under the cap.** When all shown entries are same-turn but a cross-turn ref sits beyond `@max_completion_entries`, the summary reads `"... (1 cross-turn)"` while NO visible line carries `[cross-turn]` (the shown-lines are all clean). Verified by the shipped test `completion_evidence_test.exs:244-269`. Correct by design (tally over all refs), but a reader sees a cross-turn count with zero visible cross-turn lines -- a mild UX seam worth a "+N more (cross-turn)" hint on the tail row.

- Sanitize/clamp boundary re-confirmed sound; no crash path found; `completion_rows/2` fallback to `[]` (`block.ex:773`) is total.

### Verdict: CONCERNS

The specific prior HIGH reproduction (cross-turn foreign_turn) is genuinely fixed and the cross-turn disclosure is well-built and tested; a latent BlockBody byte-identity bug was also fixed. But the false-evidence HIGH is only partially closed: two of the gate's five rejection classes (`:stale_evidence`, `:mutation_echo`) still render as clean, unmarked evidence (reproduced), and the "cannot re-validate" rationale for leaving them is a false constraint since those predicates are local and pure. The fail-open absence-row MED is documented but not fixed. Not a BLOCK -- the gate remains the real boundary and the residual is display-only under a dishonest producer -- but the honesty guarantee is narrower than the PR advertises.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #620 — Harness UI: seal-pipeline hardening (write-confirmed sealing, frame order, synchronized output)
State: OPEN
Drew entries: 2

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-17T00:09:20Z

## Adversarial Review (automated)

Scope: `try_seal/2` two-phase seal, frame-order (`advance/3` + `adopt_resize/3`), and DEC 2026 synchronized output (`with_sync/3`). Verified against `lib/raxol/ui/rendering/paint_authority/inline_authority.ex` and `lib/raxol/harness/surface.ex` at the diff. Frame-order (item 2) reads correct: `advance/3` threads `adopt_frame_resize/2` unconditionally ahead of `do_advance/2`, and `seal_frame/3` computes `will_commit` at the already-adopted geometry. No findings there.

### HIGH

- **[Saboteur + New Hire] The rescue is broader than "device failure" and does not filter on the reason it documents.** `inline_authority.ex` `confirmed_seal/2` rescues `_e in [ArgumentError, ErlangError]` (diff, new `confirmed_seal/2`), and `sync_write/2` uses the identical clause. But the docstring for `try_seal/2` names the dead-device class as `%ErlangError{original: :terminated}` -- the code catches **every** `ErlangError` regardless of `original`, and every `ArgumentError` raised anywhere inside the `with_cursor -> append_sealed` closure (not only the io-server `{:error, reason}` reply). Consequence: a genuine logic bug that raises `ArgumentError`/`ErlangError` from inside the seal (a malformed region struct, a `count_lines`/`IO.iodata_to_binary` fault on bad iodata, a future refactor bug) is silently reclassified as `{:error, :write_failed, t}`. Per `surface.ex` `seal_block/2` + `commit_walk/5`, `next_row`/`painted_count` are left un-advanced and the SAME entry is retried on every subsequent `advance` -- and a code bug is not transient, so this is an unbounded retry loop that never surfaces the real error. The task's own premise ("rescues ... a dead device as ErlangError :terminated") is what the prose promises but not what the code does. Narrow the rescue to the reason it documents (guard on `original: :terminated` for the `ErlangError` arm; scope the `ArgumentError` arm as tightly as the io seam allows) so non-device faults stay loud. (Saboteur MEDIUM: masks bugs into an infinite retry; New Hire LOW: doc/code disagree on the WHY -- same root, promoted to HIGH.)

- **[Saboteur + Security Auditor] `with_sync/3` can leave the terminal wedged in synchronized-update mode; "balanced by construction / never a dangling open" is an overclaim.** `inline_authority.ex` `with_sync/3` opens with `sync_write(device, "\e[?2026h")` and closes in the `after` with `sync_write(device, "\e[?2026l")`; `sync_write/2` rescues device errors and returns `:error` **without the byte landing**. The moduledoc guarantees the close is emitted "iff the open succeeded" -- but that guarantees the close is *attempted*, not that the close *byte reaches the device*. If the open is accepted (`?2026h` on the wire, device alive) and the device then faults on the close write (transient `{:error, :enospc}`, SIGHUP mid-frame), the open lands with no matching close and the terminal stays frozen in synchronized mode. There is no reset-on-next-frame or idempotent re-close: I grepped and the harness path has no `?2026l` recovery seam (only `backends.ex` emits its own independent pair). The balanced-bracket test (`surface_seal_pipeline_test.exs`) only exercises a device that *recovers* before the close (`FailingDevice` fails exactly once), so the stuck-through-the-close path is unverified. Security framing: a hostile or flaky device that ACKs the open and drops the close is a display-DoS (terminal wedged) reachable from a presentation-only feature. Same root, Saboteur + Security -> promoted to HIGH. Suggest a self-healing close (emit `?2026l` unconditionally at the top of the next sealing frame, or track an "open but unclosed" latch).

### MEDIUM

- **[Saboteur + Security Auditor] "Partial-write honesty ... safe by construction" breaks at the scroll boundary.** `inline_authority.ex` `try_seal/2` writes a whole multi-line block in one `IO.write(device, iodata)`; the partial-write doc argues a retry "produces the same rows the confirmed write would have" because `next_row` was not advanced. That holds only when `target_row = min(next_row, bottom)` sits with slack above `history_bottom`. On a real tty a partial write can flush some of the block's embedded `\r\n`s before erroring; if `target_row` is at/near the region bottom, those newlines scroll the DECSTBM region and evict partially-written rows into native scrollback, which this process can never rewrite (the module's own core invariant). The retry then re-CUPs to the un-advanced absolute `target_row` and re-emits the full block, but the evicted partial rows are permanent duplicate/garbled scrollback. StringIO cannot reproduce this (it never partial-writes), so it is a design-honesty gap rather than a test-caught one -- but the blanket "no seal-once violation" claim is not true at the boundary. (Security: content-integrity duplication, overlaps the same root -- left MEDIUM as it needs a real-tty partial write at the bottom row.)

- **[Saboteur / New Hire] "Confirmed" is "the io server replied `:ok`", not "the bytes reached the terminal".** `try_seal/2`'s contract ("reports whether the device actually confirmed it", "confirmed on the device") is accurate for a StringIO/port io-request round-trip, but for a buffered pipe/`:stdio` an `:ok` reply means accepted-into-the-io-server, not rendered. The module cannot do better without a DSR round-trip, so this is a wording-precision issue -- but "confirmed on the device" reads stronger than the mechanism delivers. Recommend softening to "the io server accepted the write" so a future reader does not assume end-to-end delivery.

### LOW

- **[New Hire] Magic synchronized-output sequences bypass the module's own wire-vocabulary indirection.** `with_sync/3` hardcodes `"\e[?2026h"` / `"\e[?2026l"` inline (and the test re-hardcodes them as `@sync_open`/`@sync_close`), while every other control sequence in this module routes through `Dialect` (`cursor_save/0`, `cursor_restore/0`, `cursor_position/1`). The BSU/ESU pair and the `2026` mode number have no named constant and are duplicated between production and test, so a typo (`2026` vs `2027`) or a future SGR-saver/DECRST-restore variant would drift silently. Give them a `Dialect.sync_begin/0` / `Dialect.sync_end/0` (or module attributes) matching the module's stated "shared Dialect wire vocabulary" design.

- **[New Hire] Two different capability-reading idioms in one constructor.** `new/5` sets `sync_output?: match?(%{sync_output: true}, caps)` -- a loose map match that also matches any non-`Capabilities` map carrying `sync_output: true` -- while `reflow_capable?/1` in the same file uses a strict `%Capabilities{identity: ...}` struct pattern. There is also an existing public gate `Raxol.Terminal.Capabilities.sync_output?/0` that this bypasses. Prefer the struct pattern (`%Capabilities{sync_output: true}`) for consistency and to avoid matching stray maps.

### Cross-persona overlaps

- Over-broad `[ArgumentError, ErlangError]` rescue: Saboteur (masked bug -> infinite retry) + New Hire (doc names `:terminated`, code catches all) -- promoted MEDIUM -> HIGH.
- Unbalanced `?2026` bracket: Saboteur (close byte may not land) + Security Auditor (device-driven display DoS) -- promoted MEDIUM -> HIGH.
- Partial-write boundary: Saboteur (permanent scrollback corruption) + Security Auditor (content duplication) -- same root, held at MEDIUM (real-tty-only trigger).

### Verdict: CONCERNS

Two HIGH issues (both promoted via cross-persona agreement, both in `inline_authority.ex`), several MEDIUM/LOW. No CRITICAL and fewer than three HIGH, so not a BLOCK -- but the two HIGH items are load-bearing for the exact guarantees this PR advertises (fail-closed device handling and balanced synchronized output) and should be addressed before live agent traffic. The frame-order item is clean.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-17T00:41:45Z

## Adversarial Re-review (automated)

Since last review: d7df35bf..19fd477d

Focus: the round-1 hardening commit `19fd477d` ("scoped rescues, healing sync
bracket"), which directly targets the two HIGHs. Verified against the PR-head
checkout of `pr-620-verify`; the new suite compiles and all 17 tests in
`test/harness/surface_seal_pipeline_test.exs` pass (reproduced). Two extra
probes run below.

### Resolved since last review

- **HIGH -- over-broad rescue vs "confirmed" -- RESOLVED.** The seal rescue is
  now narrowed twice over. `confirmed_seal/2` catches only
  `e in [ArgumentError, ErlangError]`
  (`lib/raxol/ui/rendering/paint_authority/inline_authority.ex:519-528`), so
  every OTHER logic-bug class (`KeyError`, `FunctionClauseError`, ...) is not in
  the rescue list at all and propagates untouched. The two classes that ARE
  caught pass through `device_io_error?/2`, which requires the stacktrace head
  to be `{:io, _, _, _}` -- i.e. the raise must have come out of the `:io` layer
  (`append_sealed/2` writes via `IO.write/2` -> `:io.put_chars`, inline_authority.ex:414-415).
  An `ArgumentError`/`ErlangError` raised by non-device code returns `false` ->
  `reraise`. The unit test `device_io_error?/2 recognizes the two device classes
  and rejects local raises` proves the discriminator returns false for a
  locally-raised `ArgumentError` (reproduced). A genuine logic bug can no longer
  be reclassified as `:write_failed`, so the logic-bug silent-retry loop is gone.

- **HIGH -- unbalanced synchronized-output -> wedged terminal -- RESOLVED.**
  `with_sync/3` is replaced by a latch-backed pair, `sync_open/1` + `sync_close/1`,
  with a `sync_close_pending?` field. A landed open latches an owed close; the
  latch clears ONLY when a close write is accepted. Every frame entry point
  (`do_advance`, `tick`, `handle_input`, inline `resize`) calls `heal_sync/1`
  first (`lib/raxol/harness/surface.ex:788-796`), re-attempting the owed close,
  and a mid-frame raise makes one best-effort `sync_close` before re-raising
  (`surface.ex:762-778`). The test `a close-write failure does not wedge the
  terminal: the owed close is re-attempted on the next frame` constructs
  accepted-open + faulted-close and confirms the next (tick) frame emits the
  owed `?2026l`, healed and balanced (reproduced). The wedge can no longer
  persist across frames.

- **MED -- scroll-boundary partial write -- documented.** `try_seal/2`'s doc now
  has an explicit "Partial-write honesty (and the scroll-boundary residual)"
  section naming the raw-fd/pty case where partially-flushed `\r\n`s evict rows
  into unreachable native scrollback, and notes no current transport
  partial-writes. Honest, not an implied guarantee.

- **MED -- "confirmed" wording -- documented.** `try_seal/2` now states plainly
  that `{:ok, _}` means the io server ACCEPTED the write (handed-off), not
  end-to-end render, and that a DSR round-trip would be needed to prove delivery.

### Medium

- **Non-transient device fault is still an unbounded, silent, un-observable
  retry loop (reproduced).** The scoped rescue kills the LOGIC-bug loop, but the
  retry mechanism itself survives for genuine device faults -- and it does not
  distinguish transient from permanent. A device that permanently refuses the
  seal write drives `advance/2` to return `{model, :ok}` forever: 200 advances
  against a persistently-failing device left `painted_count == 0`, only `:ok`
  ever returned, never `:done`, with no telemetry and no retry bound
  (`inline_authority.ex` `device_io_error?/2` + `surface.ex` `do_advance`).
  Sharper: a DEAD device (`ErlangError{original: :terminated}`) is EXPLICITLY
  classified as a retryable `device_io_error?` -- so the harness retries a corpse
  forever. Note this is a mild observability regression for the dead-device case:
  pre-PR, `seal/2` had no error path, so a dead device would have RAISED out of
  `advance` (loud crash); this PR converts that into a silent infinite loop.
  The empty-bracket-per-frame behavior (a `will_commit`-true frame whose seal
  write fails emits a bare `?2026h`/`?2026l` with no content) shares this root:
  on a persistent failure it becomes forever byte-spam of accepted open/close
  pairs. A retry bound, or a `[:raxol, :harness, :seal, :write_failed]` telemetry
  emit, would make the non-transient case observable and is the natural
  follow-up. Non-blocking, but the dead-device branch deserves a fail-fast or a
  count.

### Low

- **No teardown backstop for an owed sync-close.** The heal contract is
  explicitly "the next frame with a writable device." A wedge that lands on the
  FINAL frame, followed by process exit, has no flush seam: Surface owns no
  `terminate/2` (precondition #7, `surface.ex:381-397`), and the documented
  cleanup path `InlineDriver.Sequences.teardown_bytes/1` predates sync brackets
  -- it emits the DECSTBM region release (`\e[r`), not `?2026l`. So the specific
  wedge-then-quit topology can still strand the real terminal in synchronized
  mode. Recommend the teardown path emit `?2026l` unconditionally (DEC private
  modes are set/reset -- harmless when nothing is owed).

### Verdict: CONCERNS (non-blocking)

Both HIGHs are cleared, each with a real end-to-end test through the device seam
(reproduced): the scoped rescue no longer swallows logic bugs (they re-raise
loudly), and the latched sync bracket can no longer wedge the terminal across
frames. The remaining items are one MED (non-transient/dead-device retry loop
has no bound, telemetry, or fail-fast -- a mild observability regression from
the pre-PR crash) and one LOW (no teardown flush for an owed sync-close). Both
MEDs from round 1 are now honestly documented. Mergeable; the dead-device bound
or telemetry emit is the recommended fast-follow.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #621 — Harness UI: command palette, jump picker, session picker (+ a footer-grow seal-overwrite fix)
State: MERGED (merged 2026-07-17T05:29:03Z)
Drew entries: 2

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-17T00:12:52Z

## Adversarial Review (automated)

Scope: the substrate fix (`a22d873`) read in isolation, then the three picker
consumers. Substrate fix was reproduced in an isolated worktree.

### Substrate fix verification (the highest-value part) -- VERIFIED CORRECT (reproduced)

`grow_reclaim_count/3` (`inline_authority.ex:789` old -> `max(next_row - new_bottom, 0)`)
holds the immutable-prefix invariant across every fill state:

- **empty history** (`next_row == 1 <= new_bottom`) -> `k = 0`, no scroll, boundary row already blank.
- **partially filled** (`new_bottom < next_row < old_bottom`) -> `k = next_row - new_bottom`; after eviction content fills `1..new_bottom-1` and row `new_bottom` (the new `next_row`) is blank. The pre-fix `max(next_row - 1 - new_bottom, 0)` evicted one row too few, leaving real content ON row `new_bottom` while `next_row` claimed it blank -> the next `seal/2` overwrote it (`append_sealed/2` targets `min(next_row, bottom)`, `inline_authority.ex:406`).
- **full/steady-state** (`next_row == old_bottom`) -> `k = old_bottom - new_bottom`, identical to the retired special case; content stays `1..new_bottom-1`, boundary blank.

`k <= next_row - 2 < content_rows` in every case, so evicted rows go to native
scrollback (prefix preserved), never off the top of live content. shrink/resize
paths are untouched by this commit and independently keep the invariant.

Reproduced: checked out PR head in a worktree, reverted ONLY the formula to
the pre-fix branch -> `overlay_picker_surface_test.exs` went **18/19** (exactly the
new "grow over a PARTIALLY-filled history" regression fails on `SealOracle.immutable_prefix?`);
restored the fix -> **19/19**. The fix is load-bearing and correct. No surviving
immutable-prefix / seal-overwrite violation.

### MEDIUM

- **[New Hire / Saboteur] `keymap.ex:407-412` + `surface.ex:1063-1065`** -- vestigial `:fold_toggle` payload / contract that the dispatcher does not honor. `command_for/2`'s `build_command` threads `context.focused_block_id` into `%{type: :fold_toggle, payload: %{block_id: ...}}`, and `picker_binds_test.exs` pins this as "invocation parity made real." But the live dispatcher `dispatch_command(model, %{type: :fold_toggle}) -> apply_fold_toggle(model, model.focused_index)` ignores `payload` entirely and reads `model.focused_index`. The payload is dead for both the keypress and palette paths (`context.focused_block_id` is itself just `model.focused_index`, `surface.ex:999`). Failure scenario: a maintainer "fixes" dispatch to consume `payload.block_id`, or changes the palette's context construction, and the pinned test keeps passing while behavior silently decouples -- the test guards a value nothing reads. Fix: either have `dispatch_command` consume `command.payload.block_id` (make the contract real) or drop the payload threading and the test assertion, and stop the moduledoc calling it load-bearing.

- **[Saboteur / Security Auditor] `surface.ex:287,334-345` (`open_session_picker` / `list_fixture_sessions`)** -- unbounded, input-thread filesystem + O(N) scoring per keystroke. Every `s` press runs `File.ls/1` on `model.sessions_dir` synchronously on the input path; every `.jsonl` entry becomes a picker item, then `OverlayPicker.fuzzy_filter/3` re-runs `ListScorer.rank` over ALL items on each subsequent keystroke. There is no cap on item count and `sessions_dir` is a public `Surface.new/2` opt. `Fixture.load/1` then `File.read`s the whole selected file into memory (`fixture.ex:97`). Failure scenario: a large or externally-populated sessions directory (thousands of `.jsonl`) stalls the render thread on open and on every filter keystroke; a large fixture file OOMs/stalls on pick. Fix: cap the listing (e.g. take N + "more..."), and/or move `File.ls` + `Fixture.load` off the synchronous input path. (Base LOW each; promoted to MEDIUM by cross-persona agreement.)

### LOW

- **[Saboteur] `surface.ex:1063-1065` via the palette** -- guard bypass with silent no-op. `:open_palette` is `:always`, so the palette opens mid-compose; its entries include the `:not_composing` binds ("toggle fold", "next/previous block", "jump to block", "switch session"). Picking "toggle fold" while composing dispatches with `model.focused_index == nil` -> `apply_fold_toggle(model, nil)` is a no-op (`surface.ex:1265`) with NO notice, so the user picks an action and nothing visibly happens. Not a crash (overlay-stacking is correctly prevented -- `on_pick` runs after `close_overlay`, `surface.ex:1023-1028`), but inapplicable entries should be filtered or should emit an honest refusal notice.

- **[New Hire] `overlay_picker_surface_test.exs` (added regression)** -- dead-binding noise: `auth = InlineAuthority.seal(auth, "sealed after grow\r\n")` immediately followed by `_ = auth`. The rebind is unused; drop it or assert on the returned `auth`.

### Verified-safe (not findings, checked because the task asked)

- **[Security Auditor] session-name / `sessions_dir` -> footer injection: DEFENDED.** Filenames and paths interpolate into picker labels and `stub_notice` ("switched to session #{name}", "no fixture sessions found in #{dir}"), all rendered through the footer path, which sanitizes twice: `ViewText.sanitize/1` strips every C0 byte incl. ESC 0x1B and DEL (`view_text.ex:221-226`), then `ContentGuard.sanitize_line/1` in `InlineAuthority.repaint` (`inline_authority.ex:568-570`). No ESC/cursor/clear injection reaches the terminal; footer content is never sealed, and the sealed history path independently sanitizes via `seal/2`.
- **[Security Auditor] no path traversal.** `list_fixture_sessions` names come from `File.ls/1` basenames (no `/`), and `Fixture.load` builds `Path.join(dir, name <> ".jsonl")`; a picked name cannot escape `sessions_dir`. `Fixture.load` uses `Jason.decode` with no atom creation -- no atom-exhaustion vector.
- **[Saboteur] focus/dispatch routing while a picker is open.** `g`/`s`/`z`/`j`/`k` (`:not_composing`) are suppressed by the guard's `overlay_open?` read (`keymap.ex:390-394`); only `:always` Ctrl+P reaches dispatch with an overlay open and is caught by the `overlay_already_open` clause (`surface.ex:1065-1067`). ESC ordering is correct: `:overlay_dismiss` (guard `:overlay`) precedes `:interrupt` (`:always`) in the table, so ESC dismisses when open and interrupts when closed.
- **The substrate fix is well-documented against regression** -- the derivation comment states the `append_sealed/2` loop invariant explicitly and the named regression test pins it.

### Cross-persona overlaps

- Unbounded session-picker resource use flagged independently by Saboteur (input-thread stall / huge lists) and Security Auditor (externally-populated dir DoS) -> promoted LOW -> MEDIUM.
- The vestigial `:fold_toggle` payload was reached from two angles (New Hire: misleading contract; Saboteur: guard-bypass no-op shares the same dispatch line) -> kept at MEDIUM.

### Verdict: CONCERNS

The headline substrate fix is correct and verified across all fill states
(reproduced red->green); no CRITICAL, no surviving immutable-prefix violation.
Two MEDIUM maintainability/robustness issues (a pinned-but-unhonored payload
contract, and an uncapped input-thread session listing) warrant a follow-up but
do not block. Footer injection and path-traversal surfaces were checked and are
defended.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

### Round 2 — REVIEW | review_state=COMMENTED — 2026-07-17T00:39:04Z

## Adversarial Re-review (automated)

Since last review: d2ce51b6..58533f45

Scope: the one new commit `58533f45` targeting my two prior MEDIUMs, plus a
recheck of the two LOWs. Verified against `lib/raxol/harness/surface.ex`,
`lib/raxol/ui/harness/keymap.ex`, `lib/raxol/ui/harness/overlay_picker.ex`,
and the new tests. Affected harness suites run green in an isolated worktree
(35 passed: `command_palette_surface_test.exs` + `overlay_picker_surface_test.exs`).

### Resolved since last review

- **MED (fold payload now honored).** `dispatch_command/2` no longer re-reads
  `model.focused_index`; it consumes the command's own payload
  (`surface.ex:1133-1134`: `%{type: :fold_toggle, payload: payload}` ->
  `apply_fold_toggle(model, Map.get(payload, :block_id))`). Both producers feed
  it from one place: the live-keypress path (`Keymap.resolve/2` ->
  `build_command/2`, `keymap.ex:413`) and the palette path
  (`Keymap.command_for/2` -> `build_command/2`, `keymap.ex:388`) BOTH route
  `:fold_toggle` through `build_command(%{command_type: :fold_toggle}, context)`
  which sets `payload: %{block_id: Map.get(context, :focused_block_id)}`
  (`keymap.ex:494-498`), and `context.focused_block_id` comes from the single
  `keymap_context/1` builder shared by keypress and palette
  (`surface.ex:1063-1070`, `1622-1623`). The pinned contract is now truthful:
  a palette pick toggles the block the payload names, not a second live read of
  the model. No off-by-one -- `block_id` here IS the block index
  (`focused_block_id: model.focused_index`), and `apply_fold_toggle/2`'s
  `index < model.painted_count` guard is unchanged. Behavior-preserving in the
  current tree (both reads resolve on the same model at the same instant), so
  this is a decoupling-hazard removal, correctly scoped.

- **MED (per-keystroke session scoring now bounded) (reproduced).** The cap is
  applied to the item list handed to the overlay (`cap_session_names/1`,
  `surface.ex:1689,1701-1706`) BEFORE the picker is populated, so the
  per-keystroke ranker (`OverlayPicker.fuzzy_filter/3` ->
  `ListScorer.rank/3`, `overlay_picker.ex:160-161`, which scores over
  `picker.items`) can never exceed 100 items per keypress. Reproduced: the new
  test seeds 120 files and asserts `length(picker.items) == 100`
  (`command_palette_surface_test.exs`), i.e. the DoS vector I flagged
  ("File.ls + O(N) fuzzy scoring per KEYSTROKE") is genuinely closed -- the
  keystroke path is now O(100), not O(N). Truncation is surfaced, not silent:
  the title reads `"session — first 100 of 120"`.

- **LOW (mid-compose fold no-op).** `apply_fold_toggle(model, nil)` now sets an
  honest one-frame notice (`surface.ex:1368-1370`, `"no block focused"`) instead
  of returning the model unchanged. Covered by two new tests (palette pick of
  "toggle fold" mid-compose, and `z` in transcript-browse pre-jump).

- **LOW (dead test binding).** The `auth = ...; _ = auth` rebind in the
  footer-grow regression is gone, replaced by `_auth = InlineAuthority.seal(...)`
  (`overlay_picker_surface_test.exs:603`).

### Low

- **Session listing is only bounded on the keystroke path; the one-time open is
  still O(N).** `list_fixture_sessions/1` runs `File.ls/1` + `Enum.sort/1` over
  the FULL directory every time the picker opens (`surface.ex:1737-1742`); the
  cap's `Enum.take/2` is applied post-sort, so a pathological `sessions_dir`
  still fully materializes and sorts on each `s` press. This is a discrete user
  action (not per keystroke) and Elixir's stdlib has no streaming `ls`, so the
  sort is the only avoidable part -- acceptable, but the "bounded work on the
  input path" docstring slightly oversells it. Residual, not a blocker.

- **`Fixture.load/1` on pick remains an unbounded whole-file `File.read`**
  (`fixture.ex:96-97`), on a public `sessions_dir`. A pathological `.jsonl`
  pauses/OOMs the synchronous surface on a single pick. This is explicitly
  documented in `open_session_picker/1`'s "Listing cap" section as acceptable
  for fixture mode rather than fixed -- honest, and low-severity given picks are
  discrete, but it is a residual (documented, not eliminated).

- **The cap keeps the lexicographically-first 100 names, so sessions past the
  cap are unreachable via fuzzy filter (reproduced).** `picker.items` is exactly
  the first 100 sorted names (test asserts `List.last == "session-100"` for a
  120-file dir), and `fuzzy_filter/3` only ranks over `picker.items` -- so
  typing `115` for `session-115.jsonl` matches nothing even though the file
  exists. The title's "first 100 of 120" surfaces that truncation happened, so
  it is not silent, but "which 100" is lexicographic, not recency/relevance.
  Fine for the small-by-construction fixture dir; worth a one-liner if the
  picker ever points at a real session store.

- **The stricter `:fold_toggle` head can silently swallow a payload-less
  command.** `dispatch_command(model, %{type: :fold_toggle, payload: payload})`
  now requires a `:payload` key; a `:fold_toggle` map without one would fall
  through to the `_other` catch-all (`surface.ex:1203`) and no-op. No in-tree
  producer emits that shape (both go through `build_command/2`, which always
  attaches a payload), so this is latent only -- but it re-opens a silent-no-op
  crack for exactly the command whose silent-no-op you just closed. A
  `%{type: :fold_toggle} = cmd -> apply_fold_toggle(model, cmd[:payload][:block_id])`
  or an explicit assertion would be more honest than leaning on the catch-all.

### Verdict: CLEAN

Both MEDIUMs are genuinely cleared: the fold payload is consumed (single
producer chain, contract now truthful, no off-by-one), and the per-keystroke
session scoring is capped before the O(N) ranker runs (reproduced via the new
120-file test). Both LOWs are handled. What remains are low-severity, mostly
documented residuals (one-time open sort, whole-file load on pick, lexicographic
cap reachability, a latent payload-less no-op) -- none block merge.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PR #622 — test: fix the editor tmp-dir flake (url-base64 underscore split)
State: MERGED (merged 2026-07-17T05:23:21Z)
Drew entries: 1

### Round 1 — REVIEW | review_state=COMMENTED — 2026-07-17T00:05:51Z

## Adversarial Review (automated)

Scope: 6-line test fix replacing a `String.split("_")` extraction of the tmp-dir
random segment with `String.slice(-8, 8)`. Confirmed the generator at
`lib/raxol/harness/editor_session.ex:498-503` builds the name as
`counter_timestamp_random` where `random = 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)`.

### Saboteur

- Deterministic: CONFIRMED. 6 bytes is a multiple of 3, so base64url emits
  exactly 8 chars with no padding regardless of input; `padding: false` is a
  no-op here. `counter` and `timestamp` are digits only (no `_`/`-`), so the
  trailing 8 chars of the basename are always exactly the random segment.
  `String.slice(-8, 8)` sidesteps the alphabet entirely, so it is immune to
  BOTH url-base64 specials (`_` and `-`), not just the `_` that caused the
  flake. This is the right shape of fix.
- Minor (non-blocking) vacuity: `String.length(random_segment) == 8` is now a
  tautology -- `slice(-8, 8)` on a name that is always >= 8 chars can only ever
  return 8 chars, so the assertion tests `String.slice`, not the generator's
  output width. The real teeth are the two lines below it:
  `=~ ~r/\A[A-Za-z0-9_-]+\z/` (alphabet) and `refute =~ ~r/\A[0-9]+\z/`
  (proves the captured segment is the random tail, not a numeric field). Those
  keep the test meaningful, so this is not fully vacuous -- just note the length
  line no longer earns its keep. If you wanted it to bite, extract by stripping
  the `counter_timestamp_` prefix and assert the remainder length.
- No sibling instances: the only other `String.split` in the file is line ~104
  splitting on `'` (shell-quote parsing), which is not in the base64 alphabet
  and is safe. No other alphabet-split flake in this file.

### New Hire

- Clean. The replacement comment explicitly states WHY the old approach was
  wrong ("url-base64's alphabet includes `_`, so splitting on it self-truncated
  the segment ~12% of runs"), which makes accidental reintroduction unlikely.
  Self-documenting.

### Security Auditor

- Clean. The confidentiality guarantees (file `0o600`, dir `0o700`) are still
  asserted unchanged (lines 438-439). Directory uniqueness is provided by the
  monotonic `unique_integer`, not the random suffix, so a shorter/predictable
  suffix could not cause a collision; the random exists only for
  unpredictability, and the test still verifies its presence and non-numeric
  shape. Nothing here weakens the earlier editor-suspend O_EXCL/0600 work.

### Verdict: CLEAN

A correct, well-documented, deterministic flake fix. It fully handles the
url-base64 alphabet by not splitting on it at all. One cosmetic note: the
`== 8` length assertion is now tautological given the slice, but the alphabet
and non-numeric regex assertions preserve the test's meaning.

_Adversarial reviewer: Saboteur / New Hire / Security Auditor personas._

---

## PRs with no Drew activity in-window

- #596 — raxol_payments: harden agent-stream (route store, malleability, diagnostics) (MERGED)
- #599 — raxol_payments: announce a stranded row when a poll times out (MERGED)
- #600 — test(harness): wrap/width corpus + fix SequenceScanner trailing-ESC hang (MERGED)
- #601 — test(harness): raise timeouts on two CPU-heavy substrate property tests (Windows CI) (MERGED)
- #602 — Harness UI: needs-input starvation guard + 256-color tier separation pin (MERGED)
- #603 — Harness UI: stall/doom-loop detector + status strip alert seam (MERGED)
- #612 — fix(terminal): empty OSC payload no longer crashes the ANSI state machine (MERGED)
- #624 — feat(acp): raxol_agent_client_protocol — first Elixir/OTP Agent Client Protocol impl + durable-sessions moat (OPEN)
- #626 — Harness UI: full-screen diff expansion (footer-region maximization) (OPEN)
- #627 — Harness UI: supervise a live agent session — stream in, interrupt and steer out (OPEN)
- #628 — Harness UI: transcript search (fuzzy body search over the block corpus) (OPEN)
- #629 — Harness UI: projection panels (worktracks/memory/plan as summonable overlays) (OPEN)
