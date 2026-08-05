# Eval-harness science: distilled (the measured design laws)

Epistemic note: Tier-1 (arXiv, lab blogs, benchmark repos) load-bearing; Tier-2 (SEO aggregators) only for the cross-lab score table, flagged.

## THE DESIGN LAWS (numbers-backed)
1. **Interface design has a first-order effect on capability, comparable to a model-generation swap.** SWE-agent ACI: +10.7pp / 64% relative, same GPT-4 Turbo. Harness-Bench: 23.8pt gap at fixed model. Claw-SWE-Bench: 12.5-27.4pt harness spread vs 29.4pt model spread: *same order of magnitude*.
2. **Effect shrinks but doesn't vanish as models get stronger.** mini-SWE-agent (100 LOC, bash-only, no tool-calling API) clears **74%+ SWE-bench Verified** with frontier models where SWE-agent's elaborate ACI was needed for GPT-4 Turbo. **Weak models are harness-fragile; strong models compensate.** → don't over-invest scaffold complexity for a model generation obsolete by ship time.
3. **Output/patch-extraction plumbing can outweigh everything.** Claw-SWE-Bench: bare-diff-emission 19.1% Pass@1 (69.1% apply-failures) vs full-adapter (extract patch from actually-edited files) 73.4% (<1.5% failures): **54.3-point swing from one plumbing decision, zero model/prompt change.** Biggest single number in the pass.
4. **Fewer better-described tools beat broad coverage: but "fewer" should be query-conditioned, not a fixed global cap.** Adaptive depth matches fixed-K=50 coverage at ~7x fewer tools (K≈7.4). Fixed-K=5 scores **0%** on hard queries (true tool ranked 6th-20th) where adaptive finds 16.7%. Claude Sonnet tool-selection: 76.8% (adaptive) vs 60.9% (fixed-K=5) = 16pt swing. Practitioner ceiling ~15-20 active tools; a single MCP server = 15-20k schema tokens.
5. **Error messages are a harness surface: engineer them like success paths.** Anthropic: "specific and actionable." SWE-agent: explicit "(empty output)" needed because silence is ambiguous to an LM.
6. **Format/contract adherence, not reasoning, is the dominant failure mode.** AgentBench: Task-Limit-Exceeded 67.9-82.5%, Invalid-Format 53% in worst categories. Harness-Bench: contract/format violations 36.4% (largest bucket). Structured-output enforcement in the harness has outsized ROI vs prompting for "better reasoning."
7. **Harness informativeness at training time transfers; post-hoc doesn't fully.** ALFWorld: training-time beats post-hoc by 20.7-22.5pt; harness quality can outweigh a 2x+ param difference (3B-under-good-harness > 7B-under-poor by 14.1pt). GPT-5 Mini: 61.0% (informative harness) vs 17.1% (minimal) on hardest tier = 43.9pp, fixed model.
8. **Infra/resource headroom is a measurable confound.** Terminal-Bench 2.0: 6pp gap (p<0.01) from RAM/CPU alone. Anthropic: distrust leaderboard deltas <3pts absent matched infra.
9. **Two harnesses can produce identical pass/fail while the agent's internal belief-state (risk/progress/failure-attribution) diverges** (0.40-0.80). Outcome-only benchmarking is blind to this.
10. **Contamination is indistinguishable from ACI improvement unless you test OOD.** SWE-Bench Illusion: 76% (in-benchmark) vs 53% (OOD) file-localization: 23pt from memorization, same magnitude as real harness effects.
11. **"Home-turf" self-preference in vendor-native harnesses is real but bounded (~4pt), symmetric.** GPT-5.5 78.2%(neutral)→83.4%(native Codex); Opus 4.8 74.6%→78.9%(native Claude Code).
12. **A neutral minimal reference agent (bash/tmux-only) is now the field's standardization instrument**: mini-SWE-agent underlies Scale SEAL; Terminus for terminal-bench. Every serious eval program has one to answer "how much is model vs scaffold."

