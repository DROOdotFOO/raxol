# Ubiquitous Language

Canonical terminology for Raxol. When writing docs, marketing copy, error
messages, or talking to other contributors, use these terms. Aliases listed in
each table are _the wrong term_ -- avoid them, even when they sound natural.

This file is grouped by domain area. Each table lists the canonical term, a
one-sentence definition, and aliases that mean the same thing but should not be
used in writing. Relationships and example dialogue follow tables where
disambiguation is load-bearing.

---

## Application Model

| Term           | Definition                                                                                               | Aliases to avoid                              |
| -------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| **TEA**        | The Elm Architecture: the canonical shape of a Raxol application -- `init/1`, `update/2`, `view/1`.      | MVU, Elm-style                                |
| **TEA module** | An Elixir module that implements the TEA callbacks. The unit of authoring.                               | TEA app, application module, component module |
| **Model**      | The application's state. Returned by `init/1`, transformed by `update/2`, rendered by `view/1`.          | state, store, app state                       |
| **Message**    | An input passed to `update/2`. Triggers a state transition.                                              | event, action, msg                            |
| **Command**    | A side effect returned alongside a new model from `update/2`. Executed by the runtime, not by user code. | effect, side effect, action                   |
| **Element**    | The data returned from `view/1`: a tree of Component descriptions (e.g. `text(...)`, `row do ... end`).  | node, vdom, virtual DOM, render output        |
| **View**       | The pure function `view(model) -> Element` that produces the element tree. Optional for headless agents. | render function, template                     |

### Relationships

- A TEA module is invoked by exactly one Lifecycle process (1:1).
- A Lifecycle holds exactly one Model at any time (1:1).
- A Message produces exactly one new Model and zero or more Commands (1:1, 1:N).
- A View produces exactly one Element tree per render cycle (1:1).

### Example dialogue

> "When the user presses Tab, the TEA module's `update/2` returns a new model and a `:focus_next` command."
> NOT: "When the user presses Tab, the component's reducer fires an action and the store updates."

### Flagged ambiguities

- **TEA app** vs **TEA module**: the module is the source code; the app is what
  the runtime starts from it. Use **TEA module** when talking about
  authoring, **TEA app** when talking about a running instance. Avoid both
  in marketing copy in favor of just "Raxol app."
- **Action**: in the TEA world this is **Message**; in the agent world it is a
  separate concept (LLM-callable tool). See _Agents_ below.

---

## Surfaces

| Term         | Definition                                                                                          | Aliases to avoid                           |
| ------------ | --------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| **Surface**  | A rendering target that consumes the same TEA module: terminal, browser, SSH, MCP, watch, telegram. | backend, target, output, frontend, channel |
| **Terminal** | The native surface using termbox2 NIF (Unix/macOS) or IOTerminal (Windows).                         | console, TTY, shell                        |
| **Browser**  | The Phoenix LiveView surface: TerminalBridge converts buffer to HTML, diffed via LiveView.          | web, HTML surface                          |
| **SSH**      | The `:ssh.daemon`-backed surface; one supervised channel per connection.                            | remote, terminal-over-network              |
| **MCP**      | The Model Context Protocol surface: agents and external tools drive the app via JSON-RPC.           | agent surface, tool surface, RPC surface   |
| **Watch**    | The wearable push surface: APNS/FCM glanceable summaries with tap-to-event actions.                 | mobile, notifications                      |
| **Telegram** | The chat-bot surface: per-chat sessions with inline keyboard navigation.                            | chat surface                               |
| **Speech**   | The voice surface: TTS announcements and STT voice commands.                                        | audio, voice, TTS surface                  |

### Relationships

- One TEA module renders to many Surfaces (1:N).
- Each Surface owns its own Lifecycle process (1:1) -- surfaces never share
  Lifecycle state, even for the same module.

### Example dialogue

> "Add the LiveView surface and the same module starts rendering in the browser."
> NOT: "Add the web frontend / browser backend and ..."

### Flagged ambiguities

- **Surface** vs **Backend**: termbox2 and IOTerminal are _backends_ of the
  Terminal surface. Reserve **backend** for the implementation strategy
  _within_ a surface; use **surface** for the rendering target.

---

## Render Pipeline

The phases that turn a TEA module into pixels (or cells, or HTML, or JSON).

