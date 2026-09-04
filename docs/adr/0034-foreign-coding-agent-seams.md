# ADR-0034: Foreign coding-agent integration seams

## Status

Proposed, 2026-09-04. Nothing is implemented; this records which seam a foreign coding agent
should be handed to, and settles that question before a fourth native driver lands.

Revised the same day, after the forcing case turned out to be installed locally and every
claim below could be measured instead of read. Four findings inverted, each corrected where it
lands rather than quietly amended: the ACP seam is not prospective for this agent but shipped;
the security posture documented for upstream pi does not describe the agent actually in use;
permission delegation is per-tool rather than absent; and the mode those permission results
were measured under is `yolo`, not a conservative default. The seam ranking survives all four.
The recommendation for this particular agent, and the reason for it, changed twice.

The pattern is worth naming for anyone extending this: every one of those four came from
generalizing a single observation, and each was caught only by probing a second case. An ADR
about a foreign agent should assume its own claims are one experiment deep until they say
otherwise.

Written against **Oh My Pi** (`omp` 18.1.6), a derivative of `earendil-works/pi`, verified
directly. The distinction matters throughout: upstream pi and omp share a CLI surface, env
vars (`PI_SMOL_MODEL`, `PI_CODING_AGENT_DIR`) and an extension model, but omp adds an approval
system, MCP support, and an ACP server, which are precisely the three things the seam choice
turns on. Claims sourced from upstream pi's documentation are marked as such.

Pairs with ADR-0035, which handles the cost-metering half of the same integration work.

Depends on ADR-0020 (`Raxol.Agent.Sandbox`) for what a governed tool call looks like, and on
ADR-0030 for the `session/update` delivery contract the ACP seam rests on.

## Context

Raxol can host a foreign agent four ways. Three of them are in production and none of them was
chosen against a stated policy.

| Seam | Production instances | Governance raxol retains |
| ---- | -------------------- | ------------------------ |
| Native CLI backend | `claude_native`, `cursor`, `grok_native` | streaming and memory enrichment only |
| Symphony runner | `codex` | orchestration, evidence, pause and resume |
| ACP client role | none | permission gate, fs sandbox, journal, rendering |
| MCP server | any `.mcp.json` entry | the full Action hook chain |

The fourth is not a seam for an agent at all, for reasons in "Alternatives considered". The
first three each answer "let another vendor's agent drive this workspace" differently, and the
differences are large enough that picking by convenience has already cost something.

### Gap 1: the native seam discards the output that justifies a modern agent

`Raxol.Agent.Backend.Native` normalizes a driver's events and then throws two of the five away
(`backend/native.ex:170-171`):

```elixir
defp apply_event({:reasoning, _text}, _caller, _ref, state), do: state
defp apply_event({:tool_call, _info}, _caller, _ref, state), do: state
```

Only `{:text, _}` becomes a chunk and accumulates (`:165-168`). A driver is required by
`Raxol.Agent.NativeHarness` to parse both (`native_harness.ex:36-41`), so every driver pays to
produce events the runtime then drops. `Raxol.Agent.Harness.ClaudeCode` parses `thinking` and
`tool_use` blocks through `Harness.StreamJson`; none of it reaches a surface.

For pi this is most of the interesting output: a full `thinking_start` / `thinking_delta` /
`thinking_end` channel and `tool_execution_start` / `_update` / `_end` events carrying tool
name, arguments, partial results and error status. The user sees assistant text.

### Gap 2: a driver's usage vocabulary can disable the ledger and the guard that catches it

`Raxol.Agent.BenchmarkProfile.add_usage/2` (`benchmark_profile.ex:114-134`) reads
`:input_tokens` or `:prompt_tokens`, and `:output_tokens` or `:completion_tokens`, in atom or
string form. Pi reports `"input"` and `"output"`. Neither matches, and the failure is silent in
both directions:

1. `turn_cost_usd/3` collapses usage to zeros, so cost is `0.0`.
2. `Raxol.Agent.Code.CostLedger.record/4` guards on `cost_usd > 0.0` (`cost_ledger.ex:34`), so
   nothing is recorded.
3. `flag_unpriced/4` (`code/app.ex:1077-1083`) exists to catch exactly a $0.00 turn that burned
   tokens, but `billed_tokens?/1` (`:1085-1093`) calls the same `add_usage`, so it reports no
   tokens and the guard does not fire either.

The result is a ledger reading $0.00 forever, `RAXOL_MAX_COST_USD` that never trips, and the
fail-closed halt that exists to prevent precisely this staying silent. A budget that looks
enforced and is not is worse than no budget, and nothing in the `NativeHarness` behaviour
currently says a driver must translate.

### Gap 3: the ACP client role is complete, tested, and wired to nothing

Three pieces exist and pass their suites:

| Module | Lines | State |
| ------ | ----- | ----- |
| `Raxol.AgentClientProtocol.Client` | 896 | complete; `prompt_stream/4`, `fs_sandbox:` |
| `Raxol.AgentClientProtocol.Connection` | 1564 | complete; correlation, cancellation, delivery |
| `Transport.Stdio.start_spawn/3` | 333 | complete; spawns a peer with `:cd` and `:env` |
| `Raxol.Agent.AcpStreamAdapter` | 751 | complete; the inbound `session/update` direction |

`AcpStreamAdapter` consumes decoded `session/update` frames from `Client.subscribe/3` and
re-emits them as `Raxol.Agent.Contract.Event`s through `SessionStreamer`, the same channel
`Contract.pump/3` and `EmitBridge` publish on. Its moduledoc states the payoff: any surface
already subscribed renders an ACP-backed session with zero changes. It carries a documented
mapping table covering thought chunks, terminal-status-only tool emission, plans, and every
stop reason, with `:refusal` disclosed rather than painted as a normal end.

Grepping the tree for `AcpStreamAdapter` returns its own acceptance suite and nothing else.
The same holds for `use Raxol.AgentClientProtocol.Client` and for `start_spawn/3`, whose only
spawn tests drive `cat`, `printf`, `true` and `false`. So roughly 3,500 lines of the hard part
are written, and none of it has met a real ACP peer.

One hole is real: the adapter hard-codes `usage: %{}` on every `:turn_completed` (`:543`,
`:562`, `:576`) and leaves `usage_update` in the known-but-unmapped bucket (`:85`).
`Schema.UsageUpdate` is in fact ported (`schema/session_update.ex:491-561`), contradicting a
stale comment at `client.ex:299-303` that calls it unported.

