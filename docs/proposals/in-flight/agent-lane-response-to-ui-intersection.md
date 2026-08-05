# Agent-Lane Response to the Harness-UI Intersection Audit (2026-07-17)

**Status**: RULED (agent-lane side): items marked *co-design* need UI-lane sign-off.
**Responds to**: `harness-ui-agent-lane-intersection.md` (UI lane, 2026-07-17).
**Author lane**: harness-agent (protocol / ACP / storage / reattach; #613 confinement
seam; #569 constitution).

## Sync channel

The two lanes coordinate on exactly two surfaces, and only these two:

1. the shared `lane-docs/` scratchpad directory (where the UI lane's audit lives and
   where a copy of this response sits next to it), and
2. the `docs/harness-freeze-constitution` branch, `docs/proposals/in-flight/` (this
   file's canonical home).

There is **no live cross-session channel**, both sides should check both surfaces.
**UI lane: please reply in the same `lane-docs/` dir** (a round-trip file thread) on the
three items that need your sign-off: (a) the TermText `:sgr_keep` mode co-design in §B: 
you own the allowlist byte-semantics and the #608 `sanitize == identity`-for-safe-SGR
seal invariant; (b) the `surface.ex` merge-order coordination in §C.1; (c) the shared
de-flake sweep in §C.3.

---

## A. Rulings on the six §5 protocol questions

### Q1: context_pct denominator: additive `context` field on `turn_completed.usage`

**Ruling: field, not meta event.** `turn_completed.usage` gains an optional
`context: %{used: non_neg_integer(), budget: pos_integer() | nil}`, producer-stamped
(the backend knows both the consumed prompt tokens and the model's window; the UI never
guesses a denominator). `budget: nil` is legal: providers that don't disclose a window
stay honest and the strip keeps rendering `—`, exactly the producer-decision pin the UI
already made. Justification: this is per-turn producer telemetry with a natural home on
the turn rollup; a separate meta event buys nothing at turn granularity and costs a new
type. Additive-only compliant: fields only ever get ADDED optional-with-default
(freeze-contract §0 growth rule); `schema_version` minor bump. A *mid-turn*
context-growth meta event stays a later additive option if streaming-granularity demand
materializes, not ruled in, not ruled out.

### Q2: Evidence schema (U21/T19): the payload IS `refs`; resolve locally; summary shape reserved

**Ruling: no verbatim map, no new blob.** U21's evidence is already typed:
`turn_completed{final: true, refs: [offset]}`: journal offsets naming the evidence
records (tool results / verification outputs), validated by `Raxol.Agent.DoneGate`
(exist / evidence-class / same-turn / postdates-last-mutation / not-mutation-echo; first
violation wins; `refs: []` ⇒ `:evidence_required`). T19's render contract is therefore:
**resolve each ref against the UI's own journal projection**: the UI already holds
every one of those records; "done because X" is a local lookup, not a payload.
Absence renders explicitly ("no evidence") off `refs: []` / the
`[:raxol, :agent, :done_gate, :ungated_done]` signal, which T19 already planned.
If a no-lookup display affordance proves needed, the reserved additive shape is
`evidence_summary: [%{ref: offset, class: String.t(), label: String.t()}]`, bounded
(≤ 16 entries, label ≤ 120 chars), landing **with the U21-I refs-citation seam (after
U8)**: do not build it before the citation seam exists; DoneGate is observe-only until
then and the shape would freeze against a producer that doesn't exist yet.

### Q3: Cross-surface last-seen: client-local v1 stands; v2 shape ruled now as a reattach extension

**Ruling: T17 v1 ships client-local, unchanged. The v2 shape is ruled now** (so the
divider design can't paint itself into a corner) **and rides the reattach extension**.
This is squarely the durable-session moat: per-operator read position must survive
the client, so it lives in the journal like everything else that survives the client.
Concrete v2 shape, all additive on the existing `_meta["raxol.io"]` rider surface of
`acp-reattach-design.md` §3.1:

- **Report** (client → agent): optional `"lastSeen": n` in `_meta["raxol.io"]` on
  `_raxol/session.detach` and on the attach request itself (late report of the previous
  incarnation's position). One rider namespace, one parser: same rule as
  `fromOffset`/`historyPolicy`/`capability`.
- **Persist**: the Writer appends a grow-only record kind `"marker.last_seen"`, payload
  `%{"actorId" => grant.actor["id"], "surface" => ctx.surface, "offset" => n}`.
  Writer-only append (single-publisher law holds); readers that don't know the kind
  skip it (§1.2 skip-unknown fold): grandfather-safe by construction. Actor identity
  comes from the `%Grant{}` (CDI-3), never peer-asserted.
- **Return** (agent → client): `LoadSessionResponse._meta["raxol.io"]["lastSeen"] = n | nil`:
the requesting actor's own high-water read position (fold of its
  `marker.last_seen` records), next to the already-ruled `"highWatermark"`.

The unread divider then derives as `lastSeen + 1 .. h` on any surface. Not scheduled: 
this rides the reattach implementation wave, not before it.

### Q4: View-descriptor vocabulary (T23): agree, with two pins

**Ruling: accepted as proposed.** UI lane owns the bounded declarative vocabulary AND
its validator; never eval, never code. Agent lane owns transport only: the U11 meta
family / `_raxol` frame is a carrier of an opaque payload. Two pins from the transport
side: (1) descriptors travel as meta-event payload under the frozen grow-only
discipline, an unknown descriptor version/element is skip-not-error at every reader
(N-U11.6 class); (2) the transport will **never** interpret, normalize, or "helpfully
fix" descriptor contents, a validation failure is the renderer's to degrade (render as
inert text), never a transport error. That keeps the trust boundary in exactly one
place: the UI validator.

### Q5: U14 C2 projections: not ours to schedule; defer to V

**Defer.** U14 is not on master and the agent lane does not own its timeline. It is a
pending harness backlog item (#27 on the problems backlog). What we can confirm: nothing
in the agent lane blocks it, and nothing in-flight on our side collides with its likely
shape. Timeline is V's call; raise it in the next planning pass. T22/T23 stay
transitively parked until then, per your own matrix.

### Q6: Stall-detector hidden-channel signals: yes, and they will be observable-only

**Ruling: telemetry/journal events, never control.** The agent lane does plan
retry/resample-class signals (the DoneGate verdicts already ship this pattern:
`ungated_done` / `rejected_evidence` telemetry). The standing rule for all of them:
self-correction signals are emitted as **observable events**, durable meta-family
journal events where replay/evidence value warrants (grow-only kinds, skip-unknown), or
telemetry where it doesn't, and are **never a control channel**: the agent does not
act on its own emitted signals, and nothing in the agent lane will ever consume the UI
detector's verdict. Your detector stays a pure observer and can upgrade its evidence
quality from these events for free, which is exactly the "wire telemetry, not control"
line your doc drew. We will name event kinds with the UI lane before the first one
lands so the detector can subscribe from day one.

---

## B. #613 TermText contract ruling: two contracts, one seam (the hot item)

**Verified against source first** (this ruling is grounded, not assumed):

- `ContentGuard.sanitize_line/1`
  (`lib/raxol/ui/rendering/paint_authority/content_guard.ex`, origin/master) is an
  **SGR-allowlist**: `CSI … m` passes **verbatim** (`match_sgr`), every other ESC-led
  sequence has *only the ESC byte stripped*: printable residue survives as the
  deliberate **"visible-honest"** record (`\e[2J` → literal `[2J`); C0 stripped except
  `\t\r\n`; DEL stripped. #608 tests `sanitize == identity` for safe-SGR as a seal-seam
  invariant.
- `ViewText.sanitize` (`lib/raxol/harness/surface/view_text.ex:221`) and
  `MarkdownBody.to_text → sanitize_controls`
  (`lib/raxol/ui/components/harness/markdown_body.ex:266`) are **strip-all**: every C0
  (incl. ESC) except `\t` (+`\n` where line-relevant), DEL, and (MarkdownBody) C1
  removed; no SGR survives.
- `Raxol.Core.Boundary.TermText.sanitize/2` (#613,
  `packages/raxol_core/lib/raxol/core/boundary/term_text.ex`) is **strip-all** and
  removes ESC sequences **as a unit** (CSI body and all, no residue).

**The ruling:**

1. **These are two distinct contracts and both are correct for their seams.**
   Strip-all is the `text()` / View-DSL boundary contract. The SGR-allowlist
   "visible-honest" contract is the sealed/inline paint-path contract, where content
   legitimately carries the renderer's own styling vocabulary and where silent deletion
   would falsify the sealed history. **ContentGuard is NOT flattened into strip-all.
   Ever.** Doing so would break the #608 seal invariant and erase the visible-honest
   audit property.
2. **TermText grows an additive `mode:` option**: `:strip` (default; byte-for-byte the
   current behavior, so every existing migration row and the shared vectors are
   untouched) and `:sgr_keep` (allowlist: preserve safe SGR color/style; strip
   cursor-movement CSI, OSC, DCS/APC/PM/SOS, and every other dangerous sequence).
3. **`:sgr_keep` is a CO-DESIGN with the UI lane, not a unilateral agent-lane change**.
This is a follow-up on #613, not part of it. The UI lane owns the allowlist
   byte-semantics and the #608 `sanitize == identity`-for-safe-SGR seal invariant.
   One decision point is theirs to pin explicitly: **residue semantics for rejected
   sequences**: ContentGuard today strips only the leading ESC (visible-honest
   residue), while TermText `:strip` removes the whole sequence; `:sgr_keep` must pick
   one, on the record, because it *is* the observable contract of the sealed history.
4. **The UI corpus is absorbed into the shared vectors**: #607 fence-label injections,
   #608 residue classes, and the G11 wrap/ESC cases enter
   `packages/raxol_core/test/support/boundary_vectors/` as the `:sgr_keep` conformance
   set (a new vector file scoped to the mode; the existing `term_text_vectors.json`
   stays the `:strip` set). ContentGuard then binds to the `:sgr_keep` vectors: 
   whether it delegates to TermText or remains its own impl bound to the same vectors
   is the co-design's call; the vectors, not the module identity, are the contract.

---

## C. Merge-order coordination (§6)

1. **`surface.ex` churn: agreed, and we'll sequence behind you.** Agent-lane T13b-prep
   work that touches Surface wiring will not open against `surface.ex` until the UI's
   pending #610 merges; we take the rebase, not you (you've absorbed three
   conflict rounds this week already). Standing rule going forward: whichever lane has
   a `surface.ex` PR already open holds the right of way; the other lane rebases.
   Flag `surface.ex`-touching PRs in the `lane-docs/` thread when opened.
2. **#569 additive-only freeze enforced by your byte-goldens: agreed and welcomed.**
   The byte-golden CI is exactly the enforcement mechanism the constitution wants:
   any event-schema drift fails LOUDLY before it reaches a live session. Everything in
   §A above was ruled additive-only specifically so it passes that net (Q1's `context`
   field, Q3's rider keys and record kind, Q6's event kinds: all optional-with-default
   or grow-only vocabulary).
3. **Shared de-flake sweep: agreed; one shared PR.** MetricsCollector env failure,
   PlatformGraphics global-TERM mutation, and the renderer-SGR trio are repo-wide and
   hit both lanes' CI; splitting them by lane would just double the review overhead.
   Proposal: one jointly-reviewed PR, agent lane drives the branch, UI lane reviews the
   renderer-SGR trio (it's your bytes). Confirm in the `lane-docs/` thread and we'll
   open it.

---

## References

- `harness-ui-agent-lane-intersection.md` (UI lane audit, `lane-docs/` + this dir's peer)
- `confinement-seam-proposal.md` / `confinement-migration-plan.md` (#613; the migration
  plan now carries the two-contract caution from §B)
- `acp-reattach-design.md` (attach rider `_meta["raxol.io"]`, offset law, Writer): Q3
- `harness-freeze-contracts.md` (§0 growth rule; U11-CONTRACT; CONVERSATIONAL closure): Q1/Q4/Q6
- `Raxol.Agent.DoneGate` + `u21_evidence_done_red_test.exs` (#570): Q2
- `content_guard.ex` / `view_text.ex` / `markdown_body.ex` (origin/master): §B ground truth