| Term             | Definition                                                                                                           | Aliases to avoid                 |
| ---------------- | -------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| **Lifecycle**    | The GenServer that owns one running TEA app instance. Created by `Raxol.start_link/2`.                               | runtime, app process, app server |
| **Engine**       | The rendering engine: orchestrates `view/1` -> Preparer -> LayoutEngine -> UIRenderer -> ScreenBuffer per frame.     | renderer, render loop            |
| **Dispatcher**   | The GenServer that delivers Messages to `update/2` and queues Commands.                                              | reducer, store, event loop       |
| **Preparer**     | The phase that measures text widths and attaches animation hints to elements before layout.                          | preprocessor, normalizer         |
| **LayoutEngine** | The phase that positions PreparedElements (flexbox / CSS grid) into x/y/w/h boxes.                                   | layout, positioner               |
| **UIRenderer**   | The phase that converts positioned elements to cell tuples `{x, y, char, fg, bg, attrs}`.                            | rasterizer, painter              |
| **ScreenBuffer** | The 2D cell array; diffed against the previous frame to compute minimal updates.                                     | buffer, framebuffer, cell grid   |
| **Frame**        | One complete render cycle's output (a ScreenBuffer + diff + applied effects).                                        | tick, refresh                    |
| **Hint**         | Animation metadata attached to an Element by `Animation.Helpers.animate/2`; consumed by surfaces that understand it. | animation, transition spec       |

### Relationships

- Lifecycle has exactly one Dispatcher and one Engine (1:1, 1:1).
- Engine produces one ScreenBuffer per Frame (1:1).
- The Terminal surface diffs ScreenBuffers and emits ANSI; the Browser surface
  emits HTML diffs over LiveView.

### Example dialogue

> "The Preparer caches text measurements so resize triggers only the LayoutEngine, not re-measurement."
> NOT: "The preprocessor caches widths so resize only re-runs positioning."

---

## Components

