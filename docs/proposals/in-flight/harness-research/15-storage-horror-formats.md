# Storage Horror Stories + File-Format Theory

Forum-first sourcing: GitHub issues (numbered, dated), Reddit/HN/vendor-forum threads,
one npm-ecosystem security study, one trade-press article. Companion to
`06-horror-stories.md` (agent *behavior* failures — destructive actions, prompt
injection, runaway cost); this brief is scoped to **storage**: transcript/session
data loss, corruption, secrets-at-rest, and size pathologies, plus the file-format
theory that would have prevented each class. Confidence is flagged inline —
"title confirmed via search" means the issue exists but body/quotes weren't
independently fetched; unmarked items were fetched directly.

---

## 1. The horror catalog

### 1.1 Silent retention deletion (GC/cleanup wipes the primary record)

**Claude Code #62041** (github.com/anthropics/claude-code/issues/62041, May 24 2026,
@ghh1111) — the anchor incident. Startup-triggered GC (`cleanupPeriodDays`, v2.1.149,
macOS) silently deleted every session transcript across all projects with no
confirmation, opt-out, or recovery: *"Session transcripts are not cache — they are
the primary record of work."* Reporter's own count via `history.jsonl`: 133 unique
session IDs for one project, extrapolated to **~2,300 sessions of work** lost
across all projects; 70+ orphaned session directories survived with no matching
transcript. The `.last-cleanup` timestamp matched the exact moment Claude Code
launched. No maintainer response recorded.

Six confirmed siblings, same mechanism (`cleanupPeriodDays`, default 30, no
first-run disclosure, not surfaced in `/config`):
- **#62476** (May 26 2026, @joelhochstetter): *"I lost months of conversation
  history before realizing this was happening."* 14 sessions / 1,315 prompts gone.
- **#59248** (May 14 2026, @FTSBrand, labels `data-loss`+`has repro`): cleanup ran
  12 minutes after session start; surviving transcript was **71 days old**,
  contradicting the documented 30-day default — cleanup logic appears to diverge
  from its own spec.
- **#62272**: deletion recurs even with `cleanupPeriodDays` set high, apparently
  triggered by app updates/restarts rather than pure age — the standard user-side
  mitigation (raise the value) doesn't reliably work.
- **#69140**: Windows desktop, all transcripts deleted on first launch after a
  2.1.177 update — a version-upgrade trigger distinct from the age-based GC.
- **#62959**: cleanup deletes the `.jsonl` but leaves sidebar metadata behind, so
  the UI keeps listing sessions that error with "session not found on disk" on click.
