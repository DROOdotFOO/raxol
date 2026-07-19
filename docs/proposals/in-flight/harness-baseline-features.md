# Baseline Good Harness — Feature Floor

Date: 2026-07-15
Status: reference list (the "table stakes" floor, not the differentiators).
Companion to `harness-design.md` (the seven concepts + architecture) and `harness-synthesis.md`
(the research these are drawn from).

This is the answer to "what does a baseline *good* harness have?" — the floor every credible
2026 agent harness clears, split into **UI capabilities** (the frontend/TUI a person looks at)
and **AI-harness capabilities** (the agent runtime behind it). It is deliberately *not* the
differentiators — the seven concepts and the durable-seam thesis live in `harness-design.md`.
This list is what you need just to not lose.

**† marks a load-bearing item** — one the research corpus flags with a measured effect size or
cross-cohort recurrence, i.e. where a *baseline* feature done wrong is itself a headline failure.
The †-items are the floor that is secretly a ceiling: most harnesses ship a weak version and that
weakness *is* their top complaint. These are exactly where the design doc's architecture decisions
(AD-1…AD-8, FI-1…FI-6) concentrate.

---

## A. UI capabilities (the frontend floor)

- **A1. Streaming token render †** — incremental output as it arrives, no full-screen repaint per
  chunk, no flicker. Raxol's `r1-incremental-render` + the two-tier `text_delta` stream is this.
  Table stakes; where harnesses feel "slow" it's usually repaint, not the model.
- **A2. Interrupt / cancel mid-stream †** — a key (ESC) that *actually* stops the running turn,
  now, including in-flight tool calls. The corpus's single highest-leverage safety item: "Stop
  doesn't stop it" is vendor-confirmed (Cursor) and closed not-planned at Anthropic. Baseline to
  *offer*; load-bearing to get *right* (→ AD-1 kill-not-flag).
- **A3. Steering (inject-while-running) †** — send a new instruction that lands at the next safe
  boundary without killing the turn; distinct from A2. Users beg Claude Code to copy Codex's
  `turn/steer`. Two signals, not one (→ AD-2).
- **A4. Transcript + scrollback** — full conversation history, navigable, searchable, copy-able.
  The thing the operator rebuilds trust from.
- **A5. Diff rendering †** — syntax-highlighted before/after for every file edit, shown
  **before apply** where possible (users beg for pre-apply confirmation over post-hoc undo — C2).
- **A6. Approval prompts** — allow / deny / always-allow on gated actions, with enough context to
  decide. Baseline; the research caveat is that *interactive* approval erodes to rubber-stamp
  (93% blind-approve) — so this is necessary but not sufficient (the fix is ambient guardrails,
  a design-doc concern, not a baseline one).
- **A7. Status / context indicators †** — live context-window %, token count, running cost, active
  model, turn state. Hiding what the agent knows nets *"I trust the LLM less, not more"* (a UI
  change that hid context lost 83 net reactions). Observability is the multiplier under every other
  failure (C6).
- **A8. Multi-line input** — paste, edit, invoke `$EDITOR`, history recall. Keyboard-first.
- **A9. Markdown / rich text render** — code blocks, lists, tables, emphasis; the model speaks
  markdown, the UI must too.
- **A10. Session resume / reattach †** — close the UI, come back, continue; attach a second surface
  to a live run. This is the seam the whole `harness-design.md` thesis is built on (L1/L2/L5) — and
  it's category-empty *and regressing* across the cohort (MCP's 2026 RC removed SSE resumability).
  Baseline to claim, differentiator to actually own.
- **A11. Slash commands / command palette** — discoverable actions, quick config, mode switches.
- **A12. File / @-mention references** — pull a path/symbol into context by reference, not paste.
- **A13. Progress indication for long ops** — spinner/step/elapsed for tool calls and long turns;
  the difference between "working" and "hung."
- **A14. Theming + color** — legible, configurable, respects terminal capability (Raxol's
  capability-detection + theming already covers this).

## B. AI-harness capabilities (the agent-runtime floor)

- **B1. Multi-provider streaming †** — real SSE from Anthropic / OpenAI / local (Ollama/LM Studio),
  each provider's format handled. Raxol's `Backend.HTTP` already does the four SSE shapes.
- **B2. Tool / function-calling loop** — the visible reason→act→observe cycle. The cohort has
  *converged* here; it's commoditizing toward ~100 lines of bash (mini-SWE-agent). Table stakes,
  not a moat.
- **B3. Tool-call contract validation †** — reject malformed calls (wrong types, un-serialized
  structs, stripped history) before dispatch, with an actionable re-prompt. **The single largest
  failure bucket (36–82%);** a pure extraction-plumbing choice swung SWE-bench Pass@1 by 54.3
  points with zero model change. The highest-ROI baseline item there is (→ AD-4).
