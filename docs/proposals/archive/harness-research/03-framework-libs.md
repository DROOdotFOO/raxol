# Agent Frameworks-as-Libraries: Pain-First Research (ADJACENT Tier)

*Forum-first sources: Hacker News, GitHub issues, Elixir Forum, community forums. Vendor docs used only for primitive/API confirmation, never for sentiment.*

---

## Per-Framework Synthesis

### LangGraph (in the shadow of LangChain)

**Loop primitive/state/tools/streaming:** LangGraph models the agent as an explicit `StateGraph`: nodes are functions, edges (including conditional edges) define control flow, and a reducer-annotated state object flows through the graph. Checkpointing is a first-class concern: a `Checkpointer` (MemorySaver for dev, PostgresSaver/other DB-backed savers for prod) snapshots state at every superstep, enabling pause/resume, time-travel, and human-in-the-loop interrupts. Tools are plain functions bound to a model; a `ToolNode` executes them, though it historically struggled with tools needing to read/write graph state (`InjectedState`, `Command` objects). Streaming is token- and step-level via `.stream()`/`.astream()`. LangGraph is LangChain's answer to its own reputation problem: lower-level, graph-first, explicit: a deliberate retreat from Chain-object magic.

**LOVE:**
- "LangGraph, for agent/workflow orchestration is the least bad of the three [LangChain products]": `NeutralCrane`, [HN #44840323](https://news.ycombinator.com/item?id=44840323)
- Production users report core graph execution and stateful agents "stable across four production deployments" once they move off `MemorySaver` onto Postgres: [kalviumlabs.ai](https://www.kalviumlabs.ai/blog/langgraph-in-production-stateful-multi-step-agents/)
- Enterprise adoption is real and cited repeatedly (Klarna, Uber, LinkedIn, BlackRock, Cisco, Elastic, JPMorgan, Replit) as the "production standard for stateful, auditable agentic workflows."

**HATE:**
- "Specifying immutable dependencies for a graph run via `config['configurable']` is unintuitive and unnecessarily nested": maintainer Sydney Runkle, describing it as the **"#1 developer pain point"** heard from the community, [GitHub #5023](https://github.com/langchain-ai/langgraph/issues/5023)
- "LangGraph's default ToolNode simply can't handle tools that need to read from or write to the graph's state. The moment you try to use InjectedState or return Command objects, your tools get completely ignored" (production write-up synthesizing multiple teams' experience)
- State corruption in production: "Without proper reducers, parallel updates can corrupt state... Simultaneous state updates can lead to race conditions, causing inconsistent data and subtle errors that are hard to trace"
- The parent brand drags it down: "It's a complete dumpster fire, but they caught enough mindshare early on to be thought of as the default choice now for people newly coming into the agentic world": `ramesh31`, [HN #44840323](https://news.ycombinator.com/item?id=44840323)

**DEMAND:** A flat, typed `context` argument instead of nested `config["configurable"]` (delivered in the v1 API rework); tools that compose cleanly with injected state without opting into a parallel Command-object dialect; Postgres-grade persistence documented as the *default* path, not an afterthought to MemorySaver.

**HORROR:** Teams that started on LangChain and got burned rewrote onto LangGraph: one shop reported 8 of 12 agentic projects started in LangChain, with 4 rewritten to LangGraph specifically because "state management became a bottleneck." That's a full framework migration as the *fix* for the first framework's abstraction failure, not reassuring for framework #2's own durability.

---

### OpenAI Agents SDK (successor to Swarm)

**Loop primitive/state/tools/streaming:** Four primitives: Agent (instructions + tools), Handoffs (agent-to-agent delegation via LLM-issued tool calls), Guardrails (input/output validators), and Sessions (conversation persistence). The loop itself is intentionally thin ("the agent loop is visible," per multiple comparison write-ups) no DAG compiler, no hidden planning step. Streaming and tracing are built in. Swarm (the March 2025 predecessor) is explicitly archived and "should not be directly used in production"; its README now redirects to the Agents SDK.

**LOVE:**
- "The OpenAI Agents SDK went the other way after a wave of heavy frameworks: small, explicit, few abstractions... In 2026 it's a common default for production-grade agents, precisely because there's so little magic." (synthesis from multiple 2026 comparison pieces, converging independently)
- 26k+ GitHub stars, 4k forks: [mem0.ai review](https://mem0.ai/blog/openai-agents-sdk-review)

**HATE:**
- Handoffs are LLM-driven tool calls, not deterministic dispatch: a maintainer-acknowledged gap: "Currently, handoffs in the Agents SDK rely on LLM tool-calls, which leads to lower determinism - LLM may choose the wrong agent," [GitHub #1638](https://github.com/openai/openai-agents-python/issues/1638) (open feature request for deterministic handoffs)
- "How do I ensure (not enforce, but ensure) that tools and the handoffs will work as expected?", `adhishthite`, reporting that in his triage→specialist→formatter pipeline, "neither the tool is called, nor the `format_agent` is called" most of the time, [GitHub #617](https://github.com/openai/openai-agents-python/issues/617), **closed as "not planned," tagged stale**
- Nested handoffs don't reliably return control: "Handoffs don't hand back up to original agent" once you're more than one level deep, [GitHub #1197](https://github.com/openai/openai-agents-python/issues/1197): the SDK's own docs now gate nested handoffs behind an opt-in beta flag "while we stabilize them"

**DEMAND:** Deterministic (non-LLM) handoff routing as a first-class option, not just probabilistic tool-call delegation; handoff state that actually unwinds back up the call tree; session semantics that don't silently conflict with `conversation_id`/`previous_response_id`.

**HORROR:** A maintainer closing a core reliability bug ("handoff doesn't trigger") as "not planned" is a signal worth sitting with: it suggests the handoff primitive is being treated as best-effort-by-design rather than a contract, which matters enormously if you're building supervisor patterns on top of it.

---

### pydantic-ai

**Loop primitive/state/tools/streaming:** An `Agent` is a Python object wrapping a model, a system prompt, and a dependency-injected `RunContext`. No graph, no DAG: "the agent model is flexible and dynamic without needing to predefine a DAG." Tools are registered via `@agent.tool` decorators; Pydantic auto-derives the JSON schema from type hints and pulls parameter descriptions straight out of docstrings. Execution is automatically traced (exportable to Logfire). Structured output is the headline feature: Pydantic validates the model's output against your schema and retries on mismatch. V1 shipped September 2025 with an explicit API-stability commitment; V2.0 followed June 2026.

**LOVE:**
- "The @agent.tool decorator lets you register functions which the LLM may call, with dependencies carried via RunContext... Pydantic validates these arguments, docstrings are passed to the LLM as descriptions": praised repeatedly as FastAPI-grade ergonomics applied to tool-calling, [ai.pydantic.dev/tools](https://ai.pydantic.dev/tools/)
- "Execution is automatically traced and can be exported to Logfire for observability" without extra wiring: [HN #45055439](https://news.ycombinator.com/item?id=45055439)

**HATE:**
- "I really wish Pydantic invested in... Pydantic, instead of some AI API wrapper garbage": `iLoveOncall`, articulating a "the tail is wagging the dog" complaint about a validation library pivoting to become an AI framework vendor, [HN #45056540](https://news.ycombinator.com/item?id=45056540)
- Structured-output reliability isn't free even with the framework's help: "pretty frequently the LLM just refuses to actually supply json conforming to the model," despite retry configuration: `__MatrixMan__`, same thread
- Maintainer bandwidth strain from rapid popularity: "Pydantic AI maintainers haven't been as quick to respond to issues and review PRs since the holidays, as the project's growing popularity has increased the volume of notifications"

**DEMAND:** API stability (explicitly requested and explicitly delivered: [GitHub #1372](https://github.com/pydantic/pydantic-ai/issues/1372) is the maintainers' own tracking issue, stating breaking changes are made deliberately "to achieve stability as swiftly as possible" pre-V1, then locked down); faster triage as the issue queue grows with adoption.

**HORROR:** Nothing rising to incident-level: the sharpest complaint is philosophical (mission drift of the Pydantic brand) rather than "it broke in prod." The maintainer's own framing (intentional pre-1.0 churn as the *price* of getting to a stable contract fast) is notable as a strategy other frameworks (Mastra, notably) talked about but didn't execute as cleanly.

---

### Vercel AI SDK (v5/v6 agent loop)

**Loop primitive/state/tools/streaming:** "A model plus tools in a loop is an agent, and the AI SDK handles that loop for you": the `ToolLoopAgent`/`generateText`+tools pattern calls the model, executes requested tool calls, feeds results back, and repeats (default cap ~20 steps). Tools are defined via `tool()` with a Zod schema (or raw JSON schema) for input; the SDK validates model-supplied arguments before your `execute` runs. v5 (July 2025) was a major breaking release: it ripped out a custom streaming protocol in favor of native SSE, split `UIMessage`/`ModelMessage` into separate types, renamed `parameters`/`result` to `inputSchema`/`outputSchema`, and introduced the `Agent` class. v6 layered on tool-execution approval flows, DevTools, and full MCP support.

**LOVE:**
- Zod-first tool definitions: "You get fully typed results or an error, never malformed data that crashes later", the schema *is* the TypeScript type *is* the runtime validator, one definition, no drift, [ai-sdk.dev](https://ai-sdk.dev/docs/ai-sdk-core/tools-and-tool-calling)
- DevTools closing a real gap: "Debugging multi-step agent flows is difficult because a small change in context or input tokens at one step can meaningfully change that step's output": AI SDK DevTools built specifically to give visibility into that chain

**HATE:**
- v5→v6 mixed-version deployments have no graceful path: a GitHub issue-reporter noted client/server version skew for up to 24 hours during rolling deploys is unaddressed: *"I'm surprised there's not a section in the migration guide that addresses this,"* [GitHub #7993](https://github.com/vercel/ai/issues/7993)
- Streaming correctness bugs reach production: response streaming reported stuck in an infinite loop against Azure OpenAI's gpt-4o-mini, [GitHub #4141](https://github.com/vercel/ai/issues/4141)
- A pointedly-titled HN thread, *"i was using vercel ai sdk for my production app and it was such a bad experience..."* ([HN #43111094](https://news.ycombinator.com/item?id=43111094)), surfaced in search indices but the item itself now returns "no such item"/HTTP 429 on every fetch attempt; flagging its existence and title only, content not independently verified, so treat as a lead rather than a citable quote.

**DEMAND:** A real cross-version compatibility window for rolling deploys, not just codemods for the code you own (the official codemod explicitly "does not rewrite custom message renderers, hand-written tool-call switch statements, or provider-adapter contracts": the exact code most production apps have the most of).

**HORROR:** v5 was a from-scratch protocol rewrite (custom protocol → SSE) shipped as a major version with a stated "most codebases require 2-4 hours" migration estimate that explicitly excludes the hand-written parts of any nontrivial app: a familiar pattern of the vendor undercounting migration cost for exactly the code that took the user the longest to write.

---

### smolagents (Hugging Face)

**Loop primitive/state/tools/streaming:** The distinguishing bet: agents write their *actions* as Python code snippets executed in a sandbox, rather than emitting a JSON blob of `{tool_name, args}` that gets parsed and dispatched. `CodeAgent` is the flagship class; `ToolCallingAgent` exists for the traditional JSON path. The stated empirical claim: code-as-action "uses 30% fewer steps (thus 30% fewer LLM calls) and reaches higher performance" than JSON tool-calling, because a single code block can compose conditionals, loops, and multiple tool calls that would otherwise take several JSON round-trips.

**LOVE:**
- "Thanks, this looks great. I've been playing with Huggingface's Smolagents, which...": described elsewhere in the same thread as "really well designed," [HN #43474025](https://news.ycombinator.com/item?id=43474025)
- The philosophical one-liner maintainers use to defend the design: "If JSON snippets were a better expression, JSON would be the top programming language and programming would be hell on earth": [smolagents blog](https://huggingface.co/blog/smolagents)

**HATE:**
- "Importing smolagents Takes Excessive Time": heavy `transformers`/`torch` initialization on import even when unused, [GitHub #100](https://github.com/huggingface/smolagents/issues/100)
- "Memory-related tooling is not exposed in smolagents," a real limitation for anything beyond single-session agents, [GitHub #901](https://github.com/huggingface/smolagents/issues/901)
- Code-gen correctness edge case: the agent sometimes emits multiple `final_answer()` calls, one mid-script, "preventing code following its first occurrence from executing": a sharp-edge specific to the code-as-action model that JSON tool-calling doesn't have
- Even a positive account noted the tax: getting the prompts right for real tasks "took considerable effort," [HN #42827555](https://news.ycombinator.com/item?id=42827555)

**DEMAND:** Lighter/lazy imports so the library doesn't drag heavy ML dependencies into unrelated code paths; first-class memory/history consolidation instead of leaving it to the caller.

**HORROR:** None at incident scale found: smolagents reads as "barebones library," true to its own tagline, with correspondingly barebones failure modes (import weight, missing memory API) rather than systemic architecture regret.

---

### Mastra (TypeScript)

**Loop primitive/state/tools/streaming:** Agent class over 40+ model providers via a unified interface; Workflows are the durable/composable execution layer (with an Inngest integration for durable-execution-style step semantics: note the `WaitForEvent if/match` feature request explicitly targeting Inngest workflows, [GitHub #8689](https://github.com/mastra-ai/mastra/issues/8689)). Mastra Studio provides run-replay and token-usage inspection. Built by the team behind Gatsby, which lent early credibility.

**LOVE:**
- HN gave "a lot of enthusiasm and helpful feedback" at both the original 2025 Show HN ([#43103073](https://news.ycombinator.com/item?id=43103073)) and the 1.0 launch ([#46693959](https://news.ycombinator.com/item?id=46693959))
- 300K+ weekly npm downloads and adoption by "several YC-backed startups" cited as real production traction, not just demo interest

**HATE:**
- Breaking API changes persisted well past the point a production framework should have stabilized: "between v0.3 and v0.4, the workflow API changed significantly, requiring agent code migration": API stability was *promised* from v1.0, but as of the write-up "that hasn't shipped yet" ([developersdigest.tech](https://www.developersdigest.tech/blog/mastra-durable-typescript-agents))
- A version upgrade silently broke tool schemas: bug reports funneled straight from Discord into GitHub: `[DISCORD:1410588807325159544] Upgraded to latest version, Tools in workflow starts breaking`, validation errors like "expected object, received string," [GitHub #7186](https://github.com/mastra-ai/mastra/issues/7186)
- Basic workflow ergonomics gaps: starting and reading a single workflow run takes three separate API calls (create-run, stream, get-result), adding latency the reporter calls unnecessary, [GitHub #6477](https://github.com/mastra-ai/mastra/issues/6477)
- Workflow runs get stuck in a `running` state without progressing, [GitHub #10752](https://github.com/mastra-ai/mastra/issues/10752)
- TypeScript-only is a hard ecosystem boundary: "ML engineers who work in Python notebooks can't contribute directly," and orgs with existing Python AI infra get a coordination tax
- Small plugin surface: "maybe 50-60 integrations": niche connectors are DIY
- Security note (not a design flaw, but relevant to production trust): 145 npm packages under the Mastra namespace were compromised via a hijacked contributor account in June 2026: a supply-chain incident, not a framework-design failure, but exactly the kind of thing that erodes "can I trust this dependency" calculus

**DEMAND:** Deliver the promised v1.0 API-stability contract for real (echoing pydantic-ai's playbook almost exactly, but Mastra's own users note it hasn't landed); collapse workflow start/stream/result into one call; broaden the integration ecosystem or provide a clean escape hatch to write your own without fighting the framework.

**HORROR:** The Discord-tagged breaking-tools issue is the cleanest "abstraction tax" incident in the whole survey: an upgrade silently reclassified tool input shape and broke every workflow using tools, discovered by users in Discord before it was a tracked issue.

---

### Claude Agent SDK (glance)

**Positioning:** Library-ified version of the Claude Code loop: "give the agent a computer" is the core philosophy: deep OS/filesystem access, native MCP support (200+ servers, single-line config), prompt caching, extended thinking, and computer-use baked in rather than bolted on. Distinct from the others in that it's explicitly single-vendor (Claude-only) and optimized for coding-agent-shaped work rather than generic business-process orchestration.

**Reception:** Strongly positive on HN: "the capabilities are amazing, and the speed of creating new stuff is impressive," with some developers calling it superior to Cursor/Windsurf specifically because it's CI/CD-embeddable ("it's now the default way I'm thinking about coding agents"). Search interest reportedly grew ~500x YoY through H1 2026. The sharpest complaint found isn't architectural: it's economic: "Claude Code $200/mo pl[an]" pricing frustration echoed "all over reddit" per one HN aside ([#44759427](https://news.ycombinator.com/item?id=44759427)), plus a separate June 2026 change moving Agent SDK usage onto its own metered credit pool, which is a cost-predictability complaint, not a loop-design one.

**DEMAND:** Cost transparency/predictability as usage moved from bundled-plan to metered credits: the recurring ask is billing clarity, not API redesign.

---

## Cross-Cutting Questions

### A. The LangChain lesson, precisely

The revolt was not "frameworks are bad". It was specific, and it decomposes cleanly into four distinct grievances that different frameworks then either fixed or repeated:

1. **Hidden/opaque prompts.** "Lol, yeah the hidden prompts in langchain, and the bloat turned me off it pretty..." ([HN #38438252](https://news.ycombinator.com/item?id=38438252)). The system prompt could get silently overridden when running an agent: `minimaxir` and `mp3il` both flagged "the system prompt being ignored when running an agent" as the concrete trigger for walking away ([HN #36648142](https://news.ycombinator.com/item?id=36648142)). You could not see, by reading your own code, what was actually being sent to the model. Tracing a single request "sometimes required opening six different objects just to find the rendered prompt template."
2. **Wrapper-of-wrapper indirection with no payoff.** "The core data structure, the Chain, is basically just a function... they build all these adapters and integrations and make it seem like they're helping you piece together a solution, but in how many cases were they necessary as a middleman?": `bestcoder69` ([HN #36725982](https://news.ycombinator.com/item?id=36725982)). `louis8799`, same thread: wrapping "2 lines of code with 2 thousand lines of code, also wrapping python While loop in chain object." This is the specific "abstraction tax" pattern: the abstraction doesn't compress complexity, it multiplies indirection around code that was already simple.
3. **Debugging opacity.** "the second you need to do something a little original you have to go through 5 layers of abstraction just to change a minute detail": `sc077y` ([HN #40739982](https://news.ycombinator.com/item?id=40739982)). "Debugging LangChain performance and bugs is just an exercise in frustration": `techwizrd`, same thread. The end state teams converged on: "by the time you have built custom chains, custom prompts, and custom agents to support all that, you basically are using their interface and not their code": `avereveard`.
4. **Churn without a stability contract.** Sub-1.0 versioning (`0.0.234`) meant breaking changes shipped as patch releases: "changes that should be used properly by minor, patch version... are all lumped together": `parc_b`. Version churn was described as a "real productivity drain," with teams reporting "weeks of refactoring during the 0.1 and 0.2 transitions."

**Who learned it:** OpenAI Agents SDK (radically minimal: 4 primitives, loop stays visible, no prompt templating layer to hide behind); pydantic-ai (tools are plain decorated functions, schema derives transparently from type hints you wrote, and the maintainers turned "stability" into an explicit tracked commitment via [issue #1372](https://github.com/pydantic/pydantic-ai/issues/1372) rather than letting it happen by accident); LangGraph itself, as LangChain's own admission that the Chain abstraction needed replacing with something lower-level and explicit (CEO Harrison Chase directly engaging the criticism on HN: "frameworks are useful when there are clear patterns... it is super early on," [HN #40750669](https://news.ycombinator.com/item?id=40750669)).

**Who repeated it:** Mastra shipped a significant breaking workflow-API change between v0.3 and v0.4 and, as of the most recent write-up found, still hadn't delivered the API stability it promised for v1.0: the exact "promised stability, delivered churn" pattern LangChain became infamous for, just compressed into TypeScript's faster release cadence. Vercel AI SDK's v5 rewrite (custom protocol → SSE, type splits, renamed fields) is defensible as "architecturally cleaner," but it landed the same way: a major breaking release with an underestimated migration surface (the codemod explicitly disclaims the hand-written code that took longest to write).

### B. Checkpoint/resume as a library concern

Real production usage exists, but it's narrower and more skeptically adopted than the vendor marketing suggests. LangGraph's checkpointer story is the most mature: PostgresSaver is explicitly positioned as *the* production choice over MemorySaver, and it's the mechanism behind pause/resume, time-travel, and human-in-the-loop interrupts, not an optional add-on.

Durable-execution *engine* integrations (Temporal, Inngest, Restate) are real but contested. The strongest concrete production signal is a Show HN making OpenAI Agents SDK demos "durable and scalable with Temporal" ([HN #44736713](https://news.ycombinator.com/item?id=44736713)), where the value-add is stated plainly by a commenter: "Temporal's durable execution is the value add. The decorators... let the Temporal engine know it needs to ensure that those functions get completed in the face of any failures." But that thread had almost no debate: it's a demo, not contested production wisdom.

The skepticism shows up elsewhere, sharply: in "How to think about durable execution" ([HN #46245238](https://news.ycombinator.com/item?id=46245238)), `teeray` cuts to the bone, "the only thing the durable execution engine is buying you is an optimization against re-running some slow tasks", and `abelanger` notes "many (perhaps most) async workloads" don't need full durable execution, "you need a task queue with retries" instead. `cammil` adds the load-bearing caveat that applies regardless of framework: "The underlying tasks still have to be idempotent": the durable-execution engine doesn't remove that burden, it just gives you infrastructure to retry around it.

Inngest's own framing is telling: it does "step memoization rather than full deterministic replay": a deliberately lighter contract than Temporal's. Restate is positioned as the choice only "if workflow correctness matters enough that you want durable execution baked into service boundaries and not just background jobs": i.e., most teams don't need it, a minority do and know who they are.

**Verdict:** checkpoint/resume as *state persistence* (LangGraph-style) is broadly adopted and load-bearing in production. Checkpoint/resume as *full durable-execution engine* (Temporal-grade) is a minority pattern, reached for deliberately by teams with correctness requirements beyond "retry the LLM call," not a default expectation.

### C. Minimal loop vs. framework camp: who's winning mindshare

Both camps have real 2025-2026 traction, and the honest answer is they're optimizing for different audiences rather than one displacing the other.

**Minimal-loop camp evidence:** [12-factor-agents](https://github.com/humanlayer/12-factor-agents) crossed 10,000 GitHub stars with a thesis of "own your prompts, own your context window, treat the agent as a stateless reducer you control." On its own HN thread ([#43699271](https://news.ycombinator.com/item?id=43699271)), the author (`dhorthy`) is blunt: "you're an engineer, you can write a for loop and a switch statement. don't outsource your prompts," and "i don't think langchain or dspy are the 'C programming language' of AI yet." `daxfohl`: "you're going to be a lot better off learning the low level LLM interfaces rather than being dependent on a framework." `nickenbank`, flatly: "Most, if not all, frameworks or building agents are a waste of time." Anthropic's own "Building Effective Agents" essay landed the same message from the vendor side: find "the simplest solution possible, and only increasing complexity when needed, which might mean not building agentic systems at all", deliberately steering people away from framework-first thinking at the API level.

**Framework camp evidence:** enterprise deployment counts (Klarna at 85M users on LangGraph, JPMorgan, Uber, LinkedIn) and continued high download numbers for LangGraph (39.2M monthly PyPI) show frameworks winning exactly where the minimal-loop camp is weakest: teams that need checkpointing, observability, and multi-engineer consistency *out of the box*, where re-deriving that infrastructure by hand is the actual waste of time.

**The honest synthesis**, stated well in one 2026 survey piece: "frameworks are paying for themselves at enterprise scale, and developers are tired of the abstraction churn", both true simultaneously, because they're describing different populations. Solo/small-team builders and anyone burned once already lean minimal-loop. Platform teams building the *n*-th agent inside an org with existing observability/compliance requirements lean framework, but specifically toward the *lower-level* frameworks (LangGraph, OpenAI Agents SDK) that learned the LangChain lesson: nobody in 2026 material found is nostalgic for Chain objects.

### D. Tool definition ergonomics

Two competing philosophies, both with real adoption, plus a third (smolagents) that sidesteps the question entirely:

- **Schema-from-types (pydantic-ai, Vercel AI SDK/Zod):** universally praised for eliminating drift between "what I typed" and "what the LLM sees." pydantic-ai: "docstrings are passed to the LLM as descriptions, and parameter descriptions are extracted from docstrings": one source of truth, IDE-checked. Vercel AI SDK: "You get fully typed results or an error, never malformed data that crashes later." The complaint that *does* surface isn't about the ergonomics, it's that schema conformance is a request to the model, not a guarantee: `__MatrixMan__` on pydantic-ai, "pretty frequently the LLM just refuses to actually supply json conforming to the model" even with retries configured. The ergonomics win is real; it doesn't fully solve the underlying reliability problem, which lives at the model layer, not the schema layer.
- **Manual JSON schema (raw OpenAI-style function calling):** the thing schema-from-types frameworks are explicitly reacting against: verbose, duplicated between your type system and the schema, easy to let drift. No forum thread found actively defends hand-written JSON schema on ergonomic grounds; where it survives, it's for transparency/no-dependency reasons, not because anyone enjoys writing it.
- **Code-as-action (smolagents):** a different axis, no per-call schema at all. The tool interface becomes "a Python function the LLM calls in code it writes," and the empirical claim (30% fewer steps) comes from letting a single code block chain conditionals and multiple tool calls instead of round-tripping JSON per call. The tradeoff is sandboxing/safety complexity and edge cases like the double-`final_answer()` bug that JSON tool-calling structurally can't produce.

### E. Multi-agent primitives: real production or demo-ware?

Genuinely contested, with the two most-cited 2025-2026 voices landing on opposite headlines within 24 hours of each other, which is itself the finding: Cognition (Devin) published "**Don't Build Multi-Agents**" arguing that naive multi-agent splits fail because "actions carry implicit decisions, and conflicting decisions carry bad results": their worked example: split a "build Flappy Bird" task across a background-agent and a bird-agent, and you get a background and a bird "with completely different visual styles" because neither subagent saw the other's decisions. Anthropic published "How We Built Our Multi-Agent Research System" the same week, reporting a multi-agent (orchestrator + parallel Sonnet subagents) setup beating single-agent Opus by 90.2% on their internal research eval, but at **~15x the token cost**, and explicitly scoped to "problems that can be divided into parallel strands of research" while noting multi-agent is "less effective for tightly interdependent tasks such as coding."

Cognition's own follow-up, "**Multi-Agents: What's Actually Working**," resolves the apparent contradiction rather than doubling down: parallel-writer swarms are dismissed as "mostly a distraction," but three patterns *are* live in production: (1) a code-review agent with a **separate, clean context** from the coding agent, catching ~2 bugs/PR with 58% rated severe, where the separation itself (not parallelism) is what triggers deeper analysis; (2) "smart-friend" escalation to a stronger model, which "works today when both models are strong" but is unsolved when the primary model is weak; (3) manager-child task decomposition, explicitly "live in Devin today," requiring heavy prompt engineering to avoid over-prescription.

On the OpenAI Agents SDK side (the framework whose core multi-agent primitive literally *is* handoffs) the GitHub issue trail ([#617](https://github.com/openai/openai-agents-python/issues/617), [#1197](https://github.com/openai/openai-agents-python/issues/1197), [#1638](https://github.com/openai/openai-agents-python/issues/1638)) shows real production teams hitting non-deterministic routing failures, one closed "not planned." Marketing material calls "supervisor" the "2026 production default"; the issue tracker suggests the primitive underneath that default still has open reliability gaps.

**Verdict:** single-agent-with-good-tools is the default that should require justification to leave; the multi-agent patterns with actual production evidence are narrow and specific (separate-context review, model-tier escalation, hierarchical task decomposition with heavy engineering), not the general-purpose "swarm of peer agents" demo that most framework marketing pages show first.

---

## Top 5-7 complaints, ranked

1. **Hidden control flow / opaque prompt construction.** The single most-repeated LangChain-era complaint, and the one every successor framework advertises fixing. If a user can't `grep` their own code to find exactly what's sent to the model, trust erodes fast.
2. **Breaking changes without a stability contract.** Present in LangChain (0.0.x churn), Mastra (v0.3→v0.4 workflow API break, promised-but-undelivered v1.0 stability), and Vercel AI SDK (v5's ground-up protocol rewrite). The frameworks that recovered reputation (pydantic-ai) did so by making the stability *promise* itself a tracked, public commitment, not just a changelog entry.
3. **Multi-agent handoff/routing non-determinism.** Directly evidenced in OpenAI Agents SDK's GitHub issues (handoffs silently not firing, not returning up the call stack) and structurally explained by Cognition's "actions carry implicit decisions" framing.
4. **Debugging opacity under composition.** "6 objects deep to find a rendered prompt" (LangChain); "a small change in context... meaningfully changes the next step's output" with no visibility (Vercel AI SDK, addressed only recently via DevTools); state race conditions with unclear provenance (LangGraph without proper reducers).
5. **Ecosystem/language lock-in tax.** Mastra's TypeScript-only boundary blocking Python ML engineers; framework-specific state/tool dialects (LangGraph's Command objects, InjectedState) that don't transfer if you leave.
6. **Abstraction that doesn't compress complexity, just relocates it.** The "Chain is basically just a function, wrapped 1000x" complaint: the abstraction tax is real when the wrapper adds indirection without adding capability.
7. **Durable-execution/checkpointing complexity exceeding the actual reliability need.** "The only thing it's buying you is an optimization against re-running slow tasks," and the underlying tasks still have to be idempotent regardless: teams reach for Temporal-grade machinery before confirming they need more than a retrying task queue.

## Top 3-5 patterns worth stealing

1. **Explicit, inspectable state as a first-class value, not framework-internal.** LangGraph's reducer-annotated state and pydantic-ai's plain dependency-injected `RunContext` both keep "what does the model see" answerable by reading data, not by tracing framework internals five layers deep.
2. **Schema-from-types for tool definitions.** The pydantic-ai/Zod pattern (one declaration, both the type system and the LLM-facing schema derive from it) eliminates an entire class of drift bugs and is praised near-universally where it appears.
3. **Separate-context review as the multi-agent pattern with actual evidence behind it.** Not swarms, not peer handoffs: a second agent with a *clean, independent* context reviewing a first agent's full trace. Cheap to implement, doesn't require solving shared-state consistency, and has a concrete production metric (58% severe-bug catch rate) behind it.
4. **A public, tracked stability commitment as a first-class artifact**, not an implicit promise. pydantic-ai's [#1372](https://github.com/pydantic/pydantic-ai/issues/1372), a maintainer-owned, permanently-open issue documenting every deliberate breaking change and why, is a cheap, high-trust pattern any library can adopt.
5. **Keep the loop visible.** Every framework that recovered reputation after the LangChain backlash (OpenAI Agents SDK, LangGraph-over-Chain, pydantic-ai) did it by making the request/response loop something the developer can point to in their own code, not something that happens inside a compiled graph or hidden executor.

## Surprises / Contradictions

- **The two most-cited multi-agent takes of the era directly contradict each other in their headlines** (Cognition "Don't Build Multi-Agents" vs. Anthropic's 90.2%-improvement multi-agent report) while substantially agreeing underneath once you read past the title, both land on "narrow, specific multi-agent patterns work; general swarms don't," they just chose opposite headlines for the same underlying finding. Worth remembering that framework marketing headlines often overclaim relative to their own supporting engineering blog posts.
- **Pydantic: a schema-validation library: became an AI framework vendor**, and a chunk of its own longtime user base is unhappy about it ("I really wish Pydantic invested in... Pydantic"), even though pydantic-ai is one of the best-reviewed frameworks in this survey on pure ergonomics. Product-market success and community sentiment about mission drift aren't the same axis.
- **Durable execution has a live "we don't actually need this" counter-current** even as vendors (Temporal, Inngest, Restate) all specifically target the agent-reliability use case with dedicated content: the HN skepticism ("just a task queue with retries," "the tasks still have to be idempotent regardless") is a direct, credible pushback on category-defining marketing.
- **The most structurally rigorous rebuttal of the entire LangChain-style-framework category came from outside Python/TS entirely**: the Elixir community independently re-derived 12-factor-agents' conclusions from OTP first principles, without apparently citing it, arriving at "own your message chain, don't hide it inside an abstraction" as a natural consequence of how the language already works.
- **Mastra repeated LangChain's exact mistake** (promise stability, ship a breaking workflow-API change) inside a single year, despite being built years after the LangChain backlash was already common knowledge, suggesting the lesson doesn't automatically transfer just because a team is aware of it; it has to be operationalized (a tracked stability issue, semver discipline) or it recurs.

---

## Recommendations for an Elixir/OTP harness builder

**The Elixir community has already independently re-derived most of the minimal-loop camp's conclusions.**

From [Elixir Forum](https://elixirforum.com/t/is-anyone-working-on-ai-agents-in-elixir/69989), Jido's author `mikehostetler`: *"Long term - a few GenServers that wrap `req` calls to LLM APIs are better"* than a sophisticated framework, and *"a simple LLM wrapper doesn't need a sophisticated agent framework - Oban works great"* for the persistence/retry layer. `tfwright` reports using **Oban as the state-machine/checkpoint layer wholesale**: *"its states and arg persistence and retry handling cover pretty much all my use cases."*

The [goto-code.com](https://goto-code.com/why-elixir-otp-doesnt-need-agent-framework-part-1/) series: LangChain-style frameworks "work well enough for a POC but... it's failing to meet the challenge" as projects grow, specifically because they hide the message chain; the OTP-native alternative threads conversation state through explicit `with` pipelines so *"real magic happens when one manipulates and actively manages the chain"* directly.

Concrete recommendations:

1. **Don't build a graph/DSL compiler over control flow.** LangGraph's node/edge model earns its keep in Python specifically because Python lacks pattern matching, `with`, lightweight processes. Elixir has all three. A `StateGraph`-equivalent in `raxol_agent` would solve a problem the language doesn't have, at the cost of exactly the opacity people revolt against. (Validates existing direction: TEA's `update/2` plus explicit `Command` types *is* the visible loop.)
2. **Treat checkpointing as state-persistence, not durable-execution-engine, until proven otherwise.** GenServer state + Oban-style job persistence likely sufficient. Reach for Temporal/Restate-grade machinery only for the exception.
3. **Schema-from-types for tool definitions is the one abstraction every framework converged on praising.** Keep the Action behaviour mapping tight and single-source, never let the LLM-facing schema drift from the function signature.
4. **Multi-agent should default to evidenced patterns:** (a) reviewer/critic agent with genuinely separate context over (b) parallel peer swarms. Prefer deterministic dispatch (pattern-matching in your own supervisor) over LLM-picks-next-agent, wherever routing is expressible as code.
5. **Make the stability contract explicit and public**, pydantic-ai-style, once raxol_agent has external Hex users.
6. **Resist prompt-templating layers that aren't just readable string interpolation.** The one line item every "why I left LangChain" account converges on.

### Deeper question: which abstractions pay rent

**Pays rent:** type-derived schemas; state persistence as a concept; a visible steppable loop; narrow evidenced multi-agent patterns (separate-context review, tiered escalation).

**Gets routed around:** graph/DSL compilers over control flow (in languages with good control-flow primitives); hidden/templated prompt construction (zero defenders found anywhere); LLM-driven control-flow where deterministic dispatch would do; durable-execution machinery before confirming need; framework-specific parallel dialects for state/control.

Throughline: **abstractions worth building address genuinely cross-language problems (schema/type consistency, evidenced multi-agent patterns, stability contract): not re-solving problems the host runtime already solved better.**
