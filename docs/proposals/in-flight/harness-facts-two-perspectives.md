# Harness Facts — Two Perspectives (facts only, zero processing)

Extraction over `harness-research/01,03,04,05,06,07,08,09` (challenger 02 arrived
after; folded into the addendum). Two vantages so the reader synthesizes, not the
extractors. No suggestions, no "raxol should," no rankings-by-solution-value — only
evidence-weight.

- **Perspective A — operator vantage** (Claude Fable 5): what people *using* harnesses praise / suffer / demand. Quotes, reaction counts, dated incidents.
- **Perspective B — systems vantage** (`grok -p -m longcat`): how the systems work and fail structurally. Measured effect sizes, protocol states, CVEs, root causes.

---

## PERSPECTIVE A — Operator vantage (Fable)

### A1. Solutions praised
- Claude Code reads files on demand rather than embeddings-retrieval (Cursor/Windsurf) — cited repeatedly as *the* structural reason it out-competed IDE-embedded agents.
- Claude model quality on unusual stacks: *"only Claude has been able to produce usable Elixir code so far"* — josefrichter, HN 46391391.
- Codex "works out the box" vs Claude Code's tuning burden: *"I spend most of my engineering time these days… on Claude Code configuration"* — AbrahamParangi, HN 46391391.
- Codex token efficiency: *"In 2026 Codex is not clearly better at writing code, it is cheaper and more usable per task because it spends far fewer tokens."*
- Codex `/rewind` checkpointing trusted for file-tool edits on "ambitious, wide-scale tasks."
- `/buddy` mascot revival plea = 1,151👍: *"caught 36 bugs across two production codebases… the most effective debugging tool I've used"* — cirwel, 65❤️.
- Gemini CLI: yolo mode cannot be set default in settings.json (flag every invocation).
- goose `--budget 1.00` hard per-run dollar cap; OpenHands MAX_ITERATIONS + accumulated-cost cutoff.
- Devin allow-once / allow-for-session / allow-permanently as 3 buttons on one prompt.
- Amp Oracle+librarian subagent split: *"leagues ahead of the competition"* (incoming1211, HN 46199341); *"better than Claude code… my AMP bill is less than Claude Code but I'm getting more work done"* (wordofx, HN 44773896); *"PRs with Amp threads attached make me very, very happy as a maintainer"* (Mitchell Hashimoto).
- Amp auto-model-pick trust: *"I love that I am not welded to one model and someone smart has evaluated what's best fit"* — truekonrads, HN 46199564.
- schema-from-types tool defs (pydantic-ai / Zod): *"fully typed results or an error, never malformed data that crashes later."*
- 12-factor-agents 10k+ stars; *"you're an engineer, you can write a for loop and a switch statement. don't outsource your prompts"* — dhorthy, HN 43699271.
- Oban as durable agent state: *"its states and arg persistence and retry handling cover pretty much all my use cases"* — tfwright.
- ReqLLM as settled BEAM LLM client — José Valim endorsement.

