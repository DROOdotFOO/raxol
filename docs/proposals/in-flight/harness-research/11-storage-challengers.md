# Challengers' Storage — OpenHands, opencode, goose, Aider, Cline/Roo-Code

Forum-first sourcing: primary source code (fetched via GitHub raw/API), GitHub
issues/PRs/discussions, official docs, secondary blogs/HN/Reddit where they add
signal. Companion to `10-leaders-storage.md` (Claude Code, Codex, Gemini CLI,
grok CLI) in the `harness-cohort-research.md` round. Every claim below is
sourced inline; where a repo/org moved during the research window (several
did — this cohort ages fast), the move is flagged before the findings so
citations don't silently rot.

---

## 1. OpenHands — EventStream / EventLog (PRIORITY)

**Repo-move caveat first:** the org renamed `All-Hands-AI` → `OpenHands`, and
the monolithic `OpenHands/OpenHands` repo split. The V0 architecture
(`openhands/events/`, `openhands/controller/state/state.py`) that most
existing writeups describe now survives only as legacy/app_server code; the
current agent core lives in a separate SDK repo,
[`OpenHands/software-agent-sdk`](https://github.com/OpenHands/software-agent-sdk).
Findings below are dated to this split so V0 and current-gen aren't conflated.

### Schema/layout

Events are **immutable Pydantic models** (`frozen=True, extra="forbid"`),
[`openhands-sdk/openhands/sdk/event/base.py`](https://github.com/OpenHands/software-agent-sdk/blob/main/openhands-sdk/openhands/sdk/event/base.py):

```python
class Event(DiscriminatedUnionMixin, ABC):
    id: EventID = Field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: str = Field(default_factory=lambda: datetime.now().isoformat())
    source: SourceType
    parent_id: EventID | None = Field(default=None,
        description="Parent event id in the conversation tree...")
```

Real Action/Observation split, not a flat chat log: `ActionEvent` wraps a
tool-specific `Action` schema object plus `thought`/`reasoning_content`/
`llm_response_id` (for reconstructing parallel tool calls); `ObservationEvent`
carries `action_id` explicitly linking back to its trigger. **Events form a
tree, not a line** — `parent_id` supports `fork()`/branch navigation, a
detail most secondary writeups miss because they describe an older linear
design.

On-disk: **one JSON file per event**
([`persistence_const.py`](https://github.com/OpenHands/software-agent-sdk/blob/main/openhands-sdk/openhands/sdk/conversation/persistence_const.py)):
`{persistence_dir}/{conversation_id}/events/event-{idx:05d}-{event_id}.json`
plus a sibling `base_state.json`. Per the docs
([docs.openhands.dev/sdk/guides/convo-persistence](https://docs.openhands.dev/sdk/guides/convo-persistence)):
*"Events are appended incrementally (one file per event), while base state is
overwritten on each change... This design optimizes for fast event
appends...atomic state updates...efficient restoration"* — and this per-file
layout is itself a successor to an older monolithic `trajectory.json`.

**`FileStore`** is an explicit abstract interface (`write`/`read`/`list`/
`delete`/`exists`/`get_absolute_path`/`lock` — locking is first-class, not
bolted on). SDK ships only `LocalFileStore` (flock-based) and
`InMemoryFileStore`; **S3/GCS backends were moved out of the SDK** into the
separate self-hosted/SaaS server (`openhands/app_server/file_store/{s3,google_cloud}.py`),
selected via `[core] file_store = "local" | "memory" | "s3" | "google_cloud"`.
Self-documented limitation in `EventLog`'s own docstring: *"For LocalFileStore,
file locking via flock() does NOT work reliably on NFS mounts or network
filesystems. Users deploying with shared storage should use alternative
coordination mechanisms."*

### Replay/restore semantics — the central finding

`base_state.json` is explicitly **not** a working-memory snapshot — its own
docstring: *"Persist base state snapshot (no events; events are
file-backed)."* It holds config, cost/usage stats, secrets (encrypted or
redacted), tags, and — critically — `leaf_event_id` (tree HEAD pointer). It
never contains the reconstructed LLM-context ("View").

On cold load, `ConversationState.create()` deserializes `base_state.json`,
re-attaches `EventLog`, then calls `rebuild_view()`, whose docstring states:
*"Cold-load: rebuild the cached view with full property enforcement —
persisted events may come from an older code version or be corrupted."*
`rebuild_view()` calls `View.from_events(path_to_root(leaf))` — **the LLM's
working memory is reconstructed by replaying the active branch of the
on-disk event log, not restored from a serialized snapshot.** Confirmed
independently by bug-fix history: [PR #5946](https://github.com/OpenHands/OpenHands/pull/5946)
("Fix history loading when state was corrupt/non-existent") — *"the history is
initialized from the event stream, but that depended on whether there was a
valid State restored. That doesn't make a lot of sense... this PR fixes
[that] to always load the event stream, regardless of State."* The maintainers
literally fixed a bug where the snapshot's absence was wrongly gating replay
— direct evidence the log, not the snapshot, is authoritative.

**Steady-state is not full replay per step** — a deliberate, documented
optimization, not an architectural compromise. `view` property docstring:
*"A linear append replays only the new tail — O(k)... a branch switch
rebuilds once, O(n)."* Full replay is reserved for cold load / branch switch /
explicit error recovery; every other append is an incremental tail-update to
a cached view. This exact tradeoff traces to
[Issue #3053](https://github.com/OpenHands/software-agent-sdk/issues/3053)
("Make View construction incremental," closed): *"`View.from_events()` is
called on every agent step... every step is O(n) in total events regardless
of how many new events were added."* Shipped, not aspirational — confirmed
against current `state.py`.

Crash recovery also runs off the replayed log directly:
`get_unmatched_actions()` scans the active branch in reverse for `ActionEvent`s
lacking a matching `ObservationEvent`, with a note that error events are
matched by `tool_call_id` specifically *"for crash recovery scenarios where an
error event is emitted after a server restart."* Restore is spec'd as a
behavioral contract in `tests/cross/test_conversation_restore_behavior.py`:
*"Restore MUST fail if the agent toolset changes (tools are part of the
system prompt). Restore MUST succeed if other agent configuration changes:
LLM, condenser, skills."*

### LOVE — rationale, in the maintainers' own words

The founding architectural bet, [PR #2709](https://github.com/OpenHands/OpenHands/pull/2709)
(2024): *"It proposes an implementation of the event-stream based architecture
for agent history, which: uses directly the event stream for history — it
doesn't save its own copies of events (in `state.history`) — event stream is
*the* source of truth."*

Perf pain identified and fixed transparently ([#3053](https://github.com/OpenHands/software-agent-sdk/issues/3053),
above). Separation of concerns explicitly reasoned for multi-worker SaaS,
[PR #7592](https://github.com/OpenHands/OpenHands/pull/7592): *"The event
stream is designed to coordinate read/write access... this is overkill for
the return values from the conversation manager... This extra flexibility is
required in the SAAS env where clustering is in play, and the conversation may
be running remotely in a different worker/process."* Read-perf regression
caught with hard numbers, [PR #7667](https://github.com/OpenHands/OpenHands/pull/7667):
*"if you are using network attached storage where each file read can take
~20ms... reading an event stream with 500 events goes from taking ~10 seconds
down to ~400ms"* after adding a 25-event paged cache — fixed additively, not
by rewriting the one-file-per-event format.

**Quantified numbers** — OpenHands ships a dedicated
[event-sourcing benchmark suite](https://github.com/OpenHands/software-agent-sdk/tree/main/scripts/event_sourcing_benchmarks)
replaying 433 real SWE-Bench Verified conversations (39,870 events) through
production I/O:

| Metric | Result |
|---|---|
| Median single-event persist latency | 0.166ms |
| Full replay, median conversation (82 events) | ~5ms |
| Full replay, 1,500 events (synthetic) | 48.06ms |
| Crash recovery at 1,500 events | 90.26ms |
| Storage composition | ObservationEvents = 47.8% of events, 78.0% of bytes |

### HATE

Full O(n) view rebuild per step before the #3053 fix. NFS locking explicitly
broken (quoted above, no workaround shipped). Per-file NAS reads catastrophic
before paging (~10s/500 events). **Corrupted event files kill the whole
session with no isolation**: [Issue #8809](https://github.com/OpenHands/OpenHands/issues/8809)
— a post-crash truncated event file threw `JSONDecodeError: Expecting value:
line 1 column 1 (char 0)`, cascading through `_init_history` and killing
session start entirely: *"My pc crashed which caused the runtime i was
working with to be corrupted and unable to be loaded."* One bad file, total
loss, no per-user recovery path offered. Secret-redaction corrupted unrelated
metadata, [PR #9793](https://github.com/OpenHands/OpenHands/pull/9793):
*"secret replacement in event streams was corrupting timestamps, causing
'Invalid isoformat string' errors"* — naive substring-matching hit `timestamp`/
`id`/`source` fields, not just user content. Session-join races could drop
events, [PR #8818](https://github.com/OpenHands/OpenHands/pull/8818): *"new
events that arrive during the replay of the event stream for a new connection
might not be sent to the client."* Standing regression test
`test_event_loss_repro.py` documents a live WebSocket delivery race
(*"events can be lost when the WebSocket callback is delayed and run()
returns before events are delivered"*) reproducing a real CI failure from
PR #1829.

### HORROR

**[Issue #13583](https://github.com/OpenHands/OpenHands/issues/13583)** —
unsafe **pickle deserialization RCE** in the *old* (V0) state-restore path,
found by automated security scan: *"`pickle.loads()` is used to restore agent
state and conversation metrics from `FileStore` without any integrity
verification... In deployments using S3, GCS, or webhook-based file stores, a
crafted pickle payload in the state file could achieve remote code
execution."* Exact locus cited: `openhands/controller/state/state.py:167,175`
— `pickled = base64.b64decode(encoded); state = pickle.loads(pickled)  # No
validation`. *"A misconfigured storage bucket with write access would allow
an attacker to replace the state file with a malicious pickle payload. The
payload executes on the next `restore_from_session()` call — no user
interaction required."* This falsifies a naive "OpenHands is clean event
sourcing everywhere" read of the V0 monolith specifically — one half of
"state" was pickle, the other half was JSON events, and only the JSON half
was actually source-of-truth-safe. The current SDK's `ConversationState` uses
pure Pydantic JSON, no pickle — designed out in the rewrite, though no PR
explicitly cites #13583 as the reason.

**[Issue #4057](https://github.com/OpenHands/software-agent-sdk/issues/4057)**
— schema-migration (flat log → parent-pointer tree) silently orphaned history
across a version boundary: *"Resuming a conversation created by an older
agent-server (pre event-tree, e.g. 1.29.3) under 1.33.0 can make the agent
lose all prior history: it rebuilds context from only the events written
after resume, and behaves as if the conversation is brand-new."* Concretely:
*"Agent's reachable branch = 165 events (2 user messages); the other 5,566
events are on disk but unreachable by `path_to_root`."* Nothing deleted — a
broken pointer, not data loss — but a legacy-events-have-no-`parent_id`
fallback interacting with a trailing artifact caused `_resolve_active_leaf()`
to stamp a false root, permanently severing the walk from the older tail.

**[Issue #6148](https://github.com/OpenHands/OpenHands/issues/6148)** — *"OH
fails to join existing conversations after an unclean exit"*, root-caused to
using event-stream-handle-existence as a (wrong) proxy for session health.

### DEMAND

[PR #2509](https://github.com/OpenHands/software-agent-sdk/pull/2509) —
pluggable `FileStore` injection into `ConversationState`, because *"users
building platforms on top of the SDK... had no supported path"* to swap in
S3/DB-backed stores. [PR #3562](https://github.com/OpenHands/software-agent-sdk/pull/3562)
— export/import of ACP CLI session blobs (Codex/Claude Code sessions running
inside OpenHands sandboxes) so a fresh sandbox could replay a nested CLI's
real session — **then reverted three weeks later**,
[PR #3576](https://github.com/OpenHands/software-agent-sdk/pull/3576): *"we
don't need this complicated plumbing because when sandbox is wiped,
conversation is archived and should not be available to start again
anymore... ACP should not have stronger resume semantics than the regular
OpenHands agent."* A rare, clean case of a persistence feature built
competently (symlink-safe, tested end-to-end) and then killed for *product*
reasons, not technical failure. Storage-growth asymmetry flagged as an
implicit future-work target by the benchmark README itself: ObservationEvents
are 48% of events but 78% of bytes.

### Verdict

**Genuine event-sourcing for the core state-reconstruction path** — replay
of an append-only, immutable, tree-structured event log is the sole
mechanism by which LLM working memory is rebuilt; the adjacent
`base_state.json` is bookkeeping (config + HEAD pointer), never a
snapshot that substitutes for replay. The single steady-state exception
(incremental tail-append instead of full per-step replay) is memoization of
a pure function over the log, not a competing source of truth. Caveats: the
*previous* generation had a real pickle-RCE wart running alongside the JSON
events (#13583); NFS/shared-storage locking is explicitly unsafe; at least
one WebSocket event-loss race needed hardening as late as PR #1829; and a
tree-schema migration caused real (if recoverable) silent history loss on
upgrade (#4057) — exactly the failure mode this brief set out to check for.
Net: the strongest verified prior art in the cohort for "replay reconstructs
truth," with concrete, load-tested numbers (sub-50ms replay at 1,500 events)
backing the design.

---

## 2. opencode

**Repo-move caveat:** `github.com/sst/opencode` now redirects to
`github.com/anomalyco/opencode` (confirmed via `gh api`, not search summary
— 186k stars, 23.3k forks carried over). All URLs below use the canonical
path; old `sst/opencode/issues/N` links resolve to the same numbers.

### Schema/layout — three storage generations in ~10 months

**Current: SQLite via Drizzle ORM.**
[`packages/core/src/database/database.ts`](https://github.com/anomalyco/opencode/blob/main/packages/core/src/database/database.ts):
DB at `~/.local/share/opencode/opencode.db` (channel-suffixed for
beta/prod). PRAGMAs: `journal_mode = WAL`, `synchronous = NORMAL` (not
`FULL` — the direct cause of a durability HORROR below), `busy_timeout =
5000`, `cache_size = -64000`, `foreign_keys = ON`.

Schema (Drizzle `sqliteTable`, `packages/core/src/session/sql.ts`):
`session` (id, project_id FK cascade, **parent_id self-referential** for
subagent sessions, title, cost, token accounting incl. cache read/write,
model config JSON, `time_compacting`, `time_archived`), `message`/`part`
(FK cascade, JSON blob payloads), `session_message` (id, session_id,
**seq** unique-per-session, data JSON — an event-sourced projection layer),
`session_input` (admission-control inbox: `admitted_seq`/`promoted_seq`
distinct from committed history), `session_context_epoch` (baseline +
snapshot JSON — a compaction checkpoint table). Plus a genuine event-store
layer, [`event/sql.ts`](https://github.com/anomalyco/opencode/blob/main/packages/core/src/event/sql.ts):
`EventSequenceTable`(aggregate_id, seq, owner_id) + `EventTable`(id,
aggregate_id FK, seq, type, data JSON) — textbook event-store shape, added
~June 2026 per migration filenames.

**So the trajectory is: flat JSON files → relational SQLite/Drizzle →
event-sourced projection on top of the same SQLite tables**, over roughly
six months. The legacy JSON layer
([`packages/opencode/src/storage/storage.ts`](https://github.com/anomalyco/opencode/blob/main/packages/opencode/src/storage/storage.ts))
still ships as a migration source (`~/.local/share/opencode/storage/
session|message|part/...json`), gated by a versioned `migration` marker
file — and each of the three storage generations produced its *own* class
of "data present but invisible" incident (below).

Share table: `SessionShareTable`(session_id PK FK cascade, id, secret, url)
— simple, but see DEMAND for the redaction gap.

### REST API / resume

[opencode.ai/docs/server](https://opencode.ai/docs/server/): `opencode
serve` exposes an OpenAPI 3.1 spec at `GET /doc`; TUI is one client among
several (desktop app, IDE extensions, CI). Endpoints: `GET/POST /session`,
`GET/PATCH/DELETE /session/:id`, `GET /session/:id/children`, `POST
/session/:id/fork`, `POST /session/:id/revert`, `POST /session/:id/message`
(sync) / `prompt_async` (204 fire-and-forget), `GET /global/event` and `GET
/event` (SSE). CLI resume: `--continue/-c`, `--session/-s <id>`, `--fork`.

### LOVE

Hacker News [id=46523178](https://news.ycombinator.com/item?id=46523178):
*"OpenCode is actually client server architecture... also super good at
letting you open an old session & carry on."* The
[Composio comparison](https://composio.dev/content/claude-code-vs-open-code)
crystallizes the pitch versus Claude Code specifically: *"stores the raw
history in SQLite, so pruning doesn't lose data. You can get it back... it
stores subagents as real child sessions in SQLite, with their own messages,
permissions, and snapshots that you can inspect after the fact, rather than
hiding the delegation within a prompt."* Confirmed independently by schema
(`session.parent_id` self-reference, cascade-deleted child rows).

### HATE

HN, same thread: *"OpenCode has been extremely unreliable. I opened a PR
about one of the simplest tools ever: `ls`, and they haven't fixed it
yet."* [#4557](https://github.com/anomalyco/opencode/issues/4557) — no way
to discover a session ID to resume from `/sessions`'s non-unique
name+timestamp display. [#35890](https://github.com/anomalyco/opencode/issues/35890)
(open 3+ months, "15+ duplicates," v1.17.15) — desktop silently loads
cross-project data after switching projects, traced across **six separate
storage layers simultaneously** (SQLite rows + three Electron `.dat` files
+ a sidecar JSON): *"This is a data-integrity defect, not a UX
papercut... in #29714, the agent read and modified files in a different
repository than the one the user selected."* One user did *"58 base64 path
replacements, merged workspace `.dat` files, cleared every Electron cache,
and edited the SQLite DB — Desktop still loaded the old project and
503'd."*

### DEMAND

**Share feature has zero redaction anywhere in the codebase** (confirmed by
exhaustive grep for `redact` — only hit is a test-mock utility and a
separate CLI `export --sanitize` flag not wired to `/share`).
[Issue #17188](https://github.com/anomalyco/opencode/issues/17188)
(2026-03-12, open): *"The current default... allows any user to upload
their full session — including file contents, terminal output, and
environment context — to external servers (opncd.ai) with a single /share
command, without any confirmation dialog... There is no privacy policy
(opncd.ai/privacy → 404), no terms of service... The only written statement
is a single line in the docs: 'data persists until you unshare.'"* A
third-party plugin (`opencode-vibeguard`) exists specifically to fill this
gap. [#32713](https://github.com/anomalyco/opencode/issues/32713)
(2026-06-17) — crash-recovery/autosave request, direct consequence of
`synchronous = NORMAL`: *"the SQLite DB and localized session JSONs fall
out of sync on sudden exit, the next launch results in a completely blank
session slate."* Requester built a hand-rolled Python daemon polling every
30s as a workaround. [#33321](https://github.com/anomalyco/opencode/issues/33321)
— explicit ask to *document* whether concurrent headless workers against
one SQLite file are supported at all (they currently aren't reliably; see
HORROR).

### HORROR

**Each of the three storage-format hops produced its own "data present but
invisible" incident class:**

1. **[#13654](https://github.com/anomalyco/opencode/issues/13654)** (JSON→SQLite
migration gate skipped): *"the one-time JSON→SQLite session migration gate
checks whether opencode.db exists to decide whether to run. But opencode.db
can exist from earlier schema migrations that predate the session migration
commit. For any user who updated incrementally... the migration is silently
skipped and all pre-existing JSON session files are permanently orphaned."*
188 orphaned JSON files confirmed via `find`. Root cause pinpointed to
`if (!(await Bun.file(marker).exists()))` — file-existence as a bad proxy
for migration-completion.

2. **[#33447](https://github.com/anomalyco/opencode/issues/33447)**
(event-sourcing migration, June 2026): *"sessions created before the
migration no longer appear in the session picker... conversation data is
still present... but has zero rows in the event table... 2,503 rows in
message, 9,476 rows in part, but only 12 rows in session_message."*

3. **[#35750](https://github.com/anomalyco/opencode/issues/35750)** +
**[#36222](https://github.com/anomalyco/opencode/issues/36222)** (a new
`path` filter column, unbackfilled, July 2026): *"Sessions created before the
upgrade have path = '' / NULL... those sessions no longer match the
picker's filter and disappear... though no data is actually deleted."*
Workaround: users hand-running `UPDATE session SET path = ...` against the
vendor's own schema. A bot comment clusters this with two more independent
reports (#35690, #36064) filed within the same week — a systemic pattern,
not a one-off.

Concurrency/platform incidents: **[#14970](https://github.com/anomalyco/opencode/issues/14970)**
— NFS: *"database disk image is malformed... SQLite relies on POSIX fcntl()
advisory locking, which is notoriously unreliable on NFS. The WAL -shm file
uses shared memory mappings that don't work correctly over network
filesystems."* **[#30157](https://github.com/anomalyco/opencode/issues/30157)**
— `SQLITE_CORRUPT` on stable macOS, no NFS involved, total app-access loss.
**[#33320](https://github.com/anomalyco/opencode/issues/33320)** — concurrent
headless `opencode run` workers hit unhandled `database is locked`, worker
exits silently before reading its prompt. **[#35505](https://github.com/anomalyco/opencode/issues/35505)**
— hard power-off (durability trade of `synchronous=NORMAL` made concrete):
active sessions never committed, *"no corresponding rows in the message or
session_message tables... suggesting the sessions may never have been
committed before the crash."* **[#36902](https://github.com/anomalyco/opencode/issues/36902)**
— cross-platform client/server (the architecture's headline feature)
poisons the DB: raw Windows paths from a Windows Desktop client hit a
WSL-hosted server's no-op path-normalizer, get written into SQLite, and
crash every subsequent boot in a retry loop that **pegs WSL at 100% CPU**.

---

## 3. goose (Block → AAIF)

**Repo-move caveat:** `block/goose` now redirects to `aaif-goose/goose` —
Block donated goose to the Linux Foundation's Agentic AI Foundation in
2026 (51k stars, 5.7k forks carried over). Docs moved to
[goose-docs.ai](https://goose-docs.ai/).

### Schema/layout — a genuine two-act migration

**Act 1 (through ~v1.10.0, Oct 2025): one `.jsonl` file per session, no
locking, no atomicity.** **Act 2 (current): SQLite via `sqlx`**, WAL mode,
`.foreign_keys(true)` (a *recent* addition — was absent for most of the
DB's life, see HORROR), `.busy_timeout(30s)`. DB at
`~/.local/share/goose/sessions/sessions.db`, schema version **15** (from
source, `crates/goose/src/session/session_manager.rs`). The entire
documented rationale for the migration, verbatim, from
[PR #4648](https://github.com/aaif-goose/goose/pull/4648): *"## Use SQLite
for Session manager / Don't implement your own database"* — no design doc,
no tradeoff analysis exists anywhere (checked Block's engineering blog:
nothing on session storage specifically).

Schema: `sessions` (id, name, session_type: User|Scheduled|SubAgent|Hidden|
Terminal|Gateway|Acp, working_dir, token/cost accounting incl. cache
read/write both per-turn and cumulative, `extension_data` JSON, `recipe_json`,
`provider_name`, `model_config_json`, `parent_session_id`), `messages`
(FK→sessions, content_json), `usage_ledger` (FK cascade — correctly uses
`ON DELETE CASCADE` from day one, a direct lesson learned from the FK bug
below). Session IDs: `YYYYMMDD_N`, allocated **atomically inside a single
`INSERT ... RETURNING`** with a correlated `MAX(...)` subquery under `BEGIN
IMMEDIATE` — a clean pattern avoiding a whole TOCTOU class, though it still
hit a WAL-visibility race (below). Migration chain v1→v15 is append-only/
forward-only, no down-migrations, read directly out of source.

Unusual feature: **Nostr-relay session sharing**
(`crates/goose/src/session/nostr_share.rs`, confirmed real by reading
source directly) — publishes an encrypted (NIP-44) session as a Nostr
event to public relays (`relay.damus.io`, `nos.lol`, etc.), returns a
`goose://sessions/nostr` deeplink with a decryption key. A genuinely
unusual choice — a decentralized relay network for session sharing — not
documented anywhere outside the source.

### LOVE

**`goose db backup/restore` tooling**
([PR #5490](https://github.com/aaif-goose/goose/pull/5490)): *"adds a
database management API that enables users to backup, restore, and monitor
their session database, along with automatic safety backups before schema
migrations. This protects users from data loss during upgrades."*
Auto-backups named `pre_migration_v{old}_to_v{new}_{timestamp}.db`,
validated via `PRAGMA quick_check`. The standout defensive-engineering
artifact in this whole cohort — a mature response to the JSONL-corruption
era, absent at that earlier stage. `session --edit` opens the conversation
as **YAML** for manual trim/rewrite before resuming — direct, first-class
session surgery. Forking answered a feature request outright:
[#6829](https://github.com/aaif-goose/goose/issues/6829) ("time travel
debug"), maintainer reply in full: *"we have this! it's called forking and
you can do it from the cli with `--resume --fork`."*

### HATE / DEMAND

Live and unresolved: [#10480](https://github.com/aaif-goose/goose/issues/10480)
(2026-07-15) — DB fully healthy (`integrity_check → ok`, schema v15) yet
Desktop UI shows "Failed to load sessions" — a pure Electron↔backend
WebSocket desync bug sitting on top of an otherwise-fine SQLite layer. A
frustrated aside on a *recurring* closed issue, 2026-07-14: *"Why do you
guys need SQL at all? What about plain text?"* `--name` semantics needed a
full redesign after the SQLite migration removed custom session IDs
([#5044](https://github.com/aaif-goose/goose/issues/5044)) — maintainer
wpfleger96: *"it's a little confusing what the relationship between a
session's ID, name, and description is supposed to be... since the SQLite
DB migration session IDs are auto generated, which breaks that previous
behavior."*

### HORROR

**Era 1 (JSONL, pre-migration):** [#1946](https://github.com/aaif-goose/goose/issues/1946)
(2025-03-31) — malformed JSONL froze the whole session-loading UI.
[#2529](https://github.com/aaif-goose/goose/issues/2529) (2025-05-13) —
*"session corruption with bad session jsonl file still happening
occasionally... possibly file writing related,"* traced to a truncated
last line. [PR #3588](https://github.com/aaif-goose/goose/pull/3588)
(2025-07-22): *"the session list endpoint was failing completely when
encountering corrupted session files... `filter_map` with early returns...
caused the entire endpoint to fail when session metadata couldn't be
read"* — one bad file, no isolation, took the whole list down. This
directly motivated the SQLite move.

**Era 2 (SQLite):** [#7624](https://github.com/aaif-goose/goose/issues/7624)
(2026-03-03) — connection-pool leak, `SQLITE_BUSY (code 5)`, `lsof` showed
22+ FDs accumulating, worsened by sub-agent sessions each opening their
own connection: *"VACUUM: Temporarily reduces DB size but error returns
within minutes... WAL checkpoint (TRUNCATE): cleans WAL file but error
persists."* **The only reliable fix was restarting the app.**
[#8638](https://github.com/aaif-goose/goose/issues/8638) (2026-04-18) — a
schema migration (v10) added a `thread_id` column and `threads` table
**without backfilling it**, and startup code assumed every session had a
matching thread row: `panicked at row.rs:43: index out of bounds` /
`Error: no rows returned by a query that expected to return at least one
row`. `SELECT COUNT(*) FROM sessions WHERE thread_id IS NULL` → 52 (all
orphaned). Workaround required moving the entire DB aside, losing all
session history from the UI. **Recurred on v1.43.0, 2026-07-14 — three
days before this research** — same panic trace. [#9120](https://github.com/aaif-goose/goose/issues/9120)
— FK enforcement was **off by default and never turned on** for the whole
life of the connection pool: *"SQLite foreign key enforcement is off by
default and must be enabled per-connection via `PRAGMA foreign_keys =
ON`. The connection pool in SessionStorage never sets this pragma, so all
REFERENCES constraints in the schema are declared but never enforced,"*
orphaning `thread_messages` on thread delete. [PR #5793](https://github.com/aaif-goose/goose/pull/5793)
— WAL read-after-write visibility race: `create_session()` immediately
followed by `get_session()` could see a stale pre-commit WAL snapshot
absent an explicit commit; verified via a stress test run "a few thousand
times." [#7601](https://github.com/aaif-goose/goose/issues/7601)
(2026-03-02) — with 4-5 desktop windows open during an app upgrade, *"a
user reported losing an entire chat session... Two sessions got 'mixed
up' - one was completely overwritten/lost."* Root cause stacked four
layers deep (unpersisted in-memory cache, session-reuse heuristic,
async-naming race, client/server refactor edge case).

---

## 4. Aider

### Schema/layout — deliberately no machine format

**`.aider.chat.history.md`**: plain markdown, append-only, from
[`aider/io.py`](https://github.com/paul-gauthier/aider/blob/main/aider/io.py).
Session-start header `# aider chat started at {timestamp}`; user turns
prefixed `####` (a level-4 heading, not blockquote — [contested by
Issue #916](https://github.com/paul-gauthier/aider/issues/916): *"Headings
are typically used for structuring document content, not for representing
user inputs"* — unresolved, code unchanged years later); assistant turns
appended raw, unprefixed. Confirmed against a live example file
([johns10/generaite_todo_app_1](https://github.com/johns10/generaite_todo_app_1/blob/main/.aider.chat.history.md)).
No embedded machine-readable diff object — whatever markdown the model
emitted is what's stored. `.aider.input.history` is a separate
readline/Ctrl-R buffer only (`prompt_toolkit` `FileHistory`), no
conversation content. `.aider.tags.cache.v{N}/` is a `diskcache`/SQLite
cache for repo-map tag extraction (see HORROR — this is where the
SQLite-on-network-mount failure actually lives, not in the chat history).
No `.aider.chat.history.json` exists anywhere — confirmed by direct
search of the codebase.

**Critically: nothing is replayed by default.** A fresh `aider` invocation
starts with empty context; the markdown file is purely write-only unless
`--restore-chat-history` is passed, in which case `base_coder.py`
re-parses the **entire file** back into role-tagged messages — no
incremental cursor, no checkpoint offset, no session-boundary marker
beyond the timestamp headers.

### LOVE

FAQ, verbatim: *"Copy the markdown logs you want to share from
`.aider.chat.history.md` and make a github gist"* — a dedicated viewer at
`aider.chat/share/?mdurl=` renders any gist's raw markdown *"like you'd
see in a terminal,"* with zero conversion step, because the storage format
already **is** the display format. [Issue #2684](https://github.com/Aider-AI/aider/issues/2684):
the per-repo default *"provides good context when returning to a repo
where aider has been previously used"* — valued specifically because it's
just a readable, greppable file, no query tool required.

### HATE

[Issue #118](https://github.com/paul-gauthier/aider/issues/118)
(2023-07-18) — surprise that resume isn't automatic: *"Is there anyway to
resume a previous context? I see .aider.chat.history.md &
.aider.input.history but I don't see any signs that this is being used in
any way."* Lost an in-progress session to a crash from a typo: *"aider
crash[ed]... I open aider back up and it has no clue what I was doing."*
[Issue #2979](https://github.com/Aider-AI/aider/issues/2979)
(2025-01-23) — restore breaks at scale: an 80k-token history file
triggered `litellm.InternalServerError` on restore, and the user
explicitly rejected "just don't restore it" since the workflow depends on
accumulated context — replaying raw markdown verbatim doesn't scale.
[Issue #3607](https://github.com/Aider-AI/aider/issues/3607)
(2025-03-22) — all-or-nothing: *"Aider includes the whole chat history in
context, with /clear being the only way to control context by deleting
the whole chat history."* [Issue #1787](https://github.com/Aider-AI/aider/issues/1787)
— scripted/API usage **silently writes no transcript at all** because the
writer path lives in the CLI I/O layer, not the core.

### DEMAND

**Direct database request, explicitly modeled on prior art**:
[Issue #1859](https://github.com/paul-gauthier/aider/issues/1859)
(2024-10-01): *"It would be handy to log chats to a database rather than
just save a large .md file,"* citing Simon Willison's `llm` CLI
(SQLite+Datasette) as precedent — cost tracking, full-text/vector search,
natural-language SQL querying. A contributor built exactly this,
[PR #1860](https://github.com/Aider-AI/aider/pull/1860) (SQLite storage +
`/datasette` browsing command). **Maintainer paul-gauthier explicitly
rejected it**, 2024-10-02: *"This is a very specific integration that is
not likely to make sense to merge into the main aider releases."* Still
unmerged; a second independent attempt (PR #4079, 2025-05) recurred,
rejected on the same grounds — Aider holds the file-based line by
deliberate policy, not oversight.

**Unmet demand forked downstream**: [Lorbic's writeup](https://lorbic.com/aider-session-management/)
("I Added Session Management to Aider") — motivation *"All that context is
gone... Stepping away for meetings... Switching Git branches (triggering
automatic resets)... Terminal session crashes... Accidental /clear
commands."* Ships `/session save|list|view|load|delete` snapshotting to
**JSON** under `.aider/sessions/` — abandoning markdown-as-storage
precisely to make resume reliable, keeping `.md` only as a human-readable
export. *"The pull request was never merged upstream."*

Maintainer's actual answer to the demand is intentionally shallow —
[v0.61.0](https://x.com/paulgauthier/status/1852392299445276947) added
`/save`/`/load`, but docs confirm these snapshot **which files are open**,
not conversation content — the transcript-replay gap the forks are
chasing remains open by design.

### HORROR

Not the chat-history file itself, but the sibling SQLite cache hits the
same network-filesystem locking failure other harnesses hit:
[Issue #2855](https://github.com/Aider-AI/aider/issues/2855) — on a CIFS
mount, `.aider.tags.cache.v3` directory creates but `cache.db` fails:
`Tags cache error: database is locked` /
`Directory not empty`, works once copied to local disk. Recurs at
[#4136](https://github.com/Aider-AI/aider/issues/4136) (Cloudflare SSH
tunnel) and [#3915](https://github.com/Aider-AI/aider/issues/3915)
(mounted home directory) — the same SQLite-on-NFS locking pathology found
independently in opencode (#14970) and goose's architecture generally.
Encoding fragility recurs across releases with no schema/version guard:
[#3853](https://github.com/Aider-AI/aider/issues/3853),
[#112](https://github.com/paul-gauthier/aider/issues/112)/
[#3666](https://github.com/Aider-AI/aider/issues/3666)
(`'utf-8' codec can't decode byte 0xd6`),
[#4117](https://github.com/Aider-AI/aider/issues/4117). Aider's own
`.gitignore` blanket-excludes `.aider*` — a tacit admission the plaintext
transcript is a plausible secrets-leak vector (no automatic `.env`-style
gitignore *offer* exists for it specifically). No literal secrets-leak
postmortem or merge-conflict incident surfaced despite targeted search —
a genuine negative finding, likely because the gitignore convention heads
the problem off before it happens.

---

## 5. Cline / Roo-Code

**Status caveat:** Roo-Code (a Cline fork) **shut down May 15, 2026** —
"the team stopped because they no longer believe IDEs are the future of
coding," per multiple secondary sources
([vibecodinghub.org](https://vibecodinghub.org/blog/roo-code-shutdown),
[bodegaone.ai](https://www.bodegaone.ai/blog/roo-code-shutdown-alternatives)),
independently corroborated by the GitHub repo showing archived. A
community fork (ZooCode) continues it. Roo findings below describe a
frozen end-of-life snapshot, not an evolving system.

### Schema/layout

VS Code `globalStorage` (extension ID `saoudrizwan.claude-dev`):
`state/taskHistory.json` (index), `tasks/<task-id>/{api_conversation_
history.json, ui_messages.json, task_metadata.json}` (confirmed split),
`checkpoints/` (shadow-git repos keyed by a 13-char numeric hash of the
workspace's absolute path via `hashWorkingDir`). No cross-machine sync —
purely local to one machine's `globalStorage`.

**Checkpoints (shadow git)**: a completely separate git repo per
workspace, living under `globalStorage`, decoupled from the user's real
`.git`. Docs: *"After each tool use (file edits, commands, etc.), Cline
commits the current state of your files to this shadow repo"* — one
commit per tool call, capturing **untracked files too**. Three restore
modes: Restore Files / Restore Task Only / Restore Files & Task. Nested
`.git` dirs are handled by temporarily renaming them to `.git_disabled`
during staging — the exact mechanism that later causes corruption
(below). Official docs concede the design doesn't scale: *"For very large
repositories, checkpoints may use significant storage and slow down
Cline... "* and recommend disabling checkpoints outright for big repos.

**Roo's divergence**: checkpoints **before** file modification (not
after, like Cline); more prominently honors `.gitignore`/`.gitattributes`
for exclusion rather than a separate hardcoded list; only two restore
modes (no "Task Only" equivalent).

### LOVE

Cline's own blog reframes checkpoints as a prompt-engineering tool, not
just an undo button: *"LLMs experience a 39% average performance drop
when instructions are delivered across multiple conversation turns... The
best way to fix a bad prompt isn't to patch it through a polluted
conversation; it's to rewrite it with the benefit of hindsight."*
[Addy Osmani](https://addyo.substack.com/p/why-i-use-cline-for-ai-engineering):
*"Cline's checkpoint system automatically captures workspace state after
each AI operation... browser sessions and terminal states are
preserved,"* useful for testing multiple approaches in parallel.
[DeployHQ](https://www.deployhq.com/guides/cline): *"Checkpoints capture
untracked files too, which is the difference between 'I lost a file' and
'I lost nothing'"* — framed as complementary to real git, not a
replacement (*"Cline for 'step back two prompts', Git for 'throw the
whole branch out'"*).

### HATE — disk bloat is the dominant complaint

[#1311](https://github.com/cline/cline/issues/1311) (2025-01-17): *"Why
does Cline use nearly 4GBs of disk space for each task?"*
[#3790](https://github.com/cline/cline/issues/3790) (2025-05-24):
*"deleting the tasks and their checkpoints do not in fact remove those
associated files"* — closed "Help Wanted," unresolved by maintainers.
[#4386](https://github.com/cline/cline/issues/4386) (2025-06-23) rolls up
four prior issues: *"Checkpoint directories grow to 120GB+ over time
without cleanup," "No option to disable checkpoints," "Task deletion
doesn't remove checkpoint files."* Performance: [#4519](https://github.com/cline/cline/issues/4519)
(2025-06-27) — 20+ seconds per checkpoint on a large repo, root-caused to
`CheckpointGitOperations.ts`'s nested-`.git` traversal using
`suppressErrors: true` that **fails to respect `.gitignore`**; removing
`node_modules` cut traversal time 64%. Roo's equivalent
([#7843](https://github.com/RooCodeInc/Roo-Code/issues/7843)) had a
hardcoded 15s timeout that silently disabled checkpoints on large repos —
the reporter noted *"a competing tool (Cline) handles this differently by
lacking a timeout entirely, instead displaying a reminder while
continuing to wait"* — a direct comparative point favoring Cline's UX
despite Cline having the same root performance problem. Roo-specific
nested-repo fragility recurs more than in Cline:
[#8433](https://github.com/RooCodeInc/Roo-Code/issues/8433) — checkpoint
silently disables with a detected nested repo, reporter: *"they don't
experience this issue in Cline"*; [#8164](https://github.com/RooCodeInc/Roo-Code/issues/8164)
— Roo's own shadow-git init creates the "nested repo" it then complains
about; [#4567](https://github.com/RooCodeInc/Roo-Code/issues/4567) —
devcontainer `GIT_DIR` leaks into checkpoint commits, landing them in the
wrong repo entirely.

### DEMAND

[Discussion #5233](https://github.com/cline/cline/discussions/5233) —
cross-machine sync/import, unimplemented; a user explains why naive file
copy fails: *"Cline must keep a list of task IDs...in a preferences file
or DB somewhere"* so `taskHistory.json` needs re-registration, not just a
file copy. [#4386](https://github.com/cline/cline/issues/4386)'s remedy
list: disable toggle, intelligent file filtering, age/size-based cleanup,
manual selective deletion — none confirmed shipped.
[#7742](https://github.com/cline/cline/issues/7742) — recovery/diagnosis
tooling request, *"one of our most common support questions is how users
can recover or reconstruct their task history"* — **this one shipped**
(docs PR #7776) — the rare case of a durability gap actually getting
closed.

### HORROR

**[#7101](https://github.com/cline/cline/issues/7101)** (2025-10-25, P1):
JSON corruption (`Unterminated string in JSON at position 3504746`)
triggers `resumeTaskFromHistory`'s own "recovery" mechanism to **silently
delete "a large number of history folders from the filesystem"** rather
than isolating the one bad file. Closed **"not planned."**
**[#7736](https://github.com/cline/cline/issues/7736)** (2025-11-28):
*"History is gone"* — VS Code shows only the last task, everything else
vanished, unreproducible, unresolved. **[#4359](https://github.com/cline/cline/issues/4359)**
(2025-06-21) — a systemic catalog rolling up **14 independently-filed
corruption incidents**: non-UTF8 characters corrupting files, 8MB+/350k+
line tasks causing grey-screen crashes, escape sequences in terminal
output breaking JSON structure, devcontainer rebuilds wiping ephemeral
storage. **[#9631](https://github.com/cline/cline/issues/9631)**
(2026-03-02, open) — a shadow-repo `.git/config` file corrupted to all
null bytes by an interrupted write (*"a classic NTFS corruption pattern
that occurs when a file write is interrupted"*) **disables checkpoints
system-wide across every workspace**, not just the affected one — blast
radius far exceeds the damaged file. **Roo:
[#7765](https://github.com/RooCodeInc/Roo-Code/issues/7765)**
(2025-09-07) — mid-session API-rate-limit cancellation hit a nested-git
checkpoint-init failure, permanently losing the entire task prompt with
UI stuck on *"Still initializing checkpoint..."*, even the "share task"
fallback failing with "Task not found." Filed against a now-archived
repo — will never get a first-party fix.

---

## Cross-cutting

### A. Real event-sourcing vs. chat-history-dump

Only **OpenHands** and (as of mid-2026) **opencode** built a real event
store in the textbook sense (append-only, typed events, `aggregate_id`/
`seq`, replay reconstructs state). OpenHands is the deeper, more mature
implementation: tree-structured (not just linear) events with explicit
`parent_id`/fork support, a locking `FileStore` abstraction with pluggable
backends, and — uniquely in this cohort — a **published, quantified
benchmark suite** proving replay stays sub-50ms at 1,500 events. opencode's
event layer is newer (added ~June 2026) and layered *on top of* an
already-relational SQLite schema as a projection, which is why its
migration to it produced its own orphaning incident (#33447) — it's
retrofitted event-sourcing, not designed-in from day one like OpenHands'.
**goose** and **Cline** are relational/document stores with good metadata
(cost tracking, tool linkage) but no event-log/replay concept — restoring a
session means reading rows, not replaying a log. **Aider** is the pure
opposite pole: no event concept at all, a write-only markdown transcript
that can be *reloaded* (regex-parsed back into messages) but never
*replayed* in any structural sense — there's no distinction between what
happened and what's shown.

**What event-sourcing concretely buys OpenHands that the others can't do**:
(1) **branch/fork semantics with sibling history preserved** — Cline's
checkpoint restore *destroys* forward history when you roll back and
continue; OpenHands' `parent_id` tree keeps every branch addressable
forever. (2) **Self-documented, load-tested crash recovery** —
`get_unmatched_actions()` replays the log to find exactly which action
never got its observation, versus Cline's #7101 where corruption produces
*silent mass deletion* as the "recovery" strategy. (3) **A genuine
separation between "coordinate concurrent writers" (EventStream) and "read
existing events" (StoredEventList)** built explicitly for multi-worker SaaS
clustering (PR #7592) — none of the file-based or single-SQLite-file
designs in this cohort have an analogous concurrent-multi-writer story that
isn't "hope WAL mode handles it" (and it frequently doesn't, per B below).

### B. SQLite vs. files — scoreboard

| Harness | Chose | Stated reason | Observed failure modes |
|---|---|---|---|
| OpenHands | Files (JSON, one/event) + optional S3/GCS | Fast append, atomic pointer swap, cheap incremental replay | NFS locking explicitly broken (self-documented); NAS reads were ~10s/500 events before paging fix; one truncated file kills a whole session (#8809) |
| opencode | SQLite (Drizzle), was files | (unstated for the SQLite move specifically; inferred: relational queryability) | NFS `fcntl()`/WAL-shm unreliable (#14970); `SQLITE_CORRUPT` on stable macOS (#30157); concurrent headless workers hit `database is locked` (#33320); **3 separate migration hops each orphaned data** (#13654, #33447, #35750) |
| goose | SQLite (sqlx), was JSONL | "Don't implement your own database" (one-line rationale, no doc) | Connection-pool FD leak → `SQLITE_BUSY`, only fix was app restart (#7624); FK enforcement silently off for the DB's whole life (#9120); unbackfilled migration panicked on startup, **recurred 3 months after "fixed"** (#8638); WAL read-after-write race (#5793) |
| Aider | Files (plain markdown) | Human-readability, git-shareable, zero-conversion display = storage format (explicit maintainer policy, twice rejected a DB PR) | No file-corruption incidents found for the `.md` itself (negative finding); sibling SQLite tag-cache hits the *same* NFS-locking pathology as opencode/goose (#2855, #4136) |
| Cline/Roo | Files (JSON) + shadow-git repo | (unstated; VS Code `globalStorage` convention) | Unbounded growth, 120GB+ reported (#4386); one corrupt JSON file → mass silent deletion (#7101); one corrupt shadow-git config disables checkpoints **globally** (#9631) |

**Pattern that cuts across every SQLite adopter**: WAL-mode SQLite as a
single shared file is the load-bearing assumption, and it breaks under
exactly the conditions a coding-agent harness is most likely to hit — NFS-
mounted home directories (opencode #14970, Aider #2855/#4136), concurrent
headless worker fleets (opencode #33320, goose #7624), and cross-platform
client/server pairs (opencode #36902). **Pattern that cuts across every
file-based adopter**: no per-file isolation on read — a single malformed
JSON/event file takes down either the whole session (OpenHands #8809) or
the whole history list (goose #3588 pre-migration, Cline #7101). No design
in this cohort has both engine-level concurrency safety *and* per-record
corruption isolation simultaneously; each picks one failure mode over the
other. **Migrations are the recurring blind spot regardless of storage
choice**: every harness that changed its on-disk schema at least once
(opencode ×3, goose, OpenHands) produced a silent-data-orphaning incident
from an unbackfilled column, a wrong existence-check gate, or a
parent-pointer edge case — this is a process failure (no "does old data
become visible after migration" test), not a format failure.

### C. Checkpoints-of-workspace vs. checkpoints-of-conversation

**Cline/Roo couple them tightly and explicitly**: one shadow-git commit
per tool call *is* the workspace checkpoint, and it's paired 1:1 with a
point in the conversation — restore modes (`workspace`/`task`/
`taskAndWorkspace`) let users pick which half to roll back, but both halves
are generated from the *same* event (a tool use). This is the most
full-featured design here for "undo what the agent just did" — Osmani
values it specifically for capturing *"browser sessions and terminal
states"* alongside file state — but the shadow-git mechanism is also the
single largest source of disk bloat and corruption blast radius in the
whole cohort (#4386, #9631).

**OpenHands separates them cleanly**: the event log is conversation-state
only; workspace/filesystem state lives in the sandboxed runtime, not the
event store. There's no "restore files to checkpoint N" concept native to
the persistence layer at all — replaying events replays *what the agent
decided*, not *what the filesystem looked like*. This is a real, deliberate
scope boundary (confirmed by the ACP export/import feature being built and
then explicitly reverted, PR #3576, on the grounds that resume shouldn't
promise more than the conversation layer can honor).

**opencode/goose/Aider don't checkpoint the workspace at all** — none of
them snapshot file state; all three assume the user's own git (or nothing)
covers that concern, and none advertise workspace-rewind as a feature.

**What users actually seem to want, reading the demand signal across the
cohort**: something closer to OpenHands' separation (conversation replay as
a cheap, always-safe operation) *plus* Cline's workspace-undo as an
**optional, prunable, opt-out** add-on — not Cline's current "always-on,
unbounded, tightly coupled" default. The repeated "add an option to
disable checkpoints" and "add automatic cleanup" requests (#4386) are
users asking for exactly that decoupling after the fact.

### D. Steal-list — top 5, with attribution

1. **Replay-as-source-of-truth with a thin pointer/metadata sidecar, not a
   working-memory snapshot.** *From OpenHands.* `base_state.json` never
   holds the reconstructed context — only config + a `leaf_event_id` HEAD
   pointer. Actual memory is always rebuilt by walking the log. This is
   the cleanest way to get event-sourcing's honesty (nothing can silently
   diverge from the log) without event-sourcing's naive perf cost (full
   replay only on cold load/branch-switch/error-recovery, not every step —
   #3053's fix). Steal the split, not the file format.

2. **`db backup`/`db restore` with automatic pre-migration snapshots,
   validated by an integrity check.** *From goose*, PR #5490. The single
   best piece of defensive engineering found in this entire cohort, and
   the one thing that could have prevented goose's own #8638 (migration
   panic) from being a *crisis* rather than a `goose db restore` away from
   fine. Any storage layer doing in-place schema migration should ship
   this before shipping the migration itself.

3. **Migration correctness must be tested as "does old data become
   visible," not "does the app boot."** *Negative lesson from opencode*,
   which hit this exact bug shape three separate times (#13654 JSON→SQL,
   #33447 SQL→event-projection, #35750/#36222 unbackfilled column) across
   six months, plus goose once (#8638) and OpenHands once (#4057). The
   common root cause every time was a wrong existence-check or a missing
   backfill step, never a fundamentally bad format choice. A behavioral
   test suite like OpenHands' `test_conversation_restore_behavior.py`
   ("restore must succeed when config changes, must fail only when tools
   change") is the shape to copy — extend it to explicitly assert
   pre-migration data resolves post-migration.

4. **Per-record failure isolation on read.** *Missing everywhere, worth
   stealing the absence-of-failure as the design target.* Every file-based
   design in this cohort had at least one incident where a single
   malformed record took down an entire list or session (OpenHands #8809,
   goose pre-SQLite #3588, Cline #7101 — whose "recovery" was actually
   *worse*, mass-deleting good data alongside the bad file). A journal
   design should make "skip and flag the one corrupt record, keep serving
   everything else" the default, not something bolted on after users
   report data loss.

5. **A machine-readable format is not optional if replay/resume is a
   promised feature — but keep a human-readable export as a first-class,
   separate artifact.** *From Aider's own scar tissue.* Aider's maintainer
   twice rejected a SQLite PR on principle, and the project is stronger
   for staying legible and diffable — but the direct cost is that resume
   is fundamentally unreliable at scale (#2979) and was reinvented from
   scratch downstream (Lorbic's JSON-based fork) because upstream
   wouldn't do it. The lesson isn't "use SQLite" or "use markdown" — it's
   that a harness needs *both*: one format optimized for machine replay
   (don't derive it from parsing prose) and one optimized for human
   sharing/diffing (Aider's `aider.chat/share` gist-viewer, needing zero
   conversion, is worth stealing directly as a pattern even without
   Aider's underlying storage choice).

---

## Sources index (deduplicated)

OpenHands: [software-agent-sdk](https://github.com/OpenHands/software-agent-sdk)
(`event/base.py`, `conversation/{persistence_const,event_store,state}.py`,
`io/base.py`), [OpenHands/OpenHands](https://github.com/OpenHands/OpenHands)
PRs #2709 #5946 #7592 #7667 #8818 #9793, Issues #6148 #8809 #13583,
software-agent-sdk Issues #3053 #4057, PRs #2509 #3562 #3576, docs
[docs.openhands.dev/sdk/guides/convo-persistence](https://docs.openhands.dev/sdk/guides/convo-persistence),
[benchmark README](https://github.com/OpenHands/software-agent-sdk/tree/main/scripts/event_sourcing_benchmarks).

opencode: [anomalyco/opencode](https://github.com/anomalyco/opencode)
(`database/database.ts`, `session/sql.ts`, `event/sql.ts`, `share/sql.ts`,
`opencode/src/storage/storage.ts`), Issues #2086 #4557 #10904 #12889 #13611
#13654 #14970 #17188 #23892 #30157 #30302 #32431 #32713 #33320 #33321
#33447 #35505 #35750 #35890 #35892 #36222 #36902, docs
[opencode.ai/docs/{server,cli,share}](https://opencode.ai/docs/),
[Composio comparison](https://composio.dev/content/claude-code-vs-open-code),
[HN 46523178](https://news.ycombinator.com/item?id=46523178).

goose: [aaif-goose/goose](https://github.com/aaif-goose/goose)
(`session/{session_manager,session_naming,nostr_share,legacy}.rs`), Issues
#1946 #2529 #5044 #6829 #7601 #7624 #7914 #8638 #8711 #9120 #10480, PRs
#3052 #3588 #4648 #5202 #5490 #5682 #5793 #7429 #7629 #9121, docs
[goose-docs.ai](https://goose-docs.ai/).

Aider: [Aider-AI/aider](https://github.com/Aider-AI/aider) (`io.py`,
`base_coder.py`, `history.py`, `.gitignore`), Issues #112 #118 #166 #857
#916 #1787 #1859 #2684 #2855 #2979 #3607 #3666 #3853 #3915 #4117 #4136,
PRs #1860, docs [aider.chat/docs](https://aider.chat/docs/),
[Lorbic writeup](https://lorbic.com/aider-session-management/).

Cline/Roo-Code: [cline/cline](https://github.com/cline/cline),
[RooCodeInc/Roo-Code](https://github.com/RooCodeInc/Roo-Code), Issues #1311
#3790 #4359 #4386 #4519 #7101 #7736 #7742 #7929 #9631 #9554, Discussion
#1887 #5233, Roo Issues #4567 #7765 #7843 #8164 #8433, docs
[docs.cline.bot/core-workflows/checkpoints](https://docs.cline.bot/core-workflows/checkpoints),
[Cline blog](https://cline.bot/blog/how-i-learned-to-stop-course-correcting-and-start-using-message-checkpoints),
[Addy Osmani](https://addyo.substack.com/p/why-i-use-cline-for-ai-engineering),
[DeployHQ](https://www.deployhq.com/guides/cline),
[shutdown coverage](https://vibecodinghub.org/blog/roo-code-shutdown).
