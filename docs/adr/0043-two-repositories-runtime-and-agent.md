# ADR-0043: Two repositories: the runtime, and the agent built on it

## Status

Accepted, 2026-10-26. Depends on [ADR-0042](0042-lean-on-omp.md) landing
first: its harness deletion removes about 25k lines that would otherwise move.

| Amends ADR-0042 | Change | Here |
| --- | --- | --- |
| Decision 1 | The story is replaced. | Decision 1 |
| Decision 2 | Derived tools continue, scoped to the terminal and SSH surfaces. The plugin's home moves. | Decisions 4 and 3 |
| Decision 3 | The second preparatory PR, Symphony's `omp` runner, is dropped. | Decision 6 |
| Decision 4 | The backend catalog gains `zkapi`. | Decision 10.2 |

Amended, 2026-11-13: `Raxol.Agent.Policy` and the `SessionLane` behaviour with
its `raxol_agent` implementation are removed, so Decision 3's `raxol_agent`
row and Decision 7's prompt-callback follow-up name code that no longer exists.

## Context

One repository holds two products with one dependency direction, agent on
runtime, and a short list of exceptions (Decision 7). Its README leads with
the agent harness, which ADR-0042 deletes.

### The settlement standards

| Standard | What it provides |
| --- | --- |
| ERC-8262, Zero-Knowledge Compliance Oracle | A submitter proves AML, sanctions and anti-structuring compliance client-side. The oracle stores an attestation with a TTL. There are nine proof types (0x01 to 0x09). `submitter` is a public input and must equal `msg.sender`. The reference implementation is Solidity plus one Noir circuit per proof type, and pins `nargo` and `bb`. |
| zkAPI (Ethereum Foundation) | A deposit is held as a private note. Each request carries a zero-knowledge spend proof and a nullifier. A local client exposes OpenAI- and Ollama-compatible endpoints. It is experimental and gives no network-layer anonymity. |
| ERC-8273, Attestation-Gated Agentic Actions | `attestAndCall` writes a transient attestation, runs the action and clears the authorization. The record carries `capability`, `actionDigest` and `evidenceHash`. |

## Decision

### 1. The story, in two sentences

**Raxol** is a runtime: write one app, render it to a terminal, a browser, an
SSH session, or as tools an agent can call.

**A Raxol agent** is a supervised BEAM process that can hold money and cannot
spend it outside a policy it did not write. The model proposes; the agent
checks the policy, writes the journal, then acts or refuses.

Two repositories: two readers, two release cadences, two definitions of done.

### 2. What a Raxol agent is

Five properties define the agent. Four are enforced in code today; the fifth
is Decision 10. They lead the agent README and are absent from the runtime's.

| Property | Enforced by |
| --- | --- |
| Policy is data the operator owns. | `Raxol.Broker.PolicyFile` parses `broker.policy.exs` as data and requires per-order and daily caps. Money passes `Raxol.Payments.Actions.SpendGate.authorize/3` and the ledger. Model spend passes `Raxol.Agent.SpendGate`. |
| Every decision is journaled before it is acted on. | `Raxol.Agent.Journal.FileStore.open(session, chain: true)` gives a SHA-256-chained, replayable record. `Raxol.Broker.Journal` writes `placing` before any order call. `mix raxol.broker.replay` rebuilds a day from disk. |
| Every mutation is gated, and the gate cannot be bypassed from outside. | Every mutating action is ALLOW, ASK or DENY. `Raxol.Broker.Executor.run/3` requires a review between intent and order, with an HMAC `ReviewReceipt` under a key that exists only in the executor's process. |
| It fails closed. | An unconfigured agent refuses to start. `Raxol.Agent.OperatorFile` refuses untrusted policy and credential files. Signing nodes forbid Erlang distribution. Armed mode waits for #1179. |
| Settlement is private to everyone and provable to anyone. | Compliance is proven, not disclosed (ERC-8262). Value moves through stealth or shielded rails. The agent's own API spend is unlinkable to its deposits (zkAPI). The chained journal regenerates a proof on request. |

The model sits outside (ADR-0042): a host proposes and the agent decides.

