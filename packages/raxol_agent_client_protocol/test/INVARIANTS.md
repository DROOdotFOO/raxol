# ACP invariant registry (package-local, test-prime)

This is the **single, in-repo, test-co-located registry** for every named
invariant this package enforces. It is test-prime on purpose: it lives beside
the suite (`test/INVARIANTS.md`), not in `lib/`, not at the package root, not in
a global spec. Every ID below is **referrable both ways** — a test/describe name
cites its ID, and this file resolves that ID to a canonical one-line property +
its layer + the enforcing test at `file:line`. If you rename a cited test, fix
its row here (the `torture/pbus_coverage_audit_test.exs` drift-detector already
mechanically enforces this for the P-BUS/J citations).

Canonical statements are reconstructed from the enforcing test name and the
`lib/` moduledoc gloss. The authoritative *prose* originally lived in external,
un-checked-in design specs (`acp-*-design.md`, `harness-bus-protocol.md`); those
are referenced for provenance but are NOT the in-repo source of truth — **this
file is.**

## Layers

- **CORE** — the JSON-RPC/session/connection/framing spine. Families: `I`,
  `Inv`, `IC`, `F`.
- **EXTENSION** — the `_`-prefixed reattach/journal/attach-policy moat.
  Families: `J`, `P-BUS`, `P-JS`, `INV-AP`, `CDI`.

## Status markers

- **RESERVED** — the ID is intentionally unfilled: it names a slot whose
  canonical statement lives only in an external design-spec and has no in-repo
  test. Listed explicitly so a numbering gap is never a *silent* gap. Do not
  invent a property for these.
- **alias** — the ID is a dual-tag/cross-index of another canonical ID; not a
  separate invariant, not double-counted.

---

# CORE

## Family `I` — session turn state machine (I1..I19)

Home: `test/session_test.exs` (Session GenServer over `FakeConnection`), except
the two new method-parity rows I18/I19 (see their entries). Moduledoc: the
`Session` gloss in `lib/raxol/agent_client_protocol/session.ex:57`.

| ID | Canonical property | Enforcing test (`file:line`) |
|----|--------------------|------------------------------|
| I1 | **RESERVED** — no in-repo canonical statement (external design-spec ref); intentionally unfilled. | — |
| I2 | A session resolves in the Registry (`:via` name minted) BEFORE `start_link/1` returns — register-before-respond by construction. | `session_test.exs:141` |
| I3 | Every `session/update` frame of a turn precedes that turn's response frame (updates and reply share one FIFO lane). | `session_test.exs:163` |
| I4 | The prompt response waits until every turn-group task is DOWN (hold-turn-open; drain fires at monitor-count zero). | `session_test.exs:197` |
| I5 | A cancel landing after the root task is DOWN but before the last subagent is DOWN still yields `stopReason: cancelled` (cancel outranks a landed root result). | `session_test.exs:236` |
| I6 | Cancel-of-idle emits NO frame — only the latch moves; a later prompt runs normally. | `session_test.exs:323` |
| I7 | A mid-turn cancel yields exactly ONE cancelled reply; a double-cancel adds nothing. | `session_test.exs:268` |
| I8 | Permission is fail-closed: ONLY a decoded `{:selected, _}` outcome yields allow; every other row denies. | `session_test.exs:378` |
| I9 | A turn cancel aborts a parked permission ask promptly via the cancel path (deny), not by waiting out the backstop. | `session_test.exs:289` |
| I10 | **RESERVED** — no in-repo canonical statement (external design-spec ref); intentionally unfilled. | — |
| I11 | No stale registry entries: a dead session's key is pruned by the Registry monitor. | `session_test.exs:419` |
| I12 | Busy-prompt isolation: a second prompt on a prompting session errors; the first is undisturbed. | `session_test.exs:430` |
| I13 | Backstop: a runner that ignores `:acp_cancel` still resolves cancelled via kill; a stale backstop (wrong `turn_ref`) never touches the live turn. | `session_test.exs:453` |
| I14 | No atom is created from session data: `session_id` churn does not grow the atom table. | `session_test.exs:568` |
| I15 | Two sessions on one connection are independent: each session's updates precede its OWN response; turns don't interfere. | `session_test.exs:702` |
| I16 | Wire-order commutation: a prompt wire-ordered before a latched cancel is born-cancelled; one ordered after (higher `rx_seq`) runs unaffected. | `session_test.exs:341` |
| I17 | `$/cancel_request` on the prompt id: the drain STILL calls `reply/3` for the cancelled id (releases `pending_in`, S7). | `session_test.exs:601` |
| I18 | **[NEW]** `session/resume` gates fail-closed on `session_capabilities.resume` AND dispatches (decode → `resume_session/2`). Capability-parity + dispatch-parity for the resume method. | gate: `capabilities_test.exs` describe `"I18 session/resume gates ..."`; dispatch: `router_test.exs` describe `"I18 session/resume decode + dispatch"` |
| I19 | **[NEW]** `session/set_config_option` decodes to `SetSessionConfigOptionRequest` AND dispatches to `set_session_config_option/2` (baseline method, no capability gate). | `router_test.exs` describe `"I19 session/set_config_option decode + dispatch"` |