That hole is load-bearing rather than theoretical, which a measurement settled. Driving
`omp acp` with `scripts/acp_probe.py` produced a clean turn whose frames were:

```
out  initialize          in  RESULT (agentInfo oh-my-pi 18.1.6)
out  session/new         in  RESULT (sessionId + configOptions)
out  session/prompt      in  session/update  available_commands_update
                         in  session/update  session_info_update
                         in  session/update  agent_message_chunk  text='OK'
                         in  session/update  usage_update
                         in  session/update  session_info_update
                         in  RESULT stopReason=end_turn
```

Zero `__NON_JSON_STDOUT__` entries and an empty stderr log, so the peer's wire is clean. The
`usage_update` frame was:

```json
{"sessionUpdate": "usage_update", "size": 272000, "used": 22974,
 "cost": {"amount": 0.11544, "currency": "USD"}}
```

which is `Schema.UsageUpdate`'s `%{used, size, cost: %{amount, currency}}` exactly. So the
first real foreign agent raxol talks to emits the one frame the adapter drops, and it carries
authoritative cost in USD. Two further frames, `available_commands_update` and
`session_info_update`, are not in the adapter's mapping table either and should land in its
known-but-unmapped bucket rather than its catch-all.

### Gap 4: five registries disagree about which backends exist

| Name | `Resolver.@providers` | `Selector.@backend_table` | `ExecutorConfig.@type backend` |
| ---- | --------------------- | ------------------------- | ------------------------------ |
| `grok_native` | yes | yes | missing |
| `cursor` | missing | yes | yes |
| `codex` | no | reserved, intentional | yes |

And in raxol_symphony, `Runner.resolve_from_config/1` (`runner.ex:99-115`) resolves
`"raxol_agent_session"` and `"noop"`, while `Config.Schema.@supported_runner_kinds`
(`config/schema.ex:23`) lists neither, so both resolve and then fail their own preflight.

Each gap is a live bug class rather than untidiness. `grok_native` is absent from the typespec,
so Dialyzer cannot see it. `cursor` is absent from `@providers`, and since `@by_string`
(`resolver.ex:164`) is derived from `@providers`, `harness_from_string/1` cannot name it:
`cursor` is selectable in code and unreachable from `/login`, `--backend` string resolution and
`.raxol/config.json`. The docs drift the same way, with `AGENT_FRAMEWORK.md:206` omitting
`grok_native` and `cursor`, and `CODING_AGENT.md:93-94` omitting all three native backends.

Adding a fourth native backend and a tenth provider widens all five.

### Gap 5: cross-vendor review is a fiction on most machines

`Raxol.Symphony.Runners.Review` runs implementer and reviewer as different vendors, and
`Review.select_reviewer/3` (`runners/review.ex:31-45`) needs at least two distinct available
vendors or it escalates to `:awaiting_human`. But `default_available?/1` (`:182-187`) returns
`true` unconditionally for `raxol_agent`, `raxol_agent_session`, `noop` and `review`, and
probes the filesystem only for `codex`.

So on a machine without `codex` installed, the only pair the selector can form is
`raxol_agent` against `raxol_agent_session`, which are the same vendor wearing two hats. The
adversarial premise the whole runner rests on is not met, and nothing reports that.

## Decision

### Rank the seams, and say what each one costs

| Seam | New Elixir | Retained | Surrendered |
| ---- | ---------- | -------- | ----------- |
| ACP client | ~640 | permission gate, fs sandbox, journal, rendering, usage | nothing structural |
| Native backend | ~95 | streaming, memory enrichment | tools, authz, hooks, ReAct, cwd scoping |
| Symphony runner | ~800 | orchestration, evidence, pause and resume | agent framework, tools |

**ACP is the strategic target.** It is also, counter to the intuition that a protocol layer is
expensive, the cheapest of the three, because Gap 3's inventory is already paid for. It is the
only seam where a foreign agent executes inside raxol's governance rather than beside it.

**The native backend is the tactical seam**, appropriate when a vendor CLI does not speak ACP
and the operator accepts the surrender in the security section below.

**The Symphony runner is neither a substitute nor a competitor.** It answers a different
question: tracker-driven orchestration with isolated workspaces, evidence capture and
human-in-the-loop pauses. Use it when that is the requirement.

These compose. A future `Raxol.Agent.ExternalAgent` behaviour with `start/2`, `prompt/3`,
`cancel/1`, `stop/1` and `capabilities/0` lets one vendor registry serve both an ACP driver and
a protocol-specific driver, so a foreign agent that does not speak ACP is not thereby excluded
from the registry that names it.

### For Oh My Pi specifically, the seam is ACP, and the native backend is not a fallback

`omp acp` is a shipped subcommand: "Run Oh My Pi as an ACP server over stdio". Gap 3's probe
drove it end to end. So for this agent there is no protocol work at all, and the ranking above
stops being a trade-off:

| | ACP (`omp acp`) | Native backend (`omp -p --mode json`) |
| - | --------------- | ------------------------------------- |
| Reasoning stream | delivered | discarded at `native.ex:170` |
| Tool calls | delivered, gateable | discarded at `native.ex:171` |
| Usage and cost | `usage_update`, USD on the wire | vendor-keyed, needs translation (Gap 2) |
| Tool-call visibility | `tool_call` / `tool_call_update` frames | discarded at `native.ex:171` |
| **Permission gate** | **bash gated and honoured; writes ungated** | **none** |
| Session model | `loadSession`, list/fork/resume/close | one shot per turn |
| Model selection | `configOptions` on the wire | argv only |

Five of six rows favour ACP, and the native backend buys nothing here except a smaller diff.
Build `:pi_native` only if a concrete need appears that ACP cannot serve; the `:in` fix below
is worth landing regardless, because it is a defect in the shared runtime rather than
pi-specific.

**The permission row is per-tool, and establishing that took three wrong answers.** It is worth
recording the sequence, because each wrong answer was produced by a plausible experiment.

The first probe asked omp to write a file. Zero `session/request_permission` frames across 27,
and the file appeared. The obvious reading, which this ADR briefly asserted, was that omp never
delegates and raxol's authorizer is decoration. That reading was wrong: it generalized from one
tool.

