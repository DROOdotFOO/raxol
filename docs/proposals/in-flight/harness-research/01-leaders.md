# Leaders: Claude Code + Codex — distilled

Full report in task transcript; this is the decision-relevant spine.

## Codex loop architecture (the copyable state machine)
`codex app-server` = **stateful long-lived process, bidirectional JSON-RPC 2.0 over stdio** powering every surface (CLI/VSCode/JetBrains/desktop/web) off one implementation. OpenAI tried MCP first and **rejected it**: *"maintaining MCP semantics in a way that made sense for VS Code proved difficult. Rich interaction patterns like workspace exploration, streaming progress, and emitting diffs required richer session semantics that didn't map cleanly through MCP endpoints"* ([openai.com/index/unlocking-the-codex-harness](https://openai.com/index/unlocking-the-codex-harness/)). Primitives: **Thread → Turn → Item**, each streamed `item/started → deltas → item/completed`. Maps mechanically onto GenServer lifecycle + PubSub.

## Permission models
- **Claude Code:** six-mode ladder (default/acceptEdits/plan/auto/dontAsk/bypass) + two-stage classifier in auto mode. Protected paths (`.git`, `.claude`, rc files) evaluated *before* allow-rules — structural floor.
- **Codex:** two orthogonal dials — `sandbox_mode` (read-only/workspace-write/danger-full-access) × `approval_policy` (untrusted/on-failure/never). Kernel enforcement: Landlock+seccomp+bubblewrap (Linux), Seatbelt (macOS). **Only major CLI with sandboxing on by default.** Even `--yolo` still blocks `git push --force` + branch deletion — hardcoded exception list.

## Context/compaction
Codex uses **hybrid compaction**: preserves last ~20k raw tokens alongside LLM summary (not full-summary). Claude auto-compact at ~95%. Both are the single most-hated subsystem. Amp (Sourcegraph) rejects auto-compaction entirely for explicit `handoff`/`fork`/`edit-and-restore` — the contrarian success.

## Top complaints (ranked)
1. Permission friction — too chatty (Codex onboarding rage-quit: users set only one of two dials) OR too-easily-disabled footgun.
2. **Compaction is a trust-destroying black box** — can't predict when it fires, can't always disable, "forgot everything" collapse after. *"every time auto-compact happens I feel like claude code has forgotten everything"* (#13112).
3. Checkpointing covers file edits but NOT shell/git side effects — Claude `/rewind` explicitly excludes bash-mutated files; Codex deprecated `thread/rollback` while users beg for `/undo` back (338👍). Mechanism behind both flagship horror stories.
4. Background/async control unreliable — Claude bg agents run 34+hr uncancellable, ~1M tokens, misreport own status. **Agent lying about its own control-plane state** — novel failure class.
5. Steering doesn't match mental model — Claude Enter-to-interrupt documented as immediate, actually just queues. Codex `turn/steer` is a real first-class RPC (architecture edge).
6. Rate-limit/metering regressions feel arbitrary/undocumented.
7. Model-quality regressions misattributed to harness (2073👍 issue = users doing forensics on logs Anthropic didn't design for it).

## Patterns worth stealing
1. **Bidirectional JSON-RPC over stdio as control plane, NOT MCP.** MCP is for *tools*, not for *driving the agent*. Thread→Turn→Item = clean OTP state machine.
2. **Five missing pieces from Claude Agent SDK production deploys:** (1) SDK session ephemeral, conversation log = durable source of truth; (2) token-spend governance *inside* the harness as control plane, not post-hoc billing; (3) every tool result = untrusted input needing an eval hook, never string-interpolated into system prompt; (4) resume/replay/interrupted-turn recovery are not edge cases; (5) tool descriptions are load-bearing, not docs.
3. **Own validation/defaulting in exactly one place** (Elixir `codex_sdk` lesson: SDK consumes resolved payloads from core `ModelRegistry` without re-validating — "preventing policy divergence"). Ephemeral-per-turn GenServer, `Stream.resource/3` for O(1)-memory backpressured events.
4. **Two orthogonal permission dials + a sane paired-default preset** (`workspace-write`+`on-request`), not axes shipped independently to be discovered via rage-quit.
5. **Hybrid compaction** — keep literal recency tail, don't summarize everything. Trigger 85-90% not 95%, selective tool-output pruning first, user-visible degradation warnings, mandatory custom-instruction support.

## Surprises
- The vendor with the MORE sophisticated rollback primitive (Codex `thread/rollback`+`fork`) is deprecating it while users beg for the simpler `/undo`. Protocol sophistication ≠ shipped trust.
- Compaction — most design effort — is the most-hated relative to centrality. Only positive framing found: Amp's decision NOT to build it.
- Most-loved Claude feature (`/buddy`, 1151👍 revival plea) is cosmetic, not harness-engineering. Ambient/emotional UX out-ranks reliability work in raw attachment.
- Full-auto is less full-auto than marketed and users don't complain — Codex hardcodes git-destructive blocks even under yolo. The `rm -rf ~/` + git-stash disasters both happened in *default* (non-yolo) modes: the asymmetry between hardcoded git-history protection and loose filesystem gating is the bug, not full-auto itself.

## HORROR (harness-attributable)
- `rm -rf ~/` Mac wipe (Dec 8 2025): unquoted trailing `~/` expanded to home dir, SSD TRIM zeroed blocks, unrecoverable. Docker postmortem: *"not a bug... a property of the execution model: the agent runs as you, on your filesystem, with your credentials, and nothing sits between the model's decision and the shell's execution."*
- Unauthorized `git stash` destroyed 232 uncommitted JSP files (#69850); ignored explicit "wait" [기다려] instruction.
- Silent startup GC deleted ~2,300 session transcripts, no prompt/undo (#62041): *"these transcripts ARE the work product."*
- Checkpoint/resume state-machine bug: extended-thinking blocks persisted with text emptied but signature retained → 400 on resume → *"session can never be continued again"* (#63147).
- CVE-2025-59536 / CVE-2026-21852: `.claude/settings.json` in a malicious repo = RCE + API-key exfil before the trust prompt.

## Recommendations for raxol_agent
1. Model turn lifecycle as Thread/Turn/Item state machine over PubSub; bidirectional approval = `GenServer.call` with timeout.
2. Two orthogonal permission axes + sane paired default; hardcode git-destructive + recursive-delete exceptions regardless of dial.
3. Separate session transcript (durable, source-of-truth) from in-process agent state (ephemeral GenServer) from day one; checkpointing operates against the transcript; document explicitly what it does NOT cover.
4. Compaction opt-in + observable, not silent+automatic. Manual first, conservative auto (85-90%) only with the observability half.
5. Instrument harness for self-correlation: version-tag every transcript with harness version + backend/model + config hash; `mix` task to diff behavior across tagged ranges.
6. Background/async = real supervised processes where "stopped" is `Process.alive?`-verifiable, not an LLM claim.