### 3. Package assignment

**Runtime repository** (`DROOdotFOO/raxol`, unchanged URL, lockstep line):

| Package | Role |
| --- | --- |
| `raxol`, `raxol_core`, `raxol_terminal`, `raxol_liveview`, `raxol_plugin`, `raxol_sensor` | framework line, as today |
| `raxol_mcp` | server, `TreeWalker`, `ToolSynchronizer`, focus lens, test harness and client; loses `agent_bridge.ex` (Decision 7) |
| `raxol_journal` (new, Decision 5) | `Journal`, `FileStore` with its reader and writer, `Chain`, `Tip`, the checkpoint records, the event schema and encoder from `Contract`, golden corpora |
| `raxol_speech`, `raxol_telegram`, `raxol_watch`, `raxol_gateway` | surfaces; the gateway loses `Handler.Agent` to `raxol_console` and drops its optional `raxol_agent` dependency (Decision 7) |

**Agent repository** (`DROOdotFOO/raxol-agent`, new, own release line):

| Package | Role |
| --- | --- |
| `raxol_agent` (after ADR-0042) | `Session`, `Team`, `Comm`, `Scheduler`, `SpendGate`, `Policy`, `Auth`, `OperatorFile`, `Sandbox`; the `SessionLane` implementation; the `zkapi` model backend (Decision 10.2) |
| `raxol_payments`, `raxol_broker`, `raxol_earn` | the money; `raxol_payments` gains the zkAPI rail (Decision 10.2) |
| `raxol_web3` | guarded chain access; gains `Raxol.Web3.Compliance` (Decision 10.1) |
| `raxol_console` | Virtuals ACP console runtime (ADR-0031); gains `Raxol.Gateway.Handler.Agent` (Decision 7) |
| `raxol_cli` | the `raxol` binary, its npm wrapper `@raxol/cli`, and the OMP plugin with its marketplace catalog |
| `raxol_agent_client_protocol` | stays beside its only consumer |

**Neither:** `raxol_symphony` (Decision 6).

`raxol_cli` moves because the binary bundles the agent and `raxol_payments`.
`playground` and `new` leave the binary. The runtime keeps `mix mcp.server`,
`mix raxol.new` and `mix raxol.playground`. Until the split, the plugin is
built in this tree at `integrations/omp/raxol/`.

### 4. The runtime's agent surface, narrowed