- **#54907**, **#64403**, **#64999**, **#49903**, **#61532**, **#34584** (titles
  confirmed via search, not independently fetched) — same shape, including one
  case (#34584) where the Write tool's own output files, not just transcripts,
  were caught by the cleanup.

**Hacker News** (news.ycombinator.com/item?id=48732846, "Beware, Claude Code
deletes >30 day old transcripts. Anthropic won't fix it," ~July 2026):
@ojura — *"it is silent, not announced anywhere, and calls rm on your data"* (also:
setting `cleanupPeriodDays` to zero purges everything immediately, and some
subagent transcripts ignore the configured retention entirely). @skeledrew — *"I
consider the LLM output to be mine as well, as it's something I paid for. Nothing
should be deleted without my knowledge and approval."*

**Windsurf/Cascade** (github.com/Exafunction/codeium/issues/136, Feb 18 2025):
hardcoded 20-conversation cap, no export/archive before eviction — *"Once you
start your 21st conversation, your first conversation is gone forever."*

### 1.2 Non-atomic writes → crash/concurrency corruption

**opencode #7607** (Jan 10 2026, maintainer-confirmed) — disk filled mid-session;
two on-disk JSON "part" files were truncated to **0 bytes**, and because the
server does a blind `JSON.parse` on load, the truncation crashed the *entire*
session with `Unexpected end of JSON input`, not just the truncated parts.
Maintainer @thdxr's proposed fix is the textbook answer: atomic writes
(temp-file-then-rename), parse-error skip-and-continue, and a repair tool for
quarantined artifacts.

**Claude Code #20992** (Jan 26 2026, closed as duplicate) — multiple Claude Code
processes appending to the same JSONL concurrently; Node's file-append is not
atomic; interleaved writes truncate a line mid-stream (one truncated line showed
a cut-off base64 signature); the parser hit invalid JSON and recursed infinitely
→ `RangeError: Maximum call stack size exceeded`. Affects all terminal tabs
sharing one `~/.claude/projects/` directory — a single-writer violation.

**Cline #7101** (Oct 25 2025) — one corrupted history JSON
(`SyntaxError: Unterminated string in JSON at position 3504746`) crashed parsing;
on restart Cline's own "recovery" logic responded by **bulk-deleting** task-history
folders instead of isolating the one bad file: *"A large number of task history
folders were silently deleted... this is caused by a critical bug in the
extension's error handling, not by external factors."* This is the sharpest
illustration in the whole catalog of a panic-response making corruption worse
than doing nothing.

**goose #7556** (Feb 27 2026) — `settings.json` read via unguarded
`JSON.parse` with no try/catch fallback; a crash/power-loss mid-write leaves a
truncated file that then hard-crashes the whole desktop app on next launch — no
atomic-write (temp+rename) pattern on save.

**goose #2529** (May 13 2025) — intermittent session JSONL corruption, trailing
line malformed mid-token (`ole":`), suspected non-atomic save; UI fails with
`TypeError: Cannot read properties of undefined (reading 'sessionId')`.

**opencode #14970** — `"database disk image is malformed"` running concurrent
sessions against one shared SQLite DB over NFS: SQLite's WAL mode depends on
POSIX advisory locking and shared-memory mapping, both unreliable over NFS — a
known SQLite-on-NFS anti-pattern, surfaced specifically because opencode
centralizes *all* sessions in one DB file rather than one file per writer.

**opencode #20786 / sst/opencode#2135** — once a session's stored JSON is
truncated/malformed, the session becomes permanently unusable: *"any further
prompts sent to the session just repeat the same error"* — no degrade path.

### 1.3 Resume/replay state poisoning

**Claude Code #63147** (May 28 2026, the anchor for this class) — extended-thinking
blocks are persisted with the `thinking` text emptied to `""` but the
`signature` field retained. On resume this malformed block is replayed to the
API; the signature no longer matches the (now-empty) text, the API rejects with
`400 ... 'thinking' or 'redacted_thinking' blocks... cannot be modified`, and
because the original text is gone from disk the request can never be
reconstructed validly — the session is **permanently poisoned**, no recovery
short of starting a new one.

**Claude Code #41992** (Apr 1 2026, **closed as "not planned"** two months before
#63147 was filed) — a sibling mechanism: the model occasionally emits an empty
text block mid-stream during thinking-enabled responses; Claude Code records it
verbatim, and replay on resume fails with `400 ... text content blocks must be
non-empty`. Anthropic explicitly declined to fix the closely related precedent.

**Claude Code #36583** (Mar 20 2026) — on resume, file-history-snapshot entries
write a `messageId` that collides with an existing message `uuid`, breaking
`parentUuid` chain traversal. Hard numbers: 330 total entries, 34 collisions,
only 190 (75%) messages reachable after resume — **61 messages (25%) permanently
lost** to a broken graph, not deleted from disk but unreachable.

**Codex CLI #21196** (May 5 2026) — rollout JSONL files vanish from disk while
DB metadata rows still reference them: 91 thread records in state, only 1
matching rollout file — 90 threads orphaned. *"Durable chat payloads were removed
without corresponding metadata cleanup."*

### 1.4 Secrets captured/leaked via the storage layer

**Lovable BOLA** (disclosed ~Apr 20 2026, researcher @weezerOSINT; sources:
dev.to/jon_at_backboardio, medium.com/beyond-localhost) — the strongest single
incident in this category. A broken-object-level-authorization bug in
`api.lovable.dev/GetProjectMessagesOutputBody.json` let **any free-tier account**
fetch **any other project's** stored AI chat history, prompts, model reasoning
traces, source code, and database credentials, in plain JSON, no ownership check:
*"Every secret you ever mentioned in a conversation with Lovable is sitting in a
JSON response that any free account could fetch."* Affected all free accounts and
all projects created before Nov 2025; the report was reportedly marked duplicate
and left open for weeks. Unlike every other item in this category, this is a
confirmed, dated, disclosed vulnerability that exposed the **chat transcript
itself** as the leak vector, not just secrets pasted into generated app code.

**Cursor "CursorJacking"** (layerxsecurity.com) — API keys and session tokens
stored in a local **unencrypted SQLite database** instead of OS keychain/Credential
Manager; *"any extension — regardless of its declared permissions — can directly
read from it."*

**Claude Code #59094** (May 14 2026, @youja2014) — a concrete reproduction:
`Get-Content .env | Select-String "KIS|PAPER|..."` printed four secret values to
stdout, captured verbatim in the session JSONL, and transmitted to Anthropic
inference — despite an explicit user-authored CLAUDE.md rule forbidding it.
Reporter's framing, worth stealing as a design principle: *"user-authored rules
in CLAUDE.md/memory cannot be relied upon for secret handling — they're advisory
text the LLM may deprioritize... the harness should enforce it,"* not the model.

**Claude Code #44868** (Apr 7 2026) — a live Cloudflare API token exposed via
`grep -n` on a `.dev.vars` file despite CLAUDE.md prohibition: *"the model's
safety reflex fires on output it has already produced, not on commands it is
about to run, so the violation is detected only after the secret has already been
written to chat history."* A third sibling, **#58173**, reports the identical
failure mode — this is a recurring class, not a one-off.

**Lakera npm study** (via bdtechtalks.com, Apr 27 2026, Ben Dickson) — scanned
~46,500 npm packages; **428 shipped a `.claude/settings.local.json` file**
(Claude Code's "allow always" permission cache, which persists approved terminal
commands including any embedded credentials); **33 files across 30 packages held
live credentials** — roughly 1 in 13 shipped settings files exposed sensitive
data, because package managers publish this directory by default absent explicit
`.npmignore`.

**Cline #3361** — telemetry containing sensitive user-generated content (tasks,
filenames, MCP config) sent **even when telemetry is explicitly disabled** in
settings.

### 1.5 Unbounded size → cascading failure

**Claude Code #24207** (Feb 8 2026, **closed "not planned"**) — the single most
severe incident in this catalog, worse than pure disk-full because of what it
takes down with it. `~/.claude` grows unbounded (3,640 MB reported: `projects/`
2,707 MB, `debug/` 734 MB, `file-history/` 188 MB) with no monitoring, cleanup,
or warning. At 0 bytes free: *"a failed write produces a zero-length file...
Claude Code creates a new default config, overwriting all project settings...
Authentication lost — OAuth/API tokens are also corrupted or wiped. There is no
warning before this happens. No graceful degradation. No recovery path."*
Unbounded transcript growth doesn't just waste disk — filling the disk destroys
config and auth via non-atomic writes to unrelated files, cascading class-1.5
into class-1.2.

**Claude Code #22365** (Feb 1 2026, closed not planned/duplicate, labels
`has repro`+`perf:memory`+`oncall`) — one session JSONL grew to **3.8 GB**
(vs. 13–28 MB peers); Claude Code appears to load/index the entire file on
every prompt, consuming **12.8 GB RAM** (84.1 GB virtual) on a 30 GB server,
hanging indefinitely on the second prompt.

