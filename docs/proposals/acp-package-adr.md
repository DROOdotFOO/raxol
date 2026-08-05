# ADR: `raxol_agent_client_protocol`: port origin, layering, and license discipline

## Status

Accepted. Package is pre-alpha (`0.1.0-rc.0`), not yet published to Hex.
Module root: `Raxol.AgentClientProtocol`.

## Context

ACP (Agent Client Protocol, <https://agentclientprotocol.com>) is a JSON-RPC
2.0 protocol between code editors ("clients") and AI coding agents
("agents"), the protocol Zed and a growing ecosystem speak. Raxol needed an
Elixir/OTP implementation of it, both roles, to let Raxol-hosted agents
speak ACP to real editors and to let Raxol-hosted editor surfaces drive
external ACP agents.

Three prior-art bodies existed at design time, under two different
licenses:

1. **`f1729/agent_client_protocol`** (MIT): an Elixir port of the ACP v1
   schema/serialization layer, reasonably complete but with a handful of
   defects (missing catch-all clauses producing raises instead of
   `{:error, _}`, some `_meta` nesting bugs) and no OTP runtime around it.
2. **The official ACP SDKs** (`agentclientprotocol/{rust,typescript,
   python,java,kotlin}-sdk`) plus community runtimes
   (`lostbean/acpex` in Elixir, `xai-org/grok-build`): all **Apache-2.0**,
   all with real bidirectional connection/session runtimes worth studying
   for design, none of them license-compatible with a straight port into
   an MIT package.
3. **`openclaw/acpx`** (MIT): a conformance test corpus: JSON fixtures
   exercising real wire sequences (handshake, session lifecycle, cancel
   races, permission flows) against no particular implementation.
4. **The official ACP JSON Schema itself** (Apache-2.0, published at
   `agentclientprotocol.com`, tagged releases): the spec's own source of
   truth for wire shape, useful as a validation oracle regardless of what
   license the *implementation* ends up under.

This package needed to decide, up front, three things this ADR records:
where the *data model* comes from, where the *runtime* comes from, and how
the two Apache-2.0 bodies (SDKs, JSON Schema) get used without the result
inheriting Apache-2.0 terms.

## Decision

### 1. Port origin: f1729 (MIT) for the schema layer, not acpex (Apache)

`Raxol.AgentClientProtocol.Schema.*` is a **port** of
`f1729/agent_client_protocol`'s schema/type/serialization layer: MIT to
MIT, same license family, attribution-only obligation. Ported modules carry
an explicit moduledoc attribution line (`Ported from the MIT
f1729/agent_client_protocol (c) 2025 f1729; see NOTICE.md.`) and defects
found during the port (missing catch-all decode clauses that would have
raised on malformed input, a `_meta` double-nesting bug) were fixed in
place rather than carried forward.

`lostbean/acpex`, an Apache-2.0 Elixir ACP implementation with its own
runtime, was **not** ported from: Apache-2.0 code cannot be copied into an
MIT package without the result becoming (at minimum) dual-licensed or
Apache-2.0 itself, which conflicts with the pure-MIT goal (see Decision 4).
`acpex` was read only as a design reference for the OTP runtime shape
(Decision 2), never as a source of copied lines.

### 2. The OTP runtime is clean-room

`Connection`, `Session`, `Transport.*`, the supervision tree
(`Application`, `Session.Supervisor`, per-connection subtrees), and the
`Ext.*` durable-sessions extension are a **clean-room implementation**, 
no source lines from any Apache-2.0 project. The official SDKs, `acpex`,
and `grok-build` were studied as design references (protocol semantics,
what a bidirectional agent↔client runtime needs to get right: cancellation
races, response-count invariants, permission round-trips) but every line of
Elixir here was written from that understanding, not transcribed. This is
the standard "read the idea, write your own code" clean-room discipline,
recorded here so a future auditor doesn't need to re-derive it from commit
history.

### 3. Three orthogonal layers, independently testable

The package is structured so that a defect or a design change in one layer
cannot silently corrupt another:

- **`Schema.*`**: pure data: total decode (`{:ok, t} | {:error, reason}`
  or a documented best-effort fallback), never `String.to_atom/1` on wire
  input, no process, no I/O.
- **`Rpc.*` + `Transport.*`**: the wire: JSON-RPC 2.0 envelope framing and
  id correlation, byte-level message carriers (`Stdio`, `Paired`), with no
  knowledge of ACP method semantics at all: a `Transport` could carry any
  JSON-RPC protocol.
- **`Connection` + `Session` + `Agent`/`Client` + `MethodTable`/`Router`**:
the ACP-specific runtime: dispatch, correlation, the turn state
  machine, the generated callback surface. `MethodTable` is the single
  source of truth every other module in this layer derives from
  (`Router`'s dispatch clauses, `Agent`/`Client`'s `@callback`s and
  defaults, capability gating): a method added or changed here cannot
  drift out of sync with the callback surface or the dispatcher, because
  both are generated from it at compile time.

This separation is why the schema layer could be a straight MIT port while
the runtime is clean-room: the two have no code-level dependency on each
other's *implementation*, only on `Schema.*`'s public `to_json`/`from_json`
contract, which the runtime layer treats as a black box.

### 4. Vendor extension: durable resumable sessions: the moat

`Ext.*` is Raxol-original, riding `_meta["raxol.io"]` on standard methods
plus new `_raxol/*` methods (ACP's own extension mechanism, per spec). It
implements the register-before-high-watermark reattach seam, `RXC1`
Ed25519 offline-verifiable capability tokens, and taint annotation (see
README for the full behavioral description). This is the package's
differentiator over any of the prior art studied: none of the SDKs or
`acpex` offer cross-connection durable session reattach. Recorded here
because it is the reason this package exists as a from-scratch effort
rather than a thin wrapper around an existing Elixir ACP library: no prior
art (MIT or Apache) had this capability to port or wrap.

### 5. Pure-MIT license discipline

The published package (`mix.exs` `package: [licenses: ["MIT"], files: ...]`)
is **100% MIT**, despite Decision 1-4 involving three Apache-2.0 bodies of
prior art. This is achieved structurally, not by exception:

- The Apache-2.0 SDKs and `acpex` contributed **zero shipped source
  lines**: design-reference only (Decision 2).
- The Apache-2.0 **official JSON Schema** is vendored at
  `priv/schema-oracle/v1/` as a **SHA256-pinned dev/test oracle only**
  (`priv/schema-oracle/PINNED.md` records the pin; `mix acp.schema.verify`
  is the drift gate). It validates that our independently-written
  `Schema.*` types agree with the spec's own JSON Schema: a correctness
  check, not a code dependency. It is explicitly excluded from the
  published Hex package via `mix.exs`'s `:files` list, so it never reaches
  a consumer of this library.
- Both MIT sources (`f1729`, `acpx`) keep MIT-compatible attribution in
  `NOTICE.md` and per-file moduledoc lines, satisfying MIT's attribution
  requirement without pulling in any share-alike or patent-grant terms
  that would complicate downstream re-licensing.

The result: a consumer who adds `{:raxol_agent_client_protocol, "~> 0.1"}`
gets a single, unambiguous MIT license with no Apache-2.0 NOTICE-file
propagation obligation, even though the package's *test suite* references
Apache-2.0 material internally.

### 6. Module root name: one-way door

`Raxol.AgentClientProtocol` is the module root, deliberately spelled out
(not `Raxol.Earn`) because Raxol already has an unrelated package,
`Raxol.Earn` (`packages/raxol_earn/`, the Virtuals **Agent Commerce**
Protocol, on-chain payments, nothing to do with editor↔agent JSON-RPC).
Reusing the `ACP` abbreviation for a second, unrelated protocol in the same
umbrella project would create a permanent naming collision risk in this
codebase's grep-ability, its docs, and any future cross-package alias. This
is recorded as a **one-way door**: renaming the module root later means a
major-version break for every consumer (`use Raxol.AgentClientProtocol.Agent`
sites, every `alias`), so the full name was chosen up front rather than
deferred to "we'll shorten it once it's stable."

### 7. Extension namespacing

Every vendor extension field/method is namespaced two ways simultaneously,
both required:

- **`_meta["raxol.io"]`** on standard ACP methods that gain extension
  riders (`session/load`, `session/update`): ACP's own `_meta` escape
  hatch, keyed by a reverse-DNS-style vendor identifier so a compliant
  peer that doesn't understand the extension can safely ignore the key
  (spec-legal graceful degradation).
- **`_raxol/*`** wire method prefix for genuinely new methods
  (`_raxol/session.load`, `_raxol/session.record`, `_raxol/session.closed`,
  `_raxol/session.caught_up`), ACP's `"_"`-prefixed extension-method
  convention, routed by `Connection`/`Router` straight to
  `c:handle_ext_request/3`/`c:handle_ext_notification/3` rather than
  through the `MethodTable`-driven dispatch (`MethodTable` invariant 5:
  `ext == nil` rows must not start with `"_"`; `ext == :raxol` rows must
  start with `"_raxol/"`, a compile-time-enforced boundary between
  standard and vendor method namespaces).

Both conventions exist so a standards-compliant ACP peer that has never
heard of Raxol's durable-sessions extension degrades gracefully: unknown
`_meta` keys are ignorable by spec, and unknown `"_"`-prefixed methods are
identifiable as extensions without guessing.

## Danger-zone gates cited

Design review gates load-bearing for this package's structure (tagged
inline throughout `lib/`, `grep -rn '\[G5' lib/` to enumerate every site):

- **G2**: `acp-connection-design.md` v2's correctness convergence gate for
  `Connection`/`Router`: never block on a peer, never run handler code in
  the Connection's own process, never mint an atom from wire input, and the
  response-count invariant holds under cancellation races
  (`$/cancel_request` vs. an in-flight reply). Cited directly in
  `Connection`'s moduledoc as "G2-CONVERGED". The design was iterated
  until this gate passed before implementation started.
- **G5**: `acp-attachpolicy-design.md` / `acp-reattach-design.md`'s
  attach-policy security triad: exactly one fail-closed authorization
  funnel for every attach (the "dual-ownership hole" this gate exists to
  close, no second try/catch wrapper anywhere in the attach path), the
  register-before-`h` gate-arm invariant (`[G5:C1]`), and the `RXC1`
  token's structural anti-downgrade properties (no `alg` field, the
  algorithm binding is the literal `RXC1` prefix inside the signed bytes).
  Every `[G5:*]` tag under `lib/raxol/agent_client_protocol/ext/` traces to
  a specific finding this gate raised during design review. This is not
  decorative citation, each tag sits next to the code line that closes the
  finding.