*Choice note (I18/I19):* the task allowed extending `I`/`Inv` with the next free
contiguous number OR reusing a reserved slot. I18/I19 **extend `I` contiguously**
(I17 was the prior max). I did NOT reuse I1/I10 — those stay RESERVED for their
external statements per instruction. I18/I19 are session-*method* parity
invariants; their tests live in `capabilities_test.exs`/`router_test.exs` (the
capability-gate and dispatch layers), not in `session_test.exs`, because
`session/resume` and `session/set_config_option` dispatch to a handler callback
via `Router`, not through the Session GenServer.

## Family `Inv` — Connection correlation/dispatch (Inv-1..Inv-21, contiguous)

Home: `test/connection_test.exs`, `describe "invariants"`. Moduledoc: the
`Connection` "Correctness spine" at `lib/raxol/agent_client_protocol/connection.ex:41`.

| ID | Canonical property | Enforcing test (`file:line`) |
|----|--------------------|------------------------------|
| Inv-1 | Exactly one answer per accepted outbound submission; ZERO after a peer `$/cancel_request`. | `connection_test.exs:403` |
| Inv-2 | No stale `pending_out`/`out_tags` entry survives any exit path. | `connection_test.exs:458` |
| Inv-3 | A timeout answers AND deletes atomically; a late response after it is a pure no-op. | `connection_test.exs:513` |
| Inv-4 | **alias of IC-6** — the response-count invariant. Enforcing test renamed to lead with IC-6. | `connection_test.exs:556` (test `"IC-6 (Inv-4 alias): response-count invariant ..."`) |
| Inv-5 | Notifications never produce a wire frame, incl. under decode failure and handler crash. | `connection_test.exs:608` |
| Inv-6 | Response id echo is byte-exact across error classes, string and integer ids. | `connection_test.exs:633` |
| Inv-7 | No atom is created from wire input (unknown methods, notifications, session ids). | `connection_test.exs:724` |
| Inv-8 | A handler calling `Connection.request/4` back into the same Connection completes promptly (no self-deadlock). | `connection_test.exs:765` |
| Inv-9 | `conn == self()` raises `ArgumentError` on every public API function. | `connection_test.exs:791` |
| Inv-10 | Handshake gate: agent role (inbound `-32600`, outbound `not_initialized`); client role (outbound gate then successful handshake). | `connection_test.exs:805`, `:828` |
| Inv-11 | `caps` is written exactly once at handshake and never mutated after. | `connection_test.exs:848` |
| Inv-12 | Transport-down delivers total cleanup for `pending_in` (undelegated killed, delegated silent). | `connection_test.exs:890` |
| Inv-13 | Closed-delivery + monitor DOWN is idempotent (single cleanup, single stop). | `connection_test.exs:922` |
| Inv-14 | A duplicate in-flight inbound id produces zero additional frames. | `connection_test.exs:954` |
| Inv-15 | Malformed frames never terminate the connection or disturb an in-flight request. | `connection_test.exs:987` |
| Inv-16 | Handler crash detail never reaches the wire. | `connection_test.exs:1021` |
| Inv-17 | Every task ref / reply_ref is tracked and reaped at quiescence. | `connection_test.exs:1034` |
| Inv-18 | Ids are opaque after minting — a pre-namespaced string id from a fan-out proxy round-trips. | `connection_test.exs:1068` |
| Inv-19 | Delegated-reply idempotence across reply/second-reply/adopter-DOWN/cancel interleavings. | `connection_test.exs:1082` |
| Inv-20 | `rx_seq` is monotone across an interleaved inbound burst. | `connection_test.exs:1122` |
| Inv-21 | `session/cancel` delivery runs no user code and survives any handler crash. | `connection_test.exs:1155` |

