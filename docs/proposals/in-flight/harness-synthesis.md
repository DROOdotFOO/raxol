# Agent Harness — Cohort Research Synthesis (Phase 5–6)

Date: 2026-07-15
Inputs: 9 forum-first Sonnet research briefs (`harness-research/01`–`09`), priors in
`harness-cohort-research.md` written before dispatch.
Status: challenger tier (02) re-running after a stall; covered secondhand here,
refine on landing.

---

## 0. The one-paragraph verdict

The agent-harness cohort has converged on what the *loop* looks like (a visible
reason→act→observe cycle you can read in your own code) and is fighting a losing,
recurring war on everything *around* the loop: keeping state trustworthy across
compaction and resume, stopping a running turn, bounding blast radius and spend,
and telling model failure apart from harness failure. Those un-won fights are not
protocol-standardized and won't be — they are exactly where lock-in concentrates,
and they are **the same set of problems OTP was built to hold** (durable supervised
processes, kill-a-subtree cancellation, snapshotable state, restart-intensity
budgets). Raxol's durable-layer bet is not "a better loop" — vendor loops win coding
and the loop is commoditizing toward 100 lines of bash. It is **owning the stateful
seams the cohort leaves empty, across a surface (terminal/LiveView/SSH/MCP for one
loop) nobody else has.**

---

## 1. Calibration: priors vs. findings

The skill's honesty gate: *if research only confirmed priors, it was run wrong.* It
didn't. Priors were ~60% right; the corrections are load-bearing.

| Prior | Verdict | The correction that matters |
|---|---|---|
| Context lifecycle = pain #1 | **Confirmed + sharpened** | Not "window fills up." It's a *safety/correctness* failure: compaction summarizes away **constraints** (OpenClaw deleted 200+ emails after "suggest, don't execute" was compacted out) and silently corrupts state into **hallucination** (Claude Code #31330). Compaction and resume are **one destructively-interacting subsystem**, not two features. The unifying frame I lacked a name for: **verifiable state integrity** — the corpus's single measured switch-trigger. |
| Autonomy dial = pain #2 | **Confirmed + re-shaped** | Anchor number: **93% of permission prompts get blind-approved** (Anthropic, instrumented). Corrections: it's a **multi-axis** control surface (file/network/command-class/spend/duration/reversibility), not one slider; **placement > frequency** (confirm at irreversibility boundaries cut task time 13.5%, 81% preferred); enforcement must sit **outside the model** (COMPASS: 60–87% denylist failure under adversarial conditions). |
| Tool-substrate reliability | **Confirmed + upweighted** | Bigger than I rated it. **Format/contract violations are the single largest failure bucket** (36–82% across benchmarks). A pure patch-**extraction** plumbing choice swung SWE-bench Pass@1 by **54.3 points**, zero model change. And local-model "dumbness" is mostly a **plumbing gap** (Go-struct serialization, unsent `num_ctx`), not a capability gap. |
| Loop control (stall/budget/stop) | **Confirmed, re-clustered** | "Stop doesn't actually stop it" is **vendor-confirmed** (Cursor team) and closed **not-planned** at Anthropic — the highest-leverage safety item in the corpus. Cooperative-flag cancellation is structurally broken. |
| Workspace safety = harness's job or git's? | **Answered: harness's job, category-empty as a standard** | Users beg for **pre-apply confirmation over post-hoc undo**. Checkpoints that cover file-edits-but-not-shell are the mechanism behind the flagship disasters. |
| Observability & steering | **Confirmed, split** | Observability is a **multiplier** (lets 1/2/3 go undetected), not standalone severity. Steering is its own high-severity item. |
| Parallelism/session model | **Corrected — more niche than the hype** | The parallel-agent tooling boom looks **builder-supply-driven, not user-demand-driven** (9 Show-HN orchestrators; a head-of-eng asks *"why do you need 10 parallel agents… how is this even a workflow?"*; "couldn't run more than three sessions — attention is the limiter"). Cognition's "Don't Build Multi-Agents" + evidenced-patterns-only reinforce. **Do not headline swarms.** |
| **Differentiation prior** ("durable supervised runs = cohort-empty") | **Corrected in the most useful direction** | On BEAM it is *not* empty — it's the **most independently-reinvented pattern** (everyone hand-rolls it on Oban). The genuine white space is narrower and better: **a multi-surface front end for one agent loop.** And the real strategic frame (protocols brief): the durable layer = the category-empty seams = **exactly OTP's home turf.** |
| Deeper question ("is the durable layer the loop or the protocol?") | **Answered: neither — it's the STATE** | The loop commoditizes (mini-SWE-agent: 100 LOC bash beats elaborate scaffolding on strong models; own-loop value concentrates in **weak/local models** where plumbing dominates, and **non-coding agents** where vendor loops don't go). Protocols are commodity (consume them). The moat is the stateful seams you own. |

