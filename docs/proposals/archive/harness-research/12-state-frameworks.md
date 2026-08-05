# State/Persistence Frameworks: What Actually Transfers to a Single-Process Agent Journal

Forum-first sourcing: GitHub issues, HN threads (Algolia API used where HN rate-limited direct fetch), practitioner blogs, official docs/essays treated as primary sources. Reddit was unreachable in this research pass (WebFetch refuses reddit.com, thin Google index): flagged wherever it thins out a "praise" section. Two products are studied here as **theory sources, not adoption candidates**: Temporal (round-1 verdict NC-4, "just a task queue with retries") and LangGraph (competitor architecture). SQLite/JSONL and the ES/CQRS literature are studied as design inputs for a **local, single-process, single-writer** agent journal: the distributed-systems concerns (multi-writer conflicts, network partitions, cross-service consistency) in Kafka/EventStoreDB material are explicitly filtered out where they don't transfer.

---

## 1. LangGraph Checkpointers

### 1.1 Data model

The `Checkpoint` TypedDict (`libs/checkpoint/langgraph/checkpoint/base/__init__.py`):

```python
class Checkpoint(TypedDict):
    v: int                              # format version, currently 1
    id: str                             # monotonically increasing (uuid6-based)
    ts: str                             # ISO 8601 timestamp
    channel_values: dict[str, Any]      # deserialized channel name -> value
    channel_versions: ChannelVersions   # channel name -> monotonic version string
    versions_seen: dict[str, ChannelVersions]  # node ID -> {channel: version seen}
    updated_channels: list[str] | None
```

Identity is `(thread_id, checkpoint_ns, checkpoint_id)`: `thread_id` is the conversation/session key, `checkpoint_ns` namespaces subgraphs ("each subgraph manages its own checkpoint namespace"), `checkpoint_id` is the monotonic per-write ID. Parent linkage is **not** a field on `Checkpoint`: it lives in `CheckpointMetadata.parents` (namespace → parent checkpoint ID) and surfaces as `parent_config` on `CheckpointTuple`, forming a linked list walked backward for time-travel. `.put_writes()` stores writes for an in-flight superstep before they're folded into `channel_values`: how a crashed graph resumes without re-running already-succeeded nodes at that step, using negative-indexed markers `ERROR(-1)/SCHEDULED(-2)/INTERRUPT(-3)/RESUME(-4)`. Postgres backend: three tables: `checkpoints` (JSONB metadata + pointer), `checkpoint_blobs` (serialized channel values, keyed by version), `checkpoint_writes`. Default serializer is `JsonPlusSerializer` (`ormsgpack` + JSON fallback for LC-specific types); historically had `pickle_fallback=True` by default: now `False` as of `langgraph-checkpoint` 4.0.0 for security reasons (§1.3).