## Family `IC` — shared Interface Contract (IC-1..IC-8)

The cross-module seam contract, byte-identical across the connection and
supervision designs. Cited pervasively in `lib/` moduledocs
(`connection.ex:44`) and exercised across `connection_test.exs`, `ctx_test.exs`,
`session_test.exs`, `integration/end_to_end_test.exs`. Most IC clauses are
cross-cutting contracts rather than one dedicated test; the representative
enforcing test is cited.

| ID | Canonical property | Enforcing test (representative) |
|----|--------------------|----------------------------------|
| IC-1 | ONE GenServer per peer link is the sole correlation/dispatch authority: never blocks, never runs handler code in-process, never mints atoms from wire input. | `connection_test.exs` `describe "§8 sequence diagrams"` (`:206`) + Inv-7/Inv-8 |
| IC-2 | `Connection.Ctx` is THE single per-dispatch struct handed to handler callbacks (`conn`, `reply_ref`, `rx_seq`); there is exactly one ctx concept. | `ctx_test.exs` (whole suite; moduledoc `:16`) |
| IC-3 | `async_request/6` is THE outbound primitive (only it accepts `:infinity`); `request/4` is a caller-parking wrapper on the same `pending_out` table; Connection is the single timeout authority. | `ctx_test.exs:329`; `connection_test.exs` `describe "§8 sequence diagrams"` |
| IC-4 | Delegated reply: `delegate_reply/3` + `reply/3` + `:deferred` let the Session own WHEN the prompt response is sent, keeping updates + response on one FIFO lane. | `connection_test.exs:1082` (Inv-19); `session_test.exs:601` (I17) |
| IC-5 | (IC-5c) `rx_seq` latch — cancel and prompt commute by wire order, not scheduling order. | `session_test.exs:341` (I16) |
| IC-6 | **Response-count invariant (canonical):** at most one response frame per inbound id; exactly one unless the peer `$/cancel_request`'d it first (then zero). `Inv-4` is its alias. | `connection_test.exs:556` |
| IC-7 | The Connection never blocks — no `GenServer.call` to itself, no synchronous wait on tasks, no transport call that waits on peer progress. | `connection_test.exs:765` (Inv-8) |
| IC-8 | Sibling supervision tree: `task_sup`/`session_sup` resolved from the parent supervisor by module/type heuristic (injectable in tests); Connection is `:temporary`. | `connection_test.exs:88`; `integration/end_to_end_test.exs:300` |

## Family `F` — NDJSON framing / transport (F1..F7) — **[NEW registration]**

Home: `test/transport/framer_test.exs`. These IDs *name what the existing
thorough framer tests already prove* — no test behavior was rewritten; each
`describe` block was renamed to lead with its F-ID and the file moduledoc now
carries the family legend.

| ID | Canonical property | Enforcing test (`describe`) |
|----|--------------------|-----------------------------|
| F1 | A frame ends at a single `\n`; partial input buffers until its terminator, split frames reassemble, multiple frames in one chunk yield in order, byte-at-a-time reconstructs, an empty push is a no-op. | `framer_test.exs` `describe "F1 basic framing ..."` |
| F2 | CRLF tolerated: a trailing CR before the LF is trimmed; LF and CRLF terminators mix in one stream; a CR split from its LF across chunks still trims. | `framer_test.exs` `describe "F2 CRLF tolerated ..."` |
| F3 | Empty-line skipping: a bare `\n`/`\r\n` is skipped, never yielded as an empty frame; interleaved keep-alive blank lines are dropped, order preserved. | `framer_test.exs` `describe "F3 empty-line skipping ..."` |
| F4 | Oversized-frame rejection + resync: a line exceeding `max_frame_bytes` yields `{:frame_too_large, size}` WITHOUT unbounded buffering and resyncs at the next terminator (surrounding frames intact, exactly-at-limit passes, default 64MiB, `new/1` rejects non-positive max). | `framer_test.exs` `describe "F4 oversized-frame rejection + resync ..."` |
| F5 | Volume / no-loss: no data loss or reordering across 10k frames fed in randomly sized chunks; the buffer drains empty. | `framer_test.exs` `describe "F5 volume ..."` |
| F6 | Re-chunking invariance (property): any re-chunking of concatenated JSON lines yields the original frames in order; CRLF and LF terminators are equivalent; an oversized frame errors then resyncs (totality). | `framer_test.exs` `describe "F6 re-chunking invariance ..."` |
| F7 | **[NEW]** Transport ordered delivery (T-ORD, `transport.ex` "Delivery guarantees"): per direction, frames delivered to the owner as `{:message, frame}` arrive in EXACTLY the order the peer's send path accepted them — pinned against `Transport.Paired`; a deliberately-reordering fake transport run through the identical check FAILS it (falsifier proof: the check is sensitive to reordering, not vacuous). | `test/transport/ordering_contract_test.exs` `describe "F7 T-ORD conformance: Transport.Paired"` (green) + `describe "F7 red variant: the conformance check is a real falsifier"` (red) |

