# Command/control channels for running agents — how surfaces drive a live agent process

Forum-first sourcing: protocol specs + source structs (fetched raw from GitHub), GitHub issues, implementer complaints. Verification tiers marked where load-bearing: **[SOURCE]** = read from repo source/spec directly, **[DOC]** = official docs (possibly AI-rendered), **[ISSUE]** = GitHub issue/forum. Research date 2026-07.

## The one lens

A "tool protocol" answers *"agent, call this function"*. A **command channel** answers *"human/surface, drive this live process"* — prompt it, interrupt it, steer it mid-turn, answer its permission questions, attach a second surface to it. These are different protocols with different verbs, and the industry keeps discovering that the hard way (MCP's Tasks experiment shipped in core 2025-11, got demoted to an extension by SEP-2663 eight months later). The current field: **Codex app-server** is the richest verb set (the only one with true `turn/steer`), **Zed's ACP** is the standardization play (cooperative cancel, no steer, attach in-RFD), **opencode** is the multi-client REST+SSE outlier, **MCP is deliberately not this protocol** — and everything descends from LSP's `$/cancelRequest` and, further back, Unix job control and tmux control mode.

---

## 1. Codex app-server (the praised reference)

Two crates in `codex-rs/`: `app-server-protocol` (wire types) and `protocol` (core engine types). https://github.com/openai/codex/tree/main/codex-rs/app-server

**Why it exists at all — the anti-MCP origin story.** OpenAI first tried exposing Codex *as an MCP server* for the VS Code extension; per InfoQ (2026-02-17, attributing OpenAI engineer Celia Chen — secondary-sourced, openai.com original 403'd) **"maintaining MCP semantics in a way that made sense for VS Code proved difficult"** — streaming reasoning progress, emitting diffs, approvals, and thread persistence didn't map onto tool request/response. So they built "a JSON-RPC protocol that mirrored the TUI loop." The official README is the cleanest one-liner in the field: *"The app server is not MCP. MCP connects external tools to Codex... The app server connects clients to Codex. They coexist."* — https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md. Official positioning: *"Use it when you want a deep integration inside your own product: authentication, conversation history, approvals, and streamed agent events."* (https://learn.chatgpt.com/docs/app-server)

**Lifecycle.** `initialize` (client→server) carries `clientInfo{name,title,version}` + `capabilities{experimentalApi, requestAttestation, mcpServerOpenaiFormElicitation, optOutNotificationMethods}` **[SOURCE: v1.rs `InitializeParams`]**; `clientInfo.name` feeds OpenAI's Compliance Logs Platform **[DOC]**. Pre-`initialize` requests error "Not initialized"; double-init errors "Already initialized" **[DOC]**. `initialized` notification follows. Then `thread/start` (params: model, cwd, approvalPolicy, sandbox, personality → returns `thread.id`) and `thread/resume` — which takes `excludeTurns`/`initialTurnsPage` for **reattach without full history replay** **[DOC]**. Also `thread/rollback` (rewind history).

**Turn start.** `turn/start` **[SOURCE: v2/turn.rs `TurnStartParams`]** — the payload is a kitchen-sink of per-turn overrides, notable because everything is *re-negotiable per turn*, not fixed at session creation:

```rust
pub struct TurnStartParams {
    pub thread_id: String,
    pub client_user_message_id: Option<String>,   // client-side idempotency/correlation
    pub input: Vec<UserInput>,                     // text | image | localImage
    pub additional_context: Option<HashMap<String, AdditionalContextEntry>>,
    pub cwd: Option<PathBuf>,
    pub approval_policy: Option<AskForApproval>,
    pub approvals_reviewer: Option<ApprovalsReviewer>,  // "user" | "auto_review"
    pub sandbox_policy: Option<SandboxPolicy>,
    pub model: Option<String>,
    pub effort: Option<ReasoningEffort>,
    pub output_schema: Option<JsonValue>,
    pub collaboration_mode: Option<CollaborationMode>,
    pub multi_agent_mode: Option<MultiAgentMode>,
    // + service_tier, personality, summary, environments, runtime_workspace_roots, permissions
}
```

**Interrupt vs. steer — the crown jewels.** Both real, distinct RPCs **[SOURCE: v2/turn.rs]**:

```rust
pub struct TurnInterruptParams { pub thread_id: String, pub turn_id: String }
pub struct TurnSteerParams {
    pub thread_id: String,
    pub input: Vec<UserInput>,
    pub expected_turn_id: String,   // optimistic-concurrency guard
    // + client_user_message_id, additional_context, responsesapi_client_metadata
}
```

- `turn/interrupt` kills the turn; response carries `abort_reason: TurnAbortReason` = `Interrupted | Replaced | ReviewEnded | BudgetLimited` **[SOURCE: protocol.rs ~L4160]**. Note `BudgetLimited` — the abort taxonomy includes cost enforcement.
- `turn/steer` injects user input **into the live turn without killing it** — *"append additional user input to the currently active regular turn"* — and fails if `expected_turn_id` doesn't match the active turn (so a stale surface can't steer a turn that already ended: compare-and-swap for conversations). Returns `{turnId}`.
- Caveats: the `Replaced` abort variant suggests some "steer" paths are internally modeled as abort-and-fork rather than clean mid-flight injection — **unconfirmed which path triggers it, flagged for further digging**. And `NonSteerableTurnKind` exists in `v2/shared.rs` **[SOURCE]** — some turn kinds explicitly refuse steering (variants not retrieved).
- Steer is used in the wild: CodexMonitor (https://github.com/Dimillian/CodexMonitor) exposes a user-facing "Queue vs Steer while a run is active" toggle.

**Approval flow.** Server→client *requests* (id-bearing, expect a response), not notifications **[SOURCE: v1.rs]**: `ExecCommandApprovalParams{conversation_id, call_id, command: Vec<String>, cwd, reason, parsed_cmd}` and `ApplyPatchApprovalParams{conversation_id, call_id, file_changes: HashMap<PathBuf, FileChange>, reason, grant_root}` (v2 names: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` **[DOC]**). The response enum is the richest decision vocabulary in the field **[SOURCE: protocol.rs ~L4059]**:

```rust
pub enum ReviewDecision {
    Approved,
    ApprovedExecpolicyAmendment { proposed_execpolicy_amendment: ExecPolicyAmendment },
    ApprovedForSession,
    NetworkPolicyAmendment { network_policy_amendment: NetworkPolicyAmendment },
    #[default] Denied,   // "the agent should not execute it, but should continue the session"
    TimedOut,
    Abort,               // "the agent should not do anything until the user's next command"
}
```

Three things to notice: (1) approval responses can carry **policy amendments** — the answer to "may I?" can be "yes, and here's a durable rule"; (2) `Denied` vs `Abort` distinguishes *try-something-else* from *full-stop* — two different failure modes most protocols conflate; (3) `TimedOut` is a first-class decision: unanswered approvals resolve, they don't hang — issue #21982 shows a stalled approval timing out after 300s with `"aborted by user after 300.0s"` (that figure is bug-path-specific, not confirmed general default) **[ISSUE: https://github.com/openai/codex/issues/21982]**.

**Event stream.** `ThreadItem` types **[SOURCE: v2/item.rs]**: `UserMessage, AgentMessage, Plan, Reasoning, CommandExecution, FileChange, McpToolCall, DynamicToolCall, CollabAgentToolCall, SubAgentActivity, WebSearch, ImageView, ContextCompaction, EnteredReviewMode/ExitedReviewMode`, etc. Pattern is `item/started → deltas → item/completed` (source-confirmed via `ItemStartedNotification`, `ReasoningTextDeltaNotification`, etc.); doc-level method names: `turn/started`, `turn/completed`, `item/agentMessage/delta`, `item/reasoning/textDelta`, `turn/plan/updated`, `rawResponse/completed` (behind `experimentalRawEvents`). Note `ContextCompaction` as a *visible stream item* — compaction is surfaced to clients, not hidden.

**Framing.** NDJSON over stdio — and **not actually JSON-RPC 2.0**: `rpc.rs` comment, verbatim: *"We do not do true JSON-RPC 2.0, as we neither send nor expect the `\"jsonrpc\": \"2.0\"` field."* **[SOURCE: rpc.rs]** No documented rationale for NDJSON-over-Content-Length found in source.

**Praise.** Zed shipped a production bridge (https://github.com/zed-industries/codex-acp, now community-pooled under `agentclientprotocol/codex-acp`; https://zed.dev/blog/codex-is-live-in-zed). Zed's sharp architectural observation: Codex runs commands in *its own* process (non-PTY) and streams output — reverse of ACP's client-executes pattern — *"being in PTY mode means that an agent can get stuck... Codex uses non-PTY mode, resulting in fewer colors and less interactivity, but also fewer cases of agents getting stuck."* Third parties write whole integration guides (https://gist.github.com/oneryalcin/ee2c27e2d8aa040da8fbe7eebcc2ecea).

**Complaints (all [ISSUE]):**
- Idle-timeout masquerades as interrupt: a 60s `turn.completion_idle_timeout` surfaces as "user interrupted" — *"silently stops multi-step work and makes the user believe they interrupted the agent when they did not."*
- Interrupt breaks lifecycle hooks: #22858 — *"When an active Codex turn is interrupted... the Stop hook does not appear to run... A tool can observe that a turn started, but cannot reliably observe that it ended if the user interrupts it."*
- Approval-surfacing gaps: #21982 (approval request never fires for `sandbox_permissions: require_escalated`, turn stalls); #14192 — *"in strict protocol-only mode it does not expose a usable approval response RPC for the controller to call back into"* (`"Approval RPC method is not supported by the connected bridge"`).
- **No true second-client attach**: #25676 — reconnecting from a second device and messaging an active thread spawns *two parallel continuations against the same goal* instead of attaching; #14722 asks for `codex resume` from a second device to behave "as if it is being remotely controlled." Known gap, unsolved.
- Backpressure/memory failure modes on the stdio channel: #24048 (SIGKILL at ~27GB on large tool output), #18203/#19608 (outbound-queue-full disconnects over SSH).

---

## 2. Zed's ACP — Agent Client Protocol

(Always "Zed's ACP" in raxol docs — raxol_acp = Agent *Commerce* Protocol.) Spec: https://agentclientprotocol.com; repo migrated `zed-industries/` → `agentclientprotocol/agent-client-protocol`; JetBrains co-governs (Oct 2025), plus a Jan 2026 joint ACP Agent Registry.

**Verb set** (https://agentclientprotocol.com/protocol/schema):
- Agent-side baseline: `initialize` (`{protocolVersion, clientCapabilities?, clientInfo?}` → `{protocolVersion, agentCapabilities, agentInfo?, authMethods[]}`), `session/new` (`{cwd, mcpServers[], additionalDirectories?}` → `{sessionId, configOptions?, modes?}`), `session/prompt` (`{sessionId, prompt: ContentBlock[]}` → `{stopReason}`).
- Agent-side optional (capability-gated): `authenticate`, `logout`, `session/load` (resume **with full history replay** via `session/update` notifications; `loadSession` cap), `session/resume` (lighter reconnect, **no replay**; stabilized alongside), `session/close` (frees resources; stabilized 2026-04-23), `session/set_mode`.
- `session/cancel` is a **notification**, not a request — `CancelNotification{sessionId}`, no response. Direct descendant of LSP `$/cancelRequest`.
- Streaming: `session/update` notification (message chunks, tool-call updates, plan updates, mode/config changes).
- Client-side: `session/request_permission` (baseline); optional `fs/read_text_file`, `fs/write_text_file`, `terminal/{create,output,wait_for_exit,kill,release}`.

**Cancel semantics — explicitly cooperative** (https://agentclientprotocol.com/protocol/prompt-turn): agent *"SHOULD stop all language model requests and all tool call invocations as soon as possible,"* MUST catch the resulting abort exceptions and return `stopReason: "cancelled"` on the original `session/prompt` response (`StopReason` = `end_turn | max_tokens | max_turn_requests | refusal | cancelled`). Implementers don't fully trust it: the `acpx` CLI (https://github.com/openclaw/acpx) documents that Ctrl-C sends `session/cancel` and *"waits briefly for stopReason=cancelled before force-killing if needed"* — cooperative cancel with a kill-timeout fallback, the exact LSP pattern reborn.

**Steer: does not exist.** No method injects input into a live turn; the only path is cancel → new `session/prompt`. No ACP-repo RFD proposing it was found (absence-of-evidence flag). The gap is a known problem class ecosystem-wide: openclaw #48003 ("Steer mode does not inject messages mid-turn"), #50880 ("Steer queue mode silently degrades to followup"), docker-agent #2223 ("steer the running agent mid-work instead of queuing").

**Permission flow** (https://agentclientprotocol.com/protocol/tool-calls): `session/request_permission{sessionId, toolCall: ToolCallUpdate, options: PermissionOption[]}`; each option `{optionId, name, kind}` with four canonical kinds: `allow_once`, `allow_always`, `reject_once`, `reject_always`. Response `outcome: {outcome: "selected"|"cancelled", optionId?}` — `cancelled` fires if the whole turn is cancelled while the permission request is pending (clean composition of cancel × approval). **No timeout / default-on-no-response is specified — genuine spec gap.** And clients can just skip the flow: github/copilot-cli#845 ("ACP mode should send session/request_permission... instead of auto-approving").

**Attach/multi-client — confirmed gap, actively in-flight.** Sessions are 1:1 with the creating connection. Open draft PR **#533 "Multi-Client Session Attach"** (https://github.com/agentclientprotocol/agent-client-protocol/pull/533): motivation quote — *"Permission requests block in whichever terminal started the session — there is no way to respond from a unified dashboard."* Proposes `session/attach{sessionId, historyPolicy: full|pending_only|none|after_message, clientInfo, clientId?}` + `session/detach`, first-writer-wins permission routing with broadcast, `turn_complete` sync signal, delta-sync via `afterMessageId`. Cited pressure: `acp-multiplex` (mobile mirroring) and `hydra-acp` (editors/Slack/web → one agent) both exist *because* native attach doesn't. Design debate resolved during review: controller/observer role split dropped — broadcast-all-events, clients filter (per-event-type filtering = long-term maintenance burden).

**Framing.** **Newline-delimited JSON over stdio** — *not* LSP Content-Length, despite the "LSP for agents" branding (confirmed via https://acpex.hexdocs.pm/protocol_overview.html). JSON-RPC 2.0 semantics on top. PR #721 proposes Streamable HTTP & WebSocket transports.

**Adoption reality (2026-07).** Native: Gemini CLI (`--acp` flag), Codex CLI (runs as ACP backend). Bridged: Claude Code (Zed-maintained `@zed-industries/claude-agent-acp` wrapping the Claude Agent SDK — still no native support), Cursor CLI (ad hoc in Zed only), opencode (external-harness mode). Editors: Zed, JetBrains, Neovim (CodeCompanion.nvim), Emacs (`agent-shell`); Microsoft Terminal reportedly (secondary-sourced, unverified). **VS Code: still nothing native** — microsoft/vscode#265496 "under discussion," third-party extensions only.

**Praise vs criticism.** Zed (zed.dev/blog "Bring Your Own Agent"): *"Just as the Language Server Protocol unbundled language intelligence from monolithic IDEs, our goal with the Agent Client Protocol is to enable you to switch between multiple agents without switching your editor."* JetBrains: *"Your IDE will mediate access to files, the terminal, and other tools via the ACP protocol – you decide what runs."* Sharpest documented criticism is maintainer-acknowledged: discussion #50 (@vlaaad) — agent-side ripgrep sees stale files because unsaved editor buffers aren't synced (LSP solves this with didOpen/didChange; ACP deliberately doesn't). Maintainer ConradIrwin: FS virtualization was tried and rejected; direct FS access kept *"even though this introduces some race conditions"* because stale search is "much less sensitive" than edit conflicts. Plus HN "too many agent protocols" fatigue (45038792, 45493609).

---

## 3. opencode server API (REST + SSE)

Now `github.com/anomalyco/opencode` (moved from sst/). `opencode serve [--port n] [--hostname h] [--cors origin]`, default `127.0.0.1:4096`. Docs: https://opencode.ai/docs/server/

**Sessions.** `GET/POST /session`, `GET/PATCH/DELETE /session/:id`, `GET /session/:id/children` (sessions form a tree — subagents are child sessions).

**Prompting — the sync/async split.** `POST /session/:id/message` **blocks until the full response completes**; `POST /session/:id/prompt_async` (same body: `{messageID?, model?, agent?, noReply?, system?, tools?, parts}`) returns `204 No Content` immediately, results stream via SSE. `noReply: true` **injects context without triggering generation** — a "load the gun, don't fire" verb nobody else has. Also `POST /session/:id/command` (slash commands) and `POST /session/:id/shell`.

**Abort.** `POST /session/:id/abort` — cooperative, not a hard kill. Issue #13841 documents the consequences: *"the abort cascade (task.ts:121-124) only fires when the parent session is manually aborted by the user"* and *"the LLM stream itself has [no timeout]"* — hung subagent calls have no automatic escape besides manual abort. **[ISSUE: https://github.com/anomalyco/opencode/issues/13841]**

**Steer.** Not supported at launch — #21388 ("Allow messages to be sent mid-turn," closed 2026-04-07) records the prior mess: mid-turn messages were *"queued silently and delivered as a new turn," "discarded in some UI states," or "never acknowledged."* Still-open #32157 ("Configurable mid-run prompt delivery: queue vs steer," 2026-06-13) proposes the clean three-mode taxonomy: **`queue`** (next turn) / **`steer`** ("should belong to the active turn... should not start a new compaction unit" — note steering interacts with *compaction-unit identity*) / **`break`** (abort), plus a proposed `session.steer({sessionID, parts})` SDK method. **Not confirmed shipped.** Third-party client OpenChamber built its own client-side Queue-vs-Steer setting around the gap.

**SSE.** Two **global** streams: `GET /event` (opens with `server.connected`) and `GET /global/event`. Event types **[SOURCE: message-v2.ts]**: `MessageUpdated, MessageRemoved, PartUpdated, PartDelta, PartRemoved`, `session.idle`, `permission.asked/replied`. **No per-session stream** — #7451 asked, closed "not planned"; clients filter by `sessionID` client-side. Churn is real: #27966 — `/event` silently stopped delivering `message.part.updated` in 1.14.42+ while other events kept working.

**Permissions — push, not poll.** Config-driven allow/ask/deny per tool, pattern-matched, last-rule-wins (https://opencode.ai/docs/permissions/). On "ask": server emits `permission.asked` over SSE `{requestID, sessionID, ...}` → client `POST /session/:id/permissions/:permissionID {response, remember?}` → server broadcasts `permission.replied`. A mobile-approval-queue build on this (https://codeongrass.com/blog/opencode-permission-events-mobile-approval-queue/) articulates why events beat polling: *"The important moment is not 'what is the current permission state?' but 'a specific tool invocation is blocked until a human answers.'"* Because approvals ride the shared event bus, **any connected client can answer** — this composes with multi-client below.

**Multi-client — the only one that has it today.** Docs, directly: *"This architecture lets opencode support multiple clients and allows you to interact with opencode programmatically"* and *"A client can be a terminal tab, your phone, a desktop, a browser — each an isolated session pointed at the same server, fully synced"* (https://opencode.ai/docs/web/); concretely `opencode web --port 4096` + `opencode attach http://localhost:4096` shares TUI+web against one server. Caveat: two-clients-watching-the-*same*-session live-delta sync is strongly implied by the global event bus but not textually confirmed anywhere found.

**Auth — the horror story.** Default: no auth, localhost-only; optional `OPENCODE_SERVER_PASSWORD` basic auth; `--cors` flag. HN thread on the unauthenticated-RCE CVE (https://news.ycombinator.com/item?id=46581095): the server *"silently started an HTTP server listening on localhost"* with *"CORS set to allow all origins (*)"* so *"any web page served from localhost/127.0.0.1 can execute code."* Verbatim: *"WTF, they not just made unauthenticated RCE http endpoint, they also helpfully added CORS bypass for it."* Reported Nov 2025, initially unacknowledged. Lesson: a command channel is an RCE channel by definition — auth is not optional garnish.

**Why hackers praise it.** HN #47941721 (idempotent_): *"OpenCode harness is so good I'm surprised one of the big players hasn't bought t[hem]"* — *"the harness IS code, agents ARE Code — they can be modified as needed dynamically... The map is the territory."* The stronger evidence is the ecosystem the API grew: OpenChamber (alt web UI), opencode-manager, opencode-sessions, a2a-opencode — independent clients exist, therefore the API is genuinely drivable.

---

## 4. MCP's gap — why it is not a command channel

**The verdict from its own founders' actions.** OpenAI tried MCP for exactly this job and walked away (§1). The MCP committers themselves then ran the experiment: **Tasks** (long-running-operation semantics) shipped as experimental core in 2025-11-25, and by SEP-2663 was **demoted to an extension** (`io.modelcontextprotocol/tasks`, polling `tasks/get` + `tasks/update`, `tasks/list` dropped): *"Production use surfaced enough redesign that the right home for it is an extension rather than the specification."* (https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2663, changelog: https://modelcontextprotocol.io/specification/draft/changelog)

**The 2026-07-28 spec is moving the opposite direction from session control** (all verified against changelog): sessions removed (`Mcp-Session-Id` gone, SEP-2567 — "servers that need cross-call state use explicit, server-minted handles passed as ordinary tool arguments"); stateless core (`initialize` handshake removed, SEP-2575); SSE resumability removed ("a broken response stream loses the in-flight request; clients MUST re-issue"); Sampling/Roots/Logging deprecated (SEP-2577).

**The detours and why they fall short.** `sampling/createMessage` = server borrows the *client's* LLM for one nested completion (now deprecated — migration guidance: call provider APIs directly). `elicitation/create` = server pauses one tool call to ask the human for structured input; reworked by SEP-2322 into client-driven Multi Round-Trip Requests (`resultType: "input_required"`, client retries the original request with `inputResponses`) — even more request-scoped than before. Both live strictly inside *one tool call*. There is no turn, no thread, no agent loop in MCP's object model — nothing to steer, nothing to attach to.

**Cancellation.** `notifications/cancelled` (https://modelcontextprotocol.io/specification/draft/basic/utilities/cancellation): cancels **one in-flight request** by id + optional reason; explicitly cooperative — *"Receivers MAY ignore cancellation notifications"*; `initialize` uncancellable; single-request-scoped, no session/turn cancel. Compliance gap in Anthropic's own SDK: python-sdk #1419 (response still sent after cancellation received).

**Community attempts to add control semantics, none merged into core:** #982 (steering-committee tracking issue: SEP-975 disconnect/reconnect, `stream/begin|end|resume|poll` resumable streams, polling async tools — closed); SEP-1391 "Long-Running Operations" — *"The current MCP specification only supports single request-response tool execution, which creates significant limitations for real-world applications"* — closed, "SEP proposal without a sponsor"; discussion #314 (earliest articulation: *"MCP tools must complete their execution within a single request-response cycle"*); discussion #1227 — core maintainer jspahrsummers, directly: *"we don't have any notifications that are intended for consumption by the model itself"* — i.e. no channel exists to feed a running agent live steering signals. Unresolved.

**Cleanest third-party framing** (mcp.directory, no Willison post found making this claim — flag): *"MCP says nothing about where the agent runs or which editor a human is watching from... Its job ends at the tool boundary."* MCP = LSP-for-tools; ACP = LSP-for-agents; app-server = TUI-loop-as-API. Complementary layers.

---

## 5. Theory tier — the ancestors

### LSP `$/cancelRequest`
Notification, payload `CancelParams{id}` only. Because `$/`-prefixed, spec-optional: *"free to ignore the notification"* — with the canonical excuse that a single-threaded server "can do little to react." The spec's real requirement is about the *response*, not the *work*: *"A request that got canceled still needs to return from the server... It can not be left open/hanging"* (return `ErrorCodes.RequestCancelled`). Cancellation is advisory bookkeeping, not preemption. (https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)

Field bugs are the curriculum: godot #38814 (server ignored cancels entirely → spurious errors), FsAutoComplete #1009 (cancel crashes server), intelephense #1622 (doesn't work), and the sharpest — **vscode-languageserver-node #722**: cancel notification loses the event-loop race against an already-dispatched handler (`push dispatchCancelRequest -> ... -> Too late foldingRangeHandler already executed`); the proposed fix is generating cancellation tokens at the *message-reader* layer, not at dispatch. lsp-mode #1323/#2305 show the inverse: cancel-happy clients spamming quiescent servers. Every one of these failure shapes recurs in the agent protocols above.

LSP's framing is `Content-Length: N\r\n\r\n{json}` — and notably **neither ACP nor Codex app-server inherited it**; both chose NDJSON.

### Framing conventions
Three families: **Content-Length** (self-describing byte boundary, survives embedded newlines, needs a stateful reader, hostile to `nc`/`jq`); **NDJSON** (one object per line — MCP's stdio transport mandates it: *"messages MUST NOT contain embedded newlines"*, and the spec recommends custom stream transports "SHOULD reuse the stdio framing"; trivially inspectable, forbids pretty-printing); **transport-native** (WebSocket frame / SSE event = message; zero app-level framing but the transport becomes the hard part — "JSON All the Way Down" (https://geekfence.com/json-all-the-way-down/) calls HTTP+SSE *"the hard part... Sessions, replay buffers, resume-after-disconnect"* and lands on framing-as-pluggable-codec). The failure mode is mismatch, not choice: codegraph #172 — Claude Code's MCP client speaking Content-Length to an NDJSON server = silent connection failure, both sides "JSON-RPC 2.0 compliant." **Field consensus 2026: NDJSON won for agent stdio** (MCP, ACP, Codex app-server all use it; LSP alone on headers).

### Unix job control — the grandfather
SIGINT (catchable "polite stop") vs SIGTSTP (cooperative suspend) delivered to the whole foreground *process group* via the controlling terminal — group delivery is what makes shell job control compose (GNU libc manual). Agent CLIs run raw-mode TUIs, so Ctrl-C is just byte 0x03 they must handle themselves — and they keep fumbling it:
- **Claude Code**: recurring can't-interrupt bugs — #17466 ("ESC and Ctrl+C fail to interrupt during active tool calls"), #17724 (inert during streaming), #68854 (totally inert), #17717 (Windows: kills the window), #38761 (keyboard mode not restored on exit, breaking the *parent shell's* Ctrl-C).
- **Codex CLI**: single Ctrl-C exits immediately, no confirmation; #7035 requests double-press-to-quit citing convention: *"The other CLI interface tools prompt you whether you'd like to quit... and prompt to press CTRL-C again within a short period to actually quit"* (+ #14708, #24170).
- **opencode**: deliberately splits the verbs — **Esc = interrupt turn, Ctrl-C = exit app** — refusing the overload; #9041/#26371 ask for Codex-style double-tap anyway.
- **Gemini CLI**: overloaded single-press (interrupts and exits).

Pattern: *interrupt-turn* and *quit-process* are different verbs; overloading one chord onto both is the recurring UX bug. Double-Ctrl-C (escalate cooperative → forceful on repeat) is the most-requested convention and maps exactly onto acpx's cancel-then-kill-after-timeout — **escalating interrupt is the convergent design**.

### tmux control mode — the attach ancestor
`tmux -CC` turns a client into a text-protocol peer (https://github.com/tmux/tmux/wiki/Control-Mode): commands get reply blocks bracketed `%begin`/`%end` (or `%error`) carrying timestamp + command number + flags (request/reply correlation); live state streams as async `%`-notifications (`%output` with octal-escaped pane bytes, `%window-add`, `%session-changed`, `%pane-mode-changed`). *"Any output in any pane in any window in the attached session is sent to the control client,"* with `pause-after` flow control for slow clients. iTerm2 renders tmux sessions natively this way; `new-session -A` = idempotent attach-or-create; text-only so it "can easily be parsed and used over ssh(1)."

This is structurally what PR #533 is reinventing for ACP: correlated request/reply + broadcast notification stream + late-joiner state sync. Its documented limitation is the key design lesson: *"output generated by tmux itself (for example in copy or choose mode) is not sent to control mode clients"* — client-local UI state is invisible to the control channel. Translation for agents: **the agent process, not the rendering layer, must be the source of truth** for everything a second surface needs to reconstruct — which is exactly why ACP pushes semantic `session/update` notifications instead of terminal bytes.

---

## Cross-cutting

### A. Verb inventory

| Verb | Codex app-server | Zed's ACP | opencode | MCP | LSP (ancestor) |
|---|---|---|---|---|---|
| prompt (start turn) | `turn/start` | `session/prompt` | `POST /session/:id/message` (sync) + `/prompt_async` | — (tools/call only) | request |
| **steer (mid-turn inject)** | **`turn/steer`** (+ `expected_turn_id` CAS; `NonSteerableTurnKind`) | ✗ (no RFD found) | ✗ (proposed #32157: queue/steer/break) | ✗ (maintainer: no model-directed notifications) | ✗ |
| interrupt/cancel | `turn/interrupt` → `TurnAbortReason` | `session/cancel` notif (cooperative) | `POST /session/:id/abort` (cooperative) | `notifications/cancelled` (per-request, MAY ignore) | `$/cancelRequest` (MAY ignore) |
| approve | `item/*/requestApproval` → 7-variant `ReviewDecision` | `session/request_permission` → 4 option kinds | SSE `permission.asked` → POST reply | ✗ (elicitation ≠ approval; client-side concern) | ✗ |
| attach (2nd client) | ✗ (#25676 dual-continuation bug) | ✗ (draft PR #533 `session/attach`) | **✓ server-native multi-client** | ✗ (sessions removed from spec) | ✗ |
| resume/load | `thread/resume` (`excludeTurns` pagination) | `session/load` (replay) + `session/resume` (no replay) | server holds state; REST reconnect free | ✗ (resumability removed 2026 RC) | ✗ |
| seek/rollback | `thread/rollback` | ✗ | session tree (`/children`) | ✗ | ✗ |
| context-inject w/o firing | `additional_context` on start/steer | ✗ | `noReply: true` | ✗ | ✗ |
| detach/close | (drop stdio) | `session/close` | (drop HTTP) | ✗ | `shutdown`/`exit` |
| list sessions | ✗ (client tracks) | ✗ | `GET /session` | ✗ | n/a |

Codex has the deepest single-session vocabulary; opencode has the only real multi-client story; ACP is the intersection everyone can implement — which is precisely why it lacks the two hard verbs (steer, attach).

### B. Interrupt-semantics scoreboard

| | Mechanism | Actually stops work? | Documented failures |
|---|---|---|---|
| Codex | `turn/interrupt` request w/ response + abort taxonomy (`Interrupted/Replaced/ReviewEnded/BudgetLimited`) | Yes (strongest) | Stop-hook skipped on interrupt (#22858); idle-timeout mislabeled as user interrupt |
| ACP | one-way notification; SHOULD stop; MUST return `stopReason: cancelled` | Cooperative; acpx adds kill-after-timeout fallback | copilot-cli auto-approve bypass shows optionality of whole client contract |
| opencode | REST abort; cooperative cascade | Only from parent-session/user path; LLM stream has no timeout | #13841 hung subagents unescapable |
| MCP | per-request notification, receiver MAY ignore | Explicitly not guaranteed | python-sdk #1419 responds after cancel |
| LSP | `$/cancelRequest`, receiver free to ignore; must still respond | Suppresses response, not work | #722 dispatch race; #38814 ignored entirely |

Nobody has kill-now. Everything is cooperative-flag; the only honest designs *admit* it (ACP's SHOULD + acpx's timeout-kill; Codex's `TimedOut`/`Abort` decisions). The convergent correct shape: **cooperative cancel → bounded wait → force-kill, with the escalation visible in the protocol**.

### C. Approval flows compared
- **Codex**: server→client *request* with structured payload (`command` argv + `parsed_cmd` + `cwd` + `reason`; or `file_changes` map + `grant_root`); 7-variant response including **policy amendments** (approve-and-persist-rule), `Denied` (continue, try else) vs `Abort` (halt until next command), and first-class `TimedOut` — approvals resolve even unanswered.
- **ACP**: request with agent-*proposed* option list (`allow_once/allow_always/reject_once/reject_always`), `cancelled` outcome when turn dies mid-question. **No timeout specified** — spec gap.
- **opencode**: config engine decides allow/ask/deny; "ask" becomes a **broadcast SSE event** any client may answer + `remember?` flag. Only design where approval is decoupled from the asking surface — which is what makes phone-approval queues trivial.
- **MCP**: none. Approval is the client's problem by design (and elicitation is input-gathering, not permissioning).

### D. Attach/multi-client — the differentiator check
Expected mostly-no, confirmed mostly-no. **opencode: yes** (server-holds-state architecture makes it free; same-session live sync implied, not textually confirmed). **ACP: no, but PR #533 is a fully-designed draft** (`historyPolicy`, first-writer-wins permissions, broadcast) — the spec is telling you what to build. **Codex: no** — #25676's two-parallel-continuations bug and #14722's "remotely controlled" request show demand colliding with a stdio-pair architecture. **MCP: opposite direction** (sessions deleted). The field's demand-evidence: acp-multiplex, hydra-acp, CodexMonitor, OpenChamber — four independent third-party tools built to paper over missing attach. This is a real open seam, and OTP process registries + PubSub make it raxol's cheapest differentiator: an agent as a supervised process with N subscribed surfaces is the *native* BEAM shape, whereas every protocol above has to bolt it onto a 1:1 pipe.

### E. Framing/transport as experienced
- **stdio NDJSON** won the agent space (MCP mandate, ACP, Codex-which-isn't-even-real-JSON-RPC). Experienced upside: `jq`-able, trivial to bridge. Experienced downside: it *is* the process lifecycle — client dies, session dies (hence all of §D), plus real backpressure failures (Codex #24048 27GB OOM, #18203 queue-full disconnects).
- **Content-Length**: only LSP. Its practical sin is silent mutual incompatibility with NDJSON peers (codegraph #172).
- **REST+SSE**: server outlives every client — attach, phone approvals, and `curl`-driveability fall out for free. Experienced costs: global-not-per-session streams (opencode #7451 wontfix → client-side filtering), silent event-type regressions across minor versions (#27966), and the auth trap — a localhost command channel with `CORS: *` was an RCE (HN 46581095). geekfence's summary stands: per-message framing is free on persistent transports, but "sessions, replay buffers, resume-after-disconnect" is where the complexity reappears.

### F. Steal-list (top 5, attributed)
1. **`turn/steer` with `expected_turn_id`** (Codex): the steer verb itself plus optimistic-concurrency — a stale surface cannot steer a turn that already ended. Also steal the honesty: `NonSteerableTurnKind` says some turns refuse steering rather than silently queueing.
2. **`ReviewDecision`'s full taxonomy** (Codex): `Denied` ≠ `Abort` (retry-differently vs full-stop), `ApprovedForSession`, approval-carries-policy-amendment, and `TimedOut` as a first-class outcome so unanswered approvals resolve deterministically instead of hanging a turn.
3. **Broadcast approvals on an event bus** (opencode): `permission.asked` as an event any subscribed surface can answer (+`remember`), decoupling *who asked* from *who answers* — the enabling primitive for phone/watch/dashboard approval. Fix its flaw: per-session streams and real auth from day one.
4. **The queue/steer/break triad + compaction-unit rule** (opencode #32157): mid-run input needs exactly three user-selectable fates — next turn, current turn ("should not start a new compaction unit"), or abort-and-replace. Name them in the protocol; don't let messages be "queued silently, discarded in some UI states, or never acknowledged" (#21388).
5. **`session/attach{historyPolicy}` + tmux's guard-line discipline** (ACP PR #533 + tmux -CC): late-joiner sync policy as an explicit parameter (`full|pending_only|none|after_message`), broadcast-all-and-client-filters over role splits, correlated replies + async notifications — and tmux's negative lesson: the agent process, never the rendering surface, is the source of truth.

Honorable mentions: ACP's `cancelled` stop-reason threading (cancel composes cleanly with in-flight permission requests); escalating interrupt (cooperative → timeout → kill) as the double-Ctrl-C convention formalized (acpx, Codex #7035); Codex's `client_user_message_id` for client-side idempotency; opencode's `noReply` context injection.

---

## Implication for raxol (one paragraph)

The verb set to implement is now legible: **prompt / steer(queue|inject|break, CAS-guarded) / interrupt(escalating, with abort-reason taxonomy) / approve(rich decisions, timeout-resolving, bus-broadcast) / attach(historyPolicy) / resume / rollback**, over NDJSON stdio for embedding parity *and* a server surface for multi-client — because the single architectural divide in this entire research is *who owns the process*: stdio protocols die with their client (Codex #25676, ACP pre-#533), server architectures get attach for free (opencode). raxol's agent-as-supervised-OTP-process with surfaces as subscribers is the shape opencode approximates in TypeScript and ACP #533 is trying to retrofit onto a pipe — here it's the substrate. Every command verb should be a message to a named process; every surface a subscriber; approvals a broadcast with a deterministic timeout decision. The 25-item field bug catalog above is the test plan.