**Codex CLI #22004** (May 10 2026) — session files with large inline base64
image blobs blow past V8's ~512 MB max single-string length
(`RangeError: Invalid string length`) because the Electron main process
concatenates all child-runtime stdout into one JS string — the session becomes
**permanently unloadable through the UI**.

**Codex CLI #24948** (May 28 2026) — session JSONLs reaching 700 MB–2 GB, driven
by repeated `compacted` records with large `replacement_history` payloads
(337.8 MB in one sample) and untruncated raw tool output (230.8 MB) — no
retention, truncation, or compression policy on the log itself. Same file family
that crashes the desktop app in #22004.

**Cursor `state.vscdb`** (forum.cursor.com threads, multiple) — one workspace DB
reported at 25–50 GB, `.pack` checkpoint files ("72 over 1 GB, plus 306 between
500 MB–1 GB") pushing macOS System Data past 200 GB. A Cursor staffer
(Dean Rie, Feb 28 2026) confirmed the vendor-suggested cleanup — delete the
global `state.vscdb` — is exactly what causes the "infinite Loading Chat"
corruption bug in a separate thread: *"Cursor can't rebuild that index from
workspace-level files after the global DB is deleted."* Size pathology and
corruption pathology are causally chained through the vendor's own remediation
advice.

**aider** (`.aider.chat.history.md`, Aider-AI/aider#2979 and FAQ, lower
confidence) — the flat markdown transcript grows toward ~1M tokens for heavy
users; `--restore-chat-history` then re-sends the entire file to the model for
summarization, turning unbounded append-only growth into a severe latency bug.

### 1.6 UI/index desync (data survives, discovery breaks — the softest class)

**Cline #6183** (Sept 12 2025, closed not planned) — after an extension update,
the visible task list showed only today's items while *"the recent tasks list has
completely disappeared"* — the "Delete all" button still reported **600 MB** of
stored history, proving the data was intact and only the UI/index was desynced.

**opencode**, at least four separate issues (**#14546, #17765, #6625, #26207**)
— Windows Desktop loses all *visible* session history on every restart while
sessions remain in the local database; root causes vary (path matching,
`opencode.global.dat` staleness, TUI reload) but the shape recurs.

**opencode #20903** (Apr 3 2026, closed not planned) — clicking "Archive" in the
Windows Desktop app destroys unsaved session data because auto-save doesn't
persist in real time and Archive doesn't force-flush first: *"all conversation
history from the current session that hasn't been persisted to the database is
permanently lost."*

---

## 2. Format theory

### 2.1 JSONL/NDJSON conventions

Two overlapping specs. **ndjson-spec** (ndjson.org) is normative: UTF-8 required,
each line MUST be a full RFC 8259 JSON text followed by `\n` (optionally
preceded by `\r`), and — the load-bearing guarantee for line-splitting —
*"The JSON texts MUST NOT contain newlines or carriage returns"*, so naive
line-splitting is always safe. **jsonlines.org** is looser: any JSON value per
line (not just objects), no BOM, trailing newline "strongly recommended but not
required" because *"including a line terminator after every JSON value makes
generating and concatenating JSON Lines files easier"* — the explicit
append-friendliness rationale. **Neither spec addresses a torn final line** —
real gap, left to implementations. In practice: `jq` has a documented bug
(jqlang/jq#1161) where it exits 0 on truncated input instead of signaling
failure — naive pipelines don't reliably detect a torn tail. The working pattern
from tooling that does handle it (`jq`'s `fromjson? // sentinel`,
`--seq`/RFC 7464 mode which "ignores but warns" on unparseable records) is:
**best-effort parse the final line only; treat any parse failure on a non-final
line as real corruption, not tail truncation** — mirroring the
middle-vs-tail distinction in WAL/LevelDB below. Crash safety: write a complete
line in one `write()` call terminated by `\n`, `fsync`/`fdatasync` per line or
batched — this is the same durability/throughput knob as Redis's `appendfsync`.

### 2.2 Asciicast v2/v3 (.cast)

v2 (docs.asciinema.org/manual/asciicast/v2/): line 1 is a single header JSON
object (required `version`, `width`, `height`; optional `timestamp`, `duration`,
`idle_time_limit`, `command`, `title`, `env`, `theme`); every subsequent line is
a 3-tuple `[time, code, data]` where `time` is **absolute** seconds since start,
`code` is `o`/`i`/`m`/`r`. This aged well for exactly the reasons that matter for
an agent journal: **streamable** (append one line as each event happens, never
rewrite earlier bytes), **crash-safe by construction** (a crash after any
complete line leaves a structurally valid prefix — the header is a commit
point, every event line after it is independently parseable), **self-describing**
(header carries the schema/dimensions needed to interpret the rest), and
trivially simple (`json.loads()` per line, no nested framing). v3
(docs.asciinema.org/manual/asciicast/v3/) keeps the same newline-delimited-JSON
shape and event codes (plus `x` for exit status) but is **not backward
compatible**: it switches `time` from absolute offsets to **relative
intervals between consecutive events**, rounded to millisecond precision with
error-diffusion to avoid cumulative drift, and restructures the header
(`term.cols`/`term.rows` nested). The tradeoff made explicit: absolute
timestamps are simpler and robust to reordering/concatenation; relative deltas
are more compact but demand rounding discipline.

**Raxol alignment check** (`lib/raxol/recording/asciicast.ex`): the wire format
is correct v2 — header line + one `[seconds, type, data]` JSON tuple per line,
absolute (not delta) timestamps, matching v2 not v3. **Two gaps against the
theory above, though:** (1) `write!/2` calls `encode/1`, which builds the
*entire* session (header + all events, via `Enum.map_join`) into one string in
memory and does a single `File.write!` — this is buffer-then-write-once, not
the incremental per-event append that is the actual reason the format is
crash-safe in the wild (asciinema's own recorder appends as it captures). A
crash mid-session with Raxol's current writer loses the *whole* recording, not
just the tail. (2) `decode/1` pattern-matches
`[header_line | event_lines] = String.split(content, "\n")` and maps
`Jason.decode!` over every line with no rescue — this will raise (`MatchError`
or `Jason.DecodeError`) on a torn last line rather than tolerating it per the
NDJSON discipline in §2.1. Neither gap breaks *correctness* today (Raxol writes
complete `.cast` files at the end of a recording, not incrementally), but if
this format or its writer discipline is reused for the incremental agent
journal under discussion, both gaps need closing first: switch to append-mode
writes with per-event `fsync`, and make the reader tolerant of a truncated
final line.

### 2.3 SQLite as an application file format

The canonical essay (sqlite.org/appfileformat.html) argument, condensed to what
transfers: **atomic durability** — *"Writes to an SQLite database are atomic...
even during system crashes or power failures"*; **incremental writes** — *"only
those parts of the file that actually change are written out to disk"*, versus
pile-of-files formats that *"usually require a rewrite of the entire document in
order to change a single byte"*; single-file portability; automatic
multi-reader coordination; no bespoke parser to write and maintain. On
concurrency (sqlite.org/whentouse.html): strict **single-writer** — *"SQLite
only supports one writer at a time per database file"* — framed as rarely a
practical constraint since write transactions are typically millisecond-scale
and writers "take turns." The quotable comparison: *"SQLite does not compete
with client/server databases. SQLite competes with `fopen()`."* On "database vs.
filesystem" (sqlite.org/fasterthanfs.html, "35% Faster Than The Filesystem"):
not a flat rule but a **size-dependent crossover** — SQLite beat direct
filesystem reads by ~35% (up to 5x on Windows) for 8–12 KB BLOBs because
`open()`/`close()` syscall overhead per file dominates at small sizes, but the
study states explicitly: *"The filesystem will generally be faster for larger
blobs, since the overhead of open() and close() is amortized over more bytes of
I/O."* Named crossover is roughly 250 KB–1 MB. Directly relevant to a journal:
small structured event records belong in a DB row or an NDJSON line; large
attachments (multi-MB diffs, screenshots) belong on the filesystem, referenced
by path/hash, not inlined — which is exactly the mistake behind Codex CLI
#22004/#24948 above (inline base64 blobs and untruncated tool output growing
the transcript itself past a language-runtime string-length ceiling).

### 2.4 JSON-RPC 2.0 + LSP framing vs. NDJSON framing

LSP's Base Protocol (microsoft.github.io/language-server-protocol) frames every
stdio message as ASCII headers terminated by `\r\n\r\n`, with `Content-Length`
mandatory: *"The length of the content part in bytes. This header is
required."* The reader reads headers until the blank line, parses
`Content-Length`, then reads exactly that many bytes — no scanning inside the
payload for a delimiter, fully robust to any byte content in the body. MCP's
stdio transport (modelcontextprotocol.io) chose the opposite: newline-delimited
JSON-RPC, with the invariant pushed onto the *writer* instead of the framing —
*"Messages are delimited by newlines, and MUST NOT contain embedded newlines"*
— trading Content-Length's structural robustness for `tail -f`/`grep`/`jq`
transparency. The practical nuance: conformant JSON already escapes literal
newlines inside strings as the two-character `\n`, so a well-behaved encoder
never emits a raw `0x0A` inside a value — length-prefixing mainly guards against
non-conformant/pretty-printed producers and against the *reader* needing
incremental-parse-and-backtrack to know "have I received the whole message
yet." For a durable local journal — one process writing, human/tool readers
wanting to `tail -f` and `grep` it — NDJSON/MCP-style framing is the right
default; LSP's Content-Length framing is the right choice only if payloads with
literal control characters must be tolerated without serializer discipline.

### 2.5 CloudEvents / OpenTelemetry envelope conventions

CloudEvents core attributes (github.com/cloudevents/spec): **id** (String,
REQUIRED — *"Producers MUST ensure that source + id is unique for each distinct
event"*, note the pair, not id alone, is the dedup key), **source** (URI-ref,
REQUIRED, the producing context), **specversion** (REQUIRED, schema-version
marker), **type** (REQUIRED, reverse-DNS-style category e.g.
`com.github.pull_request.opened`), **time** (OPTIONAL, RFC 3339), and
**subject** (OPTIONAL — scopes an event to a sub-resource within `source`
without overloading `type`). OpenTelemetry's trace/span model
(opentelemetry.io/docs/concepts/signals/traces) adds the causal-tree piece
CloudEvents alone lacks: every span carries a shared **trace_id** (correlation
key across a whole request/turn), a unique **span_id**, and a **parent_span_id**
(empty for roots) — *"spans can be nested, as is implied by the presence of a
parent span ID: child spans represent sub-operations."* Synthesized, the
transferable envelope for a generic event log: unique **id** (idempotent
replay/resume key, combined with source), a **schema-version marker**, a
**source/origin** field (essential once multiple agents/tools/subprocesses
write into one journal), a namespaced **type** string (filter/dispatch without
parsing the payload), an unambiguous **RFC 3339 timestamp** (both specs
converge on ISO8601-family, not epoch floats), and an explicit
**trace/span/parent** triad for reconstructing a causal tree of nested tool
calls and sub-agent spawns on replay, not just a flat list.

### 2.6 Write-ahead-log discipline

**SQLite WAL** (sqlite.org/wal.html, frame layout at sqlite.org/fileformat2.html):
32-byte WAL header (magic, version, page size, salts, header checksum); each
24-byte frame header carries a page number, a non-zero commit-size field only
on commit frames, salts copied from the WAL header, and **cumulative** checksum
words chained across every frame from the header forward. A frame is valid iff
its salts match and its checksum matches the running chain — recovery reads a
page from the WAL only if it's a commit frame or followed by one; a torn write
at the tail simply fails the chain and everything after the last valid commit
frame is discarded. **Rule: chained checksums plus an explicit commit marker
let a reader find exactly where valid data ends, without external
truncation-detection — the checksum chain IS the torn-write detector.**
**LevelDB log format** (github.com/google/leveldb, doc/log_format.md):
`crc32c(4B) | length(2B) | type(1B) | data` records, fixed 32 KB block
quantization, trailing block space zero-padded and skipped. **Rule:** block
quantization makes "ran out of well-formed bytes near EOF" (benign truncation)
structurally distinguishable from "checksum failed but more data follows"
(real corruption); documented recovery is "skip to the next block" — corruption
is block-recoverable, not file-fatal. **Redis AOF**
(redis.io/docs/latest/operate/oss_and_stack/management/persistence):
`appendfsync` policies trade durability for throughput (`always`, `everysec`
default, `no`); a truncated tail is auto-detected and *silently dropped* on
load by default (`aof-load-truncated`), logged as a warning, no manual step
needed. But AOF records have **no per-record checksum** (they reuse plain RESP
framing), so real interior corruption is unrecoverable past the corruption
point — `redis-check-aof --fix` can only discard everything from the bad byte
to EOF: *"leading to a massive amount of data loss if the corruption happened
to be in the initial part of the file."* **Rule (the cautionary
counter-lesson): without per-record checksums, a format can cleanly recover
tail-truncation but not interior corruption — length/syntax framing alone is
not enough if corruption can land mid-file, not just at the tail.**

---

## 3. Cross-cutting

### A. Horror taxonomy, ranked by severity × frequency

| # | Class | Frequency | Severity | Worst incident |
|---|---|---|---|---|
| 1 | **Silent retention deletion** (GC wipes primary record) | very high — 10+ Claude Code siblings, Windsurf cap | high — permanent, no consent | Claude Code #62041, ~2,300 transcripts |
| 2 | **Non-atomic-write corruption** (crash/concurrency) | high — every tool researched | high — total-file loss, crash loops, panic-deletes | opencode #7607 (disk-full → 0-byte truncation kills whole session, maintainer-confirmed); Cline #7101 (corruption → bulk-delete history) |
| 3 | **Secrets captured/leaked at rest** | high — structural, recurring | critical when triggered — credential compromise, not just data loss | Lovable BOLA — any free account could read any project's transcripts + secrets |
| 4 | **Unbounded size → cascading failure** | medium-high | high — can destroy unrelated config/auth, not just the log | Claude Code #24207 — disk-full write cascade wipes settings AND auth tokens |
| 5 | **Resume/replay state poisoning** | medium | medium-high — session-specific, workaround exists (new session) | Claude Code #63147 — permanently poisoned by empty-text/retained-signature mismatch |
| 6 | **UI/index desync** | medium | low-medium — data intact, just unreachable/undiscoverable | Cline #6183 — 600 MB of history invisible in UI |

Note the causal coupling documented in §1.5: class 4 and class 2 are frequently
the *same bug wearing two hats* — Cursor's `state.vscdb` bloat (4) is what
drives users to the deletion that triggers "infinite Loading Chat" (2); Codex
CLI's 700 MB–2 GB session files (4) are the exact files that crash the desktop
app at the V8 string ceiling (2).

### B. Which format disciplines would have prevented each class

- **Class 1 (silent deletion):** prevented by policy, not framing — but
  format theory supplies the mechanism for *safe* retention: SQLite's atomic,
  checkpoint-then-truncate model (§2.3, §2.6a) and asciinema's append-only,
  never-destructive model (§2.2) both demonstrate "never delete without a
  completed, verified transfer" as a structural pattern, versus Claude Code's
  unconditional startup `rm`.
- **Class 2 (non-atomic corruption):** directly prevented by §2.6's three
  disciplines — atomic temp+rename writes for any non-append file (would have
  stopped goose #7556 and the class-4-cascading Claude Code #24207), per-record
  checksums to distinguish interior corruption from tail truncation (would have
  stopped Cline #7101's panic bulk-delete — a checksummed reader would know the
  *rest* of the file was fine), and single-writer enforcement (would have
  stopped Claude Code #20992's concurrent-append stack overflow and opencode's
  NFS/SQLite corruption).
- **Class 3 (secrets):** **format theory does not solve this** — worth stating
  as an explicit gap. None of the six disciplines in §2 redact content; they
  only govern framing/durability. The Lovable BOLA is an authorization bug, and
  the Claude Code secrets issues are a policy-enforcement-location bug (§1.4's
  #59094 quote: rules belong in the harness, not the model). The one adjacent
  lever format theory does supply: CloudEvents-style event `type` tagging
  (§2.5) lets a redaction/scrubbing pass target specific event types
  (`tool_call.env_read`, `file.read`) before persistence, rather than scanning
  opaque blobs after the fact.
- **Class 4 (unbounded size):** prevented by SQLite's incremental-write
  property plus the fasterthanfs size-crossover discipline (§2.3) — keep large
  blobs out-of-band, referenced not inlined — and by NDJSON's line-oriented
  streaming reads (§2.1) instead of Claude Code #22365's whole-file
  load-on-every-prompt pattern.
- **Class 5 (resume poisoning):** prevented by the CloudEvents/OTel envelope
  discipline (§2.5) — a versioned schema marker per record would let a resume
  path detect and reject a malformed thinking-block record instead of
  replaying it blind, and the WAL/LevelDB tail-checksum pattern (§2.6a/b) would
  let a reader distinguish "this record is structurally broken" from "this
  record is fine but semantically stale."
- **Class 6 (UI/index desync):** prevented by treating the append-only journal
  itself as the source of truth and deriving any index/UI list from it on
  demand (or via a durable, checksummed rebuild), rather than maintaining a
  separate mutable index that can silently drift from the log — exactly the
  CloudEvents `id`+`source` dedup-key pattern (§2.5) applied to index rebuilds.

### C. Steal-list — top 6 non-negotiable disciplines

1. **Append-only NDJSON, one event per line, never in-place rewrite.**
   Prevents class 2 from cascading past the last written line (§2.1, §2.6c —
   Redis AOF's default auto-recovery of a truncated tail is the proof this
   works in production at scale).
2. **Atomic writes (temp file → fsync → rename) for every non-append file** —
   config, settings, any index/metadata that isn't the journal itself.
   Prevents goose #7556 (settings.json hard-crash) and the disk-full cascade in
   Claude Code #24207 that destroyed config *and* auth tokens as collateral
   damage from an unrelated log growing unbounded.
3. **No silent, unconditional deletion — ever.** Retention/GC must be
   user-visible, opt-in, and structurally incapable of running as a startup
   side effect with no confirmation. This is the single discipline that would
   have prevented Claude Code #62041's ~2,300-transcript loss outright; every
   other steal-list item is defense-in-depth, this one is the direct fix.
4. **CloudEvents-style envelope on every record** — unique id (paired with
   source for dedup), schema version, source/origin, namespaced type, RFC 3339
   timestamp, and an OTel-style trace/span/parent triad for causal structure.
   Prevents class 6 desync (index and log can never silently diverge if the
   index is a derived, rebuildable view) and gives class 5 resume logic a real
   integrity check instead of blind replay.
5. **Tail-tolerant, checksum-aware reads: parse failure on the final line is
   expected and benign (discard); parse failure anywhere earlier is a hard
   corruption alarm, never a trigger for bulk deletion.** This single rule
   would have prevented both Cline #7101 (corruption → panic bulk-delete of
   history) and Claude Code #20992 (concurrent-write corruption → infinite
   recursion crash) — in both cases the actual data loss was caused by the
   *reader's* response to corruption, not the corruption itself.
6. **Size-bounded records with large payloads kept out-of-band.** Per-record
   or per-file size ceilings, streaming reads (never whole-file-load), and
   filesystem-referenced blobs above the ~250 KB–1 MB SQLite/filesystem
   crossover (§2.3). Prevents Claude Code #22365 (12 GB RAM from a 3.8 GB
   session load) and Codex CLI #22004 (V8 string-length crash from inlined
   base64 blobs).