The runtime keeps one agent feature: agent-readable surfaces. A Raxol app
derives MCP tools from its Component tree, with session-scoped names and a
small listed set (ADR-0042 Decision 2). Write tools route through `update/2`
(#1303). Answers are structured snapshots, not screen text.

The scope is the terminal and SSH surfaces, which have no DOM to query and no
Phoenix runtime to introspect. The README makes no claim about the browser.

Removed from the runtime's story: "a runtime for agents as much as for
humans", the agent-harness comparison in `WHY_RAXOL.md`, `raxol code`,
`raxol p` and the Pay/Earn/Improve/Reach/Orchestrate list. The runtime README
links to the agent repository once.

### 5. The one shared seam: `raxol_journal`

`raxol_journal` is a new framework-line package in the runtime repository.
It holds `Raxol.Agent.Journal`, `FileStore` with its reader and writer,
`Chain`, `Tip`, the checkpoint records, and from `Raxol.Agent.Contract` the
event schema and its encoder: `Event`, `encode_line/1`, `sanitize_payload/1`
and `evidence_status/1`. `Contract.pump/3` and its helpers stay in
`raxol_agent`. The golden corpora and the contract and journal sections of
`docs/harness/architecture.md` move with it. Module names stay for this
release, gain `Raxol.Journal.*` aliases and are deprecated one minor later.

It sits in the runtime because the root already matches journal events by
shape: `Raxol.Harness.Projection` folds the event stream and
`Raxol.Harness.Fixture.Event` mirrors the schema. The root `raxol` does not
depend on the package. It takes the dependency when its code first calls it.

`raxol_journal` depends on Jason and `:telemetry`, and on nothing from Raxol.
`raxol_agent` and `raxol_broker` depend on it.

### 6. `raxol_symphony` is frozen in its own repository

`raxol_symphony` is frozen in `DROOdotFOO/raxol-symphony` (#1320) with its
history, unpublished, pinned to the last versions it built against. It gates
no CI. It left before the ADR-0042 cutover, so ADR-0042's second preparatory
PR, Symphony's `omp` runner, is dropped.

### 7. The boundary, enforced

In the runtime repository, `scripts/check_package_boundaries.exs` gains a
root rule. No file under `lib/` or `packages/*/lib` may reference
`Raxol.Agent.*`, `Raxol.Payments.*`, `Raxol.Broker.*`, `Raxol.Earn.*`,
`Raxol.Web3.*` or `Raxol.Console.*`, in code, `apply/3`, atoms or process
names. `Raxol.Agent.Journal`, `Raxol.Agent.Contract` and docs are exempt. The
root `lib/` is scanned for the first time. Crossings are removed, not kept:

| Crossing | Resolution |
| --- | --- |
| `packages/raxol_mcp/lib/raxol/mcp/agent_bridge.ex` | moves to `raxol_agent` |
| `Raxol.Gateway.Handler.Agent` and the gateway's optional `raxol_agent` dependency | `Handler.Agent` moves into `raxol_console`, which already depends on both sides; the optional dependency goes. A `SessionLane` prompt callback is later work. |
| `Raxol.Agent.Scheduler.Delivery` reaching `Raxol.Gateway.Delivery` | becomes a callback passed in by the application that composes both, `raxol_console` |
| `Raxol.Application` reaching `Raxol.Agent.Code.*` and `Harness.McpTools`; `Code.CostLedger` reaching `Raxol.Payments.Ledger` | deleted by the ADR-0042 cutover |
| The root harness's use of the event contract | stays a shape match; the root takes no dependency until its code calls `raxol_journal` (Decision 5) |

In the agent repository the runtime is a Hex dependency. One environment
variable, `RAXOL_PATH=../raxol`, turns every runtime dependency into a path
dependency. A nightly job against runtime `master` may fail without blocking.

### 8. Versions

The runtime keeps its lockstep line and adds `raxol_journal` to it.
`raxol_agent` leaves it. Its next release is 3.0.0, because the ADR-0042
deletion is breaking, and it pins the runtime as `~> 2.7`.

### 9. Order of work

1. Land ADR-0042's preparatory work and its cutover: the decoupling (#1302),
   `raxol acp` on Raxol agents (#1301 and its follow-ups), then the harness
   deletion. Nothing below starts before the delete set is gone.
2. In tree: extract `raxol_journal`, add the root boundary rule with every
   crossing listed, and shrink the list to zero (Decision 7).
3. `git filter-repo` the agent packages, tests, docs and ADRs (0016 to 0018,
   0020 to 0022, 0024 to 0028, 0030 to 0036, 0038 to 0042) into `raxol-agent`,
   with history. One PR deletes them here; the index keeps a row per moved ADR.
4. The agent repository takes the runtime from Hex. Its CI is the runtime's
   `ci-unified.yml` minus the terminal, Scoreboard and RATE jobs.
5. `raxol_symphony` out (Decision 6). Done first, in #1320.
6. READMEs, `ROADMAP.md`, `PACKAGES.md` and `llms.txt` split per Decisions 1,
   2 and 4. The runtime's `ROADMAP.md` loses "Agent runtime parity".
7. Decision 10 lands in the agent repository only, after step 4.

### 10. Private and compliant settlement

None of this exists in either tree today; every name below is a proposal. A
proof is evidence the policy consumes, never a key the model can turn.

#### 10.1 ERC-8262 is the compliance seam

`Raxol.Web3.Compliance` lives in `raxol_web3`, beside ADR-0038's client.

| Path | Behaviour |
| --- | --- |
| Read | `check/3` calls `checkCompliance(subject, jurisdictionId)` by `eth_call` and returns the attestation with its `expiresAt`. It is the only compliance call the executor's review step makes. |
| Prove | `prove/2` hands a proof type and the signals to a `:prover` seam. The first prover runs the reference implementation's `noir_js` and `bb.js` path as a port, pinned to its `nargo` and `bb` versions. Signals go to the prover's stdin and never into the journal or a log. |
| Write | `submit` wraps `submitCompliance`. It is a mutation: it passes the gas cap and the ledger, is journaled with the proof hash, and is never triggered by a failed `check/3`. A stale attestation at review time is a journaled refusal. |
| Policy | The payments and broker policies gain a `compliance:` section: oracle address per chain, `jurisdiction`, accepted proof types, `min_remaining_ttl`, `counterparties: :attested \| :any`, and the account that is the subject. |

`check/3` and `submit` run only against Sepolia and Base Sepolia, under the
same `sandbox: true` rule that keeps the broker in dry run. For on-chain
settlement, armed mode and mainnet compliance arrive together or not at all.
`raxol_broker`'s Robinhood stock path has no on-chain subject and is outside
this rule: it arms under its own gate (#1179, then the #1183 soak).

#### 10.2 zkAPI is a rail and a model backend

The journal records nullifiers and caps, never note secrets or deposits.

- **Model backend.** `raxol_agent` gains a `zkapi` backend on the local
  client's Ollama-compatible endpoint, through the Ollama codec ADR-0042
  keeps. It is a fourth kind in ADR-0042's catalog. The OpenAI-compatible
  family stays deleted. `Raxol.Agent.SpendGate` meters every call.
- **Rail.** `raxol_payments` adds `zkapi` beside its existing rails, under
  the per-rail cap of `Raxol.Payments.Actions.SpendGate.authorize/3`. Vault
  deposits are a capped, journaled operator action.

#### 10.3 Compliant on the way in, private on the way through

An ERC-8262 attestation gates entry into a stealth or shielded rail and
acceptance of a `raxol_earn` job. Past that gate, spends are unlinkable.

#### 10.4 What the journal makes possible

ERC-8262 pattern proofs (0x03) need the transaction set and a
`settlement_root` the consumer recomputes. The chained journal is that set:
`Raxol.Broker.Journal` records carry `prev_hash` and `hash`, so a replay
yields the same root. `mix raxol.compliance.pattern` selects the settlements,
proves through 10.1 and submits under the same caps. The journal marks each
proof's offset range so a proof is never reused.

#### 10.5 ERC-8273 and ERC-8004, later

The broker's `ReviewReceipt` is an HMAC over `intent_id`, `group_id`, a nonce
and an intent fingerprint. Its digest changes to ERC-8273's
`(capability, actionDigest, evidenceHash)` layout: one receipt-format change
and nothing on-chain. The local gate does not change. An ERC-8004 identity is
registered only when an agent needs a public one.

## Consequences

- A runtime change the agent needs ships in a runtime release first.
- Runtime CI loses the Windows `raxol_agent` job and the broker suites.
- ADR-0042's other decisions carry over to the repository owning each package.
- `docs/harness/architecture.md` splits: contract, journal and projection
  sections to `raxol_journal`; the rest to the agent.
- The agent repository takes on a proving toolchain it does not own: pinned
  `nargo` and `bb`, checked before every proof. A bump is a release.
- Given up: one `mix test`, one Dependabot surface, one `CLAUDE.md`.
- Deferred: whether `DROOdotFOO/raxol` is renamed. Hex names never change.

## References

- [ADR-0012](0012-mcp-as-rendering-target.md),
  [ADR-0031](0031-console-runtime-integration.md),
  [ADR-0038](0038-guarded-outbound-client-evm-rest-backend.md),
  [ADR-0041](0041-agent-client-protocol-package.md),
  [ADR-0042](0042-lean-on-omp.md).
- ERC-8262: <https://eips.ethereum.org/EIPS/eip-8262>; reference
  implementation <https://github.com/xochi-fi/ERC-8262>.
- zkAPI: <https://blog.ethereum.org/2026/10/01/introducing-zkapi>,
  <https://github.com/ethereum/zkapi>.
- ERC-8273: <https://ethereum-magicians.org/t/erc-8273-attestation-gated-agentic-actions/28617>.
