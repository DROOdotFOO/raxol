# Protocol/standards seam map — distilled (the strategic spine)

## The one lens
A harness = a bundle of **seams** (LLM↔harness, harness↔tools, harness↔UI, agent↔agent, harness↔own-state). Every seam is where the harness could be swapped. **A settled protocol commoditizes the side that gets standardized** (commoditize-your-complement). LSP standardized language servers → editors won. MCP standardized tools → the consumer (harness) stays durable. ACP standardizes *agents* → editors win, agents become interchangeable dropdown backends.

## The seam map
| Seam | Status | Reality |
|---|---|---|
| LLM inference API | **Settled-shape, divergent-wire** | JSON-schema tools/parallel/streaming converged; `tool_use`≠`function_call`, object≠string args, **3 incompatible reasoning-continuity tokens**. Must abstract, non-trivially. |
| Harness↔tools | **SETTLED** | MCP, foundation-governed (donated to Linux Foundation AAIF 2025-12-09), 24x A2A adoption. |
| Capability packaging | Informally settled | `SKILL.md` (Anthropic convention, OpenAI adopted Feb 2026). |
| Harness↔editor | **CONTESTED (Zed's ACP leading by default)** | Real cross-vendor traction, two-company governance, Anthropic abstains, VS Code absent. Alternative = bespoke CLI wrapping. |
| Harness↔web UI | Contested (single-vendor) | AG-UI real but CopilotKit-stewarded. |
| Embedding vendor CLIs | Bespoke, convergence-by-imitation | stream-json / app-server / Amp-clone — no standard, none coming. |
| Agent↔agent cross-org | Contested-narrow | A2A real in enterprise, thin elsewhere. |
| Agent↔agent intra-fleet | Bespoke, fine | raxol Registry/Team; A2A overkill. |
| **Session/transcript format** | **CATEGORY-EMPTY** | Claude JSONL / Codex threads / opencode REST / Aider Markdown. No interchange. |
| **Resumability** | **EMPTY and REGRESSING** | MCP 2026 RC *removed* SSE resumability. Trend negative. |
| **Checkpoint format** | **CATEGORY-EMPTY** | All internal, no interchange. |
| **Permission-policy exchange** | **CATEGORY-EMPTY** | ACP `session.request_permission` = runtime prompt; MCP annotations = untrusted hints. No standard for expressing a *policy*. |
| **Context lifecycle/compaction** | **CATEGORY-EMPTY (documented practice, no protocol)** | Correctness requirement, not just cost. |

## MCP state (decision-critical)
- Governance de-risked: donated to LF AAIF, co-founders Anthropic/Block/OpenAI, multi-vendor now.
- **2026-07-28 RC has breaking changes: stateless core (removes initialize handshake), sessions removed, SSE resumability removed, Sampling+Roots+Logging DEPRECATED, Tasks demoted to extension.** MCP is *shrinking its core*, opposite of standards-bloat. Bet on core tool-calling only.
- Adoption reality: Stacklok survey (300 leaders) = only **11% "in production,"** top blocker security 64%. Viral "78% of enterprises" stat is unsourced, discard.
- Context bloat = dominant complaint. Huntley: GitHub MCP = *"93 additional tools, 55,000 tokens."* Willison: give the agent `gh` CLI instead, *"token cost close to zero — every frontier LLM already knows how to use that tool."*
- **⭐ NO official Elixir MCP SDK. Hermes MCP is dead (404), forked to `zoedsoupe/anubis-mcp` (license changed MIT→LGPL-3.0 — legal flag). Implement the JSON-RPC wire yourself — the stateless RC makes that EASIER.**

## Zed's ACP
- **Name collision: FOUR "ACP"s.** Zed's Agent Client Protocol / IBM's Agent Communication Protocol (defunct) / **raxol's own `raxol_acp` = Agent Commerce Protocol** / adjacent A2A. **Always write "Zed's ACP" on first mention in raxol docs.**
- JSON-RPC over stdio, "LSP but for agents." Native: Zed, JetBrains (co-governs), Gemini CLI, Cursor CLI, opencode. **Claude Code NOT native (Zed-maintained bridge). Codex bridged. VS Code zero native support.**
- **Load-bearing subtlety: ACP sits ON TOP of vendor protocols, doesn't replace them.** Embedding Claude/Codex at full fidelity still means their native protocols underneath.

## The continuity-token trap (sharpest concrete finding)
All 3 providers independently invented **opaque reasoning-continuity tokens that must be replayed byte-for-byte** or hard-fail (400): Anthropic `thinking.signature`, OpenAI `reasoning.encrypted_content`, Gemini `thought_signature`. 5 major OSS projects have public issues from dropping Gemini's alone (LiteLLM, Google's *own* adk-js, opencode, Goose, openclaw). **Rule: never filter content blocks by type when replaying history** — exactly what a naive normalization layer does, exactly what breaks continuity. Note Chat Completions is NOT dying — Ollama/LM Studio/OpenRouter/Kimi (all in raxol) speak that 3rd OpenAI-family shape.