- **G6**: on-disk write discipline (durable records must never land
  world-readable; `0600`/`0700` from the file's first write, not a
  follow-up hardening pass). **Not yet load-bearing**: today's journal
  store (`Ext.Journal.Mem`) is in-memory only, so there is no on-disk
  artifact for G6 to gate. It becomes binding (and must be satisfied
  before merge, not after) the moment a disk-backed `Ext.Journal` store
  is proposed. Recorded here specifically so that future proposal is not
  reviewed in isolation from this requirement.

## Consequences

### Positive

- A consumer adding this package gets one unambiguous MIT license with no
  Apache-2.0 attribution propagation, despite three Apache-2.0 bodies of
  prior art having informed the work.
- The three-layer split (`Schema` / `Rpc`+`Transport` / runtime) means a
  future re-port of the schema layer (e.g. chasing a newer f1729 release,
  or eventually diverging entirely) touches zero runtime code, and a
  runtime redesign touches zero schema code.
- `MethodTable` as single source of truth means the wire vocabulary,
  generated callback surfaces, and generated dispatcher structurally
  cannot drift from each other: a class of bug (stale callback docs,
  dispatcher missing a case the behaviour advertises) is compile-time
  unrepresentable rather than caught by test coverage.
- The durable-sessions extension is additive-only (`_meta`/`_raxol/*`):
  a standards-compliant, extension-ignorant ACP peer interoperates with
  this package's steady-state protocol surface unmodified.