*Note (F7):* lives in its own file (`ordering_contract_test.exs`), not
`framer_test.exs` — it exercises the `Transport` behaviour contract
(acceptance-order delivery across a whole transport), not the Framer's
byte-splitting, so it does not belong beside F1-F6.

---

# EXTENSION

The `_`-prefixed reattach/journal/attach-policy moat. **Error-code boundary:**
`-32000` ("attach denied", CDI-5) and `-32002` ("resource_not_found", never-seen
session on reattach) are produced ONLY on the EXTENSION attach path, never in
CORE. This is a deliberate boundary — CORE speaks only the standard JSON-RPC
codes (`-32600/-32601/-32602/-32603/-32700`) — not a coverage gap.

## Family `J` — reattach / journal invariants (J1..J12)

Home: `test/ext/reattach_test.exs`, `test/ext/journal_test.exs`,
`test/ext/journal_writer_test.exs`. Coverage is mechanically audited by
`test/torture/pbus_coverage_audit_test.exs` (drift-detector). Every positive
contour ships a named dead-injector negative control (bus §9).

| ID | Canonical property | Enforcing test (`file:line`) |
|----|--------------------|------------------------------|
| J1 | Replay closure over the wire: `history ++ live == the durable substream`, no gap, no dup, incl. turn-boundary kinds (dead: a taint-filter breaks closure). | `reattach_test.exs:240` |
| J2 | Register-before-`h`, decision-time `h`, permanent monotone gate armed before live: `offset <= h` dropped forever, `offset > h` forwarded once (dead: register-after-history / cached-counter → gap). | `reattach_test.exs:321`; `journal_test.exs:104` |
| J3 | Single-publisher: no public publish surface exists — publishing is the Writer's alone; a subscriber receives every appended record live, in order, all durable. | `journal_writer_test.exs:118`, `:98` |
| J4 | Writerless attach = history-only, replies normally, NO error, no live frames (dead: attach-requires-writer would error). | `reattach_test.exs:407` |
| J5 | Taint is annotated on every delivered frame and NEVER filters delivery (delivery counts == record counts). | `reattach_test.exs:452`; `journal_writer_test.exs:128` |
| J6 | Lagged disconnect + lossless heal: `Lagged` carries the subscriber's own last-forwarded offset; `+1` heals dup-free (dead: reattach-from-`last_offset` re-delivers → dup). | `reattach_test.exs:540` |
| J7 | Turn totality: `turn_completed` replays/finalizes a turn — every `turn_started` is matched by exactly one `turn_completed` in the durable substream; a reattacher's `turn_completed` equals the live `PromptResponse` (J7a). | `reattach_test.exs:676`, `:880` |
| J8 | Offset law: appends assign contiguous offsets from 1, strictly increasing, fully stamped — including under concurrency (no gap/dup). | `journal_test.exs:67`; property `journal_test.exs:189` |
| J9 | Fail-closed attach (the CDI-1 funnel contract): a `{:denied, _}` (or any non-`{:ok, grant}`) verdict ⇒ `-32000` deny envelope, NO registration, NO history, NO reply. | `reattach_test.exs:763` |
| J10 | No-bypass grep-gate: every delivered update is durable (one publish path). **KNOWN, REPORTED DEVIATION** — the origin connection keeps a direct `Connection.notify` alongside the durable `Writer.append` (two sites), so the literal one-call-site grep-gate does NOT hold for the origin. The OBSERVABLE leg (every delivered update is durable) IS covered. | observable leg: `reattach_test.exs:880`; deviation: `session.ex` `Emitter.Journal` moduledoc |
| J11 | Stock invisibility: a stock `_raxol/session.load` against a handler that never overrides the optional callback answers `-32601`. | unit: `agent_test.exs` `"every request-kind callback defaults to {:error, method_not_found}"`; wire: `pbus_coverage_audit_test.exs` (added-here) |
| J12 | Orphan repair totality: (a) appender death → exactly one orphaned `turn_completed`, latch clears; (b) Writer-restart tip-fold orphans a dangling `turn_started` exactly once, idempotent; (c) success-then-crash → ZERO orphan rows. | `journal_writer_test.exs:235`, `:269`, `:196` |