---

## 2. Decomposition by pain (severity × irreversibility, not frequency)

Six clusters. Ordered by severity × irreversibility (the quiet-but-fatal float up),
with the frequency rank noted where it differs.

### C1 — State integrity *(freq #1, the substrate under all others)*
Compaction + resume + memory as one subsystem. Failure signature is **silence**:
no crash, model behaves "normally" on corrupted state, so nothing prompts a
double-check (#31330 → hallucinated numbers to fill a lost gap). Constraints living
in the prompt die at compaction (OpenClaw). *"compaction itself is the bug"* (#21925).
**This is the measured switch-trigger** — the one team that wrote a switching *policy*
did so over context integrity: *"if an agent fails twice, switch engine… the CLI's
context management is the bottleneck, not the model"* (#42542).

### C2 — Blast-radius containment *(freq #9, severity #1)*
Irreversible actions. Every documented destructive incident was **cooperative, not
adversarial** — the model confidently trying to help, no internal uncertainty signal.
Checkpoints cover file-tool edits but **not shell/git side effects** — the exact gap
behind `rm -rf ~/`, the git-stash disaster, the Terraform destroy. The worst
(~800GB) was **harness housekeeping, not an agent action at all** — no transcript,
no prompt, no Recycle Bin. Defense needed = a blast-radius check **independent of the
model's confidence**, because the confidence is what fails.

### C3 — Control plane: steering + spend + autonomy *(one family — "cost and control are the same bug")*
The corpus's sharpest structural finding: #68619 is simultaneously the top
cost-anxiety quote (4M tokens / 5 min) and the top steering quote (interrupt loses
all in-flight work from every agent in the tree). Treating billing and control as
separate product surfaces is a design error. Sub-parts:
- **Interrupt = kill, not a cooperative flag.** "Stop doesn't stop it," vendor-confirmed.
- **Steer ≠ interrupt** — two distinct signals (inject-at-next-safe-boundary vs kill-now); users beg Claude Code to copy Codex's `turn/steer`.
- **Spend gated before the next call, not after the bill.** Per-run caps exist only in goose (`--budget`) + OpenHands; the leaders ship account-level only.
- **Autonomy = multi-axis + placement-aware + ambient-not-interactive.** Ambient/structural guardrails survive; interactive ones erode to rubber-stamp (93%).

### C4 — Tool substrate reliability *(freq #5, widest breadth)*
Format/contract validation is the largest failure bucket. The same failure shape
recurs across 15+ unrelated repos and defaults to **"the local model is dumb"** when
the real fault is serialization/streaming/template plumbing — *"false intelligence
capability accusations"* (Cline #10843). Curated task-scoped tool exposure (20–40
tool degradation ceiling). The multi-provider landmine: **opaque reasoning-continuity
tokens** (`thinking.signature` / `reasoning.encrypted_content` / `thought_signature`)
that hard-fail if not replayed byte-for-byte — five OSS projects broke on Gemini's
alone, incl. Google's own SDK. Rule: **never filter content blocks by type when
replaying history.**

### C5 — Trust boundary / injection *(low freq, high irreversibility)*
Lethal trifecta (private data + untrusted content + exfil channel). Tool poisoning
fires **at connection time, before any approval** (Trail of Bits "line jumping") — so
invocation-time gates are insufficient by construction. Tool descriptions *and*
results are both untrusted input. Only reliable mitigation: **never assemble all
three capabilities in one unsupervised context** — a by-construction property, not a
classifier.

### C6 — Observability *(the multiplier, not standalone severity)*
The reason C1/C2/C3 go undetected as long as they do. Hiding what the agent
reads/knows → *"I now trust the LLM less, not more"* (a UI change netted −83 reactions
against Anthropic's own lead defending it). Raxol's Time-Travel Debugging already
answers most of this for free **if the agent action log is wired into the same
snapshot mechanism** rather than built separately.

---

## 3. Category-empty differentiation opportunities

The protocols brief's seam map: these are empty *because they're where lock-in lives
and no incumbent will standardize away their moat.*

1. **Session / transcript / checkpoint / resumability format** — empty **and regressing**
   (MCP's 2026 RC *removed* SSE resumability). The clearest opening in the map.
2. **Permission-policy exchange** — no standard for expressing a *policy* ("reads here,
   never network"); ACP's `request_permission` is a runtime prompt, MCP annotations are
   untrusted hints. Raxol's `SpendingPolicy` is already a bespoke instance of the empty thing.
3. **A multi-surface front end for one agent loop** — terminal/LiveView/SSH/MCP over a
   single supervised loop. **Nothing in the entire survey has this shape.** Raxol's actual proposition.
4. **Post-hoc review UX as a story** for the operator's own trust-rebuilding (not a
   compliance transcript) — universally absent.

**The isomorphism (the keystone):** the category-empty seams and OTP's home turf are
*the same set.* Anthropic's own long-running-harness postmortem describes hand-rolling
"engineers working in shifts with no memory of the previous shift," file-based handoff,
manual context resets — a poor-man's supervised-durable-process with hand-rolled
checkpointing. That's `GenServer` + supervision tree + `:pg` + the CRDT swarm layer,
native. The ecosystem hasn't standardized these because in Python/TS they're genuinely
hard and every solution is bespoke. **On BEAM they're the substrate. The market's empty
seam is the platform's strongest muscle** — and that coincidence is the whole thesis.

---

## 4. What Raxol already has right (validate, don't rebuild)

- **TEA `update/2` + explicit `Command` types = the visible loop.** Directly validated
  against the LangChain backlash, whose #1 grievance was epistemic — *inability to
  inspect/modify agent state mid-run.* Explicit-state architecture solves it by
  construction. Don't add a graph/DSL compiler over control flow (Elixir has
  `with`/pattern-match/processes; that compiler exists in Python only to buy back the
  inspectability BEAM already has).
- **`Authorization.Engine` ALLOW/ASK/DENY with `:once`/`:session`/`:root` scope** —
  already **ahead of the cohort**: `:root` remembers one human decision across an entire
  spawn tree, covering multi-agent fan-out that *none* of the six researched harnesses
  handle (beats even Devin's once/session/permanent buttons).
- **`ToolPolicy.deny_sensitive`** = MCP's `destructiveHint` but **trustworthy** (compiled
  Elixir in your own tree vs. self-reported by an untrusted external MCP server). Worth
  stating explicitly in docs as a structural advantage of "tools are modules, not remote
  servers with self-declared metadata."
- **`raxol_symphony`'s two-`Runner` shape** (`Runners.RaxolAgent` native + `Runners.Codex`
  subprocess) = validated by **OpenAI's own Symphony being Elixir-on-BEAM and hybrid**
  (OTP supervises, vendor subprocess reasons). Double down on the Runner abstraction; don't
  collapse to one approach.
- **`raxol_payments` `Ledger`/`SpendGate`/`try_spend`** = the exact atomic pre-call
  reservation pattern the whole cohort lacks for blast-radius and token spend. Generalize it.
- **`Raxol.Debug.TimeTravel` + `Raxol.Recording`** = most of the deterministic-replay +
  observability infra the eval-science literature says production harnesses lack.

---

## 5. Dispositions (Phase 6)

### Architectural decisions (change a commitment now)
- **AD-1 Interrupt = supervision-tree kill, not a cooperative flag.** Process-per-turn;
  interrupt terminates a supervised subtree. Closes the "Stop doesn't stop it" class at
  the architecture level. *(C3; user-voice #1 recommendation)*
- **AD-2 Steer and interrupt are two distinct OTP messages** to the session process —
  inject-at-next-safe-tool-boundary vs. kill-now — never a queue the loop must remember
  to poll. *(C3)*
- **AD-3 Compaction and resume are one subsystem.** The checkpoint is a **real term/struct
  snapshot** (task + plan-with-completion-status + touched-artifacts-with-hashes), **not
  prose**, and it is the *same* artifact whether recovering from compaction or a crash.
  GenServer state → snapshotting real terms is native, not a stretch. *(C1)*
- **AD-4 Tool-call validation layer at the dispatch boundary** — reject malformed calls
  (wrong types, stripped history, un-serialized structs) loudly and specifically **before**
  they reach the Port, with an actionable re-prompt. Largest-failure-bucket ROI. *(C4)*
- **AD-5 Continuity-token discipline: never filter content blocks by type when replaying
  history.** Bake into the `Backend.HTTP` multi-provider path. *(C4)*
- **AD-6 Blast-radius gate** — generalize the `Ledger` pattern: any `:shell`/FS/DB-touching
  Action atomically reserves against a supervised gate **before** `Port.open`, fail-closed.
  *(C2)*
- **AD-7 Safety constraints are typed TEA-model state enforced outside the model's context,**
  not prose in the prompt — `update/2` pattern-matches and rejects structurally. Sidesteps
  the OpenClaw compaction-drops-the-constraint failure entirely. *(C1/C2)*
- **AD-8 Own the MCP JSON-RPC wire directly.** No Elixir MCP SDK dependency (Hermes died →
  Anubis, license flipped to LGPL; none stable). The 2026 stateless RC makes direct
  implementation *easier*. Keep the native tool model primary; MCP is one adapter. *(protocols)*

### Foundation invariants (cheap now, painful to retrofit)
- **FI-1 Session transcript = durable source-of-truth, separate from ephemeral GenServer
  state, from day one.** Checkpointing operates against the transcript; document explicitly
  what it does *not* cover.
- **FI-2 Version-tag every transcript** (harness version + backend/model + config hash) so a
  future behavior change is attributable — the 2073👍 "Claude regressed" forensics done *for*
  you, cheaply. *(eval-science)*
- **FI-3 Housekeeping/cleanup code is gated + audited identically to an agent command.** The
  800GB deletion wasn't agent-initiated; "the harness did it" is not a distinction users credit.
- **FI-4 Reserve the kernel-sandbox seam at the `Port` boundary** (Seatbelt / bubblewrap+Landlock).
  BEAM isolation stops at the VM edge; a shell subprocess is outside it. Route the Shell directive
  through a wrappable point even before enforcement ships. *(permissioning, C5)*
- **FI-5 Trust-taint marker on tool outputs from untrusted sources**; any later call whose args
  derive from tainted content takes a distinct confirmation path or privilege-stripped sub-call. *(C5)*
- **FI-6 Completion events carry a verification artifact** (test output, diff, exit code) as
  first-class, not prose — gate "done" on evidence. *(C1/observability)*

### Explicit non-commitments (name it, defer it, note why)
- **NC-1 No graph/DSL loop compiler** — the language already has the primitives it buys back.
- **NC-2 Don't headline parallel-agent swarms.** Default single-agent + the one evidenced
  multi-agent pattern (separate-context reviewer). Builder-supply-driven demand; "couldn't run
  >3"; Cognition "Don't Build Multi-Agents." Keep `Agent.Team` for coordination, not peer swarms.
- **NC-3 Don't expose Raxol as an ACP *server* yet** — it relocates you to the commodity side
  (one dropdown entry; the editor becomes durable). Reserve; adopt only if editor-distribution
  becomes an explicit goal, eyes open.
- **NC-4 Don't adopt A2A** (intra-fleet `Registry`/`Team` covers it), **AG-UI** (LiveView
  MCP-diff covers it), or **Temporal-grade durable execution** (GenServer + Oban-style
  persistence suffices; HN "just a task queue with retries").
- **NC-5 Don't build server-drives-your-LLM (MCP Sampling/Roots)** — deprecated protocol-wide.

---

## 6. Reusable diagnostics (extract to the cohort-research skill library)

- **Empty-seam == platform-home-turf test.** When the category-empty differentiation seams
  coincide with what your runtime natively provides, that convergence *is* the moat, not a
  coincidence — build there. (Raxol: durable state seams ≡ OTP.)
- **Commodity-vs-durable via protocol direction.** Consuming a protocol entrenches you above a
  commoditized complement; *exposing* one puts a commoditized copy of you on someone else's
  platform. Check which way each integration points before adopting it. (LSP→editors win;
  ACP→editors win, agents commoditize.)
- **Plumbing-gap masquerading as capability-gap.** When a component reads as weak ("the local
  model is dumb"), inspect the serialization/streaming/template layer before believing the
  capability story. Misattribution defaults to the least-trusted component.
- **Same-bug-two-departments.** When two "separate" pain clusters share a single root incident
  (cost + control both live in #68619), don't split them across product surfaces — they're one
  failure viewed twice.
- **Ambient beats interactive for guardrails.** A safety mechanism demanding the same repeated
  human judgment degrades measurably to rubber-stamp (93%); make guardrails structural /
  compile-time / supervision-level properties instead.
- **Cooperative-cancellation is structurally broken.** "Stop" implemented as a flag the loop
  must check will fail mid-tool-call. Kill a supervised subtree instead.

---

## 7. Meta-review — what could this research have missed?

- **Reddit was environment-blocked** → the user-voice corpus skews power-user / "$200-mo" /
  team-lead. Casual-user pains (onboarding confusion, first-run friction, mental-model
  mismatches) are under-sampled. *Second-pass candidate.*
- **Challenger tier (opencode/goose/amp/Aider/OpenHands/Gemini CLI) is secondhand here** — the
  dedicated agent stalled and is re-running. Fold its "innovations users praise vs ignore" and
  "converging vs fragmenting" answers into §2/§4 on landing.
- **No cost model.** Every finding is qualitative; none priced the engineering. A build-order
  pass (which AD/FI first, effort vs. leverage) is the natural next step *before* implementation.
- **Non-coding agents under-covered.** The whole cohort is coding-agent-shaped; Raxol's own-loop
  value partly rests on ops/payments/sensor agents where vendor loops don't go — that space got
  little forum signal (it may barely exist yet = opportunity or void, unresolved).
- **Raxol's actual current code was read only secondhand** (via the permissioning agent's spot-read
  of `authorization/`, `sandbox.ex`, `tool_policy.ex`). Before implementing any AD, verify the
  present state of `Agent.Session`/`Directive.Executor`/`Turn` firsthand — the dispositions assume
  a shape that should be confirmed, not trusted.

---

## 8. The build-order one-liner

**Consume the settled protocols (MCP wire, LLM APIs), own the empty ones (state,
checkpoint, policy, compaction), be deliberate about the provider-facing protocols that
trade durability for reach — and build the durable core on the OTP primitives that happen
to be exactly what the whole cohort is hand-rolling badly.** First stone: the
state-integrity subsystem (AD-3 + FI-1), because it's the substrate under C1–C3 and the
one measured switch-trigger. Second: the control plane (AD-1/AD-2/AD-6), because "stop
doesn't stop it" is the highest-severity-per-unit-effort fix in the corpus.
