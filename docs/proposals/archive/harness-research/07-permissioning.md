# Autonomy dial: permissioning, sandboxing, spend: distilled

## The one hard number
**Claude Code: users approve 93% of permission prompts** (Anthropic, instrumented, first-party). Manual per-action approval degrades to rubber-stamping at scale, not a hypothesis. Their fix wasn't a bigger allowlist, it was a two-stage classifier + ambient sandboxing (−84% prompts). SOC-team analogue: 4,484 alerts/day, 67% ignored to false-positive fatigue.

## The axes users actually want (vs the one linear mode slider every tool ships)
Every harness ships ONE scale (Manual→Bypass). Evidence says the real surface is multi-dimensional + independent:
1. **File-write scope**: workspace / outside / protected-paths (universal)
2. **Network/egress**: domain allowlists, orthogonal to file writes (backstop against exfil regardless of FS policy)
3. **Command class**: shell vs edit vs browser vs MCP (Cline ships 5 separate toggles)
4. **Spend/compute**: orthogonal; only goose + OpenHands treat it as first-class
5. **Duration/temporal scope**: Devin ships allow-once/session/permanent as 3 buttons; IAM research converges on time-bound consent
6. **Reversibility**: the axis that determines *whether an axis needs a prompt at all*

Academic backing: Engin & Hand "Dimensional Governance" (Decision Authority × Process Autonomy × Accountability, continuously tracked, not fixed tiers); Feng et al. five roles (Operator→Collaborator→Consultant→Approver→Observer), "autonomy is a design decision separate from capability."

## Sandbox tech: composes in LAYERS not one choice
Codex's own stack = bubblewrap AND Landlock simultaneously, each closing the other's gaps. macOS Seatbelt (`sandbox-exec`), Linux Landlock+seccomp+bubblewrap, Docker (weak, shared kernel), gVisor, Firecracker microVMs (E2B ~150ms, GPU passthrough), Daytona (~90ms, weaker), WASM/WASI (best for *tool* isolation: inert-by-default capability model). **Denylist-vs-allowlist is settled in the literature:** Cursor denylist bypassed 4 ways, Claude Code denylist beaten by binary-padding (hash evasion), COMPASS shows 60-87% adversarial failure on denylist enforcement. Yet allowlist-by-default remains minority (only Codex + Wassette). Di Donato (Falco creator): *"Claude Code's sandboxing is a complete joke. There should be no 'off switch.' Sandboxing should not be opt in."*

## Spend controls: the absence pattern
Per-run hard cap: **only goose (`--budget 1.00`) + OpenHands (MAX_ITERATIONS+cost cutoff)**. Claude Code/Cursor/Codex ship strong *account/org*-level caps but NONE ships a `--budget` at the CLI-invocation level: the exact layer where a runaway loop does damage. Uber burned annual AI budget in 4 months (leaderboard-driven); $500M/month anon story. Root cause both = organizational (no cap set), not technical (cap unavailable). Convenience-wins again.

## Policy engines: real, not vaporware
OPA (Rego) + Cedar are real production (AWS Bedrock AgentCore Policy GA March 2026, Cedar: default-deny, forbid-wins, order-independent, no side effects). **COMPASS paper is the load-bearing citation:** models 95%+ on allowed queries but **60-87% error on denylist enforcement under adversarial conditions.** Enforcement MUST sit outside the model's control at tool-dispatch layer. "Prompt the model with the rules" is the actual vaporware.

## HITL UX research: concrete + convergent
- **CDCR study** (48-participant, causal): intermediate confirmation at *irreversibility boundaries* cut task time 13.54%, 81% preferred over blanket/end-only. **Placement > frequency.**
- Crosley's four failure modes of approval-as-consent: **scope loss** (see tool name not blast radius), **evidence loss** (justification invisible), **fatigue**, **persuasion** (confident agent talks past scrutiny). Maps to real incidents: scope loss = Cursor `cd &&` escalation; persuasion = "YOLO THROUGH THIS" verbal override.
- Show intent + blast-radius + alternatives in plain language, not a tool name. Jargon correlates with worse (faster, less-considered) approvals.
- Batching: review a coherent diff of 20 changes > 20 individual prompts.