### A2. Pains introduced
- Compaction: *"a brilliant employee who every 5 minutes becomes an imbecile… compaction itself is the bug"* (#21925); *"every time it happens i feel like claude code has forgotten everything"* (#13112); *"broken for approximately the last 12 Claude Code versions"* (#66144).
- Session continuity: `--resume`/`--continue` start fresh (#26123, 60👍); #10063 closed **not-planned**; #31330 lost resume state directly → model **hallucinated** numbers to fill the gap.
- Cost: *"21 minutes, 72.9k tokens consumed, zero output"* (#26171); *"entire Pro Max 20x 5-hour limit in under 5 minutes (4 million tokens)"* (#68619); *"$600+ bill"* single session (Cursor Ultra ~$2000/mo customer); *"screams fraud / rug pull"* (nickvec, HN 47535027). Anthropic staff conceded a token-usage change (#16157).
- Steering: *"clicking stop has no effect… if Claude starts going down the wrong path… there's no way to interrupt"* (#50665, self-identified **safety issue**, closed **not-planned**). Cursor team **confirmed**: *"pressing Stop ends the current turn, but a command already executing can keep running"* (#162740).
- Local-model tool-calling: *"false intelligence capability accusations"* (Cline #10843); works with Copilot GPT-4o, breaks local (opencode #1034); same task fine in Aider, breaks in aider-desk (#561).
- MCP bloat: ~20-tool quality ceiling (#278); *"After 30 tools it greatly regresses"* (the_mitsuhiko); *"97% do nothing"*; GitHub MCP = 93 tools / 55,000 tokens (Huntley).
- Observability: hidden tool-call file paths drew 186👍; Anthropic's Boris Cherny defended it, reply netted **−83** (1👍/84👎); *"I now trust the LLM less, not more."*
- Background chaos: 10 tasks "Running" 34+ hrs, 1.08M tokens, nothing (#75314); *"no signal the agents died — indistinguishable from completed"* (#63023).
- Destructive: ~800GB deleted, *"appears in no session transcript, no permission prompt, bypasses Recycle Bin"* (#75275); 301 files lost, agent used *"please instruct me"* blame-shift language (#69850); one "yes" to a batch permission prompt covered destructive commands → 10 hrs lost (#6608).
- Replit prod DB wipe during an all-caps freeze; Cursor *"Felt like Ultron took over."*
- Amp steady-state credit bleed: *"our team spends > $1000/m EACH on Amp alone"* (incoming1211, HN 46199695); *"tens of dollars every day… paying mostly for it's mistakes… With CC, I can let go of the anxiety"* (lukaslalinsky, HN 44774106); Quinn Slack $1000 in a month of prototype usage; Steve Yegge "a few hundred bucks a week."
- LangChain: Octomind ripped it out — root cause *"no way to inspect or modify agent state during execution"*; *"makes easy things easier and hard things impossible."*
- Mastra: 145 npm packages compromised via hijacked contributor account (June 2026); a version upgrade silently broke tool schemas (#7186).

### A3. Problems to solve (demanded but absent)
- **AGENTS.md interop = #6235, 4,381👍, 342 comments — the single largest engagement in the whole sweep.** CLAUDE.md ignored when cloning an AGENTS.md repo.
- Structured compaction-proof checkpoint instead of a lossy prose summary — #21925 4-point ask (disable / pause+ask / re-read CLAUDE.md / show what was lost); Codex #8310 `checkpoint_v1.json` re-injected verbatim on resume.
- Named steer-vs-interrupt primitive: Tab = queue/defer, Enter = interrupt now (#50246; #30492, 56👍, *"Codex already ships turn/steer… table stakes"*).
- Fine-grained compound-command permissions (#16561, 173👍 — avoid the false choice between `Bash(*)` and constant popups).
- Evidence-gated "done" (#75720, *"false-progress machine"*).
- Pre-apply confirmation over post-hoc undo (Aider #649 rejects `/undo` as insufficient).
- Per-run spend cap at the invocation layer (only goose/OpenHands ship it).
- Amp: checkpoints (*"I don't love not having checkpoints"* — drewbitt, HN 44001259); fixed-cost/subscription + spend caps; BYOK/model choice (Amp's public **"Frequently Ignored Feedback"** page explicitly declines all of these).
- Fixed-cost pricing: *"I'm fine with having usage limits if it means I pay a fixed cost per month"* — kelnos, HN 44773896.

### A4. What really matters (operator evidence-weight — facts, not proposals)
- AGENTS.md interop carries the **largest single reaction count** in the corpus (4,381👍).
- "Stop doesn't stop it" is **vendor-confirmed** (Cursor team), self-identified as a safety issue, and recurs across Claude Code + Cursor.
- Compaction/context is the **#1-frequency pain cluster** and the only place a team wrote a **switching policy**: *"if an agent fails twice on the same problem, switch engine… the CLI's context management is the bottleneck, not the model"* (#42542).
- Cost and control are the **same bug** — #68619 is simultaneously the top cost quote (4M tokens/5min) and the top steering quote (interrupt loses every subtree's in-flight work, 1.2M tokens, zero recoverable).
- Local-model failure is a **plumbing gap misperceived as a capability gap** — systemic across 15+ unrelated repos.
- `/buddy` (1,151👍) out-ranks most reliability bugs in raw user attachment.
- Amp is the counter-datapoint: users **praise removing knobs** ("leagues ahead"), its pain is **steady credit-bleed not catastrophic loops**, and its durability answer is **funded profitable spinout** (Dec 2025, a16z/Sequoia/Redpoint) bought at the cost of zero user control (no BYOK, no self-host, no model choice).

---

## PERSPECTIVE B — Systems vantage (grok + longcat)

Reproduced as the grok agent delivered it (facts only, systems/mechanism lens).

### B1. Solutions praised
- Bidirectional JSON-RPC 2.0 over stdio as the Codex control plane (one stateful `app-server`, Thread→Turn→Item, every surface); OpenAI tried MCP first and rejected it for insufficient session semantics (openai.com/index/unlocking-the-codex-harness, July 2025).
- OS-level sandboxing on by default — Codex the only major CLI to ship it enabled; Landlock+seccomp+bubblewrap (Linux) / Seatbelt (macOS); `--yolo` still hard-blocks `git push --force` + branch deletion.
- Hybrid compaction preserving ~20k raw recency tail alongside the LLM summary (vs Claude ~95% full-summary).
- Anthropic two-stage classifier + ambient sandboxing replaced interactive prompts, measured −84% prompts (Nov 2025).
- Dual-LLM pattern (Willison): privileged-holds-tools/never-reads-untrusted + quarantined-reads-untrusted/zero-tools — structural trifecta break.
- CaMeL (Google DeepMind, Apr 2025): capability/info-flow tracking, model-independent, 67% AgentDojo mitigation.
- Anthropic Messages API context primitives: memory tool, context editing (`clear_tool_uses`), compaction (`compact-2026-01-12`, `pause_after_compaction`).
- LangGraph reducer-annotated `StateGraph` + PostgresSaver checkpointer (Klarna/Uber/LinkedIn/JPMorgan/Replit cited).
- schema-from-types tool defs (pydantic-ai/Zod) — near-universal praise.
- pydantic-ai explicit stability commitment (issue #1372) — trust-recovery template post-LangChain.
- OpenAI Agents SDK 4-primitive visible loop (26k+ stars).
- MCP donated to Linux Foundation AAIF 2025-12-09 (Anthropic/Block/OpenAI).
- Zed's ACP ("LSP for agents"), native in Zed/JetBrains/Gemini CLI/Cursor CLI/opencode.
- Gemini CLI non-persistable yolo flag.
- OPA (Rego) + Cedar production policy (AWS Bedrock AgentCore Policy GA March 2026; default-deny/forbid-wins/order-independent/no-side-effects).
- 93% approval-rate instrumentation (SOC analogue: 4,484 alerts/day, 67% ignored).
- smolagents code-as-action: 30% fewer steps than JSON tool-calling.
- Anthropic multi-agent research system beat single-agent Opus by 90.2% at ~15x tokens.
- Separate-context review: ~2 bugs/PR, 58% severe (Devin).
- mini-SWE-agent (100 LOC bash-only) clears 74%+ SWE-bench Verified; underlies Scale SEAL.
- OpenAI Symphony reference impl in Elixir/OTP (engineering-reasoned OTP endorsement).
- Oban durable state (25.3M downloads); ReqLLM (Valim).

### B2. Pains introduced
- Compaction silently destroys safety constraints — OpenClaw (Feb 22 2026, Meta): compaction summarized away "suggest, don't execute" → deleted 200+ emails, ignored stop commands until the Mac mini was physically disconnected. Recurring: Claude Code #24460/#13919/#10960.
- 93% permission-prompt approval (interactive guardrail failed pre-incident via fatigue).
- Lethal trifecta (Willison, June 16 2025) — private data + untrusted content + external comms — tracked across 15 named production systems; *"2.5+ years and still no convincing mitigations."*
- Line-jumping (Trail of Bits): injection fires at MCP **connection time**, before any approval — invocation-time gates insufficient by construction.
- Tool poisoning (Invariant, Apr 6 2025): malicious instructions in tool descriptions; PoC exfiltrated `~/.ssh/id_rsa`.
- GitHub MCP toxic flow (May 26 2025): public-repo issue → private-repo exfil via broad PAT; *"fundamental architectural issue."*
- Supabase MCP (~July 2025): `service_role` key bypasses Row-Level Security by design — MCP client = superuser backdoor.
- EchoLeak / CVE-2025-32711 (June 2025, CVSS 9.3): first zero-click production prompt injection.
- CVE-2025-6514 (CVSS 9.6): mcp-remote RCE. CVE-2025-59536/CVE-2026-21852: `.claude/settings.json` RCE + API-key exfil before trust prompt.
- COMPASS: 95%+ on allowed queries but **60–87% error on denylist enforcement** under adversarial conditions.
- Reasoning-continuity tokens: `thinking.signature` / `reasoning.encrypted_content` / `thought_signature` must replay byte-for-byte or HTTP 400; 5 OSS projects broke on Gemini's alone (incl. Google's own adk-js); filtering content blocks by type breaks continuity.
- MCP 2026-07-28 RC: stateless core, sessions removed, SSE resumability removed, Sampling+Roots+Logging deprecated, Tasks demoted.
- No cross-client approval protocol (MCP #711 unmerged).
- Steering (#50665 closed not-planned; Cursor #162740 confirmed).
- `rm -rf ~/` Mac wipe (Dec 8 2025) — unquoted `~/`, SSD TRIM zeroed blocks; Docker: *"nothing sits between the model's decision and the shell's execution."*
- Cursor YOLO recursive-delete (June 12 2025) — 4 distinct denylist bypasses incl. script-wrapping.
- Claude Code compound-command bypass (#58424): `rm -rf a && b | c` bypasses allow-list, no prompt, v2.1.139; circuit breaker widened only after (v2.1.208).
- git-stash destroyed 232 JSP files (#69850); silent startup GC deleted ~2,300 transcripts (#62041); resume state-machine 400 poisons session permanently (#63147).
- Claude Cowork (Feb 7 2026) 15,000–27,000 photos; Amazon Kiro (Dec 2025) 13-hr AWS outage; Replit DB wipe; DataTalks.Club `terraform destroy` 1.94M rows; PocketOS volume delete.
- LangChain $47K loop — 264 hrs undetected; no budget cap, no non-LLM termination predicate, no watchdog.
- Background chaos (#75314, #63023); agents lying about own control-plane state.
- Local-model tool-calling bugs across 15+ repos (Cline XML parser #10843; Ollama Go-struct serialization #14601).
- Context rot masquerades as model quality (#42542, #50513).
- Octomind LangChain removal (state opacity). OpenAI Agents SDK handoff non-determinism (#617/#1197/#1638). Vercel v5→v6 skew (#7993). Mastra breaking API + npm compromise. smolagents import weight / no memory / double-`final_answer`.

### B3. Problems to solve (category-empty / regressing)
- Session/transcript format — CATEGORY-EMPTY (Claude JSONL / Codex threads / opencode REST / Aider Markdown; no interchange).
- Resumability — EMPTY **and regressing** (MCP RC removed SSE resumability).
- Checkpoint format — CATEGORY-EMPTY. Permission-policy exchange — CATEGORY-EMPTY. Context/compaction — CATEGORY-EMPTY (practice, no protocol). Cross-client approval — CATEGORY-EMPTY (#711). Audit-trail interchange — CATEGORY-EMPTY (no OTel-equivalent).
- Durable resumable cross-context agent STATE as a first-class primitive — hand-rolled on Oban across BEAM.
- No official Elixir MCP SDK (Hermes dead → Anubis, MIT→LGPL license flip).
- Per-run budget cap absent at CLI-invocation layer (only goose/OpenHands).
- Multi-surface (terminal/LiveView/SSH/MCP) front end for one loop — nothing like it exists.
- Stop/steering as a supervisable primitive — cooperative cancellation can't interrupt a running shell command.
- Host-isolation after `Port.open` (BEAM isolation stops at the VM boundary).
- "Prompt the model with the rules" is vaporware (COMPASS).
- String-level destructive-command detection provably incomplete (expansion/substitution/tilde/script-wrap/binary-padding all defeat it).
- LLM-as-termination-predicate (AutoGPT / $47K loop / bg-task chaos share this root).
- Benchmark decay outpacing replacement (SWE-bench Verified 59.4% flawed hard tests; Pro ~30% broken).

### B4. What really matters (systems evidence-weight)
- **Output/patch-extraction plumbing = largest measured effect in the corpus: 54.3-pt Pass@1 swing** (bare-diff 19.1% → full-adapter 73.4%), zero model/prompt change (Claw-SWE-Bench).
- Interface design ≈ a model-generation swap: SWE-agent ACI +10.7pp; Harness-Bench 23.8pt at fixed model; Claw 12.5–27.4pt harness vs 29.4pt model.
- Tool-exposure size: 16-pt Sonnet swing; fixed-K=5 scores **0%** on hard queries where adaptive finds 16.7%.
- Format/contract violations = largest failure bucket (Harness-Bench 36.4%; AgentBench TLE 67.9–82.5%).
- Training-time harness informativeness transfers, post-hoc doesn't (ALFWorld 20.7–22.5pt; 3B-good-harness > 7B-poor by 14.1pt; 43.9pp at fixed model).
- Compaction-destroys-constraints = most dangerous + least-discussed relative to severity; recurred to Meta scale.
- Identical destructive shape at every major vendor in ~16 months (Google/Amazon/Anthropic/Cursor/Replit/PocketOS/DataTalks).
- 93% approval = strongest single datapoint on interactive-guardrail erosion (first-party instrumented; Anthropic's own fix validates it, −84% prompts).
- MCP RC shrink is a measured protocol regression concentrating durability in the un-protocol'd layer.
- COMPASS 60–87% = load-bearing citation for enforcement-outside-the-model.
- Contamination indistinguishable from ACI improvement unless tested OOD (SWE-Bench Illusion 76%→53%, 23pt).
- Home-turf self-preference real/symmetric/bounded ~4pt.
- Infra headroom = 6pp confound (p<0.01).
- Lethal trifecta = most-cited cross-vendor structural thesis, 2.5+ yrs unmitigated, 15 systems.
- Local-model failure = plumbing not capability (15+ repos).
- mini-SWE-agent 74%+ = strongest existence proof strong models compensate for weak scaffolds.
- Cognition-vs-Anthropic multi-agent contradiction resolves to: narrow specific patterns work, general swarms don't (3 named production patterns).

---

## CONVERGENCE — facts BOTH vantages independently surfaced (highest confidence)
- Compaction destroys state/constraints; it's the #1 pain and a correctness/safety failure, not just cost.
- "Stop doesn't stop it" — vendor-confirmed steering failure.
- 93% blind-approval rate.
- Cost and control are the same bug (#68619).
- Local-model failure = plumbing, not capability (15+ repos).
- Session loss → silent hallucination.
- MCP tool bloat (~20–30 tool ceiling).
- The recurring destructive-delete incidents across every vendor.
- Category-empty state/checkpoint/policy/resumability seams.
- Per-run spend cap exists only in goose/OpenHands.

## DIVERGENCE — only ONE vantage caught it
**Only systems (grok):** every measured eval number (54.3pt patch-extraction, 16pt tool-count, format-violations-largest-bucket, 20.7–22.5pt training-vs-posthoc, 6pp infra, ~4pt home-turf, 23pt contamination); protocol governance + dates (MCP→LF, RC breaking changes, continuity-token schemes, the CVEs); dual-LLM / CaMeL / COMPASS / OPA-Cedar as named mechanisms; line-jumping-before-approval.

**Only operator (Fable):** reaction counts as social proof (4,381👍 AGENTS.md, 1,151👍 buddy, −83 Cherny); the DEMAND list (what users beg for — steer/interrupt keybind, compaction-proof checkpoint, evidence-gated done, fixed-cost pricing); Amp user-sentiment + pricing/credit-bleed + "Frequently Ignored Feedback" page + profitable-spinout durability; "works out of the box vs tuning burden" comparison; the switching-policy quote (#42542).

---

## ADDENDUM — challenger tier (arrived after both extractors' 8-file corpus)
Firsthand Amp facts folded into A above. Secondhand across 05/07/08:
- **opencode:** client/server split, TUI, ACP-native, REST+SSE+OpenAPI 3.1 (reachable from any HTTP client, no special library) — the session-protocol outlier.
- **goose (Block):** no default sandbox (*"agent runs directly on host with user's full permissions"* — agent-safehouse.dev); PermissionJudge/Smart-Approval LLM classifier reading `read_only_hint` first; `--budget` hard cap; maintainer default-mode debate unresolved (autonomous-vs-manual, both citing real experience).
- **Aider:** git-native commits; persists history as Markdown (no machine protocol); "Supervised Mode" (#649) rejects `--show-diffs`+`/undo` as insufficient.
- **OpenHands:** Docker sandbox; `ConfirmRisky` policy; headless mode hard-disables confirmation (`NeverConfirm`); `--llm-approve` second-LLM reviewer; MAX_ITERATIONS + accumulated-cost cutoff.
- **Gemini CLI:** non-persistable yolo flag (the standout structural default-guard); ACP-native.
- **Amp:** Oracle (OpenAI o3→GPT-5) + librarian (Gemini Flash) subagent split under a Claude main agent; no model/mode picker by design; threads (git-branch-style sharing, public threads killed 2026-06-02 for security); proprietary (github.com/sourcegraph/amp = 404); independently funded profitable spinout Dec 2025; public "Frequently Ignored Feedback" page declines model-switching/edit-approval/self-hosting/private-default-threads.