| Term          | Definition                                                                                                                                  | Aliases to avoid                    |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| **Component** | A reusable UI building block: Button, TextInput, Modal, Table, Tree, etc. Authored with the `Raxol.UI.Components.Base.Component` behaviour. | widget, control, primitive, partial |
| **Effect**    | A visual augmentation layered on top of Components: CursorTrail, HoverHighlight, BorderBeam.                                                | animation, decoration               |
| **Theme**     | A named palette + style overrides applied at the buffer level (Dracula, Nord, Synthwave '84, etc.).                                         | skin, palette, color scheme         |

### Note

The Component name aligns with the behaviour module
(`Raxol.UI.Components.Base.Component`). Although React's "component" carries
its own connotations, Raxol's choice predates this glossary and we keep it.
Avoid **widget** in new writing; if you encounter it in old docs, treat it as
a Component.

---

## Agents

| Term                    | Definition                                                                                            | Aliases to avoid                       |
| ----------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------- |
| **Agent**               | A TEA module wired up for AI work via `use Raxol.Agent`. Supervised, hot-reloadable, can be headless. | bot, AI, assistant, autonomous worker  |
| **Headless agent**      | An Agent with no `view/1` callback. Skips rendering entirely.                                         | invisible agent, background agent      |
| **Agent Session**       | A running Agent instance: a Lifecycle in the `:agent` environment.                                    | agent process, agent runtime           |
| **Agent Team**          | An OTP supervisor grouping a Coordinator and one or more Workers.                                     | agent group, agent cluster, swarm      |
| **Coordinator**         | The top-level Agent in a Team that delegates to Workers.                                              | parent agent, master agent, dispatcher |
| **Worker**              | A specialized Agent supervised by a Coordinator.                                                      | sub-agent, child agent                 |
| **Action**              | An LLM-callable tool exposed by an Agent: a function described by a name, schema, and handler.        | tool, function, capability, skill      |
| **Strategy**            | The decision-making style of an Agent: `Direct` (single-shot) or `ReAct` (reason-act-observe loop).   | mode, behaviour, planner               |
| **Backend**             | The LLM provider integration: Anthropic, OpenAI, Ollama, Lumo, Kimi, LLM7, Mock.                      | provider, API, vendor, LLM             |
| **Inter-agent message** | A `{:agent_message, from, payload}` tuple delivered to an Agent via the Agent Registry.               | RPC, IPC, message-pass                 |

### Relationships

- An Agent has zero or one Strategy (default: Direct) (1:0..1).
- A Team has exactly one Coordinator and many Workers (1:1, 1:N).
- An Agent exposes many Actions to its Backend (1:N).
- An Agent calls one Backend at a time per request (1:1 per request).

### Example dialogue

> "The Coordinator dispatches an inter-agent message to the research Worker, which calls the `web_search` Action via the Anthropic Backend."
> NOT: "The parent bot sends an RPC to the research sub-agent which uses the search tool against the Claude provider."

### Flagged ambiguities

- **Action** (Agent context) vs **Command** (TEA context): both are "things the
  framework does after the user code returns." The distinction:
  - **Command** is a TEA concept: a side effect returned from `update/2` and
    executed by the Dispatcher (`:async`, `:shell`, `:send_agent`, etc.).
  - **Action** is an Agent concept: a tool the LLM may call. Surfaces as a JSON
    schema in the Backend.
    Never use them interchangeably. When ambiguous in conversation, say
    "TEA command" or "agent action."
- **Backend** (Agent context) vs **Backend** (Surface context): two completely
  different uses. When the audience is mixed, say "LLM backend" or
  "terminal backend."
- **Swarm** vs **Agent Team**: a Team is local OTP supervision (one BEAM node);
  a Swarm is multi-node distribution (libcluster). Don't conflate.

---

## Commands & Actions (cross-cutting)

| Term             | Definition                                                                                         | Aliases to avoid               |
| ---------------- | -------------------------------------------------------------------------------------------------- | ------------------------------ |
| **TEA Command**  | A side effect returned from `update/2`. Tagged tuple: `:async`, `:shell`, `:send_agent`, etc.      | effect, action, side effect    |
| **Agent Action** | An LLM-callable tool. Implements the `Raxol.Agent.Action` behaviour.                               | tool, function, skill, command |
| **Hook**         | A function the framework calls at a defined extension point: CommandHook, PermissionHook, McpHook. | callback, listener, middleware |
| **Plugin**       | A package that adds Components, themes, hooks, or actions via `use Raxol.Plugin`.                  | extension, addon, mod          |

### Flagged ambiguities

- **Hook** has two unrelated meanings depending on context:
  - In Raxol agent code, **Hook** is a deny/transform interceptor.
  - In LiveView code, "hook" means a JavaScript hook (`phx-hook`).
    When mixing both contexts in writing, say "Raxol hook" or "LiveView hook."

---

## MCP (Model Context Protocol)

| Term           | Definition                                                                                                | Aliases to avoid          |
| -------------- | --------------------------------------------------------------------------------------------------------- | ------------------------- |
| **MCP server** | A process that exposes Tools and Resources to AI agents over JSON-RPC (typically stdio).                  | RPC server, agent server  |
| **MCP client** | A process that consumes an external MCP server's Tools and Resources.                                     | RPC client, integration   |
| **Tool**       | An MCP-exposed callable: name + input schema + handler. Auto-derived from Components via `ToolProvider`.  | function, action, command |
| **Resource**   | MCP-exposed read-only state: a projection of Model fields, streamed as diffs.                             | data, view, snapshot      |
| **Focus lens** | An attention-aware filter that narrows the exposed Tool set to those relevant to the current interaction. | tool filter, scope        |

### Flagged ambiguities

- **Tool** (MCP context) vs **Action** (Agent context): MCP Tools are _exposed
  outward_ to AI clients; Agent Actions are _callable inward_ by an Agent's
  own LLM Backend. They often map 1:1 in practice -- but say "MCP tool"
  when the consumer is external, "agent action" when the consumer is the
  Agent's own LLM.

---

## Commerce (Payments + ACP)

| Term                 | Definition                                                                                             | Aliases to avoid                           |
| -------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------ |
| **Payment protocol** | A wire protocol for agent-driven payment: X402, MPP, Xochi, Riddler.                                   | payment method (use this only at UX layer) |
| **Wallet**           | A signer of EVM transactions and EIP-712 typed data: `Wallets.Env` or `Wallets.Op` (1Password-backed). | key, signer, account                       |
| **Mandate**          | A per-request EIP-712 Xochi delegation envelope authorizing a single action under stated limits.       | authorization, permit, delegation, voucher |
| **Spending policy**  | Per-request / per-session / per-lifetime limits enforced by the SpendingHook.                          | budget, cap, limit                         |
| **Ledger**           | The append-only ETS-backed record of every payment attempt, executed or denied.                        | log, history, journal                      |
| **Job**              | One unit of paid agent work in the Agent Commerce Protocol (ACP); flows through a state machine.       | task, request, order                       |
| **Memo**             | An EIP-712 typed-data record signed during ACP Job state transitions.                                  | receipt, attestation                       |
| **Offering**         | A sellable agent service registered via `use Raxol.ACP.Offering`.                                      | listing, product, service                  |
| **Stealth address**  | An ERC-5564 / ERC-6538 one-time recipient address derived via ECDH for privacy-preserving payments.    | shielded address, anonymous address        |
| **Privacy tier**     | One of 6 levels in the Glass Cube model mapping trust score to disclosure level.                       | privacy level, anonymity tier              |

### Flagged ambiguities

- **Mandate** (Xochi context) vs general "permit" or "approval": Mandate is
  Xochi-specific and per-request; ERC-20 `approval` is on-chain and
  unbounded. Never use them as synonyms.
- **Job**: in ACP this is paid agent work. In OTP / Elixir generally, "job"
  often means a background task. When mixing contexts, say "ACP Job."

---

## Distribution & Swarm

| Term          | Definition                                                                                                 | Aliases to avoid             |
| ------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------- |
| **Swarm**     | The distributed multi-node subsystem: discovery, topology, CRDT replication, elections.                    | cluster, mesh, fleet         |
| **Discovery** | The libcluster-wrapped node-finding layer with strategy presets: `:gossip`, `:epmd`, `:dns`, `:tailscale`. | bootstrap, peering           |
| **Topology**  | The current set of connected nodes and their roles after election.                                         | cluster state, peer map      |
| **CRDT**      | A conflict-free replicated data type used to sync state without coordination: LWWRegister, ORSet.          | shared state, replicated map |
| **Election**  | The process of choosing a coordinator node when topology changes.                                          | leader vote, consensus       |

### Flagged ambiguities

- **Swarm** (distribution) vs **Agent Team** (local OTP supervision): see Agents above.

---

## Time-Travel & Recording

| Term                  | Definition                                                                                               | Aliases to avoid                 |
| --------------------- | -------------------------------------------------------------------------------------------------------- | -------------------------------- |
| **Time travel**       | Snapshot-based navigation of an app's update history: `step_back`, `step_forward`, `jump_to`, `restore`. | undo, history, replay            |
| **Snapshot**          | A captured `{message, model_before, model_after}` triple stored in the time-travel CircularBuffer.       | state dump, frame                |
| **Session recording** | An asciinema v2 capture of a Lifecycle's frames over time.                                               | screen recording, video, capture |

### Flagged ambiguities

- **Replay** is overloaded:
  - Replaying a **session recording** plays back captured frames at original speed.
  - Time-travel **restore** sends a historical model back to the Dispatcher
    for re-render at the current moment.
    Use **replay** only for recordings; use **restore** for time travel.

---

## Cross-domain ambiguities (one-stop reference)

| Term          | Meanings                                                                     | Decision                                                                                                                    |
| ------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Action**    | (1) TEA Message handler input; (2) Agent LLM-callable tool; (3) generic verb | Reserve **Action** for **Agent Action** only. Use **Message** for TEA inputs.                                               |
| **Command**   | (1) TEA side effect; (2) shell command; (3) MCP tool invocation              | **Command** = TEA Command. For shell, say **shell command**. For MCP, say **tool call**.                                    |
| **Backend**   | (1) Surface implementation (termbox2); (2) LLM provider                      | Always qualify: **terminal backend** or **LLM backend**.                                                                    |
| **Hook**      | (1) Raxol agent interceptor; (2) Phoenix LiveView JS hook                    | Always qualify: **Raxol hook** or **LiveView hook**.                                                                        |
| **Tool**      | (1) MCP-exposed tool; (2) Agent Action; (3) generic CLI tool                 | **Tool** = MCP Tool. **Action** = Agent Action. Don't blur the two.                                                         |
| **Job**       | (1) ACP paid work; (2) generic background task                               | Qualify as **ACP Job** when mixing with Oban / Quantum / generic job-runner talk.                                           |
| **Replay**    | (1) Session recording playback; (2) time-travel state restore                | **Replay** = recording. **Restore** = time travel.                                                                          |
| **Swarm**     | (1) Distributed multi-node subsystem; (2) any group of agents                | **Swarm** = distribution. **Agent Team** = local supervision.                                                               |
| **Component** | Raxol UI building block; React's "component" overlaps but is unrelated       | Use **Component** (matches the behaviour name). When the audience is web-heavy, say "Raxol Component" once to disambiguate. |
| **Surface**   | Rendering target -- vs "backend" / "channel" / "frontend"                    | **Surface**. Never "channel" (that's a Phoenix concept) or "backend".                                                       |

---

## Marketing-copy guidance

When writing for the website, README, or Hex docs:

- "One app, four surfaces." Don't say "one codebase, four targets" -- the
  surfaces concept is the whole point.
- "Agents are TEA apps." Don't say "agents are processes" -- everything in BEAM
  is a process, the news is the _shape_.
- "Zero install via SSH." Don't say "no setup needed" -- the specific
  affordance is SSH-based, not vague no-setup magic.
- "Crash isolation." Use this as a noun phrase. Don't say "fault tolerance"
  unless paired with concrete OTP mechanics; "crash isolation" is the
  user-visible benefit.
- "MCP tools." When referring to what the AI sees. "Agent actions" when
  referring to what the LLM may call from within an agent. They are
  different sides of the same wire.
