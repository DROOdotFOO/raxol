# Why Raxol

Most agent runtimes are a Python process wrapped around a model. Raxol is an OTP runtime.
That difference decides what an agent can survive, how many can run at once, where they can
render, and what they can safely be allowed to do.

For the TUI-framework comparison (Bubble Tea, Ratatui, Textual), see [Why OTP](WHY_OTP.md).
This page is about agents.

## The runtime

| | Hermes | Omnigent | Raxol |
|-|--------|----------|-------|
| Substrate | one Python process per agent | subprocess per conversation (FastAPI) | millions of supervised BEAM processes |
| Concurrency | ThreadPoolExecutor, app-level retry to dodge the convoy effect | per-conversation processes | preemptive scheduling, mailbox serialization |
| State on crash | SQLite file (single process) | external store | supervision trees restart with state intact |
| Surfaces | chat platforms (bridges) | editor harnesses | terminal, browser, SSH, MCP, Telegram, watch, speech from one module |
| Payments | none | none | wallets, spend limits, cross-chain settlement |

The BEAM was built for systems that cannot go down, cannot lose state, and hot-swap code
while running. An agent runtime wants exactly those properties. When a background reviewer
crashes, the turn is unaffected because it runs in an isolated process. When a node
restarts, an agent's memory and skills survive because they are backed by a supervision tree
and durable stores, not held in one process. When you want a thousand agents, you spawn a
thousand lightweight processes, not a thousand OS threads.

## Four things Raxol does that the others do not

### Governed execution (ALLOW / ASK / DENY)

Every tool call passes through an [authorization engine](features/AGENT_FRAMEWORK.md#authorization-allowaskdeny)
that returns allow, ask, or deny, with per-scope approval memory. This is stronger than a
binary approve/deny prompt: an agent can be allowed to read anywhere, asked before writing,
and denied the shell entirely, declaratively. The [Coding Agent](features/CODING_AGENT.md)
runs every mutating action through it, and the [Tool Catalog](reference/TOOL_CATALOG.md)
marks which tools are gated.

### One app, every surface

The same TEA module renders to a terminal, a LiveView, an SSH session, an agent over MCP, a
watch, and a chat, through one OTP fan-out. Competitors integrate each platform separately;
Raxol projects one running module. See [Surfaces](guides/SURFACES.md).

### A learning loop backed by supervision

Raxol has an after-turn [self-improvement](features/SELF_IMPROVEMENT.md) loop, agent-authored
skills, a provider-stack [memory](features/MEMORY.md) layer, and a dialectic user model, the
same capabilities Hermes markets as its differentiator. The difference is the substrate: the
reviewer is an isolated Task, skills are on-disk `SKILL.md` files with DETS telemetry
replayed on boot, and every Curator pass is reversible. A learning loop that cannot lose
state because it is backed by OTP supervision is a stronger claim than one backed by a
single-process database.

### Agentic commerce

Raxol agents can pay and be paid: wallets, ledger-enforced spending limits, transparent
HTTP 402 auto-pay, cross-chain settlement, stealth and shielded transfers, and ZKSAR trust
attestations. See [Agentic Commerce](features/AGENTIC_COMMERCE.md) and the
[Agent Commerce Protocol](features/ACP.md). Neither Hermes nor Omnigent has any of this, and
it is not a feature they can add without a runtime for it.

## What Raxol is not

Raxol is younger than its competitors in raw tool count and hosted polish. If your only need
is a single Python agent calling a large catalog of built-in tools on one machine, a Python
harness will get you there with less Elixir. Raxol earns its keep when you want agents that
survive crashes, run by the thousand, render to more than a chat window, are governed rather
than trusted, or move money. Those are BEAM problems, and Raxol is the runtime for them.

## See also

- [Why OTP](WHY_OTP.md): the TUI-framework comparison.
- [Philosophy](PHILOSOPHY.md): the design principles behind the runtime.
- [Build Your First Agent](getting-started/BUILD_AN_AGENT.md): put the runtime to work.
