# Agent Harness — Cohort Research (Phase 1–2: frame + priors)

Date: 2026-07-15
Status: priors written BEFORE research returned (calibration discipline).
Protocol: cohort-research skill (dappsnap). Research horde: 9 Sonnet agents, forum-first.

## Phase 1 — Frame

**User pain, not feature:** A developer hands multi-step work to an agent
("fix this bug", "run this migration", "watch this deploy") and needs to
trust it to finish — without losing the plot mid-task, without wrecking
the workspace, without burning $40 in a loop, and without demanding an
approval click every 20 seconds. The *harness* is everything between the
raw LLM API and that trust: the loop, tool dispatch, context lifecycle,
permissioning, checkpointing, steering, observability.

Raxol context: `raxol_agent` has the parts (Strategy.ReAct, Turn,
Authorization.Engine, ToolPolicy, Actions, backends w/ SSE, Curator,
Teams) but no assembled harness — nothing owns the loop end-to-end the
way Claude Code / Codex / OpenHands own theirs. The Selector already
reserves `:claude_native` / `:codex` / `:cursor` as "vendor owns the
loop" — so the standing architectural fork is: **build our own loop,
host vendor loops, or both.**

**JTBD frame:** "I want to delegate real work to an agent running on my
infra, steer it while it runs, and survive its mistakes."

## Phase 2 — Priors (marked confident vs guessing)

### Expected decomposition (7 concerns)

1. **Context lifecycle** — window fill, compaction losing the plot,
   session resume, memory. Expect this to be pain #1. [CONFIDENT]
2. **Autonomy dial / permissioning** — approval-fatigue ↔ YOLO
   disasters; users train themselves to blind-click. [CONFIDENT]
3. **Tool substrate reliability** — schema validation, retries,
   hallucinated tools, MCP servers eating context, local models unable
   to tool-call. [CONFIDENT-ish]
4. **Loop control** — stall detection, turn budgets, cost caps, stop
   conditions. [GUESSING at how it clusters]
5. **Workspace safety** — checkpoint/rollback, git integration,
   sandboxing. [GUESSING whether users see this as harness's job or git's]
6. **Observability & steering** — streaming, plan visibility,
   mid-run interruption/redirect, transcripts/replay. [GUESSING]
7. **Parallelism/session model** — subagents, background tasks,
   worktrees. [GUESSING — may be niche power-user concern]

### Expected complaints

- "Compaction forgot what we were doing" / context rot
- Permission prompts as security theater (blind-approve reflex)
- MCP tool sprawl eating the context window
- Runaway loops burning money; no cost ceiling
- `--resume` never actually restores working state
- Local models (Ollama/LM Studio) break on tool-calls
- Observability = raw JSON logs, no replay

### Expected differentiation (DOMAIN-INTERNAL BIAS — research must test)

BEAM/OTP: crash-isolated turns under supervision, process-per-agent
parallelism, state-machine checkpointing, hot reload mid-session.
Raxol-specific: terminal UI first-class, MCP-as-rendering-target,
time-travel debugger already in repo (potential killer observability).
Suspicion: cohort-empty space around *durable/resumable agent runs as
supervised processes* — everyone else is a single OS process that dies.

### Expected failure modes

- LangChain-shape backlash: abstraction tax, framework obscures prompts
- Protocol churn (MCP versions, vendor APIs)
- "Demo great, real-work bad" (AutoGPT shape)
- Unbounded-autonomy incidents (Replit DB deletion, rm -rf YOLO stories)

### The deeper question

Is the durable layer the **loop** or the **protocol**? If vendor loops
(Claude Code, Codex app-server) keep winning, the harness's real value
may be *hosting + supervising + multiplexing* vendor loops (ACP-style
client), not reimplementing ReAct. Or: own-loop matters precisely for
the non-coding agents (ops, payments, sensors) where vendor loops don't
go. Research should test which.

## Phase 3 — Cohort (9 briefs)

1. Leaders: Claude Code, Codex CLI/app-server
2. Challengers: Gemini CLI, opencode, amp, goose, Aider, OpenHands
3. Framework-as-library: LangGraph, pydantic-ai, Vercel AI SDK, Mastra, smolagents, OpenAI Agents SDK
4. Elixir/BEAM cohort: Jido, Ash AI, LangChain-Elixir, Oban-pattern agents
5. Theory/standards: MCP, Zed ACP (agent-client-protocol), AG-UI, stream-json, tool-use API shapes, compaction/checkpoint patterns
6. Cautionary tales: AutoGPT, Replit incident, Cursor YOLO deletions, prompt-injection-via-tools, cost blowouts, LangChain backlash
7. Autonomy/sandboxing domain experts: permission models, sandboxes (E2B, Daytona, containers, sandbox-exec), spend caps
8. User-voice sweep: HN/Reddit/Discord/GitHub-issues pains, incl. local-model harness pain
9. Eval-harness science: SWE-bench/terminal-bench harness design; "harness quality changes model performance" findings

## Synthesis checklist (Phase 5 gate)

- [ ] Priors corrected somewhere? (If only confirmed → ran it wrong)
- [ ] 5–8 pain clusters, not feature clusters
- [ ] Surprises explicitly listed
- [ ] Per finding: decision / foundation-invariant / non-commitment
- [ ] Category-empty opportunities named
- [ ] Failure modes with attribution
- [ ] What did research NOT cover → second pass?