A later probe asked omp to run a bash command, and omp asked:

```
7.43s <- session/request_permission
        toolCall: {"toolCallId": "call_xks...", "title": "sleep 25 && echo done > ..."}
        option: {"optionId": "allow_once",    "kind": "allow_once"}
        option: {"optionId": "allow_always",  "kind": "allow_always"}
        option: {"optionId": "reject_once",   "kind": "reject_once"}
        option: {"optionId": "reject_always", "kind": "reject_always"}
```

That is the full ACP option set, correctly formed. Answering `allow_once` runs the command and
the side effect lands. So omp does implement the client round trip, and honours the answer.

Before the results, the baseline they were measured against, because it is not what "default"
suggests. `--approval-mode` overrides the `tools.approvalMode` setting, whose three values omp
documents as: `always-ask` auto-approves read-only tools only, `write` auto-approves read and
workspace-write tools, and `yolo` auto-approves all tiers. On the probing machine:

```
$ omp config get tools.approvalMode
yolo
```

and `~/.omp/agent/config.yml` is nine lines carrying model role, theme, composer shape and
`setupVersion: 2`, with **no approval key at all**. So `yolo` is what omp resolves to
unconfigured, not an override someone chose. The two related knobs are also empty:
`tools.approval` (a per-tool `allow`/`prompt`/`deny` record, documented as honoured in every
mode) is `{}`, and `bash.patterns` is `[]`.

The measured rule, across four runs. The unflagged runs are `yolo`, since that is what an
unconfigured install resolves to:

| Tool | `tools.approvalMode` | asks? | allow honoured? | side effect |
| ---- | -------------------- | ----- | --------------- | ----------- |
| `write` | `yolo` (unconfigured default) | **no** | n/a | lands |
| `write` | `always-ask` | no | n/a | denied |
| `bash` | `yolo` (unconfigured default) | **yes** | **yes** | lands |
| `bash` | `always-ask` | yes | **no** | denied |

Two findings, of opposite sign.

**The good one: raxol's authorizer is real on the highest-risk tool.** Shell execution is
gated by a round trip raxol answers. `Raxol.Agent.Authorization` decides whether a foreign
agent gets to run a command, and the decision is honoured. That is exactly the governance the
seam was claimed to provide, and it holds for the tool that matters most.

Note what that sentence costs, though: the mode in which raxol got a say is `yolo`, the most
permissive setting omp has. `bash` prompting at all under `yolo` contradicts "auto-approves all
tiers", and with `tools.approval` and `bash.patterns` both empty, nothing configured explains
it. The most likely reading is that omp gates shell over ACP regardless of mode, which is an
inconsistency in the safe direction, but it is a reading rather than a measurement and it is
listed under "Still open" rather than asserted here.

**The bad one: file writes are not gated at all**, so an ACP-hosted omp can create and modify
files without raxol seeing a decision point. Containment for the filesystem has to come from
somewhere other than the permission gate, which is what the ADR-0032 note under "Consequences"
is for.

**And a defect: `--approval-mode always-ask` breaks the round trip.** Under that flag omp
raises the request, receives `{"outcome": {"outcome": "selected", "optionId": "allow_once"}}`,
and then records:

```json
{"status": "failed",
 "rawOutput": {"content": [{"type": "text", "text": "Tool call denied by user: bash"}]}}
```

with the model reporting "Command was denied by the shell permission prompt." A valid allow is
read as a denial.

Stated against the real baseline, this is worse than "the safe flag is broken". Delegation to
raxol works under `yolo`, the setting that auto-approves everything, and breaks under
`always-ask`, the setting an operator would deliberately reach for to harden a deployment. The
configuration that sounds safe is the one that produces an agent which asks, discards the
answer, and refuses all work; the configuration that sounds reckless is the one under which
raxol's authorizer actually decides. An operator hardening by instinct gets strictly less
governance, not more.

Worth reporting upstream, and worth pinning with a test on our side, because a future omp that
"fixes" `always-ask` by not asking at all would be a silent downgrade from a gate to no gate.

Raxol's own agent surface gates every `sensitive: true` Action through
`ClientProtocol.Permission.authorizer/2`, so raxol-as-agent is stricter than omp-as-agent here:
the difference is per-tool coverage, not presence or absence of the mechanism.

What omp advertises maps onto rows raxol's `MethodTable` already has:

```json
"agentCapabilities": {
  "loadSession": true,
  "mcpCapabilities": {"http": true, "sse": true},
  "promptCapabilities": {"embeddedContext": true, "image": true},
  "sessionCapabilities": {"list": {}, "fork": {}, "resume": {}, "close": {}}}
```

`session/load`, `session/list`, `session/resume`, `session/close` and
`session/set_config_option` are all in `MethodTable` already. `Capabilities.negotiated?/2`
resolves each against what the peer advertised, so the client refuses a method omp did not
offer before decoding it, which is the behaviour that makes trusting this table safe.

One consequence worth stating up front: omp's `authMethods` offers
`{"id": "agent", "name": "Use existing local credentials"}`, so the foreign-agent auth story
Gap 3 lists as missing is, for omp, "call `authenticate` with `agent` and let omp use its own
`~/.omp` credentials". Raxol never handles the secret.

### The measured capability matrix

Every row below was probed, not inferred. Methods were sent with the shapes in
`Schema.Unstable`, which matters: an earlier pass sent `optionId` instead of `configId` and
omitted `cwd` from fork and resume, and omp answered `-32603` to all of them. Those were
malformed requests, not missing features, and the corrected calls all succeed. Note also that
omp answers a bad request with `-32603 Internal error` rather than `-32602 Invalid params`,
which is worth knowing before reading a failure as an unimplemented method.

| ACP method | omp | raxol `MethodTable` | usable |
| ---------- | --- | ------------------- | ------ |
| `initialize`, `session/new`, `session/prompt` | yes | yes | yes |
| `session/load` | yes | yes | yes |
| `session/list` | yes | yes | yes |
| `session/resume` | yes | yes | yes |
| `session/close` | yes | yes | yes |
| `session/cancel` | yes | yes | yes |
| `session/set_mode` | yes | yes | yes |
| `session/set_config_option` | yes | yes | yes |
| `session/fork` | yes, returns a new `sessionId` | **no** | no |
| `session/delete` | no (`-32603`) | yes | no |
| `logout` | no (`-32603`) | yes | no |
| `session/request_permission` | raised for `bash`, not for `write` | yes | partial |

