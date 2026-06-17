# ADR-0022: Memory provider stack, full-text recall, and dialectic user modeling

## Status

Proposed, 2026-06-17. Second of the Hermes-extraction Tier 1 ADRs (`~/Desktop/hermes-extraction-report.md`,
item H1.3). Companion to ADR-0021 (self-improving agents), which deliberately scoped memory OUT and
deferred it here. Builds on the existing `Raxol.Agent.Memory` behaviour and the omnigent item-log
(`Raxol.Agent.Conversation.{Store,Log}`). The following Tier 1 ADR is H1.4 (unified messaging gateway).

Revised 2026-06-17 after a second Hermes research pass against current sources (v0.14-v0.16 official
docs + the `NousResearch/hermes-agent` repo). Corrections folded in below: the provider set has grown
to nine, and Honcho injects its dialectic into the *system prompt* (cache preserved by a session-start
frozen snapshot), not the user message, so the user-message injection here is now framed as a
deliberate improvement over Honcho rather than parity.

## Context

Raxol has one memory subsystem and it is already pluggable, but single-layered and lexical-only.

- `Raxol.Agent.Memory` (`packages/raxol_agent/lib/raxol/agent/memory.ex:33-38`) is the provider
  behaviour: `prefetch/2`, `search/2`, `store/2`, `forget/2`, `build_system_prompt/1`. Helpers:
  `default_provider/0` (`:42`), `provider_context/3` (`:50-55`), `format_block/1` (`:59-64`).
- The single configured provider is selected per agent via `memory_provider/0`
  (`agent.ex:106`), and its Actions (`memory_remember`, `memory_recall`, `memory_forget`) appear
  only when that callback is set (`agent.ex:116-118`).
- The default adapter `Memory.Store.Ets` ranks with BM25-lite over an inverted token index:
  `score/5` (`memory/store/ets.ex:238`) = `relevance/5` (`:242-252`, `@k1=1.2` `:37`, `@b=0.75`
  `:38`, `idf` `:254`) + `recency/1` (`:256-259`, `@recency_weight=0.3` `:40`, halflife 30d `:41`)
  + `tag_bonus/2` (`:261-271`, `@tag_weight=0.5` `:42`). Tables at `:107-111`. It manages DETS
  directly via the `:dets` module (`:341,375,378,381`), predating `Raxol.Core.Stores.Dets`.
- Memory is injected into the system prompt by `Memory.Manager.enrich_messages/3`
  (`memory/manager.ex:18-28`), placed after leading static system messages
  (`inject_after_system/2`, `:38-41`) to keep the cacheable prefix intact, and wired into the
  ReAct loop at `stream.ex:157,166` via `maybe_enrich_memory/2` (`:552-557`).

Hermes is the benchmark. Three capabilities it has and Raxol does not:

### Gap 1: Single provider, no stacking

Hermes keeps a built-in `MEMORY.md`/`USER.md` layer AND exactly one of nine external providers
(Honcho, Mem0, OpenViking, Hindsight, Holographic, RetainDB, ByteRover, Supermemory, Memori) at a
time: the built-in layer is always active alongside the chosen external one, but Hermes permits
only a single external provider at once. Raxol's `memory_provider/0` is singular: an agent gets the
ETS store OR a custom provider, never both layered. There is no way to keep the fast local store
while also consulting an external semantic service.

### Gap 2: No full-text recall over conversation history

`Memory.Store.Ets` recalls curated `Record`s (semantic memory: facts the agent chose to keep). It
does NOT search raw conversation history. The episodic log (`Conversation.Store.ETS`) is
append-only and unindexed. Hermes's `session_search` is full-text recall over every past message
(SQLite FTS5, ~20ms), returning RAW messages, not summaries. Raxol has no equivalent; "what did we
say about X three sessions ago" is unanswerable.

### Gap 3: No user model

