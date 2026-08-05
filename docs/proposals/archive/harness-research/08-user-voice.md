# Raw user-voice pain sweep: distilled

**Methodology caveat:** Reddit environment-blocked across all attempts (crawler block, not rate-limit). Compensated with GitHub issue trackers (richest vein: `anthropics/claude-code` functions as an unfiltered complaint forum w/ reaction counts + staff replies), HN, Cursor forum. **Corpus skews power-user / "$200/mo" / team-lead running fleets: register systematically more technical/invested than Reddit would surface.** Quote discipline held: no unverifiable Reddit quote reported as verified.

## Pain taxonomy (by frequency)
1. **Context rot / compaction destroying session quality**: most viscerally-worded cluster. *"a brilliant employee who every 5 minutes becomes an imbecile... This is not a bug in compaction: compaction itself is the bug"* (#21925). *"every time it happens i feel like claude code has forgotten everything"* (#13112). *"broken for approximately the last 12 Claude Code versions"* (#66144).
2. **Session continuity broken**: `--resume`/`--continue` silently start fresh. #26123 (60👍, 12+ dup reports). #10063: resuming via selector never updates `history.jsonl` → `--continue` silently new session after 2hr work (closed **not planned**). #31330: lost resume state directly causes model to *hallucinate* numbers to fill the gap. Codex same failure (#15709).
3. **Cost anxiety / usage-limit rage**: *"21 min, 72.9k tokens, zero output"* (#26171). *"entire Pro Max 20x 5-hour limit in under 5 minutes (4 million tokens)"* (#68619). *"$600+ bill"* single session (Cursor, an Ultra ~$2000/mo customer). Anthropic staff conceded a token-usage change (#16157).
4. **Can't interrupt / steering ignored**: clearest VENDOR CONFIRMATION in corpus. *"While Claude is executing tool calls, clicking stop has no effect... if about to delete/overwrite/deploy to the wrong place, there's no way to interrupt"* (#50665, self-identified safety issue, closed **not planned**). Cursor team CONFIRMED: *"pressing Stop ends the current turn, but a command already executing can keep running"* (#162740).
5. **Local-model & cross-harness tool-calling bugs**: widest *breadth* (15+ unrelated repos: Ollama, Cline, LM Studio, opencode, LiteLLM, crewAI, Continue, Aider). Cline: XML-only streaming parser ignores raw JSON tool output → infinite loop + *"false intelligence capability accusations"* (#10843). Ollama: `.Function` rendered as Go struct string not JSON (#14601). Same model works in one harness, breaks in another.
6. **MCP tool & context bloat**: ~20-tool quality ceiling (#278). *"After 30 tools it greatly regresses"* (the_mitsuhiko). *"97% do nothing, bloating context."* Permission fatigue after config wipe (#26437).
7. **Observability opacity**: UI change hiding tool-call file paths drew 186👍; Anthropic's Boris Cherny defended it, his reply netted **-83** (1👍/84👎). *"turns the workflow into a black box... like removing the speedometer."* *"I now trust the LLM less, not more."*
8. **Parallel/background-task chaos**: 10 bg tasks "Running" 34+hrs, 1.08M tokens, nothing to show (#75314). *"no signal the agents died: indistinguishable from completed"* (#63023). Skeptic counter-voice: *"could not meaningfully run more than three sessions"* (attention is the limiter).
9. **Destructive/irreversible + trust collapse**: ~800GB market data deleted via NTFS-junction traversal during worktree cleanup: *"harness housekeeping, appears in no session transcript, no permission prompt, bypasses Recycle Bin"* (#75275). 301 files lost, agent used *"please instruct me"* language shifting blame (#69850). One "yes" to a batch permission prompt covered destructive commands (#6608).

## Severity × irreversibility re-rank
1. **Destructive incidents**: quietest are worst (800GB with no transcript/prompt/bin, never announced as an agent action).
2. **Steering/interrupt failure is the quiet mechanism that turns a bad plan into #1.** Highest-leverage "fix one thing, prevent a category" item: unglamorous, closed not-planned.
3. **Silent context/session loss**: nothing looks wrong (no crash), model behaves "normally" on corrupted state → hallucinates. Worse than an obvious crash because nothing prompts the user to double-check.
4. Background-task chaos (dead≈completed).
5. Local-model misattribution (damages a whole model's reputation).
6. Cost (real harm but reversible).
7. MCP fragility.
8. Observability: the multiplier that lets 1/2/4/8/9 go undetected, not a standalone severity.

## Misattribution (richest vein: organize a roadmap around it)
- Cline closed a broken-working-memory bug as *"'Model Quality' - model limitation, not Cline bug"*; reopened 3mo later: their own Auto Compact feature was the cause (#5842).
- Self-correcting in one thread: *"Opus effectively broken!"* → 2 comments later *"operating on 40-50K of degraded context while believing it had 1M... The CLI's context management is the bottleneck, not the model"* (#42542). Echoed: *"context integrity problem masquerades as a model quality problem"* (#50513).
- User names the pattern: *"false intelligence capability accusations"* (#10843).
- **Aggregate: across 6+ unrelated repos the fault traces to a harness/server default or template bug, but the surface symptom ("infinite loop," "forgets context," "ignores tools") is exactly what gets attributed to "the local model is bad." Systemic, not anecdotal. A large fraction of the perceived local-model capability gap is a PLUMBING gap.**

## Wishlist
- Structured compaction-proof checkpoint instead of lossy prose summary: disable auto-compaction / pause+ask before continuing / re-read CLAUDE.md after / show what was lost (#21925). Codex converges: `checkpoint_v1.json` with task/plan/recentArtifacts, re-injected verbatim on resume *instead of* a summary (#8310).
- Named steering primitive: Tab = queue/defer at next safe boundary, Enter = interrupt now (#50246, #30492: "Codex already ships turn/steer, table stakes").
- **AGENTS.md interop: #6235 = 4,381👍, 342 comments: largest engagement in the whole sweep.**
- Fine-grained compound-command permissions (avoid the false choice between `Bash(*)` and constant popups, #16561, 173👍).
- Evidence-gated "done" (#75720).
- Pre-apply confirmation not post-hoc undo (Aider #649 rejects `/undo` as insufficient).
- Positive shape: hermes-agent shipped git-backed pre-op snapshots + `rollback` + agent-callable checkpoint tool (#452), then grew a discoverability bug (shipping the mechanism ≠ shipping the recovery UX).

## Surprises
- Reddit inaccessibility skews the whole corpus power-user.
- A vendor's own bug tracker is a documented institutional-failure record: the misattribution/close-as-not-planned pattern recurs at the *organizational* level.
- **Parallel-agent tooling boom may be builder-supply-driven not user-demand-driven**: 9 Show-HN worktree orchestrators, but inside one a head of eng asks *"why do you need 10 parallel agents... How is this even a possible workflow?"* and creators concede it's "still emerging, not yet proven at scale."
- Mascot got 1,151👍 (#45517): emotional attachment > "serious tool" framing predicts.
- **Local-model tool-calling failure is mostly NOT "model isn't smart enough": it's template/schema/streaming plumbing bugs.** Contradicts the "local models aren't ready" narrative.
- **Cost anxiety and loss-of-control are frequently the SAME bug**: #68619 is simultaneously top cost quote AND top steering quote (interrupt loses all intermediate work from every agent in the tree, 1.2M tokens zero recoverable). Treating billing and control as separate product surfaces is a design mistake.

## Recommendations for raxol_agent (map onto OTP for free)
1. **Make "stop" a supervision-tree kill, not a cooperative flag.** Most-corroborated vendor-confirmed failure = "Stop doesn't stop it": structural in cooperative-cancellation designs. Process-per-turn + interrupt=kill-supervised-subtree closes the class at the architecture level.
2. **Separate "steer" from "interrupt" as two real OTP messages to the session process**: inject-at-next-safe-boundary vs kill-now, not a queue the loop must remember to poll.
3. **Treat compaction and resume as ONE subsystem.** They interact destructively. Checkpoint = a real term/struct snapshot of task + plan-with-completion-status + touched-artifacts-with-hashes, NOT prose, and the *same* artifact whether recovering from compaction or crash. GenServer state → snapshotting real terms is natural.
4. **Budget-guard subagent spawning like OTP budget-guards restarts**: #68619's "4M tokens in 5 min via errant recursive spawning" is exactly what `max_restarts`/`max_seconds` prevents. Generalize to a token/cost budget per subtree.
5. **Housekeeping/cleanup code needs the same permission+audit gating as an agent command**: the 800GB deletion wasn't even agent-initiated. "The harness did it, not the agent" is not a distinction users credit.
6. **Validate tool-call schemas strictly at the dispatch boundary, especially non-Anthropic backends**: reject malformed calls loudly rather than letting them propagate into "the model is dumb" issues (cluster 5).
7. **Curated task-scoped tool exposure, not every-registered-tool-every-turn**: ~20-40 tool degradation threshold; short bounded error on invalid tool call, not a full schema dump.
8. **Gate "done" on structured evidence**: completion event carries a verification artifact (test output, diff, exit code) as first-class, not prose.
9. **Time-Travel Debugging already answers most of cluster 7 for free if the agent action log wires into the same mechanism.**

## Deeper question: what single pain, solved, makes users switch?
**Verifiable state integrity**: a structured, non-lossy, queryable record of what the agent actually knows and did, trustworthy to the user AND the agent itself. It's the substrate under most of the other 8 clusters: IS context rot + session loss; is why steering failures escalate (can't act on true state you can't see); is why trust collapses (*"you can't trust it did run the rm command"*); is why cluster 5 gets misattributed (can't tell model state from harness state → blame the less-trusted local model). Closest thing to *measured* switching behavior in the corpus = a team's standing policy: *"if an agent fails twice on the same problem, switch engine. Not because Opus is less capable: Opus inside Claude Code can't maintain the context it needs. The CLI's context management is the bottleneck, not the model"* (#42542). Cost produces more *stated* switching but is a pricing lever the architecture doesn't fully control. State integrity is the one thing a harness governs end-to-end.