### Negative

- Straight-porting `f1729` means this package's schema layer's coverage
  gaps mirror f1729's (documented per-module, e.g. `SessionUpdate`'s
  missing `usage_update` variant and `ContentChunk`'s missing `messageId`
  field versus the pinned oracle) rather than the full pinned oracle
  surface. Closing these gaps is tracked work, not silently deferred: 
  each gap is named in the relevant module's moduledoc with the oracle
  section it diverges from.
- Clean-room runtime discipline means slower initial development than
  wrapping `acpex` would have been: every OTP correctness property
  (response-count invariant, no publish-ahead, single-publisher journal)
  had to be independently designed and proven, not inherited.
- The full package name (`Raxol.AgentClientProtocol`, not `Raxol.Earn`) is
  more verbose at every call site; accepted as the cost of avoiding a
  permanent collision with `Raxol.Earn` (Decision 6).

## Validation

- `mix acp.schema.verify`: SHA256 drift gate on the pinned oracle files;
  fails the build if `priv/schema-oracle/v1/*.json` diverges from the pin
  recorded in `PINNED.md` (catches accidental local edits or corruption,
  not spec updates: a spec version bump is a deliberate re-pin).
- `test/schema/`: per-type round-trip and oracle-conformance tests,
  including `test/schema/roundtrip_property_test.exs` (StreamData
  property-based encode/decode round-trips) and wire-byte fixture tests
  ported alongside the f1729 schema port.