There is no per-user persistent representation anywhere in the repo (confirmed: no "user
profile"/"dialectic"/belief-model code). `agent_id` is the only partition key. Hermes's deepest
differentiator is Honcho dialectic user modeling: implicit understanding of the user *derived* by
reasoning over past conversations (preferences, goals, habits), refreshed in the background on two
cadences (a base "who this user is" context call plus a deeper dialectic pass) and injected per-turn
into the **system prompt**. (Hermes preserves the prefix cache differently than this ADR will: the
built-in `MEMORY.md`/`USER.md` block is captured as a session-start frozen snapshot and never mutates
mid-session, so the dialectic system-prompt injection trades per-turn freshness for cacheability.)

There is also no vector/embedding infrastructure in `raxol_agent` (Nx exists only in
`raxol_sensor`, for sensor fusion). Memory is purely lexical today.

## Decision

**Layer three opt-in additions on the existing `Memory` behaviour: a provider stack, a full-text
session-recall path, and a native dialectic user model. Keep `Memory` as the single contract;
everything else composes through it. The default ETS store and single-provider path are unchanged.**

### 1. Provider stack (`Raxol.Agent.Memory.Stack`)

Add a plural callback `memory_providers/0` (default `[]`) alongside `memory_provider/0` (kept).
When set, `Memory.Stack` fans `store/2` to the writable providers and `prefetch/2` / `search/2`
across all providers, then merges and re-ranks results (by provider-reported `score`, normalized).
The stack is itself a `Memory` implementation, so the rest of the system (`enrich_messages/3`, the
Actions) is unchanged: it sees one provider that happens to be a composite.

An external service (Honcho, Mem0, ...) is just a `Memory` adapter. This ADR ships the adapter
contract plus ONE reference HTTP adapter skeleton (`Memory.Adapter.HTTP`) and does NOT port the nine
backends; third parties or follow-ups add concrete adapters against the stable behaviour. (Hermes's
released provider plugin contract, a `MemoryProvider` ABC with `is_available`, `prefetch`,
`sync_turn`, and `system_prompt_block` lifecycle hooks, is the shape this behaviour mirrors.) Where
Hermes allows the built-in layer plus exactly ONE external provider, the stack composes the built-in
store with N external providers and re-ranks across all of them: a deliberate step past Hermes, not
parity.

### 2. Full-text session recall (`session_search`)

Add a recall path over the episodic log, distinct from semantic memory:

- A token index over `Conversation.Item` content, reusing the existing tokenizer
  (`Record.tokenize/1`, `record.ex:55-64`) and the BM25-lite scoring already proven in
  `Memory.Store.Ets`. Default backend: ETS inverted index maintained on `Conversation.Log.append`,
  so search and the log stay consistent.
- A `session_search` Action returning **raw** matching items (Hermes parity: search returns
  messages, not summaries; summarization is a provider concern, item 3).
- An optional `SessionSearch.Sqlite` adapter (SQLite FTS5 via a port) for deployments that outgrow
  the ETS index. The ETS backend is the default; FTS5 is opt-in for scale.

### 3. Dialectic user model (`Raxol.Agent.UserModel`)

A native, OTP-shaped version of Honcho's dialectic modeling, built on the BEAM rather than bolted
on as an external service:

- A `UserModel` background GenServer, keyed by user id, that maintains a derived representation
  (preferences, goals, habits, contradictions resolved) by reasoning over past conversation items
  on an auxiliary (cheap) model. It refreshes asynchronously, never on the foreground turn's
  critical path, and can prewarm at session start.
- Two-layer per-turn injection, mirroring Honcho's cadences:
  - **Base context** ("who this user is"), refreshed every `context_cadence` turns.
  - **Dialectic supplement** ("what matters right now"), refreshed every `dialectic_cadence` turns.
- A new OPTIONAL `Memory` callback `build_user_context/1` (default `nil`), distinct from
  `build_system_prompt/1`. The system-prompt block stays in the cacheable prefix; the user-context
  block is injected into the LAST user message at call time, so per-turn dialectic refreshes do not
  invalidate the prompt cache. Wired via a new `maybe_enrich_user_context/2` next to
  `maybe_enrich_memory/2` (`stream.ex:552-566`). This is a deliberate improvement over Honcho, not
  parity: Honcho injects its dialectic into the *system prompt* and preserves the cache only by
  freezing that block as a session-start snapshot, which forfeits per-turn refresh. Injecting into
  the user message keeps both the per-turn refresh and a stable cached prefix.

The `UserModel` is exposed as a `Memory` provider, so it stacks (item 1) with the ETS store rather
than replacing it.

### 4. Migrate `Memory.Store.Ets` DETS to `Raxol.Core.Stores.Dets`

Replace the store's hand-rolled `:dets` open/persist/rebuild/sync (`ets.ex:341,375,378,381,113-119,
355-366`) with the shared helper landed in commit `3ed30eab`. Pure refactor, behaviour-preserving,
removes duplication and aligns with the Skills store from ADR-0021 (which also uses it).

## Consequences

### Positive

- **Local speed plus external depth.** Agents keep the fast in-process ETS store AND can layer a
  semantic external provider, without choosing one. The stack is transparent to existing code.
- **Conversation history becomes searchable.** `session_search` answers "what did we discuss
  before" over raw messages, reusing the tokenizer and scoring already in the codebase.
- **A real user model, BEAM-native.** Dialectic refresh is a background GenServer, not a forked
  process juggling prompt caches; per-turn injection into the user message preserves caching by
  design.
- **Less duplication.** The DETS migration unifies persistence across Memory, Skills (ADR-0021),
  and future stores.

### Negative

- **The dialectic model spends tokens** on background reasoning, on top of the curation loop from
  ADR-0021.
- **Two index writes per conversation append** (the log plus the session-search token index) add
  write cost to the hot path.
- **`build_user_context/1` adds a second injection point**, so authors now reason about two memory
  blocks (cacheable system vs per-turn user) instead of one.
- **Merge-and-rank across heterogeneous providers** is inherently lossy: providers report scores on
  different scales.

### Mitigation

- Make every layer opt-in: no `memory_providers/0`, no `session_search` provider, and no
  `UserModel` means today's behaviour exactly. Route the dialectic model to an auxiliary model and
  gate its cadence.
- Build the session-search index incrementally and asynchronously off `Conversation.Log.append`;
  offer the SQLite FTS5 adapter when ETS write cost bites.
- Normalize provider scores to `[0,1]` before merge and document the ranking contract; let the
  stack config pin per-provider weights.

### What this ADR does not decide

- **Vector / embedding search.** A `Memory.Adapter.Embedding` (Bumblebee/Nx, cosine similarity)
  is a natural future adapter against the same behaviour, but is out of scope; recall stays lexical
  plus optional external semantic providers.
- **Concrete external adapters** (Honcho, Mem0, etc). Only the contract + one HTTP skeleton ship.
- **Cross-node distributed memory.** Single-node ETS/DETS (or one SQLite/one external service); a
  sharded multi-writer memory is out of scope.
- **Auto-capture from turns.** Writing memory from a completed turn is ADR-0021's curation loop;
  this ADR only adds where memory is read from and what providers exist.

## Alternatives considered

### Make the external provider replace, not stack

Keep `memory_provider/0` singular and let a custom provider wrap the ETS store internally.

Rejected. Every external provider would have to re-implement local fallback. A first-class stack
keeps composition in the framework and adapters simple.

### Put `session_search` inside the Memory store

Index conversation items into the same `Memory.Store.Ets` tables as `Record`s.

Rejected. Semantic memory (curated, typed `Record`s) and episodic recall (raw messages) have
different lifecycles, ranking needs, and retention. Conflating them pollutes both. They share the
tokenizer and scoring functions, not the tables.

### Use Honcho (or another SaaS) as the user model instead of building one

Adopt an external dialectic service directly.

Rejected as the default. It would still be a `Memory.Adapter.HTTP` instance under item 1 (and is
welcome as one), but the BEAM makes a native background-reasoning GenServer cheap and removes an
external dependency, network hop, and data-egress concern from the core capability.

### Inject the dialectic block into the system prompt

Simpler than a second injection point.

Rejected. Per-turn dialectic refresh would invalidate the prompt cache every turn. Honcho keeps its
dialectic in the system prompt and dodges that cost by freezing the block as a session-start
snapshot, at the price of per-turn freshness. `build_user_context/1` instead injects into the LAST
user message, keeping both the per-turn refresh and a stable cached prefix.

## Validation

- **Existing tests pass unchanged.** All additions are opt-in; the single-provider path and ETS
  ranking are untouched (the DETS migration is behaviour-preserving and covered by the existing
  store tests).
- **Stack test:** an agent with `[Memory.Store.Ets, FakeExternal]` writes to both and recalls a
  merged, re-ranked result set; removing one provider degrades gracefully.
- **session_search test:** after N conversation turns, `session_search("term")` returns the raw
  items containing the term, ranked, with no items from other conversations; the index stays
  consistent across `append`.
- **Dialectic test:** the `UserModel` refreshes in the background without blocking a turn; the
  user-context block lands in the LAST user message (not the system prefix); base vs supplement
  refresh at their configured cadences.
- **Cache-preservation test:** a per-turn dialectic refresh does not change the system-message
  prefix bytes (cache stays valid).
- **DETS migration round-trip:** store records, restart, recall identically via
  `Core.Stores.Dets`.

## References

- `~/Desktop/hermes-extraction-report.md` (item H1.3; Honcho/Mem0/session_search mechanisms)
- ADR-0021: Self-improving agents (curation writes INTO memory; this ADR defines reads + providers)
- `packages/raxol_agent/lib/raxol/agent/memory.ex:33-64` (the behaviour + helpers; `build_user_context/1` is added here)
- `packages/raxol_agent/lib/raxol/agent/memory/manager.ex:18-41` (system-prompt injection; the user-context injection mirrors it)
- `packages/raxol_agent/lib/raxol/agent/memory/record.ex:55-64` (`tokenize/1`, reused by session_search)
- `packages/raxol_agent/lib/raxol/agent/memory/store/ets.ex:37-42,238-271` (BM25-lite scoring reused by session_search; `:341,375,378,381` the DETS code migrated to `Core.Stores.Dets`)
- `packages/raxol_agent/lib/raxol/agent/stream.ex:157,166,552-566` (memory wiring; `maybe_enrich_user_context/2` added alongside)
- `packages/raxol_agent/lib/raxol/agent.ex:106,116-118` (`memory_provider/0`; `memory_providers/0` added)
- `packages/raxol_agent/lib/raxol/agent/conversation/store.ex`, `conversation/log.ex` (the episodic log session_search indexes)
- `packages/raxol_core/lib/raxol/core/stores/dets.ex` (the shared DETS helper; commit `3ed30eab`)