Ten of thirteen are usable today, which is the concrete content of "the ACP seam needs no
protocol work".

`session/fork` is the one capability omp offers and raxol cannot reach, and the omission is
principled rather than accidental. `MethodTable` binds to the pinned schema oracle
(`priv/schema-oracle/v1/meta.json`, `schema-v1.19.0`) and its moduledoc records that
`session/fork` and `session/set_model` are absent from that oracle. The Schema layer does carry
`ForkSessionRequest` in `Schema.Unstable`, so the types exist and only the dispatch row is
missing. Adding it means moving the oracle pin, which is a deliberate decision about spec
discipline and not a one-line fix.

### What those methods actually buy

**Model selection across a catalogue raxol does not maintain.** `session/new` returns three
`configOptions`: `mode` (default or plan), `thinking`, and `model`. The model option carried
**685 entries across 5 providers**: openrouter 503, huggingface 142, anthropic 24, xai-oauth 9,
openai-codex 7. Each is selectable at runtime through `session/set_config_option`, resolved
against omp's own authenticated accounts, with raxol never holding a credential.

That is worth weighing against Gap 4. Raxol's own provider registry carries roughly a dozen
entries and costs a coordinated edit across three tables plus docs to extend. Hosting a
foreign agent over ACP reaches 685 models for one registry entry. These are not equivalent:
raxol's providers are backends for raxol's own loop, with its tools, hooks and spend gate,
while omp's are backends for omp's loop. But for the specific job of "reach a model raxol has
no backend for", the ACP seam is the cheaper answer and should be named as such rather than
left implicit.

**Session control raxol can drive, including a cancel that actually cancels.** `list`, `load`,
`resume`, `close` and `cancel` all work. `session/cancel` was measured against a running
`sleep 25 && echo done > marker`: the prompt returned `stopReason: "cancelled"` about 10ms
later, the marker never appeared after waiting past the sleep, and no orphaned `sleep`
survived. So it terminates the subprocess rather than merely detaching the stream, and it is
the one control that covers the tools the permission gate does not. It is still a reaction and
not a gate: it cannot un-write a file that has already been written.

**What the stream currently loses.** `AcpStreamAdapter` maps five update kinds:
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update` and `plan`. In
the probed turns omp emitted six kinds, of which three fall outside that set:
`available_commands_update`, `session_info_update` and `usage_update`. So half of omp's
observed vocabulary lands in the adapter's known-but-unmapped bucket today.

The adapter degrades well rather than breaking: `unmapped_counts/1` tallies each kind and the
first occurrence emits a `%{reason: :unmapped_acp_update, kind: kind}` marker, so the loss is
visible in a transcript instead of silent. But it means a first integration renders omp's text
and tool calls while dropping its command list, its session metadata, and its cost. The
`usage_update` mapping is the one worth doing before anything else, and ADR-0035 owns it.

### Ports that are never written to are declared input-only

`Raxol.Agent.Backend.Native` opens its port with
`[:binary, :exit_status, :stderr_to_stdout, :hide, {:line, 1_048_576}]` (`native.ex:129-134`)
and never calls `Port.command/2` anywhere in its 289 lines. The child therefore inherits a
stdin pipe that is held open for the port's lifetime and never closed.

Any CLI that reads stdin before doing its work blocks forever, and the run dies at
`{:error, :timeout}` after the 120s default (`native.ex:30`, `:152-155`) having produced
nothing. The pi family is such a CLI: it drains piped stdin to EOF and merges it into the
prompt, and that EOF never arrives.

Measured against the real binary, spawning `omp -p --mode json` with a deliberately invalid
model so the run fails fast without an LLM call, using the exact port options above:

```
native.ex opts as-is    BLOCKED   ms=9862  lines=1
    first output: Reading prompt from piped stdin (waiting for EOF; ctrl+c to abort)...
native.ex opts + :in    exit 1    ms=1619  lines=6
    first output: Model "zzz-nope-zzz" not found