## Security — harness must enforce what protocol won't
- Tool poisoning (Invariant): malicious instructions in tool *descriptions*, invisible to users, PoC exfiltrated `~/.ssh/id_rsa`.
- **Line jumping (Trail of Bits): attack fires at CONNECTION time, before any invocation or approval.** Invocation-time approval gates insufficient by construction.
- Lethal trifecta (Willison): *"more than two and a half years and we still don't have convincing mitigations."*
- CVE-2025-6514 (CVSS 9.6, mcp-remote RCE).
- **Harness must:** treat every tool description AND result as untrusted; enforce own policy not server-declared annotations; break the trifecta by construction (never let private-data + untrusted-content + network-egress coexist unsupervised); pin server versions; sandbox. **raxol OTP substrate = asset (process isolation, supervised boundaries, capability-scoped Runners map onto fail-closed + isolate-the-trifecta).**

## Context management practice (own it — it's the empty seam)
- Chroma: *every* model degrades well inside its advertised window — "200K window" serious loss at ~50K.
- Anthropic ships 3 API primitives on the Messages API (raxol's target): **memory tool** (client-side files, survives resets), **context editing** (`clear_tool_uses`, light/primary), **compaction** (`compact-2026-01-12` beta, `pause_after_compaction` = deterministic splice point).
- Convergent design: token-threshold trigger (caller-preemptable), **verbatim recent tail + compressed head, drop old tool-result bodies first**, never summarize system prompt/schemas, summaries retain *decisions+state* not prose.
- Manus: KV-cache stability = "single most important metric" (stable prefix, append-only); filesystem as unlimited reversible context; recite goals via todo.md; keep failures in context.
- **Cognition counter-rule for writes: single-threaded — "actions carry implicit decisions" no summary boundary transmits.** Field synthesis: **isolate freely for read/research fan-out; keep writes single-threaded through one full-context agent.**

## Bet list (2-year horizon)
**SAFE (bet the harness on):**
1. Consume LLM APIs behind a real abstraction — role-mapping, schema-dialect translation, streaming reassembly, **opaque continuity-token replay (never filter blocks by type)**.
2. Consume MCP as *optional inbound* tool-interop — **implement the JSON-RPC wire directly, no Elixir SDK dependency**. Keep own tool model primary, MCP = one adapter.
3. Own context lifecycle + compaction as first-class.
4. Own session persistence + checkpointing + permission policy as native OTP state.

**RISKY (hedge):** MCP non-core (Sampling/Roots DEPRECATED — don't build server-drives-your-LLM); exposing raxol as ACP *server* (real but relocates you to commodity side — adopt only if editor-distribution is a goal); embedding more vendor CLIs (each bespoke+churning, use capabilities feature-detection not version strings).

**AVOID:** A2A intra-fleet (overkill); AG-UI as "the" standard (LiveView covers it); any Elixir MCP SDK as stable infra; Sampling-based architectures (deprecated protocol-wide).

## Deeper question: commodity vs durable layer (THE strategic finding)
**Protocols you CONSUME entrench you** (MCP → tools are commodity, you're the durable orchestrator; LLM APIs → models fungible beneath you; Codex/Claude session protocols → those loops swappable subprocesses under your control).
**Protocols you PROVIDE/EXPOSE make you replaceable** (ACP-server → raxol = one interchangeable entry in a 50-agent dropdown, *editor* becomes durable). LSP lesson in reverse: LSP made language servers free so editors win; ACP makes agents free so editors win. Expose ACP for *reach*, knowing you volunteer as the complement.

**The durable layer is always the un-protocol'd, stateful, high-switching-cost seam.** The category-empty seams (session/transcript persistence, checkpoint, resumability, permission policy, context/compaction state, project memory) are empty *precisely because that's where lock-in concentrates and no incumbent wants to standardize away their moat.* HN: *"context window management is actually a good hunk of the secret sauce."*

**THE ISOMORPHISM: the category-empty seams and OTP's home turf are the same set.** Anthropic's long-running-harness postmortem describes reinventing process persistence in userland — *"engineers working in shifts... no memory of what happened on the previous shift,"* file-based handoff, manual context resets. That's a poor-man's supervised-durable-process with hand-rolled checkpointing — exactly what OTP gives natively (durable processes, supervision trees, `:pg` distribution, raxol's existing CRDT swarm). The ecosystem hasn't standardized session-persistence/resumability/supervision because in Python/TS it's genuinely hard and every solution is bespoke. On BEAM it's the substrate. **The market's empty seam is the platform's strongest muscle.**

**Strategic posture:**
- **Durable core (own it, OTP-native):** the loop, context lifecycle/compaction, session transcript + checkpoint + resumability, permission policy, memory. Consume MCP + LLM APIs as commodity inputs beneath it.
- **Optional distribution surfaces (expose selectively, don't relocate state into them):** ACP-as-server for editor reach; MCP-server-of-own-tools; LiveView/MCP-diff for web. Keep state in the supervised core — the moment session/checkpoint state lives in someone else's protocol, you've handed them the durable seat.
- **Ignore for now:** A2A, AG-UI, every Elixir MCP SDK.

One line: **consume the settled protocols, own the empty ones, be deliberate about provider-facing protocols that trade durability for reach. The empty seams are the moat — and they're exactly what OTP was built to hold.**