---

## Sources

Primary: github.com/anthropics/claude-code/issues/{62041,62476,59248,62272,
69140,62959,63147,41992,36583,20992,24207,22365,59094,44868,58173}; github.com/
openai/codex/issues/{21196,22004,24948}; github.com/anomalyco/opencode/issues/
{7607,14970,20903,17765,20786}; github.com/cline/cline/issues/{6183,7101,3361};
github.com/block/goose/issues/{2529,7556}; github.com/Exafunction/codeium/
issues/136; news.ycombinator.com/item?id=48732846; forum.cursor.com (state.vscdb
threads); layerxsecurity.com/blog/cursorjacking; bdtechtalks.com/2026/04/27/
claude-code-api-token-leak; dev.to/jon_at_backboardio (Lovable BOLA);
medium.com/beyond-localhost (Lovable/Vercel breach). Format theory: ndjson.org,
jsonlines.org, github.com/jqlang/jq/issues/1161, docs.asciinema.org/manual/
asciicast/{v2,v3}, sqlite.org/{appfileformat,whentouse,fasterthanfs,wal,
fileformat2}.html, github.com/google/leveldb/blob/main/doc/log_format.md,
redis.io/docs/latest/operate/oss_and_stack/management/persistence,
microsoft.github.io/language-server-protocol, modelcontextprotocol.io/
specification/2025-06-18/basic/transports, github.com/cloudevents/spec,
opentelemetry.io/docs/concepts/signals/traces. Local: `lib/raxol/recording/
asciicast.ex` (alignment check, §2.2).