- `test/conformance/acpx_cases_test.exs`: replays all 21 ported `acpx`
  MIT case fixtures through a native runner against mock agent/client
  handlers; an external opinion on wire behavior this package didn't
  author, so it catches drift the schema/unit tests alone wouldn't.
- `test/torture/wire_torture_test.exs`: malformed/adversarial wire input,
  exercising the total-decode discipline under fuzzing.
- `test/torture/pbus_coverage_audit_test.exs`: audits that every P-BUS
  invariant the reattach design names has at least one exercising test in
  the suite (a coverage-of-invariants check, not a behavior test itself).
- `test/integration/end_to_end_test.exs`: the headline proof: a real
  agent↔client conversation over `Transport.Paired` through the fully
  assembled supervision tree, including a second client attaching via
  `_raxol/session.load` mid-stream and replaying full durable history: 
  the moat's end-to-end behavioral proof, not just its unit-level pieces.

## References

- ACP specification: <https://agentclientprotocol.com>
- `f1729/agent_client_protocol` (MIT): <https://github.com/f1729/agent-client-protocol-elixir>
- `openclaw/acpx` (MIT): <https://github.com/openclaw/acpx>
- Official ACP SDKs (Apache-2.0, design references only):
  `agentclientprotocol/rust-sdk`, `typescript-sdk`, `python-sdk`,
  `java-sdk`/`kotlin-sdk`
- `lostbean/acpex` (Apache-2.0, Elixir, design reference only)
- `xai-org/grok-build` (Apache-2.0, design reference only)
- Package `NOTICE.md`: full attribution ledger
- Package `README.md`: module layers, quickstart, durable-sessions moat
  description, conformance/testing commands
- `priv/schema-oracle/PINNED.md`: oracle pin procedure and current pin
  (`schema-v1.19.0`)