## Benchmark decay caution
OpenAI stopped reporting SWE-bench Verified (Glaese: "measuring the agent's ability to correctly guess how to name a function"; 59.4% of hard problems had flawed tests). Then their replacement (SWE-bench Pro) was audited by OpenAI itself, ~30% broken. Benchmark decay outpaces replacement.

## Steal-list
1. Report capability at **(model, harness, infra-config) triple**, never model alone.
2. Keep a **neutral minimal bash-only baseline** running against every task suite, if the rich scaffold doesn't beat "just bash" by a real margin, complexity isn't earning its keep.
3. Deterministic replay / golden-trace regression fixtures for real production failures.
4. Pin+log resource limits per run as a first-class field.
5. Verification-as-a-ladder (inline → conditional gate → deterministic hook → independent fresh-context reviewer).
6. Structured failure taxonomies captured at instrumentation time.
7. Adversarial/fresh-context grading (reviewer sees only artifact + criteria, not the work session).

## Avoid porting naively
1. Single-shot unsteerable episodes (production value comes partly FROM steerability).
2. Hard uniform turn/token budgets applied blindly (terminal-bench chose wall-clock only because it couldn't standardize turn-counting across arbitrary harnesses: a comparability compromise, not an ideal). Prefer semantic stop conditions.
3. Optimizing to a metric's blind spots (file-localization-from-issue-text = guessing not checking).
4. Extreme anti-leakage sandboxing (stripped remotes / no internet): wrong for a production agent.
5. Exact-match single-correct-answer grading.
6. Outcome-only logging (loses debuggability where long-horizon failures need it most).

## Recommendations for raxol_agent
1. `{agent, harness, infra_config}` as atomic benchmark unit; raxol_symphony's two Runners + `Evidence.collect/3` already positioned: log harness identity + resource limits.
2. **Build a minimal bash-only reference agent** using the existing `:shell` Command type, zero Actions layered on. Run against the same suite as full ReAct+Actions. If the scaffold doesn't beat raw `:shell`, cut complexity.
3. `Raxol.Debug.TimeTravel` + `Raxol.Recording` are already most of the deterministic-replay infra the literature says production harnesses lack: extend TimeTravel snapshot from TEA UI state to `Agent.Session` state so a failed run = a replayable fixture (OTP-native SWE-bench Docker snapshot).
4. Make tool exposure query-conditioned not registry-static: `Raxol.MCP.ToolProvider`'s focus lens (~15 tools/interaction) already does this for the human MCP surface; reuse for the agent's own Action exposure (16pt Sonnet swing tied to candidate-set size).
5. Every Action's `{:error, reason}` = agent-readable corrective guidance, not a status code.
6. Pin+log resource limits per Symphony workspace (6pp infra noise misread as capability regression otherwise).
7. If ever fine-tuning against an Action schema, bake harness shape in at training time (20.7-22.5pt post-hoc penalty).
8. **Add a validating layer between "LLM emits tool call" and "Command executes"**: format/contract violations are the largest failure bucket (36-82%); a GenServer step rejecting malformed calls with an actionable re-prompt before reaching the Port has outsized ROI.
9. Discount ~4pt of any self-vs-competitor benchmark as home-turf bias.
10. **Weight harness-validation toward the WEAKEST backend** (Ollama/LM Studio/small local), not frontier: strong models are more robust to a bad harness, so a frontier-only eval systematically underestimates how much the harness matters.

## Deeper question: measured vs ergonomic
**Measured (≥2 independent sources):** candidate tool-set size, output/patch plumbing, harness identity at fixed model, ACI richness *for weak models*, training-time vs post-hoc, format enforcement, infra headroom, context rot (30%+ mid-document drop).
**Ergonomic (recommended, not isolated with a controlled number):** tool naming/namespacing, XML vs Markdown prompt structure, CLAUDE.md curation, error-message *wording* (vs presence/silence which WAS measured), subagent adversarial review, explore→plan→implement phase separation.
**Allocation:** spend controlled-experiment effort on tool-exposure policy, patch/output plumbing, format enforcement first: largest documented deltas per unit effort. Prompt-wording/file-structure = "probably helps, unverified magnitude": cheap so do it, but not because evidence is strong.