```

The agent announces the hang on its first line of output. With `:in` it reaches its real work
and reports the real error in 1.6s.

Note the diagnostic trap this took to find. `omp --help` does not block, because help
short-circuits before the stdin read, so probing with `--help` reports success under both
configurations and proves nothing. A shell pipeline is also the wrong instrument: in
`sleep 60 | omp --help` the shell waits for every pipeline member, so a timeout reflects
`sleep`, not the agent. Only a command that actually reaches the stdin read, timed on its own
process, distinguishes the two.

Add `:in` to the port options, unconditionally rather than per driver. This is not a
pi-specific workaround: it makes the declaration match what the module already does, and
`claude`, `cursor` and `grok` happen not to read stdin today with nothing guaranteeing they
will not tomorrow. A per-driver flag would require the next driver author to already know the
trap exists.

The exception the rule must not swallow: a child whose parent-death signal is stdin EOF needs
the pipe. `Backend.Native` has no such child, since it spawns one-shot runs.

### A native driver must translate usage at the parse boundary

Amend the `Raxol.Agent.NativeHarness` contract: `parse_line/1`'s `{:done, %{content:, usage:}}`
must report usage in raxol's vocabulary (`input_tokens`, `output_tokens`), not the vendor's.
Gap 2 is the reason, and it is worth stating as a rule rather than fixing once, because the
failure is invisible in tests that do not assert on ledger state.

Where a vendor reports per-call usage and the conversation is re-sent each call, the driver
sums across calls rather than taking the last: each call's input is separately billed.

### Registry policy: derive, do not merge

A single registry for all five is wrong. They answer different questions: which provider has a
credential, which module implements this backend, which atoms are legal, which module runs this
issue, is this workflow file valid. Merging would couple raxol_agent's credential resolution to
raxol_symphony's workflow schema across a package boundary that exists on purpose.

What is right is one declaration the rest derive from. A `Raxol.Agent.Backend.Catalog` holding
`%{id, label, kind, module, env_keys, model_env, billing, detectable?}`, with:

- `ExecutorConfig.@type backend` unquoted from `Catalog.ids()` at compile time, which closes
  the `grok_native` gap permanently rather than once;
- `Selector.@backend_table` built from `Catalog.by_kind([:http, :native])`;
- `Resolver.@providers` a **filter** over the catalog, so `cursor` becomes declared
  undetectable instead of silently absent.

Symphony keeps its own resolver, because it answers a different question, but gains a
convention test asserting `@supported_runner_kinds` equals the set `resolve_from_config/1`
handles. That is the same mechanical enforcement `Raxol.Symphony.PauseReason.awaiting?/1`
already applies to pause atoms, and it is cheaper than a third registry.

A workspace-supplied vendor registry (a `.raxol/agents.json` naming external agents) stays
deliberately separate from the catalog. Its entries are user-writable data, not compile-time
module knowledge, and conflating the two is how a file in a cloned repository becomes an
atom-minting denial of service. It should inherit `Raxol.Agent.Code.McpLoader`'s admission
discipline (`mcp_loader.ex:22-31`): a bounded server count and a name pattern, both of which
exist because each accepted entry mints an atom and spawns a subprocess.

### What `:pi_native` hands over

Selecting a native backend for pi transfers the entire tool-execution boundary out of raxol
into a process raxol cannot inspect, constrain, or audit. This is worse than the existing
native backends, and the difference should be recorded rather than assumed equivalent.

**A correction, because the first draft of this ADR got it wrong.** That draft asserted the
agent ships no permission system, citing upstream pi's documentation. That is accurate for
upstream pi and **false for omp**, which carries a real set of controls:

| Control | Flag |
| ------- | ---- |
| Approval policy | `--approval-mode always-ask\|write\|yolo`, `--auto-approve` |
| Tool allowlist | `--tools <list>`, `--no-tools`, `--no-lsp`, `--no-pty` |
| Workspace roots | `--add-dir <path>` (repeatable), `--cwd` |
| State isolation | `--profile <name>` (separate auth, sessions, settings, caches) |
| Session cap | `--max-time 10m` |

So the honest statement is narrower than the draft's, and still worth making. The risk is not
that omp is ungoverned; it is that on the native path **omp's governance replaces raxol's**,
and the two are configured in different places by different people. An operator who has set
raxol's policy has not thereby set omp's, and nothing reconciles them.

Upstream pi's posture is the reason to keep the distinction visible rather than delete it: a
deployment that swaps `omp` for `pi` on `PATH` silently loses every control in that table,
because upstream pi's non-interactive modes show no trust prompt and fall back to a global
`defaultProjectTrust`. Pin the binary, and do not treat the two as interchangeable.

This compounds the bypass raxol already documents. Because `Backend.Native` reports
`handles_tools_internally? == true`, `Raxol.Agent.Stream` routes through `native_react/4`
(`stream.ex:168-176`, `:195-203`) and retains only memory and user-context enrichment. Gone for
the turn: the ReAct loop, `:tool_call_hooks` and with them SpendGate reserve-before-call and
blast-radius approval, `:tool_authorizer` and `Raxol.Agent.Authorization`, ACP
`session/request_permission` and per-session cwd scoping, and the cron `:in_cron` recursion
guard.

On raxol's tools, the draft was too absolute in one direction and then too optimistic in the
other, so state the transport precisely. Upstream pi has no MCP support. omp advertises
`mcpCapabilities: {"http": true, "sse": true}` and **not stdio**. Raxol's own MCP server is
stdio: `.mcp.json` declares `"type": "stdio", "command": "mix", "args": ["mcp.server"]`,
`Code.McpConfig` parses `{command, args, env}`, and `Harness.McpToolConfig` emits that same
shape. So raxol cannot hand omp its tools as currently packaged; the two do not share a
transport.

The gap is bridgeable and the piece already exists, unwired. `Raxol.MCP.Transport.SSE`
(`packages/raxol_mcp/lib/raxol/mcp/transport/sse.ex`) is a Plug-based HTTP/SSE MCP server
exposing `POST /mcp`, `GET /mcp/sse` and `GET /health`, compile-gated on `Plug.Router`. It has
its own test suite and no production caller, which puts it in the same category as
`AcpStreamAdapter`: built, tested, waiting for something to wire it. Lending raxol's Actions to
omp therefore costs an SSE endpoint and a URL in `session/new`'s `mcpServers`, not a new
transport.

Whether to do it is a separate question, and on the native path the answer is probably no: it
would add a second ungoverned tool surface beside the one omp already has. On the ACP path it
is more interesting, because MCP tools raxol serves are tools raxol can refuse, which is the
one thing `session/request_permission` does not give us here.

`warn_if_tools_are_the_backend_s/1` (`client_protocol/serve.ex:125-148`) already fires for any
`handles_tools_internally?` backend, so a native pi-family backend inherits the existing stderr
warning with no code change. The added clause should say what is true of both agents rather
than repeating the draft's upstream-only claim:

```
raxol acp: backend :pi_native enforces ITS OWN approval policy, not raxol's;
raxol's tool gates, cwd scoping and spend hooks are not in play on this session
```

None of this applies to the ACP seam, which is the recommended one for omp. There, omp's tool
calls arrive as `session/request_permission` and are decided by raxol's authorizer.

### Two pi registration choices that look like mistakes and are not

**`billing: :api_credits`, not `:subscription`.** Claude and Grok are their vendors' own
subscription clients, so running one costs nothing beyond a subscription already held. Pi is a
third-party bring-your-own-credential client whose documented default path is
`export ANTHROPIC_API_KEY=...`. Marking it `:subscription` would let `auto_detect/1` select it
whenever `pi` is on `PATH` and quietly bill a prepaid balance, which is exactly what
`resolver.ex:36-44` and `:421-425` promise cannot happen. `:api_credits` drops it from the
auto-detect walk entirely, so reaching it takes an explicit `--backend pi_native` or
`RAXOL_ALLOW_PAID_API=1`.

This needs a test asserting pi is not auto-selected even when its CLI is present. Without one,
the constant reads like an oversight and gets "fixed" later.

**`model_env: "RAXOL_PI_MODEL"`, not `PI_MODEL`.** Pi exports `PI_MODEL` into the environment
of processes its own bash tool spawns. Raxol running inside a pi bash tool would therefore have
its model selection silently overridden by the outer pi. Worth breaking the `GROK_MODEL` and
`ANTHROPIC_MODEL` naming convention for.

### Symphony specifics, if that seam is taken

Recorded here so a later implementation does not rediscover them:

- **`agent_settled` is the turn-completion signal, not `turn_end`.** Pi's turn is one LLM
  round trip inside an agent run; Symphony's is a whole prompt-to-settle cycle. Mapping
  `turn_end` would inflate `turn_count` by the tool-loop depth, because
  `maybe_turn_increment/1` (`orchestrator.ex:1768-1773`) increments per `:turn_completed`.
- **Usage must be a delta.** `merge_tokens/2` (`:1786-1790`) adds into a running total, while
  pi's `get_session_stats` is cumulative. Emitting the snapshot double-counts.
- **Symphony has no cost field anywhere.** `State.codex_totals` (`orchestrator/state.ex:61-66`)
  is tokens and seconds only, and four surfaces read that shape. Pi is the first runner able to
  report authoritative dollars, which is also what would make `Sandboxes.BudgetCap`'s `cost_fn`
  seam real: its only shipped implementation uses token count as a dollar proxy.
- **Context-preserving resume is possible here and is not with Codex.** `Runners.Codex`
  documents that resume starts a fresh session and loses conversational context
  (`codex.ex:44-51`). Pi's `--session-dir`, `switch_session` and `get_entries {since}` can
  restore it, which matters because `Runners.Review` pauses after every implement phase.
- **`extension_ui_request` must be answered even with no raxol extension installed**, because a
  user-installed pi extension can raise one and pi will block waiting. Defaulting to a
  cancellation reply, an emitted `:blocked` event, and continued operation is the only posture
  that cannot hang. Whether pi treats a cancellation as deny or as proceed is unverified and is
  listed under "Validation".

### Generalize the Codex stdio machinery rather than copying it

`Raxol.Symphony.PortReaper` and `Raxol.Symphony.Ssh` are already vendor-neutral and reusable
unchanged. `Runners.Codex.Framing` contains no Codex at all and should move to
`Raxol.Symphony.Stdio.Framing`. Roughly 40% of `runners/codex/session.ex` is protocol-free port
lifecycle worth extracting alongside it.

This is where hard-won knowledge lives, and every item is a bug someone already paid for:
reaper capture must precede the handshake because the orchestrator tears workers down with
untrappable exits that skip `try/after`; the stop grace is 2s local and 10s remote for stated
reasons; `{:env, []}` must not be passed to `Port.open` at all, because an empty list scopes the
child to an explicit environment on some OTP versions. A copy forks all of it on day one, and
`Backend.Cursor` would make a third copy.

## Alternatives considered

**Run the foreign agent as an MCP server.** One `.mcp.json` entry, zero raxol code, and it
inherits the full Action hook chain: approval-gated, `sensitive: true` by default, janitor-owned
lifecycle that cannot leak because there is no cleanup function to forget
(`mcp_loader.ex:134-215`).

Rejected as the seam for an agent, kept as the right answer for a tool. It is a tool call, not
an agent turn: no streaming, no session, no multi-turn context, no `session/update`, no usage
accounting, no pause and resume, no review eligibility. It is correct for "ask the other model
a question" and wrong for "let the other agent drive the workspace". Pi also has no MCP support
in either direction.

**Wire the foreign agent as a `:send_agent` peer.** `Raxol.Agent.Registry` plus the
`SendAgent` directive already carry inter-agent messages, with sandbox gating by target id.

Rejected: it is `GenServer.cast` to a BEAM pid (`directive/executor.ex:124-157`). There is no
out-of-process transport, no network registry, no serialization boundary, and payloads are
arbitrary Erlang terms. Reaching a foreign process still requires one of the other three seams
underneath, so this adds a hop rather than a capability.

**A raxol-side transport translating pi's RPC into ACP frames.** Put the adapter behind
`Transport`, so `Connection` and `Client` drive pi unmodified.

Rejected. Pi's rpc mode is a custom command and event protocol, not JSON-RPC 2.0: the adapter
would have to fabricate request ids, correlate pi's echoed ids to ACP ids, invent a
`session/new`, and synthesize every `SessionUpdate`, all while `Connection` holds it to real
JSON-RPC semantics. That is most of a protocol implementation plus a fake envelope layer,
reusable by nothing else.

**A pi extension that makes pi speak ACP on stdio.** Then raxol's existing client role drives
it with no new Elixir at all, `AcpStreamAdapter` lights up the whole rendering path, and pi's
`extension_ui_request` becomes a natural `session/request_permission`. `Schema.UsageUpdate`'s
`%{used, size, cost: %{amount, currency}}` is a close fit for pi's `get_session_stats`.

Attractive and deferred, on one unverified assumption: the extension must make pi write ACP
frames **instead of** pi's own, and whether a pi extension can replace the stdout writer rather
than add to it is unknown. If it can only add, two protocols interleave on one pipe and the
approach collapses. It also means maintaining TypeScript in this repository and a second
implementation of the pi mapping that must stay in sync with the Elixir one. Revisit if the
stdout-ownership question resolves favourably.

**Do nothing and keep adding native drivers.** Cheapest per driver.

Rejected: it is how the tree arrived at five disagreeing registries, three drivers whose
reasoning output is discarded, and a usage contract nothing states. The fourth driver is where
that becomes a pattern rather than an accident.

## Consequences

### What becomes possible

A foreign agent can run inside raxol's governance rather than beside it, once the ACP driver
exists: permission gate, confined filesystem, journal, and every surface already subscribed to
`SessionStreamer`.

Cross-vendor review stops being a fiction on machines without `codex`, taking the ordered
implementer and reviewer pairs from two to six and dropping the escalation probability from
P(no codex) to P(no codex) times P(no pi).

Symphony gains a runner that reports real dollars, which is what makes its `BudgetCap` seam
meaningful rather than a token proxy.

The `:in` port fix removes a hang from a code path three existing drivers share.

### What costs we accept

The catalog is a compile-time indirection where five hand-maintained lists used to be. It is
more machinery for someone reading the code cold, and it buys the guarantee that they cannot
disagree.

The native seam stays available and stays ungoverned. Documenting the surrender precisely does
not reduce it, and an operator who reads the warning and proceeds has made a real choice with
real consequences.

**Governance over a foreign agent is per-tool, and has to be described that way.** For omp,
raxol decides shell execution and does not see file writes. Two mechanisms cover the gap
partially and neither covers it fully: `session/cancel` is genuine interposition on a running
turn (measured: it killed the subprocess, the side effect never landed, and no orphan
survived), but it is a reaction rather than a gate, and it cannot un-write a file. So the
honest summary is that an ACP-hosted omp is fully observable, gated on shell, ungated on the
filesystem, and interruptible throughout.

That last clause is not a technicality. Because writes are ungated, containment for the
filesystem has to come from below the protocol. Raxol **spawns** the ACP peer through
`Transport.Stdio.start_spawn/3`, which already takes `:cd` and `:env`, so the boundary omp does
not enforce in-protocol can be enforced underneath it by the OS: exactly the `Spawn.Seatbelt` /
`Spawn.Bwrap` wrapper ADR-0032 specifies, applied to a foreign agent instead of a shell tool.
An agent whose writes are unmediated inside a grant set is a defensible posture; the same agent
inside nothing is not. **That makes ADR-0032 a prerequisite for hosting omp anywhere but a
trusted local workspace**, which the seam ranking does not by itself imply.

There is also a configuration trap to carry into any deployment, and it runs the wrong way
round. `tools.approvalMode` resolves to `yolo` on an unconfigured install, and `yolo` is the
mode in which raxol's authorizer gets a say over shell execution. `always-ask`, the setting an
operator reaches for to harden, is the one that asks and then discards the answer. So hardening
by instinct removes governance rather than adding it, and a deployment should pin the mode
explicitly with a test rather than inherit whatever the install resolves to.

The two agents are held to different standards of evidence, and the ADR has to keep saying
which is which. Every omp claim here was measured against `omp` 18.1.6 on one machine. Every
**upstream pi** claim is documentation-derived, because upstream pi is not installed, and the
two diverge on exactly the points the seam choice turns on. A reader who treats a measured omp
result as a pi result will get the permission story backwards. The prototype list under
"Validation" covers the pi-specific gaps, and the design deliberately keeps defensive fallbacks
(a settle
grace window, cancellation-on-unknown) where a wrong assumption would otherwise hang or
miscount.

### What this ADR does not decide

- **Whether `Backend.Native` should forward reasoning and tool calls.** Gap 1 is stated, not
  fixed. It is a generic improvement benefiting all four drivers and belongs in its own change,
  because it adds events to a stream surfaces currently assume is text.
- **Which seam pi actually ships on.** All three are costed; sequencing is a scheduling
  decision, not an architectural one.
- **Whether the pi ACP extension is built.** Blocked on the stdout-ownership unknown.
- **Cross-tenant separation.** Unchanged from ADR-0032: one BEAM, one uid.
- **Whether `Runners.Codex` adopts the extracted `Stdio.*` modules in the same change.** It
  should, to avoid a second copy existing even briefly, but the migration is reviewable
  separately.

## Validation

The tests an implementation must produce.

- **An ACP loopback**, spawning `bin/raxol-acp` through `Transport.Stdio.start_spawn/3` and
  driving `initialize`, `session/new`, `session/prompt` through `Client` into
  `AcpStreamAdapter`, asserting the resulting `Contract.Event` stream. This is the highest
  value test in the set: it is the first time `start_spawn/3` meets a real ACP peer, the first
  production-shaped use of 751 already-written adapter lines, and it needs no third-party
  install and no network because `mock` is in both registries. It also exercises stdout purity,
  which `stdio.ex:37-49` warns about and nothing has ever tested.
- **A stdin regression test**: a fixture CLI that reads stdin before working must complete
  rather than time out, asserted with a short `:timeout` so a regression fails in seconds
  instead of stalling CI for two minutes.
- **A usage-translation test** asserting a native driver's `{:done, _}` usage survives
  `BenchmarkProfile.add_usage/2` with the expected token counts, and summed across calls where
  the vendor reports per-call. Assert the exact keys, since that is the failure mode.
- **A no-auto-select test**: with the pi CLI present on `PATH` and `RAXOL_ALLOW_PAID_API`
  unset, `Resolver.resolve/1` must not return `pi_native`.
- **Registry convention tests**: `ExecutorConfig.@type backend` covers every
  `Selector.supported_backends/0` entry, and Symphony's `@supported_runner_kinds` equals the
  set `resolve_from_config/1` handles. Both should fail today.
- **Double-count guards** on any pi driver: `message_end` and `turn_end` must produce no text
  events, since their payloads repeat the accumulated deltas; `agent_end` with
  `willRetry: true` must not terminate the run.

### Resolved by measurement

The first draft listed eight unknowns. Oh My Pi 18.1.6 was installed locally, so most were
answered rather than deferred.

| Question | Answer |
| -------- | ------ |
| Does `:in` unblock the real binary? | **Yes.** BLOCKED at 9.9s without it, exit 1 at 1.6s with it |
| Can a pi extension own stdout in rpc mode? | **Moot.** `omp acp` ships as a subcommand |
| Is a cost figure available? | **Yes.** `usage_update` carries `cost: {amount, currency}` in USD |
| Does the peer keep stdout protocol-pure? | **Yes.** Zero non-JSON frames, empty stderr |
| `--no-approve` polarity? | **Superseded.** omp has `--approval-mode always-ask\|write\|yolo` |
| Does the agent expose session resume? | **Yes.** `loadSession: true` plus list/fork/resume/close |
| Does omp raise `session/request_permission`? | **For `bash`, yes**, with the full option set, and it honours the answer. Not for `write` |
| Does `--approval-mode` reach `omp acp`? | **Yes**, and `always-ask` breaks the round trip: it asks, then ignores an allow |
| What does `tools.approvalMode` resolve to unconfigured? | **`yolo`**, auto-approve all tiers. Not written to `config.yml`; it is what omp resolves to |
| What does `session/cancel` do to a running tool? | **Kills the subprocess.** Side effect never landed, no orphan, `stopReason: cancelled` in ~10ms |
| Which ACP methods does omp implement? | 10 of 13 usable; `fork` unreachable from raxol, `delete`/`logout` absent |
| Can raxol lend omp its MCP tools? | **Not as packaged.** omp is http/sse, raxol's server is stdio |
| Does `session/load` restore a session? | **Yes**, returns the session's `configOptions` |
| Does `session/cancel` reach omp? | **Yes** |

### Still open

Each of these is now scoped to a seam rather than to the agent, and none of them gates the
seam choice, which the permission measurement settled.

1. **Which tools besides `bash` does omp gate?** Four cells were characterized (`bash` and
   `write`, across two approval modes). `edit`, `python`, `browser`, `computer` and `task` are
   untested, and `computer` (native desktop capture and input, disabled by default) is the one
   whose answer matters most. The gating rule appears to be per-tool rather than
   per-risk-class, so it has to be measured tool by tool rather than inferred.
2. **Why does `bash` prompt under `yolo` at all?** `yolo` is documented as auto-approving all
   tiers, and `tools.approval` and `bash.patterns` are both empty, so no configured override
   explains the prompt. Either shell is gated over ACP regardless of mode, or something
   undocumented is in play. The answer decides whether the shell gate is a property raxol can
   rely on or an accident that a future release removes, which makes it the highest-value
   remaining question on this list.
3. `session/load` returns a session's config, but whether the **model** sees restored
   conversational context is untested: that needs a two-turn probe referencing turn one.
4. Does omp honour `--add-dir` and `--cwd` as a containment boundary over ACP, or only as a
   convenience? This rose in importance once writes turned out to be ungated: it is the
   difference between omp confining itself and needing ADR-0032's OS wrapper to confine it.
5. Would omp accept raxol's tools over `Raxol.MCP.Transport.SSE`, and would its own approval
   policy then gate them? This is the one route to a real tool gate on the ACP path, so it is
   worth a probe even though it needs the SSE endpoint wired first.
6. Native-seam only, and unnecessary if ACP is taken: `agent_settled` emission count across an
   auto-retry, and whether a prompt beginning with `-` survives as a positional argument.

One measured fact deserves its own line because it is a cost input, not an unknown: the probe's
trivial prompt reported **22,974 input tokens** for a single turn, at $0.115. That is omp's
system prompt and tool definitions, paid on every turn. Any budget wired against an
ACP-hosted omp should be sized against a five-figure per-turn floor.

## Defects surfaced while writing this

Context for the decision rather than part of it, and each needs a tracker entry: a defect
recorded only in prose is one nobody is assigned.

1. **`Backend.Native` hangs any CLI that reads stdin.** `native.ex:129-134`. Confirmed against
   a real binary, not inferred: BLOCKED at 9.9s without `:in`, exit 1 at 1.6s with it. Latent
   for the
   three existing drivers, immediate for a fourth. Fix is one atom.
2. **Five registries disagree** (Gap 4). `grok_native` invisible to Dialyzer; `cursor`
   unreachable by name; two Symphony runner kinds resolve and then fail preflight.
3. **Cross-vendor review does not verify vendor distinctness** (Gap 5). `default_available?/1`
   returns `true` unconditionally for four of five kinds, so the adversarial premise can be
   unmet with no report.
4. **`usage["cost"]` is a dead key.** `Harness.GrokBuild` stamps it from `total_cost_usd`
   (`grok_build.ex:98-107`) and nothing reads it: the cost path runs entirely through
   `LlmPrices` and `BenchmarkProfile.cost_usd/2`, which read only token counts. Picked up in
   ADR-0035.
5. **A stale doc comment** at `client.ex:299-303` calls `usage_update` unported when
   `Schema.UsageUpdate` exists at `schema/session_update.ex:491-561`.

One upstream defect, recorded here because a deployment decision depends on it rather than
because this repo can fix it:

6. **omp ignores an ACP allow under `--approval-mode always-ask`.** It raises
   `session/request_permission` with the full option set, receives
   `{"outcome": {"outcome": "selected", "optionId": "allow_once"}}`, and answers
   `status: failed` with `"Tool call denied by user: bash"`. Reproduced on omp 18.1.6 with
   `scripts/acp_probe.py`, which selects the first `allow*` option. The consequence is that the
   flag an operator would reach for to harden a deployment is the one that makes the agent
   inoperable, while `yolo` (what an unconfigured install resolves to) is the mode in which
   delegation works. Report upstream; pin ours with a test, because a future omp that "fixes"
   `always-ask` by not asking at all would be a silent downgrade from a gate to no gate.

## References

- ADR-0020: `Raxol.Agent.Sandbox`, for what a governed tool call looks like
- ADR-0030: the `session/update` delivery-ordering contract the ACP seam depends on
- ADR-0032: multi-root filesystem grants, for the confinement an ACP-hosted agent would inherit
- ADR-0035: cost metering for multi-rate providers, the other half of this integration work
- `packages/raxol_agent/lib/raxol/agent/backend/native.ex:129-194`: port options and the
  discarded events
- `packages/raxol_agent/lib/raxol/agent/native_harness.ex:36-83`: the driver contract this ADR
  amends
- `packages/raxol_agent/lib/raxol/agent/acp_stream_adapter.ex`: the inbound adapter, written
  and unwired
- `packages/raxol_agent_client_protocol/README.md:176-222`: the client driver sequence, already
  written out
- `packages/raxol_agent/lib/raxol/agent/code/mcp_loader.ex:22-31`: the admission discipline a
  vendor registry should inherit
- `packages/raxol_symphony/lib/raxol/symphony/runners/codex/session.ex`: the extraction source
- `packages/raxol_symphony/lib/raxol/symphony/runners/review.ex:31-45`: the reviewer selector
- `scripts/acp_probe.py`: the dependency-free ACP client used to verify the peer, and the
  reference an integrator implements against
- `packages/raxol_agent_client_protocol/lib/raxol/agent_client_protocol/method_table.ex:8-14`:
  the oracle pin, and why `session/fork` is absent
- `packages/raxol_agent_client_protocol/lib/raxol/agent_client_protocol/schema/unstable.ex`:
  `ForkSessionRequest`, `ResumeSessionRequest`, `SetSessionConfigOptionRequest`; the shapes a
  probe must send, and the source of the `configId` field name
- `packages/raxol_mcp/lib/raxol/mcp/transport/sse.ex`: the http/sse MCP server that would let
  raxol lend tools to an agent that does not speak stdio MCP; tested, no production caller
- `packages/raxol_agent/lib/raxol/agent/code/mcp_config.ex:30-32` and the repo's own
  `.mcp.json`: raxol's MCP servers are stdio, which omp does not accept
- Oh My Pi (`omp` 18.1.6), the forcing case, verified locally; `omp acp`, `omp --help`
- `github.com/earendil-works/pi`: upstream, whose documented posture differs from omp's on
  every point the seam choice turns on