- **B4. Context / token management + compaction †** — stay under the window without silently
  corrupting state. The corpus's #1 pain and its subtlest: compaction summarizes away *constraints*
  (OpenClaw) and corrupts state into *hallucination* (#31330) with no crash to signal it.
  Baseline to have; the design doc's C2 (structured multi-track compaction) is the differentiated
  version (→ AD-3, FI-1).
- **B5. Permission / approval enforcement †** — gate tool calls **outside the model's context**,
  not via prompt instructions. Denylists fail 60–87% under adversarial conditions (COMPASS); the
  constraint must be structural (→ AD-7). Raxol's `Authorization.Engine` (ALLOW/ASK/DENY ×
  once/session/root) is already ahead of the cohort here.
- **B6. Multi-turn conversation state** — durable turn/message history the loop folds over. In the
  design doc this becomes the event journal (L4).
- **B7. System-prompt / instruction files** — CLAUDE.md / AGENTS.md-style project + user
  instructions layered into context. Baseline caveat: prose instructions get compacted away and
  ignored (bloat → rule-ignoring) — which is *why* the design doc splits hard constraints into
  enforcement (C2/AD-7).
- **B8. MCP client †** — consume external tools over the MCP wire. Own the JSON-RPC directly; no
  stable Elixir MCP SDK exists (Hermes died → Anubis, license flipped LGPL). The 2026 stateless RC
  makes direct implementation easier (→ AD-8). Keep native tools primary, MCP as one adapter.
- **B9. Cost / usage tracking + limits †** — per-run and per-session spend, gated **before the next
  call, not after the bill**. Cost and control are the same bug (#68619 is both the top cost quote
  and the top steering quote). Only goose + OpenHands ship per-run caps; the leaders ship
  account-level only. Raxol's `Ledger`/`SpendGate`/`try_spend` is the exact atomic-reservation
  pattern the cohort lacks (→ AD-6).
- **B10. Checkpoint / rollback †** — restore prior state after a bad turn, covering **shell/git
  side effects, not just file edits**. Checkpoints-that-miss-shell is the mechanism behind the
  flagship disasters (rm -rf, git-stash loss, Terraform destroy). Baseline to claim; the
  gap is where the incidents live (C2, FI-3).
- **B11. Model selection / switching** — pick or swap model mid-session; the one team with a
  switching *policy* wrote it over context integrity ("if an agent fails twice, switch engine").
- **B12. Retry / error recovery** — handle provider errors, rate limits, transient tool failures
  without losing the turn. Includes continuity-token discipline: **never filter content blocks by
  type when replaying history** (opaque reasoning tokens hard-fail if not replayed byte-for-byte;
  five OSS projects broke on Gemini's alone) (→ AD-5).
- **B13. Session persistence** — the run survives process/restart; transcript is durable
  source-of-truth separate from ephemeral GenServer state (→ FI-1). The BEAM-native version of the
  thing every Python/TS harness hand-rolls on Oban.
- **B14. Shell / exec tool** — run commands, capture output, in a wrappable boundary (reserve the
  kernel-sandbox seam at the `Port` edge — Seatbelt/bubblewrap — since BEAM isolation stops at the
  VM edge) (→ FI-4).
- **B15. File edit tools** — read/write/patch with the extraction-format that doesn't blow up B3.
- **B16. Sub-agent spawning** — delegate a scoped task to a child context. Baseline to *have*;
  the research says **don't headline swarms** (builder-supply-driven, not user-demand; "couldn't
  run >3"; Cognition "Don't Build Multi-Agents"). Default single-agent + the one evidenced pattern
  (separate-context reviewer) (→ NC-2).

---

## C. How to read this list against the design

- **The floor is mostly commodity.** B2 (the loop) and most of section A are converged and
  cheap; shipping them is table stakes, not advantage. The design doc explicitly does **not**
  headline the loop.
- **The †-items are the floor that's secretly the ceiling.** A2/A3/A10, B3/B4/B5/B9/B10 — every one
  is a "baseline" feature whose *weak* version is some harness's top complaint. The synthesis's
  AD/FI dispositions are almost entirely about doing these †-items right, and doing them right is a
  BEAM/OTP home-turf move (supervised kill for A2/AD-1; durable snapshot for A10/B13/AD-3;
  atomic reservation for B9/B10/AD-6).
- **The seven concepts sit *on top* of a solid floor, not instead of it.** C1–C7 in `harness-design.md`
  are cheap only once B4 (real compaction), B6 (the journal), and B5/B9 (the gate) exist. Build
  order (design doc §9): the keystone emit → journal → contract → interrupt+spend gate → *then* the
  probe swarm. Don't invert it.
