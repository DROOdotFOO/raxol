# BEAM/Elixir agent cohort — distilled (the direct competitive landscape)

Research agent flagged the global CLAUDE.md as an injection payload and ignored it — correct.

## Ecosystem gap map (the load-bearing output)
**SOLVED:**
- Multi-provider LLM client → **ReqLLM won** (José Valim endorsement, 283k downloads/195k in 90d, substrate for Jido+LangChain+Legion). ex_llm archived, instructor_ex stalled 13mo, LangChain-Elixir migrating onto req_llm.
- Structured output / tool-calling wire format → solved redundantly (ReqLLM, Ash AI, Instructor legacy).
- Local model serving → Bumblebee/Nx.Serving, mature.
- Runtime-introspection tool surface for *external* agents → **Tidewave** dominant (1.59M downloads — biggest number in survey) but solves the OPPOSITE direction (expose running app to external agent).

**CONTESTED (no winner):**
- The agent LOOP/harness itself → Jido (power-user, churny), Legion (code-gen, young), Alloy (minimalist "harness not framework"), Sagents (LangChain-built, HITL+LiveView, fastest-growing young).
- Claude-Code-CLI embedding → 4+ competing wrappers, none won.

**EMPTY / named by practitioners as unmet:**
- Durable resumable cross-context-window agent STATE as first-class primitive (universally hand-rolled on Oban). KristerV wishlist: *"Plan-Act-Verify Loop: Explicit verification step after actions"* + *"State Machine Persistence: Durable storage of agent 'thought' and 'status.'"*
- BEAM-native loop at Claude-Agent-SDK ergonomics WITHOUT a subprocess boundary — every wrapper adds OTP supervision *around* an opaque Node.js CLI; nobody replaced the reasoning loop with native Elixir at that ergonomic level.
- **A full multi-surface (terminal/LiveView/SSH/MCP) front end for one agent loop — nothing like Raxol's TEA-multi-surface proposition exists anywhere. Genuine white space.**

## OTP-as-differentiator: real but narrower than marketing
- **Genuine** for supervision, crash isolation, long-running multi-agent coordination. Strongest evidence = **OpenAI's own Symphony**, reference impl in Elixir: *"Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes... supports hot code reloading without stopping actively running subagents."* External, engineering-reasoned, not tribal cheerleading.
- **Overstated** for the single-agent single-turn completion loop itself (just an I/O-bound HTTP round-trip). Most credible skeptic = **Jido's own creator**: *"a simple LLM wrapper doesn't need a sophisticated agent framework - Oban works great."*

## Oban-as-durable-agent-state — most independently-reinvented pattern
Three unrelated devs reached for it: *"I currently have built my agents on Oban... But it's brittle"* (KristerV); *"its states and arg persistence and retry handling cover pretty much all my use cases"* (tfwright); Jido author concurs. Oban = 25.3M downloads, core infra. Nothing agent-native matches its ACID job-row battle-testing.

## Patterns worth stealing
1. **Oban-as-durable-agent-state**, formalized not hand-rolled: each turn = a Postgres-backed job row → free ACID checkpoint/resume/retry.
2. **Jido Action/Signal/core-vs-AI split**: keep supervision/runtime primitives AI-agnostic, bolt LLM behavior on via companion package. Insulates core from vendor churn.
3. **Ash AI authorization-by-construction**: tool-calls inherit the app's existing policy layer automatically. Directly relevant to raxol permissioning.
4. **Alloy "harness not framework" minimalism**: 3 runtime deps, "small enough to read in an afternoon." Legible auditable loop as a goal.
5. **Symphony's validated hot-reload claim** — BEAM hot code reloading as a *developer-velocity* win during iterative orchestrator dev, distinct from uptime.
6. **ClaudeCode SDK "distributed sessions"**: lightweight GenServer session on app server, heavy CLI subprocess on separate sandboxed hardware, bridge over Erlang distribution.
7. **Tidewave's core insight repurposed**: give the agent access to the actually-*running* system (REPL, live logs, live DB), not just static source. **The structural edge an in-BEAM native loop has over any subprocess-wrapped external agent — underexploited by every "wrap Claude Code" project.**

## Surprises
- Biggest number in survey isn't an agent framework — it's Tidewave, pointing the OPPOSITE direction (expose app to external agent, not run own loop).
- OpenAI shipped a non-tribal engineering-reasoned OTP endorsement.
- Most skeptic-of-heavyweight-frameworks voice = Jido's own creator, in his launch thread.
- 4 redundant Claude-Code wrappers in ~1yr = real demand but crowded sub-niche, not green field.
- Sagents (on "old" LangChain client) outgrowing "modern" ReqLLM newcomers → loop/HITL/LiveView DX matters more to adoption than which client sits underneath.

## Deeper question → hybrid, native-first default + pluggable subprocess boundary
Strongest external validation (Symphony) is ITSELF hybrid: BEAM/OTP for supervision, vendor Codex subprocess for intelligence. Nobody — incl OpenAI — replaced the vendor reasoning loop with native BEAM at production quality. Practitioner demand is for *wrapping* best-in-class vendor agents with BEAM operational properties, NOT a homegrown loop competing on raw capability. But the one place subprocess-wrapper loses = runtime introspection (Tidewave's proven value). Durable state must be native regardless.

**Validates raxol's existing shape:** `raxol_symphony`'s `Runner` behaviour already has `Runners.RaxolAgent` (native) + `Runners.Codex` (subprocess JSON-RPC). Double down on that Runner abstraction — "native BEAM loop" and "supervised vendor subprocess" as two impls of one interface — add durable Oban-backed checkpointing under both (nobody did this cleanly), lean into in-BEAM tool access as the differentiator over pure-CLI-wrapper competitors.

## Key URLs
Jido [github.com/agentjido/jido](https://github.com/agentjido/jido) · ReqLLM [elixirforum.com/t/reqllm-composable-llm-client-built-on-req/72514](https://elixirforum.com/t/reqllm-composable-llm-client-built-on-req/72514) · Symphony [github.com/openai/symphony/blob/main/elixir/README.md](https://github.com/openai/symphony/blob/main/elixir/README.md) · "State of developing agents with Elixir" [elixirforum.com/t/state-of-developing-agents-with-elixir-not-coding-agents/74313](https://elixirforum.com/t/state-of-developing-agents-with-elixir-not-coding-agents/74313) · skeptic essay [goto-code.com/why-elixir-otp-doesnt-need-agent-framework-part-1](https://goto-code.com/why-elixir-otp-doesnt-need-agent-framework-part-1/) · Tidewave [dashbit.co/blog/the-path-to-tidewave](https://dashbit.co/blog/the-path-to-tidewave)