Source: [raw checkpoint base source](https://raw.githubusercontent.com/langchain-ai/langgraph/main/libs/checkpoint/langgraph/checkpoint/base/__init__.py); [deepwiki 4.1 checkpointing architecture](https://deepwiki.com/langchain-ai/langgraph/4.1-checkpointing-architecture); [docs.langchain.com persistence](https://docs.langchain.com/oss/python/langgraph/persistence).

### 1.2 Praise: thin and marketing-mediated

Positive discourse skews blog/tutorial, not raw forum voice: "Time travel in LangGraph is a game-changer for debugging workflows!" (dragonforest.in), "a debugger, an undo button, and an audit log all in one... a flight recorder for your automated decision system" (callsphere.ai, loan-decision use case). No live r/LangChain praise thread was surfacing in this pass. **Finding worth stating on its own**: the positive discourse around LangGraph checkpointing is almost entirely content-marketing-shaped, while the negative discourse is concrete, technical, and primary-sourced (GitHub issues, security advisories): the honest signal here is asymmetric by construction, not because there's nothing to like.

### 1.3 What users hate

**Serialization bloat, quantified.** GitHub [#7714](https://github.com/langchain-ai/langgraph/issues/7714) (May 2026): *"LangGraph checkpoint serialization produces 85% storage bloat and 37.8% token overhead with no opt-out path."* A 16-turn ReAct agent (65 messages) produces a 21,850-byte checkpoint under defaults vs 3,217 bytes optimized (85.3% overhead); token-side, full Pydantic metadata via `dumpd()` costs 5,764 tokens vs 3,587 for the semantic content. Root cause: full Pydantic metadata serialization on every channel value, every write, no pluggable serializer at the `BaseCheckpointSaver` layer. No maintainer response visible.

**Write amplification at scale.** Practitioner post from a Tiendanube engineer, production numbers: "120,000 conversations weekly, with each average conversation generating ~93 checkpoint records across four tables"; `checkpoint_blobs` hit 56 MB / ~18,000 records in one staging week. Load-bearing line: *"Operative databases should store operational state, not historical exhaust."* Also confirms the OSS Postgres checkpointer **lacks native TTL**: TTL only exists in the hosted LangGraph Platform, not the library. [tadeodonegana.com](https://tadeodonegana.com/posts/scaling-langgraph-postgres-checkpointer/). A more vendor-flavored writeup (azguards.com, numbers treated skeptically) ties bloat to Postgres TOAST: checkpoints over ~2KB pushed out-of-line, ~50 TOAST chunks per 100KB payload, WAL generation "~150 MB/sec at 100 concurrent executions." Root-cause line worth keeping regardless of exact numbers: *"Every document retrieved, every string generated, and every embedding array processed is duplicated in the database for every node the graph traverses."*

**Unbounded growth confirmed by LangChain's own community team.** forum.langchain.com thread, user reports 282,758 checkpoint records / ~30 GB across 16,000 conversations (~7.7 checkpoints per message). LangChain responder: *"LangGraph persists a checkpoint at every 'super-step' of graph execution, not once per user message."* And directly: *"There are no built-in options to cap per-thread checkpoints or auto-prune. The only deletion helper is `deleteThread(threadId)`."*

**Migration pain between schema versions.** [#6356](https://github.com/langchain-ai/langgraph/issues/6356): `PostgresSaver.setup()` fails with `DuplicateColumn` because a migration's `ALTER TABLE` lacks `IF NOT EXISTS`: the migration itself isn't idempotent. [#3557](https://github.com/langchain-ai/langgraph/issues/3557): `UndefinedColumn: column cw.task_path does not exist` after a minor version bump. [#5862](https://github.com/langchain-ai/langgraph/issues/5862): a point release (2.0.21→2.0.22) silently switched metadata serialization from tolerant `JsonPlus` to strict JSONB, rejecting previously-valid non-JSON objects. [#6137](https://github.com/langchain-ai/langgraph/issues/6137): old Postgres rows lack a `channel_values` key entirely, `TypeError: 'NoneType' object is not a mapping`: old rows silently don't round-trip through newer code; the fix was defaulting `.get("channel_values")` to `{}`.

**Correctness bugs in serialization.** [#6789](https://github.com/langchain-ai/langgraph/issues/6789): `Send` objects (used for map-reduce/dynamic fan-out: "a core LangGraph feature") aren't msgpack-serializable at all (`__slots__`, no `__reduce__`), breaking checkpointing for any in-flight dynamic-routing step.

**Security: checkpoint corruption is a trust-boundary problem, not just a storage one.** CVE-2025-67644: SQL injection in the SQLite checkpointer's `.list()` filter (`f"json_extract(CAST(metadata AS TEXT), '$.{query_key}') {operator}"`), letting an attacker UNION-SELECT poisoned binary data into the checkpoint BLOB column returned by `get_state_history()`. Chained into **CVE-2026-28277 / CVE-2026-27794** (GHSA-mhr3-j7m5-c7c9): the msgpack unpacker's extension hook did `getattr(importlib.import_module(tup[0]), tup[1])(tup[2])`: crafted msgpack referencing `(os, system, "cmd")` = arbitrary code execution, purely from getting bytes into a checkpoint row. Root cause: `BaseCache` defaulted to `JsonPlusSerializer(pickle_fallback=True)` prior to 4.0.0: *"when msgpack serialization fails, cached values can be deserialized via `pickle.loads(...)`."* Advisory framing worth quoting directly: *"An attacker who can write to the checkpoint store can poison an agent's memory by altering reasoning traces, injecting false tool call results, or inserting persuasive content."* Full chain: [research.checkpoint.com](https://research.checkpoint.com/2026/from-sqli-to-rce-exploiting-langgraphs-checkpointer/); advisory: [GHSA-mhr3-j7m5-c7c9](https://github.com/langchain-ai/langgraph/security/advisories/GHSA-mhr3-j7m5-c7c9). CVE-2026-27022: same injection family in the Redis checkpointer's RediSearch filter.

### 1.4 Time-travel: real but narrower than the marketing implies

Per [docs.langchain.com/use-time-travel](https://docs.langchain.com/oss/python/langgraph/use-time-travel): *"Nodes before the checkpoint are not re-executed (results are already saved). Nodes after the checkpoint re-execute, including any LLM calls, API requests, and interrupts (which may produce different results)."* This is **replay-as-re-execution, not snapshot restore**: an LLM call replayed from history can return a different completion than the original run, silently diverging from "true" history. Interrupts (human-in-the-loop gates) *always* re-fire on replay. You can't cheaply "fast forward" through an already-approved decision. Forking has an open correctness bug: [#4987](https://github.com/langchain-ai/langgraph/issues/4987), re-invoking from a historical checkpoint should mint a new checkpoint ID for the fork but reuses the identical ID, *"all the history after time travel is broken."* And the feature's core selling point (keep full history so you can rewind) is in direct tension with §1.3's bloat findings, *"If your agent state includes a 50MB PDF and the agent takes 10 steps, the checkpointer writes 500MB of data to PostgreSQL."*

### 1.5 Retention: unbounded by default, no built-in pruning in OSS

Confirmed directly by LangChain's forum team (§1.3). Only first-party automated mechanism is TTL, and it's **Platform-only** (hosted product), not in the open-source checkpointer libraries. `langgraph-checkpoint-redis` is the one exception (piggybacks native Redis key expiration). `delete_thread()` is the only OSS primitive: coarse, all-or-nothing per thread. Community DIY patterns: keep only the newest checkpoint per `(thread_id, checkpoint_ns)` for restoring current state, but *"Deleting subgraph checkpoints while keeping parent checkpoints risks breaking resume flows, particularly for human-in-the-loop interrupts."* Explicit warning against manually deleting `checkpoint_writes` rows: *"it might mess up time travel."* Tiendanube's production advice: build tables via your own migrations (don't trust `.setup()`), run retention via a partitioned table to isolate delete I/O from the hot path, archive to S3 before deleting from Postgres, and reconsider whether every subgraph even needs its own checkpointer.

---

## 2. Temporal: Theory extraction only (NOT an adoption candidate)

### 2.1 Mechanics: append-only log, replay-to-reconstruct

*"A workflow execution in Temporal is not stored as a snapshot of mutable state. It is stored as an ordered, append-only log of events."* Resume is genuine re-execution, not deserialization: *"When it's time to continue the Workflow, Temporal doesn't restore memory from a snapshot. It starts the Workflow code from the beginning, replays the Event History step by step, and uses that history to guide the code back to the exact state as before."* Command-matching drives determinism enforcement: the SDK checks whether the workflow's next issued command matches the next recorded event; a mismatch (wrong type, wrong name, wrong order) throws a non-determinism error. [docs.temporal.io/workflows](https://docs.temporal.io/workflows); [How Temporal Works Internally](https://letsbuildsolutions.com/blog/system-design/how-temporal-works-internally-event-history-deterministic-replay-and-the-architecture-behind-durable-execution/).

**The performance escape hatch is the transferable mechanic**: a "sticky task queue" keeps the worker's in-process replayed state cached; only on cache miss (worker crash, 5s sticky-queue timeout) does a fresh worker do a full replay. Full replay is the **recovery-path cost**, not the steady-state cost.

### 2.2 What agent people specifically envy

The named failure mode of ad-hoc state: *"state turns into confetti: scattered across webhooks, database flags, and ad hoc timers that nobody fully understands... If a process restarts halfway through, do I lose the work I already paid for?"* ([temporal.io blog](https://temporal.io/blog/the-heros-journey-to-ai-durability-with-temporal)). What durability buys: *"Your system now remembers what it's already done, and you stop paying twice for the same work."* Agent-specific, cost-explicit framing: *"When an agent workflow fails at step 23 of a 50-step task, Temporal doesn't restart from step 1... No completed work is re-executed. No token costs are doubled."* ([AgentMarketCap](https://agentmarketcap.ai/blog/2026/04/10/durable-agent-execution-production-temporal-modal-event-sourced)). Named ad-hoc pain list: *"Timeouts, partial execution with no durable progress, poor retry semantics (restart from scratch), no clean way to wait for human input, limited operational visibility."*

**Critically, the envy has a specific granularity claim, aimed directly at LangGraph**: *"LangGraph's 'sync' checkpointing persists state changes synchronously before the next step begins... However, checkpointers only save state between nodes. They do not save state inside a node. Because an agent can be halfway through a massive loop inside a single node, all that intermediate work is gone."* This is the single most load-bearing lesson for us: **the envy is about sub-step durability (mid-tool-call), not conversation-turn durability.** A journal granular only at "turn" or "node" level reproduces LangGraph's exact gap.

Replit is cited (via [xgrid.co](https://www.xgrid.co/resources/agentic-ai-orchestration-temporal/)) as having migrated its coding agent to Temporal for reliability: a named production data point, not just vendor copy.

### 2.3 History size limits and what causes bloat

Hard documented numbers: *"The Workflow Execution's Event History is limited to 51,200 Events or 50 MB and will warn you after 10,240 Events or 10 MB."* ([docs.temporal.io/workflow-execution/limits](https://docs.temporal.io/workflow-execution/limits)). Payload-level: 2MB per individual payload, 4MB per single event-history transaction (xgrid.co). Real incident from the community forum: a subflow invocation resending the complete payload to nested subflows, terminating at event 4239 after raising a loop count from 500→600; fix recommended by Temporal staff: *"If the payload is large we recommend storing it in some external store (like S3) and pass only references to it through workflow and activity arguments."* Agent-specific empirical threshold: *"workflow termination from history limits tends to occur around 500 to 600 loop iterations when each iteration spawns child workflows or multiple activities."* The **claim-check pattern** is the named fix: *"Do not store large LLM outputs directly as activity return values... write the output to an object store, return the reference."*

### 2.4 continue-as-new: compaction with a mandatory carryover contract

Problem: *"Replaying that history takes time... if the Event History were very large, replaying it to get back to doing real work could take so long as to cause unacceptable delays."* Mechanism is analogized to stackless recursion, atomically completes the current run and starts a fresh one under the same Workflow ID with empty history. Three concrete failure classes practitioners report:
1. **State must be re-threaded explicitly**: starting from a clean history means the workflow function must be designed to distinguish (or not need to distinguish) "continuation" from "brand new."
2. **Signal draining is the most dangerous bug class**: *"you will lose any pending Signals when doing Continue-As-New unless you drain and/or process them first."* An independent practitioner writeup calls this out bluntly: *"The most dangerous bug that could happen with continueAsNew is related to the draining signals and thread, and missing any signals during draining will cause data loss."*
3. **Hidden size ceiling on the carryover payload itself**: *"There is a 2MB blob size limit for the snapshot being able to pass through a ContinueAsNew history event"* (i.e). compaction can fail the same way the thing it's compacting away from failed, if the carried-forward state itself grows too large.

Agent-specific prescription, worth adopting almost verbatim: *"Every agent loop must have a maximum iteration count enforced in code, not left to the model's judgment. Use continue-as-new at a defined checkpoint interval to carry forward an essential state with a fresh history."*

### 2.5 Versioning / `GetVersion()` / `patched()`: the lesson to extract without the pain

Problem: a code change that alters which activities run for a *replaying* (in-flight, not-yet-completed) execution breaks determinism against its recorded history: *"the server side Event History would be out of sync."* `GetVersion()` records a permanent marker at the point of divergence so replay can branch deterministically per-execution.

Three concrete complaint classes, all structural rather than incidental:
1. **Branch accumulation is forced, not optional**: *"This can become challenging to manage if you have many long-running Workflows, as you will wind up with many code branches over time"*: deprecated branches can only be deleted once every historical execution using them has completed, which requires manual tracking against retention windows.
2. **"Conceptually complex"** per the community's own tradeoff thread: *"Cognitive burden of needing to understand how both the 'old' and 'new' code paths work"* and *"If used indefinitely on the same workflow definition, can lead to a mess of branching."*
3. **Removal timing is a live footgun, not a hypothetical**: a practitioner asking *"When is it actually safe to remove `getVersion()`?"* initially got it wrong (changed `minVersion` to `1` instead of removing the call entirely), causing live Non-Determinism Errors on in-flight workflows; reliable safe-removal semantics only shipped from SDK 1.28.0 onward.
4. **Agent-specific footgun**: *"The most common agentic versioning mistake is treating prompt changes as safe because they are not code changes, then wrapping the prompt construction in a conditional that produces different activity call patterns... effectively a structural workflow change without a version guard."*

**The lesson to extract, stated plainly**: Temporal's model proves that *if you want full-history-replay recovery*, you inherit permanent, manually-audited version branching in your own code the moment application logic changes between journal-write and journal-replay time: this cost is not a Temporal implementation detail, it is a structural consequence of choosing "replay to reconstruct state" as the recovery mechanism. **A local single-process journal should explicitly decide whether it wants this tradeoff at all**, or should prefer snapshot-based recovery (durable state written directly, journal only for the un-snapshotted tail) precisely to avoid needing permanent replay-compatible version branches in agent logic that changes far more often than Temporal's typical workflow code does.

---

## 3. Append-only log wisdom (EventStoreDB / NATS JetStream / Kafka): Filtered to single-writer-relevant

### 3.1 Stream-per-entity granularity

Greg Young (EventStoreDB's creator), directly: *"One per aggregate. But generally all of these make up one big stream. Then you can repartition them however you want :)"* ([DDD/CQRS group](https://groups.google.com/g/dddcqrs/c/er1-E9nssmg)). The rationale from the same thread: rehydrating one entity needs "a stream per AR for convenient event load/replay," while cross-cutting consumers need "a general stream for all events... regardless of AR", not a conflict, a store should give you both a narrow per-entity replay path and a way to fold across streams. Real EventStoreDB deployments run to "thousands or even millions of different streams" ([Ben Morris](https://www.ben-morris.com/designing-an-event-store-for-scalable-event-sourcing/)).

**Transfer**: key/partition journal entries by entity (conversation, task, tool-invocation-batch) so "replay entity X" only touches X's slice.

### 3.2 Snapshot cadence: no universal number, consistent "don't do it prematurely"

Oskar Dudycz (via Kurrent/EventStoreDB's own blog, the closest to official guidance): *"Snapshots are caching... caching adds complexity to a system: more code to maintain, more logic to understand, and an additional source of failure... it is important to avoid using snapshots prematurely, particularly if they are not actually needed for performance reasons."* And: *"treat it as a last resort when nothing else helps."* Four cadence mechanisms enumerated, deliberately without hard numbers: after each event (rarely worth it), every N events (most pragmatic), on a domain-driven "closing the books" event, or time-based. Companion source reframes the real fix: *"It could be a good idea to consider a different design of the application to keep the streams short(er)"* (i.e). the correct response to slow replay is often finer partitioning, not snapshots bolted on. Kafka's adjacent-but-distinct mechanism, **log compaction**, retains only the latest value per key rather than snapshotting a computed state: *"guarantees that the latest value for each message key is always retained within the log"* ([Confluent docs](https://docs.confluent.io/kafka/design/log_compaction.html)).

### 3.3 Schema evolution / upcasting: the most concretely solved pattern here

Oskar Dudycz, definitional: *"Upcasting is a process of transforming the old JSON schema into the new one, performed on the fly each time the event is read. You can think of it as a pluggable middleware between the deserialization and application logic."* Mechanics: stored events are **never rewritten** (immutability preserved); upcasters chain hop-by-hop (v1→v2→v3), each simple and single-purpose; simple compatible changes (new optional field, new required field with an assumed historical default, renamed field via serializer aliasing) don't need a full upcaster. Performance warning: upcasters run on *every* deserialization of an old event, so must stay cheap (no external calls). Marten's docs frame the underlying philosophy memorably: **"The best strategy is not to change the past data but compensate our mishaps"**: same principle as accounting, append a correcting entry, never edit history ([martendb.io/events/versioning.html](https://martendb.io/events/versioning.html)). Escape hatch for a chain that's gotten too long: a rare, explicit, offline one-time stream migration that rewrites old events into current-version events.

### 3.4 Idempotent consumers

*"Kafka gives you at-least-once delivery by default... your consumer will process some messages more than once. Idempotency is the property that makes re-processing safe."* ([Conduktor](https://www.conduktor.io/blog/building-idempotent-consumers)). Mechanics: a stable idempotency key generated at write time (not derived from offset: offset-based keys break under replay/compaction); the "last applied entry ID" is committed **after** the effect is durable, in the same transaction where possible; on restart, replay from the last durably-recorded position and no-op anything already reflected via the ID-based dedup check, not by re-deriving position. Composite claim: "at-least-once + idempotent consumer = effectively exactly-once."

### 3.5 "Log as database": Kleppmann's thesis and its self-flagged limits

[Turning the database inside-out: Kleppmann](https://martin.kleppmann.com/2015/03/04/turning-the-database-inside-out.html): *"You could call that replication stream a 'transaction log' or an 'event stream'... A materialized view is just a cached subset of the log, and you could rebuild it from the log at any time."* But Kleppmann himself caveats hard: *"I think querying databases will continue to be important... it doesn't make much sense to use materialized views"* for ad-hoc analyst queries, and on cross-view transactions: *"This is a somewhat open research problem."* The counterweight ([InfoWorld, "Don't make Apache Kafka your database"](https://www.infoworld.com/article/2335427/dont-make-apache-kafka-your-database.html)): *"Kafka isn't actually a database... Kafka doesn't have a query language... For most users and use cases, my answer is a firm no."*

**Distilled transfer**: log-as-source-of-truth + views-as-derived-cache is exactly right; "the log itself is the query interface" is not settled wisdom even among the people who invented the pattern. A local journal needs a rebuildable materialized/indexed state alongside the raw log, never query the log directly.

---

## 4. CQRS/event sourcing practitioner retrospectives

### 4.1 Critiques and defenses

**Chris Kiehl, "Event Sourcing is Hard"** ([chriskiehl.com](https://chriskiehl.com/article/event-sourcing-is-hard)), the canonical modern anti-ES essay: *"Event Sourcing is not a 'Move Fast and Break Things' kind of setup when you're a green field application"*, it's *"let's move slow and try not to die."* Core heuristic: *"For which core problem is event sourcing the solution?"*: vague justifications like "auditability" or "flexibility" don't qualify. His alternative for most cases: *"A good ol' fashion history table gets you 80% of the value of a ledger with essentially none of the cost."*

**Udi Dahan** ([Clarified CQRS](https://udidahan.com/2009/12/09/clarified-cqrs/), [When to avoid CQRS](https://udidahan.com/2011/04/22/when-to-avoid-cqrs/)): bluntest defense-of-correct-usage voice: *"Most people using CQRS (and Event Sourcing too) shouldn't have done so."* Scope discipline: *"CQRS should not be your top-level architectural pattern... CQRS, if used at all, would be used inside a service boundary only."* Concurrency litmus test: *"If you've uncovered a scenario where you're wondering 'first-one-wins, or last-one-wins,' that's often a good candidate."*

**Martin Fowler** ([EventSourcing, unfinished draft](https://martinfowler.com/eaaDev/EventSourcing.html)): *"Packaging up every change to an application as an event is an interface style that not everyone is comfortable with, and many find to be awkward. As a result it's not a natural choice and to use it means that you expect to get some form of return."*

### 4.2 What breaks when applied to domains that didn't need it

From the richest HN thread ([id=19072850](https://news.ycombinator.com/item?id=19072850)): a large e-commerce ES/CQRS project burned "tens of millions of dollars... hundreds of staff hired and fired," meant to be loosely coupled but became **"the most coupled system I've ever worked on"** because events lived in shared central repositories. Same thread: CI cost: *"re-runs need to happen pretty often as you change how events are handled. Even in local CI, it eventually took DAYS."* Counter-example that worked: LMAX-style strict hub-and-spokes with a single Business Logic Processor, replaying "a few million messages per second," avoided the fan-out coupling by design.

From ["Mistakes we made adopting event sourcing and how we recovered"](https://news.ycombinator.com/item?id=20324021): the single most common failure mode named directly: *"not separating persisting the event history and persisting a view of the current state."* Teams collapse write model and read model back together, defeating the point.

From ["I feel bad for anyone who got sucked into event sourcing for general purpose apps"](https://news.ycombinator.com/item?id=28702432): *"the technical costs you incur when you attempt to store events instead of tabular data are tremendous"*, with the verdict *"don't do it!"* for general apps.

Composite/illustrative war story (Medium, treat as representative-of-genre not independently verified): *"We used time travel exactly twice. Both times for debugging"* against a 4x infra cost increase ($400/mo → $1,600/mo); ordering bugs (*"OrderItemAdded arrived after OrderShipped due to queue delays"*); debugging sessions of 6 hours pulling events/queues/handlers/read-models by hand.

### 4.3 What makes it survivable

Dudycz's most load-bearing tactical advice: **short-lived aggregates** (*"If our aggregate lives shortly, a day or two, week, then these are easier to manage"*) because short lifetimes let two schema versions coexist during a single deploy window instead of needing permanent N-version support. His framing on where the complexity goes, not whether it disappears: *"the complexity doesn't disappear no matter how hard you try, it's part of any system, you just move it where it hurts the least."* Underappreciated cost of upcasting itself: *"if you make a field mandatory and provide a default value, every part of your system has to deal with that default, even parts that would rather handle nulls their own way"*, upcasting forces a global consistency decision, it isn't free.

Snapshot consensus, consistent with §3.2: *"only introduce them when you have concrete evidence that replaying all events for a subject is causing measurable performance issues"*: a cited rule of thumb was replay time >100ms for hot aggregates, added reactively under production pain, not as a day-one default.

Testing replay correctness is the **thinnest-documented area in the entire practitioner literature**, no single well-known essay was found devoted to it, which is itself a finding: testing discipline for replay correctness gets far less public attention than versioning does, despite the two failure modes compounding. The one concrete statement found: handler purity is the precondition: *"each time you execute the function, it should always yield the same result for the same input... If your handlers aren't pure then each time you go through the events the result will be different, causing potential chaos"* ([sylhare.github.io](https://sylhare.github.io/2022/07/22/Event-sourcing-pitfalls.html)).

Action/state separation as a replay-safety discipline: *"services that perform actions based on events, and the services that rebuild current state based on events"* must stay separate, or replaying events to rebuild state re-triggers real side effects (HN, `UK-AL`). Correlation IDs on every generated event recommended for tracing cascades and catching hidden loops (`hinkley`, same thread).

### 4.4 When it's overkill vs worth it: collected heuristics

1. Dahan's concurrency test: first-one-wins/last-one-wins domain? candidate; non-collaborative domain, skip.
2. Dahan's scope rule: inside one bounded context only, never the system's top-level architecture.
3. Kiehl's "core problem" test: name the *specific* problem, not "flexibility"/"auditability" as buzzwords.
4. HN `vidarh`, apply ES only to entities you actually need to reason about past states of.
5. Dudycz's team-readiness gate ([when_not_to_use_event_sourcing](https://event-driven.io/en/when_not_to_use_event_sourcing/)): a genuine self-critical case where he blocked ES adoption on a distributed, inexperienced team despite domain fit: *"team capability matters more than technical elegance."* Recommended on-ramp: pilot on a low-stakes slice (audit/diagnostics feature) before betting the core domain.
6. HN `evnix`: don't attempt it *"unless you have someone leading the team with years of experience writing such a system."*
7. Audit-trail-as-first-class-product-requirement: ES earns its cost when "what was the state at time X" is a compliance/regulatory *requirement*, not a nice-to-have.
8. Fowler's ROI framing: demand the return (audit, debugging, parallel models) up front, don't back into ES accidentally.
9. HN `mamcx`'s hybrid escape valve: unsure? write to normal relational tables **and** append to a JSONB event column alongside: most of the audit value without full ES commitment.

### 4.5 Tooling-gap diagnosis (why the same mistakes recur)

HN `the_duke`: the ecosystem lacks "automatic schema-based event versioning," "combined event/aggregate stores with ACID guarantees," "event migration tooling," "copy-on-write stream clones for testing": *"such a solution is nowhere to be seen."* Every team hand-rolls the same painful infrastructure from scratch, which is a large share of why the same failure shapes recur across independent companies.

---

## 5. SQLite-as-application-file-format vs JSONL/append-only files

### 5.1 The sqlite.org essay's argument

[SQLite As An Application File Format](https://sqlite.org/appfileformat.html) / [Benefits, condensed](https://sqlite.org/aff_short.html): *"An SQLite database can do everything that a pile-of-files or wrapped pile-of-files format can do, plus much more, and with greater lucidity."* Reliability claim, direct quote: *"Writes to an SQLite database are atomic. They either happen completely or not at all, even during system crashes or power failures... there is no danger of corrupting a document just because the power happened to go out at the same instant."* Reduced-complexity claim: *"No application file I/O code to write and debug... Content can be accessed and updated using concise SQL queries instead of lengthy and error-prone procedural routines."* The essay concedes limits explicitly: *"SQLite is not the perfect application file format for every situation."*

### 5.2 Practitioner-confirmed advantages for local/single-writer

[Appropriate Uses For SQLite](https://sqlite.org/whentouse.html): *"For device-local storage with low writer concurrency and less than a terabyte of content, SQLite is almost always a better solution [than a client/server DB]."* And, framed as a feature for this exact case: *"SQLite will only allow one writer at any instant in time."* HN practitioner `corysama`: atomicity/crash safety under "random hardware shutdown midway through a file write" is exactly what hand-rolled formats get wrong; SQLite provides real transaction support natively where custom formats usually don't.

### 5.3 Downsides

**Sync/network-filesystem corruption risk**: direct primary-source quote, [How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html): *"SQLite depends on the underlying filesystem to do locking as the documentation says it will. But some filesystems contain bugs in their locking logic... This is especially true of network filesystems and NFS in particular."* And: *"Systems that run automatic backups in the background might try to make a backup copy of an SQLite database file while it is in the middle of a transaction. The backup copy then might contain some old and some new content, and thus be corrupt."* This is the well-known "don't put your SQLite file in Dropbox/iCloud" gotcha, directly relevant if an agent's state directory ever lives under a cloud-synced home folder.

**WAL mode multiplies files and complicates backup**: adds `-wal`/`-shm` files; live data can exist only in the WAL: *"Never copy a WAL-mode database by copying just the .db file... either copy all three files while no connections are writing, or use the SQLite backup API"* ([oldmoe.blog](https://oldmoe.blog/2024/04/30/backup-strategies-for-sqlite-in-production/)).

**Non-diffability**: standard `git diff` is useless on a binary SQLite file; git tracks the whole blob per commit rather than the logical delta, so repo size grows with edits regardless of the actual content delta. Tools like `sqldiff`/`sqlite-diffable` exist specifically to compensate: an extra dependency the essay's "no new code needed" framing doesn't account for once diffability matters.

**Schema migration friction**: limited `ALTER TABLE` support historically (no native column drop/rename in older versions) forces create-new/copy/drop-old/rename, tracked via `PRAGMA user_version`.

### 5.4 The case for JSONL: and it is where real coding-agent tools converge, independently

This is the most directly on-point finding in the whole brief: **every major production coding-agent tool surveyed chose JSONL over SQLite for session/turn history**, independently.

- **Claude Code / Claude Agent SDK**: JSONL under `~/.claude/projects/`. *"If the program crashes, only the last unfinished message may be lost. Everything written before that stays intact."* *"Each message is written to disk as soon as it's generated, instead of waiting for the session to finish."* *"New messages are added to the end of the file without reading or rewriting existing data."* *"Session files can be read one line at a time, so the entire file doesn't need to be loaded into memory."* ([Milvus deep-dive](https://milvus.io/blog/why-claude-code-feels-so-stable-a-developers-deep-dive-into-its-local-storage-design.md); [official session-storage docs](https://code.claude.com/docs/en/agent-sdk/session-storage)).
- **OpenAI Codex CLI**: JSONL under `~/.codex/sessions/YYYY/MM/DD/`, with a dedicated `codex-message-history` crate for append/lookup/trim ([openai/codex#21660](https://github.com/openai/codex/issues/21660), [#21278](https://github.com/openai/codex/pull/21278)).
- **OpenClaw**: one JSONL file per channel thread, explicit rationale: *"JSONL is append-only; you lose at most one line on a crash."*
- **pi-coding-agent**: append-only JSONL representing a *tree* (*"each interaction is a node identified by a unique ID and a pointer to its parent"*) proving JSONL isn't limited to linear logs; per-line parent pointers give a DAG without a database ([deepwiki session-management-and-history-tree](https://deepwiki.com/badlogic/pi-mono/4.3-session-management-and-history-tree)).
- **Aider**: deliberately splits a human-readable `.aider.chat.history.md` (diffable/greppable record) from a separate `.aider.llm.history` (what was actually sent to the model, machine replay log): two files serving two different consumers of the same event stream.

The invariant across all five: **one line = one atomic, self-contained event; the file is never rewritten in place; crash blast radius is bounded to the last unflushed line.** None of the major CLI coding agents chose SQLite for turn/session history: an empirical signal specific to the "agent turn/tool-call journal" use case, distinct from the "app file the user opens and queries" use case sqlite.org's essay is actually arguing for.

### 5.5 fsync discipline and torn-write detection

*"The simplest approach uses one `fsync()` call with an append-only data structure, which we usually call a log."* But: *"logs need their own internal integrity protection, so that they can tell whether or not a segment of the log had all of its data flushed to disk"*. A write is not durable until `fsync`/`fdatasync` returns; OS page-cache buffering alone is not durability ([danluu.com/file-consistency](https://danluu.com/file-consistency/); [utcc.utoronto.ca](https://utcc.utoronto.ca/~cks/space/blog/tech/FsyncDurabilityVsIntegrity)).

**Torn writes**: *"in the event of a power failure, this can lead to only a subset of the sectors being written: a torn write"*. A logical write spanning multiple disk sectors can partially land, out of order. Detection: per-sector counters, or (for append logs) per-record checksums plus a trailer, letting a reader distinguish complete-and-valid from torn/partial deterministically. Recovery pattern for line-based logs: *"read until the first error, then stop"* is a deterministic, simple state machine (same pattern Redis AOF uses) ([transactional.blog/2025-torn-writes](https://transactional.blog/blog/2025-torn-writes)). SQLite's own internal mechanism is the same idea one layer down: *"updates to pages cause the full page to be placed into the WAL"* before B-tree merge, so full-page images written before commit, exactly the discipline a JSONL journal should apply per-line.

**Design implication, directly transferable**: (1) one complete JSON object per line, (2) `fsync` after each write or batched on a size/time threshold if per-line durability isn't required, (3) checksum each line or rely on JSON parse failure as the torn-write signal, (4) on load, parse sequentially and truncate at the first unparseable trailing line rather than failing the whole file. This mirrors exactly what Claude Code, Codex, and OpenClaw already do in production.

---

## 6. Cross-Cutting Answers

### A. Snapshot cadence

No system in this survey prescribes a universal number. The convergent wisdom across EventStoreDB (Dudycz/Kurrent), Kafka's log-compaction design, and the CQRS practitioner literature is identical in shape: **snapshotting is a reactive optimization, not a day-one feature.** Add it only after profiling shows replay time is a real problem for a specific hot path (cited rule of thumb: replay >100ms for a hot aggregate), and prefer the *first* fix to be finer partitioning (shorter-lived streams/entities) over bolting a snapshot mechanism onto a stream that grew too large by design. Temporal's `continue-as-new` is the sharpest illustration of *when* a trigger becomes mandatory rather than optional: hard limits (51,200 events / 50MB, warn at 10,240/10MB) exist because unbounded replay time becomes an operational failure, not merely a performance nuisance: worth mirroring as an explicit numeric ceiling in a local journal (compact well before any such ceiling, not reactively at it).

### B. Schema evolution: pattern to adopt

Two battle-tested, complementary patterns, both converging from EventStoreDB/Marten-world and Temporal's versioning pain from the opposite direction:

1. **Upcasting on read** (Dudycz/Marten): stored records are immutable; a small ordered chain of pure functions (v1→v2→v3) transforms old-shape records to current shape at deserialization time, before application code ever sees them. New optional fields just deserialize as null; new required fields get an explicit assumed-historical default; renames handled via field-name aliasing. Never rewrite the file in place except as a rare, explicit, offline migration.
2. **Version-tag every record, keep entities short-lived where possible**: Dudycz's single most load-bearing tactical point: short aggregate lifetimes let two schema versions coexist briefly during a deploy window instead of requiring permanent N-version support forever. Temporal's `GetVersion()` proves the alternative (permanent, code-embedded version branches, manually audited for safe removal) is real but costly: a local agent journal should prefer upcasting-on-read specifically *because* it avoids Temporal's structural cost (branches embedded in live logic, unsafe-to-remove until every old execution using them has finished).

### C. Single-writer simplification

What vanishes: cross-writer conflict resolution (no concurrent-append races to arbitrate), consumer-group offset coordination, network-partition/multi-region consistency concerns, and the entire "who owns this stream right now" negotiation that Kafka partitioning and EventStoreDB's optimistic-concurrency-on-append exist to solve. What must still be done, unchanged: **fsync discipline** (a write isn't durable until fsync returns, page-cache buffering isn't enough: §5.5) and **torn-write detection** (a crash mid-write can partially land a record; per-line checksums or JSON-parse-failure-as-signal plus "read until first error, then stop" recovery are still required even with exactly one writer, because the failure mode is a *hardware/OS* boundary, not a *concurrency* boundary). The idempotent-consumer discipline (§3.4) also survives in reduced form: even a single writer/reader needs "commit last-applied-ID after the effect is durable, not before" so a crash-restart replay doesn't double-apply the tail entry.

### D. Projection rebuild

The literature is more prescriptive on *why* than *how*: Kleppmann's framing (§3.5), *"A materialized view is just a cached subset of the log, and you could rebuild it from the log at any time"*, establishes the invariant (projection code changing means throw away the derived state and replay), but the practical failure mode when replay is too slow is exactly what §3.2/§4.3/§A converge on: teams that didn't separate event history from current-state views hit this hardest (§4.2, HN `codebeaker`'s diagnosis), and the fix is architectural: factor state as derived/rebuildable-on-demand from day one (Ports-and-Adapters pattern cited, one case took "about one hour" to refactor *once* separation was correct) rather than treating current-state as a first-class stored thing that happens to also have a log. When replay actually is too slow at rebuild time, the only two levers found in this survey are (1) snapshots as a cache (§A) and (2) finer stream partitioning so a given rebuild only needs to replay the relevant slice (§3.1). There is no third lever in the literature; systems that needed a third one built ad hoc claim-check/archival tooling (Temporal's S3-reference pattern, §2.3) rather than finding one that already existed.

### E. Steal-list: top 5 transferable rules for a local agent journal

1. **Journal granularity must be below "turn," at "tool-call/action."** Source: Temporal-vs-LangGraph practitioner comparison (§2.2): *"checkpointers only save state between nodes. They do not save state inside a node... all that intermediate work is gone."* A turn-level journal reproduces LangGraph's exact durability gap that Temporal-adjacent practitioners explicitly complain about.
2. **Upcast on read, never rewrite the log in place; keep entities/sessions short-lived where possible to bound how many schema versions must coexist.** Source: Oskar Dudycz / Marten (§3.3, §4.3): *"The best strategy is not to change the past data but compensate our mishaps."* This is cheaper than Temporal's `GetVersion()` branch-forever model (§2.5) precisely because it avoids permanent code-embedded version forks.
3. **Snapshot reactively, not proactively: trigger on measured replay-time pain (~100ms cited threshold) or an explicit hard ceiling (Temporal's 50MB/51,200-event pattern), and prefer finer partitioning as the first fix.** Source: Kurrent/Dudycz (§3.2, §A) + Temporal's `continue-as-new` numbers (§2.3) as the "what happens if you don't" cautionary anchor.
4. **One JSON object per line, fsync-then-append, parse-sequentially-and-truncate-at-first-corruption on load.** Source: convergent, independent design choice across Claude Code, Codex, OpenClaw, and pi-coding-agent (§5.4), backed by the general torn-write recovery pattern (§5.5): *"read until the first error, then stop... recovery deterministic."* This is the single most directly-actionable finding: it isn't theory, it's what the adjacent production tools already do.
5. **Separate the log (source of truth) from the materialized/queryable state (derived, rebuildable, never itself authoritative) from day one: this is the fix for the single most commonly cited CQRS/ES failure mode.** Source: Kleppmann (§3.5) + the HN "mistakes we made" thread's root-cause diagnosis (§4.2, §D): *"not separating persisting the event history and persisting a view of the current state"* was independently named as the most common failure. Getting this right from day one is why LangGraph's checkpoint-plus-state model half-works and why it's cheap to fix later if you do separate them (the cited refactor took "about one hour" once the architecture was already factored correctly).