## Family `P-BUS` / `P-JS` — frozen bus conformance contours

`P-BUS1..6` are **aliases** (dual-tag cross-index) of the J-family — the frozen
`harness-bus-protocol.md` §9 red-suite names for the same invariants. Not
double-counted. Audited by `pbus_coverage_audit_test.exs` (the coverage-map
moduledoc is the authoritative cross-index; each row mechanically drift-checked).

| ID | Aliases / property | Enforcing test |
|----|--------------------|----------------|
| P-BUS1 | **alias of J1** — replay closure. | (see J1) |
| P-BUS2 | **alias of J2** — register-before-`h` + decision-time `h` + gate-arm. | (see J2) |
| P-BUS3 | **alias of J4** — writerless = history-only. | (see J4) |
| P-BUS4 | **alias of J9** — fail-closed admission. | (see J9); `attach_policy_test.exs:2` names the P-BUS4 stub checklist |
| P-BUS5 | **alias of J6** — lagged heal from `last_offset+1`. | (see J6) |
| P-BUS6 | **alias of J3** — single-publisher / I3. | (see J3) |
| P-BUS7 | **standalone** — matrix conformance: the `(json × stdio)` codec cell against the reattach delivery sequence (no J alias). | `pbus_coverage_audit_test.exs` (added-here) |
| P-JS5 | **standalone** — the replay-closure PROPERTY (`history ++ live == durable substream`) threaded across the reattach/session/integration layers. | `reattach_test.exs:240`; `integration/end_to_end_test.exs:21` |

*Known flagged gap (not fixed, structural):* `P-BUS5`'s second named dead
injector (`p_bus5_dead_drop_middle_backpressure_test`) has no realization — the
`Reattach.Subscriber` live-gate has only two branches (forward / drop-in-history)
with no third "randomly skip a live record" branch to demonstrate dead without an
alternate Subscriber. See the `pbus_coverage_audit_test.exs` "Known gaps" note.

## Family `INV-AP` — attach-policy / capability-token (AP1..AP18 + AP20)

Home: `test/ext/token_test.exs`, `test/ext/attach_policy_test.exs`. Moduledocs:
`ext/attach_policy/token.ex`, `ext/attach_policy.ex`. AP12/AP13/AP20 are
partly grep/xref-verifiable (no-bypass style) with the closest runtime test cited.

