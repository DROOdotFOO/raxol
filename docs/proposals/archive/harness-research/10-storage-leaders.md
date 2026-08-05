# Storage Leaders: how the top agent CLIs persist sessions on disk

Forum-first sourcing: GitHub issues/discussions/PRs (fetched directly, `gh api`
where WebFetch dropped comment threads), Reddit, HN, blog reverse-engineering
posts. Vendor docs used only to confirm command syntax, not as primary evidence
for schema/behavior claims. Direct quotes carry URLs; paraphrase is flagged as
such. Round: dappsnap `cohort-research` skill, continues `harness-storage-research.md`
(the priors doc) and complements `06-horror-stories.md` (destructive-action
incidents, not storage-format incidents: different failure class).

---

## 1. Claude Code

### Layout + schema
`~/.claude/projects/<cwd-with-slashes-as-dashes>/<session-uuid>.jsonl`: one
append-only JSONL file per session. Confirmed by official docs: *"By default,
transcripts are stored as JSONL at `~/.claude/projects/<project>/<session-id>.jsonl`...
Each line is a JSON object for a message, tool use, or metadata entry"*
([code.claude.com/docs/en/sessions](https://code.claude.com/docs/en/sessions)).
Sibling dirs: `plans/` (whimsical auto-named plan docs), `file-history/`
(content-addressed checkpoint snapshots, `"{contentHash}@v{versionNumber}"`),
`todos/`, `shell-snapshots/`, `debug/{sessionId}.txt`. Sub-agent (Task tool)
transcripts write `agent-{shortId}.jsonl`.

Core envelope: `type`, `uuid`, `parentUuid`, `timestamp`, `sessionId`, `cwd`,
`gitBranch`, `version`, `userType`, `isSidechain`, `isMeta`, nested `message`
(Anthropic API shape: `role`, content blocks: `text`/`thinking`/`tool_use`/
`tool_result`). Token accounting in `message.usage`
(`input_tokens`/`output_tokens`/`cache_creation_input_tokens`/`cache_read_input_tokens`,
split by 5-min/1-hour cache tiers). Example user record
([gist.github.com/samkeen](https://gist.github.com/samkeen/dc6a9771a78d1ecee7eb9ec1307f1b52)):

```json
{"type":"user","parentUuid":null,"isSidechain":false,"isMeta":false,
 "userType":"external","cwd":"/Users/sam/Projects/dev-journal",
 "sessionId":"31f3f224-f440-41ac-9244-b27ff054116d","version":"2.0.75",
 "gitBranch":"main",
 "message":{"role":"user","content":"Help me implement the batch processor"},
 "uuid":"e2dbdfef-3699-4d96-8027-24a09d5cd58d",
 "timestamp":"2025-12-22T21:18:34.755Z",
 "thinkingMetadata":{"level":"high","disabled":false},"todos":[]}
```

The fullest **line-type enumeration** found comes from a feature request, not
docs: [#53516](https://github.com/anthropics/claude-code/issues/53516) lists
`type` values: `agent-name, assistant, attachment, custom-title,
file-history-snapshot, last-prompt, permission-mode, queue-operation, system,
user, summary, result, progress`, and `system` subtypes:
`away_summary, bridge_status, compact_boundary, local_command,
scheduled_task_fire, stop_hook_summary, turn_duration, hook_callback`.
`summary` records carry a `leafUuid` marking a known-good resumption tip
(seen in [#10392](https://github.com/anthropics/claude-code/issues/10392)'s
excerpt: `{"type":"summary","summary":"Claude Code Ready...","leafUuid":"7724a014-..."}`).

Third-party parsers as evidence the schema is real and load-bearing:
`daaain/claude-code-log` (Python, JSONL→HTML/Markdown),
`simonw/claude-code-transcripts`, `ZeroSumQuant/claude-conversation-extractor`,
`withLinda/claude-JSONL-browser`, `kiliman/claude-transcript`,
`jspw/Claude-Code-Dashboard`, `nateherkai/token-dashboard`, `phuryn/claude-usage`.

### Resume semantics
`--continue` resumes the most recent session in cwd; `--resume <name>`/picker
resume a named one; lookup is **scoped to cwd + its git worktrees** (an id from
elsewhere reports `No conversation found with session ID`). Resume walks the
`parentUuid` chain backward from a tip. It is **DAG reconstruction, not flat
file replay**. `/branch`, `/rewind`, `--fork-session` write a *new* session file
(copy-on-fork), grouped under the root in the picker. Docs warn: *"If you
resume the same session in two terminals without forking, messages from both
interleave into one transcript."* Scriptable surface: `-p --output-format
json|stream-json`, `-p --resume <id>`, `transcript_path` passed to
hooks/statusline.

### Checkpoint/rewind
Automatic snapshot **before every file-editing tool call**, one per prompt,
stored in `file-history/`: separate content-addressed store, not embedded in
the transcript. `/rewind` / Esc-Esc offers *Restore code and conversation* /
*Restore conversation* / *Restore code* / *Summarize from here*. Documented
gap, repeatedly noted: *"Checkpointing does not track files modified by bash
commands... `rm file.txt`, `mv old.txt new.txt`, `cp source.txt dest.txt`...
cannot be undone through rewind. Only direct file edits made through Claude's
file editing tools are tracked"* ([code.claude.com/docs/en/checkpointing](https://code.claude.com/docs/en/checkpointing)).

### GC/retention
`cleanupPeriodDays` in `settings.json`, default 30, sweeps at **startup**
(not continuous): *"Claude Code will delete any jsonl older than the specified
number of days on each startup... history that has already been deleted cannot
be restored"* ([dev.classmethod.jp](https://dev.classmethod.jp)). As of v2.1.117
also sweeps `tasks/`, `shell-snapshots/`, `backups/` (undocumented: tracked as
a docs gap in [#51779](https://github.com/anthropics/claude-code/issues/51779)).

### LOVE
- *"Claude Code writes new lines as the session progresses; nothing is
  rewritten or deleted, making it append-only. There's no rewriting, no
  locking, no corruption risk for existing data. Crash recovery is built in, 
  since each line is independently valid, a crash mid-write only loses the
  last partial line."* ([claude-dev.tools](https://claude-dev.tools/docs/jsonl-format))
- On the DAG design: *"Each message includes a unique identifier (uuid) and a
  reference to the message that came before it (parentUuid). This makes it
  possible to see not just what happened, but why it happened."*
  ([milvus.io](https://milvus.io))
- HN: *"You can find out not just what you did and did not do but why. It is
  possible to identify unexpectedly incomplete work streams..."*
  ([news.ycombinator.com/item?id=46546937](https://news.ycombinator.com/item?id=46546937), user bredren)
- [#53516](https://github.com/anthropics/claude-code/issues/53516) itself lists
  5+ independent community dashboards/tools built directly on the raw format
  unprompted by Anthropic: the tooling ecosystem *is* the praise.

### HATE
- Anthropic's own docs now disclaim stability: *"The entry format is internal
  to Claude Code and changes between versions, so scripts that parse these
  files directly can break on any release. To build on session data, use
  `/export` or the script interfaces instead."* ([code.claude.com/docs/en/sessions](https://code.claude.com/docs/en/sessions))
- *"The catch: the format is an internal implementation detail. No
  documentation, no version field, no stability guarantee... The schema
  changes whenever the CLI updates, which is, at the current pace, almost
  daily."* ([dev.to/tznthou](https://dev.to/tznthou)): same post documents
  unpaired UTF-16 surrogates in tool-error text, duplicate `usage` objects from
  one API response fanning into multiple lines, and a dedup trap: *"the dedup
  query must exclude the session currently being indexed. Otherwise... every
  line is a duplicate, and quietly drops the entire session."*
- *"Claude Code has no export button. Your conversations are trapped in
  `~/.claude/projects/` as undocumented JSONL files."*
  (`ZeroSumQuant/claude-conversation-extractor` README)
- `isSidechain` default (`false`) on non-conversational entries breaks
  tip-finding: root cause of the Dormammu bug (HORROR, below) and of
  [#22900](https://github.com/anthropics/claude-code/issues/22900).

### DEMAND
- [#53516](https://github.com/anthropics/claude-code/issues/53516) (open,
  filed 2026-04-26): the sharpest ask found: *"Several of these
  (agent-name, custom-title, queue-operation, local_command,
  scheduled_task_fire, pr-link, system/bridge_status) are recent additions
  that did not appear in older transcripts and are not described in the public
  docs. We have no way to know whether new types are additive (safe) or
  whether existing types may be renamed or removed (breaking)."* Proposes
  SemVer for the transcript schema, decoupled from CLI SemVer, plus a
  changelog commitment.
- [#29325](https://github.com/anthropics/claude-code/issues/29325) (closed), 
  *"It would be great if we have an option to export chat conversation to
  .pdf/.MD etc."*, shipped later as `/export` (plain text only).
- [#18645](https://github.com/anthropics/claude-code/issues/18645) (closed
  dup): cross-machine session portability broke between v2.1.5→2.1.9:
  *"With version 2.1.5, manually copying session files between machines...
  worked as a workaround. After updating to 2.1.9, this no longer works...
  additional validation was added that blocks sessions not originally created
  on the current machine."*
- [#50014](https://github.com/anthropics/claude-code/issues/50014) demands
  built-in secret scrubbing/rotation (see HORROR).

### HORROR
- **[#22526](https://github.com/anthropics/claude-code/issues/22526)**: 
  corrupt `parentUuid`s pointing at UUIDs never written; resume walk hits the
  phantom and silently truncates. On a 900+-line session, only the last few
  messages survived resume.
- **[#21751](https://github.com/anthropics/claude-code/issues/21751)**: 
  assistant text dropped, only `thinking` blocks persisted, in
  54/442 (12.2%), 33/1242 (2.7%), 31/540 (5.7%) messages across three real
  sessions, correlated with a `file-history-snapshot` entry sitting between
  the truncated message and the next user turn. Filed by an AI agent itself:
  *"This issue was written and submitted by an AI agent (Claude Code), with
  human review and approval."*
- **[#43764](https://github.com/anthropics/claude-code/issues/43764) ("Dormammu
  Bug")**: a power-outage recovery reattached context to an orphaned
  assistant message **8 days / 22,000 lines earlier**, discarding 593K tokens
  of correct context while billing to rebuild the wrong 593K: *"Context didn't
  shrink: it shifted to a different timeline: Going from 82% to 62% used is
  not compaction... the model resumed at a completely different point in the
  conversation: hundreds of builds behind."* Root cause, confirmed against
  `cli.js`: the tip-finder treated any `isSidechain:false` entry (including
  non-conversational `progress`/snapshot records) as a valid tip.
- **[#22900](https://github.com/anthropics/claude-code/issues/22900)**: VS
  Code extension kept main transcripts **in memory only**; an auto-update
  wiped 30 sessions permanently, leaving only 8.4MB of sub-agent sidechain
  files as proof they'd existed: *"Extension upgrades wipe this memory,
  causing complete and permanent data loss of all conversation history."*
- **[#24207](https://github.com/anthropics/claude-code/issues/24207)**: 
  unbounded `~/.claude` growth (2,707 MB projects/, 734 MB debug/, 188 MB
  file-history/, one linked user at 300 GB) filled disk to 0 free →
  zero-length `.claude.json` write on ENOSPC → treated as invalid JSON → all
  settings/auth reset. *"There is no warning before this happens. No graceful
  degradation. No recovery path."*
- **rdiachenko.com (2026-03-16)**: a backgrounded bash `.output` file grew to
  **324 GB in 16 minutes** (~340 MB/s), tied to
  [#26911](https://github.com/anthropics/claude-code/issues/26911)/[#16130](https://github.com/anthropics/claude-code/issues/16130)/[#27371](https://github.com/anthropics/claude-code/issues/27371)
  (other users: 537 GB, 160 GB, 740 GB). *"This bug is quiet. No warnings, no
  errors, no disk space alerts."*
- **Secrets: [#50014](https://github.com/anthropics/claude-code/issues/50014)**
  (open, `area:security`, "High"): *"On my machine after ~30 days of usage, a
  simple grep revealed 5 distinct secrets scattered across 34 session files
  (418 MB total). Paste-cache, file-history, and debug logs also contained
  secrets."* Threat model given: *"a malicious npm postinstall script, a
  compromised VS Code extension, or any process running as my user."*
- **ironpeak.be (2026-02-17) + `hazcod/claudleak` scanner**: real, verified
  API keys/DB passwords found committed to public repos via
  `.claude/settings.local.json` swept up by `git add -A`: *"It contained all
  my whitelisted commands, complete with the secrets I had passed as
  environment variables."* Scanner found live secrets in 2.4% of scanned repos
  with AI-tool config dirs.
- **Index/data desync cluster** (all open): [#39667](https://github.com/anthropics/claude-code/issues/39667)
  (JSONL silently deleted, `sessions-index.json` stops updating), [#66499](https://github.com/anthropics/claude-code/issues/66499)
  (10 valid sessions absent from the index), [#41591](https://github.com/anthropics/claude-code/issues/41591)
  (auto-update deletes `.jsonl` and leaves stale index entries).

---

## 2. OpenAI Codex CLI

### Layout + schema
```
$CODEX_HOME/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDThh-mm-ss-<UUID>.jsonl
```
(default `~/.codex`). Source: `codex-rs/rollout/src/recorder.rs`. UUID = the
thread/conversation id. A local SQLite (`state_5.sqlite`, plus `logs_2.sqlite`,
goals/memories DBs) indexes sessions for fast listing without scanning JSONL.

Each line is `RolloutLine = {timestamp, type, payload}` wrapping a
`RolloutItem`. Confirmed `type` values (sampled from a real 84,643-line file
in [#29510](https://github.com/openai/codex/issues/29510)): `session_meta,
response_item, event_msg, turn_context, compacted`. `session_meta.payload`:
`id, cwd, originator, cli_version, model_provider`, plus a later-added
`thread_source` field (see HATE). `response_item` subtypes: `message`,
`function_call` (`name, arguments, call_id`), `function_call_output` (matched
back by `call_id`, ordering is purely temporal, no explicit begin/end
nesting). Example `token_count` event
([#9198](https://github.com/openai/codex/issues/9198)):

```json
{"timestamp":"2026-01-13T15:04:57.524Z","type":"event_msg",
 "payload":{"type":"token_count","info":{"total_token_usage":
 {"input_tokens":6198727,"cached_input_tokens":6005376,
  "output_tokens":60840,"reasoning_output_tokens":44372,
  "total_tokens":6259567},"model_context_window":258400}}}
```

`compacted.payload.replacement_history` is the compaction checkpoint used to
rebuild state on resume. **Terminology is genuinely three-level**: thread
(persistent conversation id) → turn (`TurnContext` per request/response cycle)
→ item (`RolloutItem`): confirmed by [PR #23534](https://github.com/openai/codex/pull/23534)
exposing `thread/resume` and `thread/turns/list` as *separate* JSON-RPC calls.

**Three incompatible schema generations coexist on disk simultaneously.**
Pre-`session_meta`/`response_item` "legacy" files (2025-era) are flat
`{"type":"message",...}` / `{"record_type":"state"}` records with no wrapper
([#26877](https://github.com/openai/codex/issues/26877), "codex doctor reports
valid legacy rollout files as scan errors"); `codex-trace` advertises explicit
support for "new (≥0.44), mid, and oldest (2025/08) session metadata formats."
An independent reverse-engineer: *"The documented format and the real format
don't match"*: a parser built against `protocol.rs` went from ~0% to 100%
event coverage only after empirical trace inspection
([dev.to/milkoor](https://dev.to/milkoor/reverse-engineering-codex-cli-rollout-traces-3b9b)).

### Resume semantics
`codex resume --last` / `codex resume <id>` / `/resume`. Per maintainer
([Discussion #3827](https://github.com/openai/codex/discussions/3827)):
*"Not at the moment: the Codex CLI doesn't support manually naming rollout
files or setting a custom session ID... `/resume` relies on the original ID
within the JSONL."* Reconstruction is a **reverse scan + forward replay**:
`Session::reconstruct_history_from_rollout` "performs a reverse scan of
rollout items to rebuild history and metadata," "identifies the newest
surviving Compacted checkpoint or WorldState to establish a baseline, then
replays subsequent items forward" (DeepWiki analysis of
`codex-rs/core/src/session/rollout_reconstruction.rs`).

### The `checkpoint_v1.json` demand
The RFC is **[#8573](https://github.com/openai/codex/issues/8573)**, "RFC:
Deterministic Session Checkpoint v1 (DSC)," filed 2025-12-27. (#8310 is a
*different*, related bug ("resume after rate limit loses task intent") 
cited inside #8573 as motivating evidence, not the checkpoint request itself.)
Quote: *"Replace lossy 'conversation summarization' compaction with a
deterministic, host-generated checkpoint... We add a tiny derived projection:
`checkpoint_v1.json`... No LLM is required to produce the checkpoint."*
Proposed schema: `schemaVersion, seq, task{text,evidence}, plan{steps,done,
evidence}, decisions[]{decisionId,topic,decision,rationale,evidence},
artifacts{uri→{kind,hash,lastObservedSeq}}, facts{key→{value,evidence,
dependsOn,status:VALID|SUSPECT}}` with hard caps (`maxFactsTotal=64`,
`maxDecisionsTotal=32`). **Status: closed, not_planned, 2026-03-20**, closing
comment verbatim from OpenAI contributor etraut-openai: *"This feature request
hasn't received enough upvotes, so closing."* Final count: 7 👍, 0 opposition.
A follow-up proposed a lighter "lossless queryable trace pointer" citing
Cursor's "dynamic context discovery" and a parallel Claude Code ask
([anthropics/claude-code#17428](https://github.com/anthropics/claude-code/issues/17428)):
also unaddressed.

### GC/retention
**No automatic retention exists.** [#6015](https://github.com/openai/codex/issues/6015)
(open): *"Codex retains every conversation indefinitely, so the history
folder grows larger over time... allow users to specify a retention period
(for example, 30 or 60 days)."* [#6526](https://github.com/openai/codex/issues/6526)
explicitly benchmarks against Claude Code's `cleanupPeriodDays`: *"Right now
you'd have to write a cronjob to achieve that obviously, but I'd prefer it to
be integrated"*: closed as duplicate of #6015, i.e. consolidated, not shipped.
Bloat is severe: [#29510](https://github.com/openai/codex/issues/29510) (open,
recurred 2026-07-14): app-server RAM ballooned to **30-40 GB / 32 GB swap**
on a 16 GB Mac loading a single **~11.88 GiB, 84,643-line** rollout file with
individual lines up to ~60.9 MB, because `RolloutRecorder::load_rollout_items`
has **no byte/record cap**. Recurrence found an even larger 29.1 GB file.

### LOVE
Mostly implicit: expressed by people building on the format rather than
praising it directly:
- `PixelPaw-Labs/codex-trace`, `jazzyalex/agent-sessions` (cross-tool viewer),
  `AgentsView`, `Cocoanetics/CodexMonitor`, `langfuse/codex-observability-plugin`
  (ingests rollouts as OTel traces).
- OpenAI's own 5-PR internal stack (#18876-#18880, merged) added a
  `rollout_trace` crate to make multi-agent relationships reconstructable
  "from durable rollout data rather than transient in-memory manager state."
- A maintainer recommends the raw file as the ground-truth debug tool in
  [Discussion #12668](https://github.com/openai/codex/discussions/12668):
  *"The practical way to see exactly what was injected is to inspect the
  latest rollout JSONL"* (`rg '"type":"session_meta"'`).

### HATE
- Three format generations coexisting (#26877, above).
- **Breaking metadata field crashed the desktop app on old sessions**:
  [#23001](https://github.com/openai/codex/issues/23001) (closed), upgrading
  0.130.0-alpha.5→0.131.0-alpha.9 broke opening *every* thread lacking the new
  `session_meta.payload.thread_source` field with a generic "Oops, something
  went wrong." User's only fix: hand-edit rollout JSONL to backfill the field.
- *"The documented format and the real format don't match"*: 0%→100% parser
  accuracy only via empirical reverse-engineering (dev.to/milkoor, above).
- `turn_context` repeats near-identically across turns, "raising concerns
  about efficiency" ([Discussion #12668](https://github.com/openai/codex/discussions/12668)).

### DEMAND
Checkpoint schema (#8573, rejected for low upvotes); configurable retention
(#6015, open); curated cleanup UX surfacing cwd/last-activity/git-branch/size
so users can judge what's safe to delete ([#20230](https://github.com/openai/codex/issues/20230),
open: *"The main problem is not disk usage alone. It is that old sessions
become operational clutter... `codex resume --all` becomes harder to
scan."*); incognito/in-memory-only sessions (spun off #6526); legacy-format
recognition in `codex doctor` (#26877).

### HORROR
- **[#21196](https://github.com/openai/codex/issues/21196)** (open): Windows
  Desktop user found **91 thread rows in `state_5.sqlite` but only 1 rollout
  file on disk**: *"durable chat payloads were removed without corresponding
  metadata cleanup, causing previously available history to become
  unreachable."* Second reporter confirmed independently (125/126 rows, 0
  recoverable files). A third contributor root-caused the failure class on
  macOS: the live app-server held a rollout file open via file descriptor
  after the path was unlinked (`NLINK == 0` per `lsof`), kept writing into the
  void, and on restart the state DB silently dropped the thread row.
- **Plaintext secrets via shell snapshots** (
  [#30971](https://github.com/openai/codex/issues/30971) (open)) the
  default-enabled `shell_snapshot` feature sources `.zshrc` and persists
  `export -p` output, including real secrets, to
  `~/.codex/shell_snapshots/*.sh` in plaintext. Root cause confirmed in
  source: `EXCLUDED_EXPORT_VARS` in `codex-rs/core/src/shell_snapshot.rs` was
  **only `PWD`/`OLDPWD`**, no secret-name denylist at all. One report found a
  live 1Password service-account token captured. A second commenter reported a
  worse headless-server variant: *"a persistent plaintext credential store
  nobody asked for,"* with *"nothing in the logs."*
- **World-readable sessions**: [#21660](https://github.com/openai/codex/issues/21660)
  (open): rollout JSONL written at mode `0644`, directories `0755`, readable
  by any other local user; full prompts/responses/tool stdout exposed. Codex
  already uses the correct `0600` pattern elsewhere (`message-history`) but
  never applied it to the rollout recorder. Disclosed via Bugcrowd, closed Not
  Applicable under a "compromised host" exclusion the reporter disputed.
- **[#24089](https://github.com/openai/codex/issues/24089)** (closed
  completed): resumed pre-0.130.0 rollouts computed impossible context-window
  usage (4,284,409 / 258,400 tokens), because reconstruction ignored the
  latest surviving `compacted` checkpoint, and the built-in auto-compact then
  failed outright with `context_length_exceeded`: the corrupted persisted
  state disabled its own recovery mechanism.
- **[#31982](https://github.com/openai/codex/issues/31982)** (open): after a
  hard shutdown, Desktop resumed a checkpoint 2h20m behind actual git history:
  *"This is particularly dangerous because it is not obvious session loss. The
  agent continues confidently from stale beliefs about the workspace, creating
  a risk of duplicate commits, conflicting rebases, or overwriting valid
  completed work."*

---

## 3. Gemini CLI

### Layout + schema: a documented JSON→JSONL migration
Two subsystems: (A) **session recording** (`ChatRecordingService`,
`packages/core/src/services/chatRecordingService.ts`), path
`~/.gemini/tmp/<project_hash>/chats/session-<YYYY-MM-DDTHH-MM>-<sessionId8>.jsonl`,
subagent runs nested under the parent session; (B) **manual checkpointing**
(off by default): `checkpoints/*.json` conversation snapshots plus a shadow
git repo at `~/.gemini/history/<project_hash>` committing before every
file-modifying tool call.

Record schema (`chatRecordingTypes.ts`, current HEAD): `ConversationRecord
{sessionId, projectHash, startTime, lastUpdated, messages[], summary?,
memoryScratchpad?, directories?, kind:'main'|'subagent'}`; `MessageRecord`
variants for `user`/`info`/`error`/`warning`/`gemini` (the last carrying
`toolCalls[]`, `thoughts[]`, `tokens{input,output,cached,thoughts,tool,total}`,
`model`); `ToolCallRecord {id,name,args,result,status,timestamp,agentId}`.
The file is a **heterogeneous event stream**, not one message-shape per line:
first line is a metadata record, then `MessageRecord`s appended, plus a
`RewindRecord` (`{"$rewindTo":"<messageId>"}`, written on `/rewind`, marks
everything after superseded without rewriting the file) and a
`MetadataUpdateRecord` (`{"$set":{...partial}}`, e.g. patching `sessionId` on
resume). Disk-full is handled gracefully: `appendRecord` catches `ENOSPC`,
disables recording, logs a clear message, and the session continues unsaved.

**This is the clearest documented case of the JSON-vs-JSONL failure mode the
cross-cutting question is looking for.** For roughly a year (tool launch
through ~April 2026), the entire session was held in memory as one
`ConversationRecord` and **rewritten wholesale** (full `JSON.stringify`,
overwrite file) on every message or tool output.
[Issue #23740](https://github.com/google-gemini/gemini-cli/issues/23740)
(closed completed): *"In long sessions with heavy tool usage, this unbounded
accumulation linearly increases peak heap usage, causes severe garbage
collection pauses, and eventually causes the application to crash."* An
earlier attempt, [#15292](https://github.com/google-gemini/gemini-cli/issues/15292)
(Dec 2025), quantified it: *"JSON Rewrite: ~6.8 seconds per message. JSONL
Append: ~0.75 milliseconds per message. Improvement: >9000x faster."* Its fix
PR ([#15309](https://github.com/google-gemini/gemini-cli/pull/15309)) stalled
on CI-approval and was auto-closed 3.5 months later for inactivity: *not* a
maintainer rejection, a bot timeout. The real fix,
[PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749) (merged
2026-04-09), migrated to append-only `.jsonl` with a `metadataOnly` streaming
read mode for the session browser and an async 4KB-read deletion path (instead
of loading a potentially gigabyte file to find the id to delete it). Legacy
monolithic `.json` files remain readable via a compatibility fallback. Total
elapsed: ~4 months from first fix attempt to merge, with one community PR
dying of neglect along the way.

### Resume/checkpoint story
Era 1 (launch-Nov 2025): **manual-only**, `/chat save <tag>` / `/chat resume
<tag>` / `/chat list`; confirmed by maintainer markmcd conceding the
`/chat save`-before-every-message friction was *"a good FR"*
([Discussion #1538](https://github.com/google-gemini/gemini-cli/discussions/1538)).
Era 2 (v0.20.0, shipped 2025-12-01): automatic full-session persistence added.
`gemini --resume`/`-r`, `--resume <N|UUID>`, `--list-sessions`,
`--delete-session`; `/resume` opens a Session Browser (search by id or content
keyword); `/chat` becomes a documented alias of `/resume` with `list/save
<tag>/resume <tag>/delete <tag>/share [filename]` (exports Markdown or JSON).
Tagged checkpoints now act as **named branch points inside the automatic log**
rather than a separate mechanism. Settings: `general.sessionRetention:
{enabled, maxAge:"30d", maxCount:50}`. Resume reconstruction is a streamed
reduce (`readline`, apply `$rewindTo`/`$set` events onto an accumulated
`Map<id,MessageRecord>`): event-sourced, no LLM calls, not "reload one
blob." Known gap: **compression state isn't persisted**, 
[#20803](https://github.com/google-gemini/gemini-cli/issues/20803) (closed):
*"the session file on disk is never updated to reflect the compression"*, a
resumed session can reload pre-compression history that overflows the context
window, and *"the reconstituted history may itself be too large for the
summarization model."*

### GC/retention
`sessionRetention` config (post v0.20.0) is the first deletion mechanism the
tool ever had: the earlier manual-checkpoint era had none:
[Discussion #2284](https://github.com/google-gemini/gemini-cli/discussions/2284),
collaborator MarlonGamez: *"As of now, there isn't a way to delete a
checkpoint from within gemini cli. However, you can manually delete the
checkpoint from your filesystem."* Automatic checkpointing (shadow-git) has an
unfixed bloat bug, [#7328](https://github.com/google-gemini/gemini-cli/issues/7328)
(closed stale, no maintainer response): *"the shadow repository sees the
project's `.git` directory as just another folder and adds it to the staging
area"*, 3.8GB from a single brief session, 2.4GB pack file inside. Session
recording itself bloated independently: [#21652](https://github.com/google-gemini/gemini-cli/issues/21652)
(closed, no response): *".gemini took up 46G of disk space,"* individual
pre-migration session files at 18-19MB each (a size symptom of the JSON
full-rewrite architecture above, not just a slow-write symptom).

### LOVE
Thin, mostly institutional/comparative rather than organic delight. The
[Google Developers Blog](https://developers.googleblog.com/pick-up-exactly-where-you-left-off-with-session-management-in-gemini-cli/)
credits the shipped feature to *"meticulous work across nine-plus well-crafted
pull requests"* by community contributor Christopher Beeson. No unprompted
forum praise of the storage format itself was found: third-party tutorial
coverage treated Session Management as a worthwhile "hidden feature" to write
up, which is weaker evidence than the tooling-ecosystem proof-by-existence
found for Claude Code/Codex.

### HATE / DEMAND (merged: the demand lineage IS the complaint history)
Pre-auto-save era: *"I'd like Gemini to automatically record and save
conversation histories like Claude Code and other tools"*
([#3882](https://github.com/google-gemini/gemini-cli/issues/3882), the master
tracking issue), with a telling aside that `/chat save` felt untrustworthy by
design: *"intended for temporary work; hence the name `.tmp`."*
[#11249](https://github.com/google-gemini/gemini-cli/issues/11249): *"An
unexpected terminal closure or system restart wipes out this progress...
Lacking this feature makes the CLI feel less robust."* Post-ship, the
complaint class shifted from *absence* to *reliability of the new mechanism*:
- [#19947](https://github.com/google-gemini/gemini-cli/issues/19947) (closed
  not planned): crash-then-resume showed the session in the picker but *"all
  history is missing... I'm afraid my project progress is lost :("*
- [#27368](https://github.com/google-gemini/gemini-cli/issues/27368) (open,
  p1), using `gemini --resume` causes the **most recently used session to
  permanently vanish** from `/chat list` on the next normal launch, a
  regression in the exact feature built to prevent data loss.
- [#24639](https://github.com/google-gemini/gemini-cli/issues/24639) (closed),
`Storage` is constructed once with the startup session id and never
  rebinds on `setSessionId()`, so plan/tracker/task artifacts get silently
  written under the *wrong* (pre-resume) session namespace, split-brain
  state across two ids at once.
- [#6960](https://github.com/google-gemini/gemini-cli/issues/6960) (export
  request) fulfilled by [PR #5342](https://github.com/google-gemini/gemini-cli/pull/5342)
  adding `/export jsonl|markdown`, later folded into `/chat share`.

### HORROR
The OOM/crash architecture flaw itself (#23740, above) is the headline: 
persistence capable of killing the very session it protects. Layered on top:
silent permanent loss via the documented resume flag (#27368); unrecoverable
context overflow from stale compression state (#20803); session-id split-brain
corrupting adjacent artifact stores (#24639). No secret-leakage-in-checkpoint
incident was found in this pass (targeted search came up empty; not the same
as "doesn't exist").

---

## 4. grok CLI (xAI): identity disambiguation required first

**There is no single "grok-cli."** Two different tools share the name and
conflating them corrupts any claim about "the format":

| | **Grok Build** (official, xAI) | **grok-cli** (community, `superagent-ai/grok-cli`) |
|---|---|---|
| Provenance | First-party, announced May 2026 ([x.ai/news/grok-build-cli](https://x.ai/news/grok-build-cli)) | README: *"community-built, open-source, and not affiliated with, endorsed by, or sponsored by xAI Corp."* |
| Install | `curl -fsSL https://x.ai/cli/install.sh \| bash` | npm/Bun |
| Storage confirmed | `~/.grok/sessions/` (docs describe behavior, not schema) | `~/.grok/grok.db`, SQLite |
| Source open? | No | Yes |

### Layout + schema
**Community `grok-cli`**: the only one with a verifiable concrete schema,
sourced from the actual repo (`src/storage/db.ts`, `migrations.ts`,
`sessions.ts`, per [DeepWiki storage page](https://deepwiki.com/superagent-ai/grok-cli/10.2-storage-and-persistence),
cross-checked against [PR #165 diff](https://github.com/superagent-ai/grok-cli/pull/165/files)):
single SQLite DB, WAL mode, foreign keys on, **schema version 2**, tables
`workspaces, sessions, messages, tool_calls, tool_results, usage_events,
compactions` (the last storing the sequence number of the first retained
message post-summarization). 12-char generated session ids. This *supersedes*
an earlier loose-JSON-file implementation
([PR #16](https://github.com/superagent-ai/grok-cli/pull/16/files):
`~/.grok/user-settings.json`, `todos.json`, `bash-session.json`): the tool
matured JSON-files → SQLite as it grew, the inverse direction from Gemini
CLI's JSON→JSONL migration, worth noting as a second real-world data point on
what "growing up" a storage layer looks like.

**Official Grok Build**: docs confirm behavior and commands but not the
per-message schema: *"Grok saves every conversation to disk automatically (
prompts, responses, tool calls, and file snapshots) under `~/.grok/sessions/`,
keyed by working directory"* ([docs.x.ai/build/features/sessions](https://docs.x.ai/build/features/sessions)).
Commands: `--resume <id>`/`-c`, `/resume` (TUI picker), `/fork [directive]`
(branches into a peer, optionally its own worktree), `/rewind`/Esc-Esc (lists
a rewind point per prompt; *"restores all files to their state at that point
and truncates the conversation to match"*: file-snapshot-backed, not
message-log-only), `/compact`, `grok sessions list|search|delete`, `grok
export <id> [file]`. Grok Build's CLI is **not open source**, no field-level
schema could be verified; two SEO-farm sources gave conflicting NDJSON
event-type lists for its headless output mode, so neither is reported as fact.

### The praise claim: does not hold up under forum-first research
Targeted search (Reddit r/grok, r/LocalLLaMA, r/artificial, HN, general web)
for quotes praising grok-cli/Grok Build's session-storage design specifically
(portability, readability, resume reliability, hand-editability) returned
**zero results**. `site:reddit.com "grok build" OR "grok cli" resume session`
→ nothing. The live HN threads about Grok Build
([48877371](https://news.ycombinator.com/item?id=48877371),
[48892468](https://news.ycombinator.com/item?id=48892468),
[48896493](https://news.ycombinator.com/item?id=48896493)) are dominated
entirely by the cloud-upload privacy scandal below, not storage-format
architecture. Comparison articles that do exist focus on model routing,
multi-agent parallelism (8 concurrent agents), and context-window size as
differentiators: one flags the *opposite* of praise: each session starts
"from a clean slate" with no cross-session project memory, unfavorably
contrasted with ChatGPT/Claude persistent memory (medium confidence,
content-farm sourcing). **Recommendation: treat "grok CLI's storage is
praised" as an unconfirmed premise**, either the praise lives on X/Twitter
(not searchable here), the tool is too new (~2 months old) to be indexed yet,
or the premise was simply wrong. One real, if modest, positive signal:
third-party session broker `cmux` has first-class Grok hook integration
(`cmux hooks setup grok`, resume via `grok -r <id>`, captured session
ids/workspace/surface/cwd/pid stored in
`~/.cmuxterm/grok-hook-sessions.json`): evidence Grok's session-id model is
stable enough to build on, in the same interoperability tier as the other
three tools, but that's *interoperability* evidence, not *praise* evidence.

### DEMAND
[Issue #158](https://github.com/superagent-ai/grok-cli/issues/158) (opened
2026-03-19, closed via PR #165) is the direct cause of the SQLite
architecture: *"message history needs persistent storage (either through
SQLite or the `.agents` folder) to enable users to 'continue from where they
left off.'"* I.e. the community tool had **no session persistence at all**
until this request drove it. No storage-specific bug reports found in either
tracker.

### HORROR: real, but not a storage-corruption story
The single most consequential fact about Grok Build's storage architecture
right now is a **covert data-exfiltration channel sharing infrastructure with
session storage**. Discovered July 2026
([gist.github.com/cereblab](https://gist.github.com/cereblab/dc9a40bc26120f4540e4e09b75ffb547),
corroborated by [The Hacker News](https://thehackernews.com/2026/07/grok-build-uploads-entire-git.html),
[The Register](https://www.theregister.com/ai-and-ml/2026/07/14/musk-promises-purge-after-grok-build-caught-sending-entire-repos-to-the-cloud/5271123),
[CybersecurityNews](https://cybersecuritynews.com/xai-grok-build-cloud-storage/),
HN front page): Grok Build silently uploaded **entire git repositories** (
full history, untracked files, everything) to a GCS bucket xAI controls,
`grok-code-session-traces`. Quote: *"model-turn traffic to `/v1/responses`
came to about 192 KB while the storage channel to `/v1/storage` moved 5.10
GiB, a roughly 27,800x gap."* A planted canary file Grok never touched still
appeared in the uploaded bundle *"verbatim along with the repo's full commit
history."* A tracked `.env` went along "unredacted, canary `API_KEY` and
`DB_PASSWORD` values and all." The user-facing "improve the model" privacy
toggle was cosmetic: *"That toggle governs whether your data trains the
model. It does not govern whether your code leaves the machine."* xAI shipped
a silent fix (`disable_codebase_upload:true`) July 13 2026 after the story hit
HN's front page; Musk reportedly promised deletion of previously uploaded
data. The naming (`grok-code-session-traces`) shows xAI's internal model
literally conflates "save my session for resume" with "harvest my repo": 
local staging for this pipeline (`~/.grok/upload_queue/*`,
`before_codebase.tar.gz`/`after_codebase.tar.gz`, `~/.grok/logs/unified.jsonl`)
sits in the same `~/.grok/` root as legitimate session data, undisclosed and
uncontrollable by the user until the July fix. **This is the biggest horror
story in the entire brief**, not corruption or GC deletion, but resume
infrastructure doubling as an undisclosed telemetry/training-data pipeline.

### Resume semantics
Official Grok Build: not documented as full-replay-against-the-model; restores
the persisted local transcript and continues. `/rewind` is snapshot-backed
(files + conversation truncated together, in lockstep). `/fork` copies state
into a peer session/worktree. Community `grok-cli`: reads `sessions` →
`messages`/`tool_calls`/`tool_results` back out of SQLite in sequence;
`compactions` rows mean resume-with-compaction is summary-based *past* the
checkpoint and full-replay *before* it.

---

## Cross-cutting answers

### A. Format convergence
Append-only JSONL is the de-facto winner for **transcript** storage: Claude
Code, Codex, and (after a documented failure and 4-month fix cycle) Gemini
CLI all converged on it. The two deviations found and their fates:
- **Gemini CLI deviated hardest**: full in-memory `JSON.stringify` +
  whole-file overwrite on every message, for roughly a year. Consequence:
  OOM crashes in production, a 9000x-slower-per-write benchmark
  (#15292), 18-19MB session files, 46GB `.gemini/tmp` reports. Fixed by
  migrating to JSONL (#23749, merged 2026-04-09).
- **Community grok-cli deviated the other direction**: went JSON files →
  SQLite as it matured (not JSONL), trading append-only simplicity for
  relational query power (7 tables, foreign keys, WAL mode). No bloat/crash
  horror stories found for this choice, but also less third-party tooling
  evidence than the JSONL tools (SQLite is harder to `grep`/pipe than JSONL).
- Codex additionally shows the *cost of not versioning* the JSONL schema:
  three incompatible generations coexist on disk (#26877), and a single
  new required field crashed the desktop app on old sessions (#23001): 
  JSONL-as-format doesn't automatically buy forward/backward compatibility;
  that has to be designed in separately (see Steal #2 below).

### B. What's stored beyond the message
All four store: message/turn ids, some form of parent/thread linkage,
timestamps, cwd, model, token usage. Differentiators:
- **Claude Code** is the only one with an explicit DAG (`parentUuid` per
  message, not just per session), enabling branch/fork navigation, at the
  cost of tip-finding bugs when non-conversational entries are miscounted as
  tips (#43764).
  and structural entries encoding UI state (`permission-mode`,
  `queue-operation`) that leak implementation detail into the log.
- **Codex** separates thread/turn/item as genuinely distinct addressable
  levels (separate JSON-RPC endpoints), not just log nesting: the strongest
  formalization of "resume needs more than the message list" found.
  `turn_context` snapshots (cwd, model, approval/sandbox policy) travel with
  the log, though redundantly repeated per-turn (efficiency complaint).
- **Gemini CLI** stores `thoughts[]` (reasoning traces) and a
  `memoryScratchpad` field per conversation record: the only tool found with
  an explicit cross-turn scratchpad slot in the schema itself, though it's
  thin on other structural metadata (no explicit DAG).
- **grok-cli (community)** is the only one storing git state via a normalized
  `workspaces` table (project dirs, git roots, access timestamps) rather than
  embedding `cwd`/`gitBranch` as flat per-message fields: a relational
  win specific to its SQLite choice.

### C. Version/migration story
This is the weakest link across the board, not just a Gemini CLI problem:
- Claude Code: **no version field, no stability guarantee, documented as an
  internal implementation detail that changes "almost daily"**: the vendor's
  own stated position. Community demand for SemVer (#53516) is open and
  unaddressed.
- Codex: three schema generations coexist un-normalized; one new required
  field (`thread_source`) broke opening every pre-upgrade session on the
  desktop app until users hand-patched their own JSONL files (#23001).
- Gemini CLI: the JSON→JSONL migration (#23749) is the one case in this
  survey with an actual **documented backward-compatibility fallback**: 
  *"Added a robust fallback to `loadConversationRecord` to gracefully read,
  parse, and process monolithic `.json` sessions from prior versions of the
  CLI... ensuring users do not lose their history or break the session UI
  upon upgrading."* This is the single best migration-engineering artifact
  found in the whole survey.
- grok-cli (community): linear numbered migrations (`schema version 2`) is
  the only tool using conventional DB-migration tooling rather than ad-hoc
  format tolerance: a direct SQLite benefit.

### D. Resume semantics: full-replay vs snapshot
None of the four do naive flat-file replay. All are some form of **event
reduction over a log, with a checkpoint/snapshot fast-path**:
- Claude Code: backward `parentUuid` walk from a tip, `summary` records mark
  known-good resumption points.
- Codex: reverse scan to find the newest `compacted`/`WorldState` baseline,
  then forward replay from there.
- Gemini CLI: streamed `readline` reduce applying `$rewindTo`/`$set` events
  onto an accumulated map, purely local, no LLM calls.
- grok-cli (community): SQL row read plus `compactions` checkpoint table.

**What's outside the transcript that resume needs and loses, confirmed
across all four:**
1. File-system state at edit time: Claude Code's checkpoint store excludes
   bash-mutated files by design; Codex's context-window/token-count state can
   desync from actual history after compaction (#24089); Gemini CLI's
   on-disk log doesn't reflect in-context compression at all (#20803).
2. Git/VCS state, Codex resumed 2h20m behind actual git history after a
   crash, with the agent continuing "confidently from stale beliefs" (#31982),
the sharpest concrete example of resume needing external-world state the
   transcript can't carry.
3. Auxiliary artifact namespaces bound to session id: Gemini CLI's
   plan/tracker/task `Storage` object doesn't rebind on resume, silently
   writing to the wrong session's namespace (#24639).
4. Live in-memory state not yet flushed: Claude Code's VS Code extension
   kept the *entire* main transcript in memory only, no disk write path at
   all, until an extension update wiped 30 sessions (#22900).

### E. The steal-list: top 5, with attribution
1. **Backward-compatible schema migration with an explicit fallback reader,
   not silent breakage.** Gemini CLI's `loadConversationRecord` accepting both
   old monolithic-JSON and new JSONL shapes (PR #23749) is the one example in
   this survey of a vendor *documenting* how old sessions survive a storage
   rewrite. Steal the pattern: any format change ships a reader that still
   understands N-1, not just N.
2. **SemVer the transcript schema separately from the CLI/app version**, with
   an explicit additive-safe / breaking-requires-notice policy. This is
   *requested*, not shipped, anywhere in the survey (Claude Code #53516 is the
   clearest articulation), which makes it a genuine opportunity, not
   catch-up work.
3. **Explicit checkpoint/summary markers embedded in the log itself**
   (Claude Code's `summary{leafUuid}`, Codex's `compacted{replacement_history}`,
   Gemini CLI's `$rewindTo`/`$set` events, grok-cli's `compactions` table): 
   all four independently reinvented "a pointer record marking a known-good
   resumption point inside the append-only log," which is strong convergent
   evidence it's the right shape. Steal it as a first-class record type from
   day one, not bolted on after a resume-corruption incident.
4. **Deterministic, non-LLM checkpoint state as a design goal**: Codex's
   rejected `checkpoint_v1.json` RFC (#8573) is worth stealing *despite*
   OpenAI closing it for low engagement: task/plan/decisions/facts as
   structured, host-computed projections of the log (not a model-generated
   summary) sidesteps the entire "lossy summarization compaction" complaint
   category that dominates every other tool's HATE section.
5. **Tip-finding/resume-anchor logic must exclude non-conversational entries
   by construction, not by a runtime filter that can be gotten wrong.**
   Claude Code's Dormammu bug (#43764) (a UI-state or snapshot record with
   default `isSidechain:false` becoming a false resume tip) is a type-safety
   problem, not a logic bug: if the "candidate resume anchor" type only
   contains conversational variants, the entire bug class is structurally
   impossible. Directly actionable for Raxol's own event-sourced render/state
   log if it ever needs resume/checkpoint semantics.

Runner-up steal, cross-cutting rather than tool-specific: **graceful
degradation on write failure over crash-on-write**: Gemini CLI's `ENOSPC`
handler (disable recording, log a clear message, keep the session usable) is
the one disk-full story in this survey that *doesn't* end in a horror story,
in direct contrast to Claude Code's ENOSPC → zero-length-config → full
settings/auth reset cascade (#24207).
