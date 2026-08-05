# 14: BEAM local-first durable storage for the session journal

Round-2 cohort brief (see `harness-storage-research.md`, Phase 3, brief #14).
Shape under evaluation: **append-heavy event journal, single writer, one log
per agent session, replay on resume, must survive kill -9 / power loss
mid-write, grep-able transcripts, local-first.**

Method: 6 parallel research agents over ElixirForum, GitHub issues/source,
erlang-questions, official OTP/RabbitMQ docs. Every claim carries a quote +
URL. Verification gaps are flagged inline rather than papered over.

---

## 1. DETS: honest limits

**The 2GB cap is real, official, and silent.**
> "The size of Dets files cannot exceed 2 GB."
>: [OTP `dets` docs](https://www.erlang.org/doc/apps/stdlib/dets.html)

Klarna hit it hard enough to fund a master's thesis rewriting the format
([wambo/Erlang-DETS-64bit](https://github.com/wambo/Erlang-DETS-64bit): "main
issue was to solve the 2GB limit in DETS") and, per
[erlangforums.com](https://erlangforums.com/t/performance-ets-vs-dets-mnesia-for-infrequent-persistence-to-disk/3214),
"the issues with DETS and needing fragment tables to compensate for its size
limitations is one of the reasons why Klarna went with the Mnesia plugin
support and LevelDB." Ulf Wiger's 2009 note stands: only `disc_only_copies`
inherits the cap; `disc_copies` doesn't, at the price of RAM residency
([erlang-questions](http://erlang.org/pipermail/erlang-questions/2009-November/047834.html)).

**Repair-on-crash scales with file size and can destroy data.**
> "If an attempt is made to open a table that is not properly closed, Dets
> automatically tries to repair it. This can take a substantial time if the
> table is large.": OTP docs, ibid.

Worse, auto-repair has been an active data-loss bug in modern OTP:
[erlang/otp#8513](https://github.com/erlang/otp/issues/8513) (May 2024,
labeled `bug`) reports that on Erlang 21+ reopening an unclosed dets file
means "all or part of the data within the dets is cleared," where OTP 19
"is able to repair all data properly." (Fix version unconfirmed: verify
before trusting.) And the definitive practitioner verdict, from Nerves
maintainer Frank Hunleth, whose users live with power-cuts:
> "DETS overwrites its data files on updates and if power is removed
> abruptly, then on the next boot, DETS may have to repair the file. …
> It can't always fix a corrupted file and you lose everything in the file."
>: [ElixirForum, "Clarification on DETS/Nerves issue"](https://elixirforum.com/t/clarification-on-dets-nerves-issue-mentioned-at-elixirconf/10145)

Small-scale war story of the same shape:
[ferd/erlang-history#17](https://github.com/ferd/erlang-history/issues/17): 
"I get a message that my DETS file is corrupted every time I start IEx …
until I delete the DETS file" (trigger: double Ctrl+C).

**Durability window**: dets flushes on `auto_save` (default 180 000 ms per
current OTP docs; a [learn-elixir.dev post](https://learn-elixir.dev/blogs/avoiding-data-loss-with-elixir-dets)
claims 3 s: the sources conflict, OTP docs win): "if the process running
:dets is terminated ungracefully, any data that has not been flushed to disk
will be lost."

**When DETS is still right**: a small (<<2GB), non-critical, rebuildable local
cache owned by one long-lived process: the
[single-owner GenServer pattern](https://elixirforum.com/t/inconsistent-state-when-saving-to-dets-table/4847)
("DETS tables are designed to be 'owned' by a single process. It should open
the file on init, and keep the table open"). The existence of
[dets_plus](https://github.com/dominicletz/dets_plus) ("The `:dets`
limitation of 2gb caused me to create this library") is the ecosystem's own
verdict on everything past that envelope. **For a journal that must survive
kill -9: disqualified**: "you lose everything in the file" is the exact
opposite of the requirement.

## 2. Mnesia: trap or fine single-node?

**The netsplit lore is real but consistently multi-node-scoped.** keathley's
[breaking_mnesia](https://github.com/keathley/breaking_mnesia): "Where Mnesia
starts to violate most people's expectations is when you start relying on
multi-node tables." The `{inconsistent_database, running_partitioned_network,…}`
machinery fires only "when Mnesia detects that both the local node and
another node received `mnesia_down` from each other"
([OTP docs](https://www.erlang.org/doc/apps/mnesia/mnesia_chap7.html)), no
second node, no netsplit. His broader warning still lands:
> "Most people who use mnesia either handle this limitation on their own or
> just accept that at some point they're going to lose data."
>: [ElixirForum](https://elixirforum.com/t/why-isn-t-mnesia-the-most-preferred-database-for-use-in-elixir-phoenix/16811?page=2)

**Backend facts**: `disc_only_copies` is dets-backed → 2GB cap and slow
repair ("a table … not closed properly (e.g. after system crash) can take a
long time to repair": [Erlang FAQ](https://www.erlang.org/faq/mnesia.html)).
`disc_copies` moved to `disk_log` in R7B-4 → no 2GB cap, but the **whole
table must fit in RAM** and startup replays the log into memory. For an
unboundedly growing journal, that's a slow-motion failure either way.

**Dump/log pain is real even single-node.** Mnesia dumps the log every 1000
records or 3 minutes; `dump_log_update_in_place` default trades safety for
speed ("the possibility for unrecoverable inconsistencies in the data files
becomes much smaller with [copy-then-rename] … however, the actual dumping …
becomes considerably slower": OTP docs, ibid.). Production incident of the
write-pressure shape we'd have:
[ejabberd#4028](https://github.com/processone/ejabberd/issues/4028): 
`"Mnesia is overloaded: {dump_log,write_threshold}"` causing client drops,
closed "not planned."

**Ecosystem direction**: RabbitMQ spent years migrating off Mnesia; their
stated reason is partition behavior
([CloudAMQP, "From Mnesia to Khepri"](https://www.cloudamqp.com/blog/from-mnesia-to-khepri-part1.html):
"When the partition eventually resolves, we end up with inconsistent data
across the different nodes"; also: "we've even seen scenarios … where
RabbitMQ does not trigger the configured partition handling strategy at all"),
and the official line is Khepri's "substantial data safety and recovery
improvements over Mnesia"
([rabbitmq.com blog](https://www.rabbitmq.com/blog/2025/09/01/6-khepri-default)).

**Verdict**: single-node `disc_copies` sidesteps the netsplit lore (no
primary source claims single-node corruption of that class: genuine
evidence gap, searched for), but RAM-residency + dump_log overload + a
transactional-KV shape that buys us nothing for append/replay makes it the
wrong tool. Notably, *nobody* in the searched record reports running a
single-node Mnesia event journal happily; absence of positive reports for a
25-year-old tool is itself signal.

## 3. CubDB: the sleeper, evaluated honestly

**Crash-safety design is real and structural.**
> "CubDB database file uses an append-only, immutable B-tree data structure.
> Entries are never changed in-place, and read operations are performed on
> zero cost immutable snapshots.": [README](https://github.com/lucaong/cubdb)

Recovery = backward scan for last valid header: "the data file is traversed
backwards block by block until the latest readable header is located"
([store/file.ex source comments](https://github.com/lucaong/cubdb/blob/master/lib/cubdb/store/file.ex));
"should something go wrong in the middle of a write (say, a power failure),
no data is destroyed by a partial overwrite"
([FAQ](https://raw.githubusercontent.com/lucaong/cubdb/master/FAQ.md)).
**Caveat found in source review: no CRC/checksum anywhere**: integrity is
"found a well-formed header," weaker than Ra's per-record CRC.

**Maturity: stalled, not dead.** Last release v2.0.2: **January 1, 2023**
([hex.pm](https://hex.pm/packages/cubdb)); trailing commits through late 2024
are CI-only. Two unresolved compaction-path crash reports match our workload
shape: [#21](https://github.com/lucaong/cubdb/issues/21) (2020, GenServer
crash under concurrent compaction; reporter: "disabling compaction seems to
fix it") and [#74](https://github.com/lucaong/cubdb/issues/74)
(`Enumerable not implemented for %CubDB.Btree{}` in `compactor.ex:46` on
v2.0.2, triggered by continuous key updates over time).

**The one detailed production report at journal-like scale is an exit.**
Electric SQL used CubDB as their sync-engine storage and replaced it
([electric.ax v1.1 postmortem](https://electric.ax/blog/2025/08/13/electricsql-v1.1-released)):
> "CubDB was performing well enough and we didn't come across any bugs …
> Writing to storage consumed excessive CPU time. This was due to frequent
> updates to CubDB's internal structures. … P95 latency was too high. Large
> transactions blocked reads for extended periods. … The challenges we
> encountered weren't due to CubDB being poorly designed: it simply wasn't
> the right fit for Electric's use case."

Their replacement measured 102x faster writes / 73x faster reads on SSD
(their numbers, motivated party, directionally credible). Also explicit:
"Avoid starting multiple CubDB processes on the same data directory"
(README), and no official throughput numbers exist anywhere.

**Verdict**: excellent design essay, correct positioning ("data storage on
single-instance applications or embedded software … a great fit for Nerves
projects": FAQ), fine for config/small-state. For an append-heavy journal:
stalled maintenance, compaction bugs on exactly our access pattern, no
checksums, and the single best real-world datapoint hit a wall. Also: a KV
B-tree gives us no grep-ability. Not the sleeper pick.

## 4. SQLite via exqlite / ecto_sqlite3

**Mature and alive**: repo since 2021-02, v0.38.0 released 2026-06-29, 2.66M
hex downloads ([hex.pm](https://hex.pm/packages/exqlite),
[releases](https://github.com/elixir-sqlite/exqlite/releases)). Bus factor:
one dominant maintainer (warmwaffles, 468 of ~560 commits, sole hex owner).

**Single-writer story is honest but the good architecture isn't shipped.**
README: "Simultaneous writing is not supported by SQLite3 and will not be
supported here." ecto_sqlite3 defaults `journal_mode: :wal` ("vastly superior
for concurrent access") + `busy_timeout: 2000`
([hexdocs](https://ecto-sqlite3.hexdocs.pm/Ecto.Adapters.SQLite3.html)).
José Valim personally weighed in on the right design, 
> "you may be able to stick with the process model as long as you assume
> each instance of the database is backed by one process"
>, [exqlite#192](https://github.com/elixir-sqlite/exqlite/issues/192)

, but that issue is **still open** (milestone 1.0); today you get a generic
DBConnection pool, and a community single-writer prototype
([ruslandoga/exqlite#3](https://github.com/ruslandoga/exqlite/pull/3)) is
unmerged. For our shape (one process per session log) we'd be fine, but the
serialization discipline is on us.

**NIF risk is documented, not theoretical.** Calls run on dirty schedulers
(README), and the [CHANGELOG](https://github.com/elixir-sqlite/exqlite/blob/main/CHANGELOG.md)
records the class recurring: v0.7.1 "segfault on double closing," v0.9.3
"SIGSEGV issue when a long running query is timed out," v0.13.8 "Handle
SEGFAULT when trying to open a database that the application does not have
permissions to open," v0.37.0 "Deadlock when canceling queries stuck in VDBE
execution." A rival Rust NIF exists specifically because "the choice came
down to not panicking and never bringing down the BEAM VM"
([dimitarvp/xqlite](https://github.com/dimitarvp/xqlite)), while its author
also concedes "If exqlite is working well for your needs today, it's a solid
choice."

**Durability**: SQLite WAL makes an ordinary crash mid-write invisible on
reopen; power-loss durability of the *last commits* requires
`PRAGMA synchronous=FULL`: "NORMAL … omits this sync" on commit
([sqlite.org/wal.html](https://sqlite.org/wal.html)). ecto_sqlite3 does not
force FULL; check before relying. Precompiled NIFs via
elixir_make/cc_precompiler cover mac/linux/musl/windows/android, with real
fetch-failure pain on record ([#272](https://github.com/elixir-sqlite/exqlite/issues/272)).

**Production**: Livebook consumes it via kino_db
([livebook.dev/integrations/sqlite](https://livebook.dev/integrations/sqlite/)),
no "why we chose it" writeup found (searched, flagged). ElixirForum
[SQLite in Production](https://elixirforum.com/t/sqlite-in-production/53295)
reports are positive but read-heavy ("50k write queries/month"), not our
shape.

## 5. Plain file append: the artisanal option, as practiced by RabbitMQ

This is not artisanal; it's the most production-hardened pattern in the BEAM
world, with source-visible discipline.

**`delayed_write` is a durability trap if misread.** OTP
[`file` docs](https://www.erlang.org/doc/apps/kernel/file.html): buffering
until `Size` bytes or `Delay` ms, and, the load-bearing sentence, 
> "the result of `write/2` calls can prematurely be reported as successful,
> and if a write error occurs, the error is reported as the result of the
> next file operation, which is not executed."

`:file.sync/1` "ensures that any buffers kept by the operating system (not
by the Erlang runtime system) are written to disk";
`:file.datasync/1` "resembles `fsync` but it does not update some of the
metadata": the cheap choice for a hot append loop.

**RabbitMQ's message store** ([rabbit_msg_store.erl](https://github.com/rabbitmq/rabbitmq-server/blob/main/deps/rabbit/src/rabbit_msg_store.erl)):
- Rotation: "messages are appended to the current file up until that file
  becomes too big (> file_size_limit). At that point, the file is closed and
  a new file is created. Files are named numerically ascending."
- fsync discipline: the striking admission: "Note: the message store no
  longer fsyncs; it only flushes data to disk." Flush interval:
  `-define(SYNC_INTERVAL, 200). %% Milliseconds`: "Confirms are sent after
  the data is flushed to disk."
- Torn-write framing: each record is
  `<<EntrySize:64>>, MsgId, MsgBodyBin, <<255>> %% OK marker`, and the
  recovery scanner only accepts
  `<<Size:64, MsgIdAndMsg:Size/binary, 255, Rest/bits>>`: a partial trailing
  write fails the marker match and is skipped/truncated.

**Ra's WAL** ([ra_log_wal.erl](https://github.com/rabbitmq/ra/blob/main/src/ra_log_wal.erl),
[INTERNALS.md](https://github.com/rabbitmq/ra/blob/main/docs/internals/INTERNALS.md))
is the stricter reference:
- Framing: magic `"RAWA"` + version header; per record
  `<<Checksum:32, EntryDataLen:32>>` + `<<Idx:64, Term:64>>` + data,
  checksum = `erlang:adler32`, `sync_method => sync | datasync` (default
  **datasync**).
- fsync batching by mailbox drain, not timer: "fsyncs in batches, typically
  the write requests received in the mailbox during the previous fsync
  operation … dynamically increasing max writes limit … to trade-off latency
  for throughput."
- Torn-tail policy (`recover_records/5`): CRC failure on the *last* record →
  assumed torn write, dropped, recovery continues; CRC failure *mid-file* →
  `wal_checksum_validation_failure`, "Unable to recover WAL data safely": 
  hard stop. Tail damage is expected; interior damage is an alarm.
- New-file creation: write header to `.tmp`, then rename: "rename is
  atomic-ish so we will never accidentally write an empty wal file."

Also in-house: OTP's own [`disk_log`](https://www.erlang.org/doc/apps/kernel/disk_log.html)
"supports automatic repair of log files that are not properly closed", 
surfaced by practitioners on
[ElixirForum, crash-recovery structures](https://elixirforum.com/t/crash-recovery-oriented-on-disk-data-structures/39356), 
but its truncation algorithm is undocumented and its format is binary/opaque
(no grep).

## 6. Ra / Khepri: overkill check

Single-member Ra clusters exist mechanically but only as a bootstrap step in
the [README](https://github.com/rabbitmq/ra/blob/main/README.md) toward
adding members; the headline example assumes three distributed nodes, and
server addressing is `{Name, Node}` throughout: distribution is structural.
Measured weight: 3 external deps (incl. `aten`, a failure detector: dead
weight at n=1), 54 modules, ~1.97MB Erlang; `ra_server.erl` alone is 4230
lines of leader-election/membership machinery we'd never exercise. Khepri is
strictly Ra-plus-tree ("Khepri is a state machine in a Ra cluster": 
[README](https://github.com/rabbitmq/khepri)) and adds a RAM ceiling:
"Khepri currently hosts the entire data set in memory as well as on disk …
storing blobs of files in Khepri is not recommended." Every stated Khepri
motivation is partition consistency: a problem we don't have. No standalone
adoption stories found ([the 2019 ElixirForum thread](https://elixirforum.com/t/has-anyone-tried-rabbitmqs-ra-library-that-implements-raft/26543)
went nowhere). **Verdict: reference for lessons only**, and the lessons
(framing, batching, torn-tail policy) are already extracted in §5.

---

## A. Ranking for "append events + replay on open + survive kill -9"

| Option | Crash-safety | Read-during-write | Ops-simplicity | Deps | Verdict |
|---|---|---|---|---|---|
| **File append, framed records** | Proven (RabbitMQ/Ra pattern: marker/CRC + truncate-tail; §5) | Trivial: independent reader fd, records self-delimiting | Highest: files, grep, rsync | **zero** | **Pick** |
| **SQLite/exqlite** | Strong (WAL by design; power-loss needs `synchronous=FULL`) | Good (WAL readers don't block writer) | Good; opaque binary, no grep | NIF + precompile chain; segfault history (§4) | Index/query layer, not the log |
| **CubDB** | Good design, **no checksums**; compaction bugs #21/#74 on our pattern | Yes (immutable snapshots) | Good; opaque, no grep | pure Elixir, but stalled since 2023 | Small-state only |
| **DETS** | **Bad**: repair "can't always fix … you lose everything" (§1) | OK | OK until repair day | zero | Disqualified |
| **Mnesia disc_copies** | Moderate; dump-cycle corruption window, `{dump_log,write_threshold}` overload | Yes | RAM-bound, log-dump tuning | zero (OTP) | Wrong shape |
| **Ra/Khepri** | Best-in-class | Yes | Heaviest by far | 3 deps, ~2MB Erlang, distribution assumed | Lessons only |

Justification is in the sections; the decisive evidence: the two systems on
the BEAM that most credibly survive kill -9 at scale (RabbitMQ msg store, Ra
WAL) are both **framed append-only files with truncate-tail recovery**. They
had every option and built this.

## B. ETF vs JSON on disk

- **Grep-ability decides it, and it's a stated requirement.** ETF/binary
  framing (Ra-style) is unreadable to every non-BEAM tool; JSONL transcripts
  work with `grep`/`jq`/editors and match the cohort winner (Claude Code
  `~/.claude/projects/*.jsonl`, Codex rollouts: round-1/round-2 priors,
  `harness-storage-research.md`).
- **Torn-write detection comes free with JSONL**: a partial trailing line is
  by construction not valid JSON and has no trailing `\n`: parse-fail on
  the last line → truncate, which is exactly Ra's torn-tail policy (§5)
  expressed in a text format. Interior parse failure → alarm, not truncate.
- **ETF's sharp edge**: decoding foreign ETF with atoms fills the finite atom
  table; OTP docs require `binary_to_term(B, [:safe])` for untrusted input
  ([erlang.org docs](https://www.erlang.org/doc/apps/erts/erlang.html#binary_to_term/2)),
  and `:safe` then breaks decoding of records whose atoms aren't loaded yet: 
  a versioning trap across releases. JSON decodes to strings; keys stay
  strings unless you opt in.
- **Versioning**: JSON forces explicit schema/version fields (a `v` per line)
  and tolerates unknown fields; ETF silently couples the file to module/record
  shape at write time. Round-2 pain-frame #4 ("old sessions stay readable as
  the tool evolves") favors JSON.
- Cost: JSON is bigger and slower to encode. For a per-session human-scale
  transcript log, irrelevant; measured systems that need binary (Ra) are
  doing millions of entries/sec across queues. We are not.

**Verdict: JSONL** (one JSON object per line, `\n`-terminated, version field
per event). Binary ETF only if a future high-rate event class appears, as a
separate segment type, never mixed into the transcript.

## C. fsync reality on BEAM

- `write/2` `ok` ≠ durable, twice over: `delayed_write` buffers in the
  emulator (errors even get reported one call late: §5 quote), and the OS
  page cache buffers after that. Only `:file.sync/1`/`datasync/1` push to
  disk; `datasync` skips metadata and is the hot-loop choice (OTP docs, §5).
- What the pros actually do: **nobody fsyncs per write.** RabbitMQ's msg
  store dropped fsync entirely (200ms flush interval, confirms gated on
  flush); Ra fsyncs **per mailbox-drained batch** with `datasync` default and
  an adaptive batch ceiling (§5). Durability window is a deliberate, small,
  documented trade in both.
- For us: open with `[:append, :raw, :binary]` (skip `delayed_write`: our
  event rate doesn't need it and its error-deferral is poison for a journal),
  write each event eagerly, and `datasync` on a policy: immediately for
  irreversible-side-effect events (tool executions, permission grants),
  batched/idle-triggered (Ra's mailbox-drain idea, or ≤200ms timer à la
  RabbitMQ) for chat deltas.

## D. The 2-store split (append log + queryable index)

Precedent is unambiguous: **both reference systems are 2-store, and the index
is always derived and disposable.** RabbitMQ msg store = append segments +
an index module (ETS-based by default) rebuilt by scanning on dirty recovery
(§5 scanner); Ra = WAL + mem tables (ETS) + segment files, where the WAL is
truncated only after the segment writer has flushed
([INTERNALS.md](https://github.com/rabbitmq/ra/blob/main/docs/internals/INTERNALS.md)).
Meanwhile the entire CLI-agent cohort (Claude Code, Codex) ships JSONL logs
with *no* index and survives fine at session scale.

Verdict: the split is correct **as an option, not a foundation**. The JSONL
log is the single source of truth; an index (ETS in-process for offsets;
SQLite later if cross-session search is wanted) must be rebuildable by a
full scan and deletable at any time. That kills the classic dual-write
consistency problem. There is nothing to keep consistent, only a cache to
warm. Do not build the SQLite index until a real query need exists.

## E. Steal-list: five decisions for our journal

1. **JSONL, one append-only file per session, version field per event**, 
   from the cohort winner (Claude Code/Codex transcripts, round-1/2 research)
   plus grep-ability requirement. Text format *is* the torn-write detector
   (§B).
2. **Ra's torn-tail recovery policy, transliterated**: on open, parse
   forward; invalid/unterminated **last** line → truncate and continue
   silently; invalid **interior** line → stop, surface corruption, never
   auto-truncate. (Ra `recover_records/5`,
   [ra_log_wal.erl](https://github.com/rabbitmq/ra/blob/main/src/ra_log_wal.erl).)
3. **Batched `datasync`, tiered by event criticality**: per-batch fsync on
   mailbox drain (Ra) with an upper flush interval (RabbitMQ's 200ms
   `SYNC_INTERVAL`); immediate sync for side-effect/permission events. Never
   `delayed_write` on the journal fd (OTP `file` docs error-deferral, §C).
4. **Single owner process per log file + tmp-then-rename for file birth**: 
   one GenServer owns the fd for the session's lifetime (DETS forum lesson,
   CubDB's own warning, exqlite#192's Valim-endorsed model all converge on
   this); create new segments/metadata as `.tmp` then `rename` (ra_log_wal's
   "rename is atomic-ish" move).
5. **Numeric ascending segments with a size cap; index derived, never
   authoritative**: rabbit_msg_store's rotation ("files are named
   numerically ascending") for unbounded sessions; replay = read segments in
   order; any offset/search index is a rebuildable cache (§D), so corruption
   of the index costs a rescan, not data.

## Flagged verification gaps (do not silently trust)

- OTP #8513 fix version unconfirmed; dets `auto_save` default (180s per OTP
  docs) contradicts a blog's 3s claim: OTP docs presumed right.
- ElixirForum threads 31005 (Mnesia 2GB) and 63588 (pool_size lore) resisted
  direct fetch; quoted only via search synthesis.
- ecto_sqlite3's default `PRAGMA synchronous` level unverified: check before
  ever relying on SQLite for power-loss-durable commits.
- No primary "why Livebook chose SQLite" source exists (searched).
- Ra INTERNALS marks snapshot/truncation internals "TBD: currently undergoing
  changes": treat that sub-design as sketch, not blueprint.
