# Raxol Journal

Append-only, file-backed session journal, and the event envelope it stores.
One directory per session, a single writer, replay that tolerates a torn tail,
an optional hash chain, and checkpoint records. Depends on Jason and
`:telemetry`.

## Install

```elixir
{:raxol_journal, "~> 2.8"}
```

It replaces the journal inside `raxol_agent` 2.7.0, which defines the same
modules: do not combine the two. Beside `raxol_agent`, it needs a
`raxol_agent` release later than 2.7.0.

## Quick start

```elixir
alias Raxol.Agent.Journal.FileStore

{:ok, journal} = FileStore.open("session-1", base_dir: "/var/lib/app/sessions")
{:ok, 1} = FileStore.append(journal, %{"type" => "turn_started", "payload" => %{"prompt" => "hi"}})
{:ok, [%{"id" => 1, "type" => "turn_started"}]} = FileStore.read(journal)
:ok = FileStore.close(journal)
```

Without `:base_dir` the base is `$RAXOL_SESSIONS_DIR`, else `~/.raxol/sessions`.

## The event contract

`Raxol.Agent.Contract.Event` is the envelope. An event carries `id`,
`turn_id`, `ts`, `family`, `type`, `tier`, `scope`, `provenance` and `payload`.
Two properties of that shape are load-bearing:

- **Two families.** `:loop` events are the agent's turns; `:meta` events are
  everything else.
- **Two tiers.** Durable events are journaled before they reach a surface.
  `item_delta` is the one ephemeral event: it is never journaled and is
  reconstructable from the matching `item_completed`, so no durable state
  depends on having seen every chunk.

**The contract only grows.** A field or a type is added, never removed, renamed
or made required. Producers are strict; readers are tolerant and skip what they
do not recognize.

`Raxol.Agent.Contract.encode_line/1` encodes an event as one JSON line and
`sanitize_payload/1` makes a payload JSON-encodable. `evidence_status/1` decodes
the `evidence` marker on a closing `turn_completed` to `:accepted`,
`:rejected`, `:absent` or `:unknown`.

## The journal

`Raxol.Agent.Journal` is the append-only behaviour.
`Raxol.Agent.Journal.FileStore` is the file-backed implementation:

```
<base>/<session_id>/
  meta.json          created_at, cwd, git_branch, title, schema_version, chain
  HEAD               current durable offset and segment
  writer.lock        the live Writer's OS pid and start time
  journal/
    000001.jsonl     one JSON object per line, size-capped segments
  snapshots/         checkpoint payloads, named by SHA-256
```

Each appended event is assigned a monotonic offset, which is its `id`. While a
Writer has the journal open, `writer.lock` names its OS process, so a second
BEAM does not write the same journal.

Interior corruption is fail-closed: `Reader.scan/2` returns
`{:damaged, records_before}`, deletes nothing, logs an error and emits
`[:raxol, :agent, :journal, :damaged]`. The damaged content is never returned.

Reads never write. A torn tail (a parse failure on the last line of the last
segment, the signature of a crash mid-write) is tolerated in memory by
`Reader.scan/2` and repaired only by the owning Writer at its own start, via
`Reader.resume_scan/1`. A reader that truncated could delete a record a live
Writer had already committed.

`open(session_id, chain: true)` creates a hash-chained journal
(`Raxol.Agent.Journal.Chain`); `verify/1` reports the first record that does not
link. `open(session_id, private: true)` keeps the directories 0700 and the
files 0600, and refuses a base or session directory that is a symlink, is owned
by another account or is group- or other-writable.
`Raxol.Agent.Journal.Records.Checkpoint` writes checkpoint pointer records
through the same Writer, and `Raxol.Agent.Journal.Tip` locates the resume
point.

### Telemetry

| Event | Metadata |
| --- | --- |
| `[:raxol, :agent, :journal, :damaged]` | `dir`, `segment` |
| `[:raxol, :agent, :journal, :write_failed]` | `stage`, `reason` |
| `[:raxol, :agent, :journal, :checkpoint, :surrogate]` | `op`, `session_id`, `tip_offset` |

## Frozen golden corpora

Every record carries the `schema_version` the Writer stamped. Reading a
journal written by an older version can only be tested against journals that
version wrote, and nothing regenerates a 1.0.0 journal once the Writer emits
1.2.0.

So `priv/golden/v<version>/` holds one journal per schema version, frozen
while that version was the default, and `priv/golden/MANIFEST.json` pins the
SHA-256 of every file. A corpus is never edited or deleted. Only `ts`,
`turn_id` and `meta.json`'s `created_at` were normalized when it was frozen, so
its bytes are reproducible.

```elixir
golden = Application.app_dir(:raxol_journal, "priv/golden")
```

## `Raxol.Journal` aliases

Every module is also reachable under `Raxol.Journal`: `Raxol.Journal.FileStore`
delegates to `Raxol.Agent.Journal.FileStore`, `Raxol.Journal.Contract` to
`Raxol.Agent.Contract`, and so on. Structs, behaviours and process names keep
their `Raxol.Agent.*` names. `Raxol.Journal` lists the pairs.

## Test helpers

`Raxol.Journal.Test.FaultJournal` (fault injection and a raw-read oracle for
the storage path), `Raxol.Journal.Test.ForeignBeam` (a second BEAM, for the
writer lock) and `Raxol.Journal.Test.MutationAnchor` are for ExUnit suites:
this package's and a dependant's. They call ExUnit, which a test run has
loaded. `:ex_unit` is not among the package's applications, and no other
module in the package calls them.