## Category-empty
1. **A standardized cross-client approval protocol**: MCP has no `approval/request` method, no `requiresApproval` field. Issue #711 proposed, unmerged. Every client reimplements incompatibly. Cleanest empty category.
2. Audit-trail interchange standards (no OTel-equivalent for "what did the agent do").
3. Post-hoc review UX as a *story* for the operator's own trust-rebuilding, not a compliance transcript.
4. Network-egress default (only Codex defaults to no-network).

## Gemini CLI's under-copied idea
**yolo mode CANNOT be set as a default in settings.json: must be a CLI flag every invocation.** Structurally prevents the maximally-dangerous mode becoming a silent permanent default. Directly targets disable-rate. Near-absent from the other 5 harnesses.

## raxol_agent already ahead
`Authorization.Engine` ALLOW/ASK/DENY reducer has scoped approval memory `:once`/`:session`/`:root`: `:root` remembers across an entire spawn tree from one human decision. **Better than anything in the cohort**: it's the temporal scoping Cursor's forum begs for AND covers multi-agent fan-out (Devin's 3-button doesn't). `ToolPolicy.deny_sensitive/0` = MCP `destructiveHint` but *trustworthy* (compiled Elixir in your own tree vs self-reported by untrusted external MCP server).

## Gaps the codebase already names
`Sandbox` moduledoc: filesystem/network/resource dims "planned but deferred." Actionable:
- **FS/network dim:** wrap the `Shell` directive's `Port` in Seatbelt/bubblewrap+Landlock. None of PermissionHook/ToolPolicy/Authorization.Engine can constrain what happens *after* `Port.open`: BEAM isolation stops at the VM boundary; a shell subprocess is outside it. Checking the command string before spawning is necessary but OS-level enforcement is what makes the check's promise true once running.
- **Resource dim:** `raxol_payments` `Ledger` (ETS GenServer, atomic `try_spend`) is the right pattern: extend it to per-session/per-root-spawn *token/cost* budget (raxol has no equivalent for its own LLM spend yet). Puts raxol ahead of Claude Code/Cursor (account-level only).

## BEAM/OTP genuine advantages
- Crash isolation as a *safety* property: PermissionHook stores policy in the calling process dict, naturally scoped, no shared global mutable state to corrupt (Cursor's allowlist misfiring across versions = exactly that shared-state bug class).
- Supervision-tree circuit breaker structurally guaranteed to run vs Claude Code's in-band "3 consecutive/20 total denials" counter. A spend/denial breaker as a supervised sibling GenServer that dispatch must call *through* > a counter in the same process as the loop. Nearly free in OTP.
- **Honest limit:** none of this substitutes for kernel sandboxing of anything leaving the VM via `Port`. Conflating BEAM isolation with host isolation is the one mistake to avoid: Codex + Claude Code learned it the hard way (in-process denylists bypassed; answer was kernel sandboxing underneath).

## Deeper question: trustworthy consent = 5 properties (mostly not UX)
1. **WYSIWYG fidelity is a technical guarantee**: every "prompt lied" failure is a mechanism failure (padded binary, `cd &&` composition, unseen shell var), not wording. Kernel sandboxing is a *prerequisite* for trustworthy prompts.
2. **Placement > frequency**: ask at irreversibility boundaries (CDCR causal evidence).
3. **The harness must ration its own prompt volume**: trust is shared+depletable across all prompts; every low-signal "are you sure?" spends down the next one's credibility. Claude's effort went to suppressing false positives (8.5%→0.4%), not better copy.
4. **Content = intent + blast-radius + alternatives**, plain language, not a tool name.
5. **Consent needs a backstop**: reversibility (git-tracked, escrowed writes, checkpointing) makes a misclick survivable; that confidence is what lets users actually engage with prompt N instead of reflex-clicking.