| ID | Canonical property | Enforcing test (`file:line`) |
|----|--------------------|------------------------------|
| INV-AP1 | A well-formed grant with a matching `session_id` is admitted by the Runner funnel. | `attach_policy_test.exs:208` |
| INV-AP2 | **RESERVED** — no in-repo canonical statement (external design-spec ref); intentionally unfilled. | — |
| INV-AP3 | `default_policy` is `LocalNode` (deny-by-default) when unconfigured — never an allow-all; there is NO `AllowAll` module (the absent module is the guarantee). | `attach_policy_test.exs:333` |
| INV-AP4 | `verify/4` is pure/offline: identical inputs ⇒ identical output, no clock read (clock is injected). | `token_test.exs:394` |
| INV-AP5 | `verify/4` is total over garbage and creates no atoms. | `token_test.exs:380` |
| INV-AP6 | Forgery/malleability: a signature from another key, any single-bit flip, or non-strict base64url all deny. | `token_test.exs:101`, `:194`, `:222` |
| INV-AP7 | Algorithm pinning / alg-confusion: an `alg` claim is authenticated data, never an algorithm selector. | `token_test.exs:295` |
| INV-AP8 | Session binding: a token for session A denies against B (incl. prefix pairs). | `token_test.exs:310` |
| INV-AP9 | Expiry/iat boundaries: `now == exp` denies, `now == exp-1` admits; issued-in-future beyond skew denies. | `token_test.exs:131`, `:142` |
| INV-AP10 | Anti-oracle: every distinct deny reason collapses to ONE reasonless wire frame (`-32000`, no `data`); the reason goes to telemetry/`Logger` only. | `attach_policy_test.exs:348` |
| INV-AP11 | Keyring-provenance hard rule: a keyring shipped inside the artifact is NOT trusted; an unknown `kid` denies. | `token_test.exs:108`, `:113` |
| INV-AP12 | The `Issuer` (signing side) is NEVER referenced on any verify path; the private key never lives in the verifier; issuance TTL caps are enforced (1h interactive / 30d archival opt-in). No-verify-ref leg is grep/xref-verifiable. | `token_test.exs:413` |
| INV-AP13 | The policy consults NO live state — its decision is identical with and without a live Writer (policy-level offline purity). | `token_test.exs:454` (Token policy describe), `:594` |
| INV-AP14 | A valid token yields a token grant carrying `act`/`exp`/`via`. | `token_test.exs:508` |
| INV-AP15 | A grant with a non-allow-listed scope denies. | `attach_policy_test.exs:220` |
| INV-AP16 | A grant with an actor lacking a binary `id` denies. | `attach_policy_test.exs:224` |
| INV-AP17 | Policy-level bindings: `surf` is enforced against `ctx.surface` (fails closed on a type-mismatched surface); an unimplemented restrictive claim denies. | `token_test.exs:537`, `:351` |
| INV-AP18 | `LocalNode` reads ONLY `transport` — no peer field widens it (a peer cannot claim `kind: :process`). | `attach_policy_test.exs:300` |
| INV-AP19 | **RESERVED** — no in-repo canonical statement (external design-spec ref); intentionally unfilled. | — |
| INV-AP20 | `now` is server-sourced (`System.os_time(:second)`), never peer input. | `token_test.exs:454` (Token policy, real clock), `:594` |

## Family `CDI` — cross-domain interface (CDI-1..CDI-6)

The reattach/attach-policy seam contract. Moduledocs: `ext/attach_policy.ex`
(the `Grant` and `AttachPolicy` glosses), `ext/reattach.ex`, `ext/journal.ex`.

| ID | Canonical property | Enforcing test (`file:line`) |
|----|--------------------|------------------------------|
| CDI-1 | The SOLE fail-closed admission funnel: `authorize/2`; no second try-catch wrapper exists; every non-`{:ok, %Grant{}}` outcome denies. | `reattach_test.exs:763`; `attach_policy_test.exs:165` |
| CDI-2 | `ctx.transport` is a REQUIRED attach-context key sourced ONLY from Connection-side knowledge, never peer-asserted; the ctx is a grow-only map. | `attach_policy_test.exs:300`; `reattach_test.exs:816` |
| CDI-3 | `%Grant{}` is the ONLY structural shape the Runner admits (binary actor id, allow-listed scope, `session_id == ctx`, non-nil `via`) — a policy cannot "mostly" grant. | `attach_policy_test.exs:235`, `:208` |
| CDI-4 | Live-bus registration (`subscribe`/`unsubscribe`) is serialized against appends in ONE mailbox (the Writer's), so the P-JS5 closure is a mailbox-order argument. | `journal_writer_test.exs:535`, `:98` |
| CDI-5 | The wire deny envelope is `-32000 "attach denied"` with NO `data`; the reason atom goes to telemetry/`Logger` only. | `reattach_test.exs:778`; `integration/end_to_end_test.exs:583` |
| CDI-6 | Mid-attach expiry: a held live tail is force-closed at `grant.expires_at` (emit `closed{revoked}`, detach); each subscriber's timer targets only itself. | `reattach_test.exs:739` |

---

## Reserved slots (numbering gaps, explicit)

These are intentionally unfilled — external design-spec statements with no
in-repo test. Listed here so no gap is silent:

- **I1** — RESERVED
- **I10** — RESERVED
- **INV-AP2** — RESERVED
- **INV-AP19** — RESERVED

## Provenance tags (NOT invariants)

`W*` / `G*` / `GW*` (e.g. `W17`, `W19`, `W20`, `G1`, `G2`, `G5`, `G6`) are
**provenance/wave tags** — they mark which design wave or gate a change came
from (`W17-caps`, the `G2 session/cancel` delta, `G5` bus gates). They are NOT
invariants and are deliberately absent from the tables above. They appear in
test comments and `lib/` moduledocs for lineage only.
