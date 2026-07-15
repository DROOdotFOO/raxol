# `adversarial.jsonl` — corruption offset table

Companion to `docs/proposals/in-flight/harness-ui-testing/06-projection.md`
§4 (the NEGATIVE suite). Line numbers are 1-based, matching the `offset`
field `Raxol.Harness.Fixture.Envelope` carries after `Fixture.load/1`
(line 1 is the header, so envelope offsets start at 2).

This table also exists **as data**: the fixture header carries a
machine-readable `pathologies` array (`[{"class": …, "offset": …}, …]`)
exposed via `Raxol.Harness.Fixture.Session.pathologies/1`, so downstream
tests seek named corruptions instead of hardcoding line numbers. The two
copies must stay in sync; the class names below match the `class` values
in the header.

Every line in `adversarial.jsonl` is a **structurally valid** envelope —
`Raxol.Harness.Fixture.decode/1` accepts all of them. The corruption is
semantic: it targets the not-yet-built projection layer (roadmap unit T7),
which is expected to recover per the policy table in 06-projection.md
§4.1 (reject-or-recover, never silently mis-render). `Fixture.load/1`
itself only rejects genuinely malformed *shape* (bad JSON, missing
required field, unknown top-level `Event.type`, ...) — see
`test/harness/tf_fixture_test.exs` for that decode-error taxonomy, tested
against inline strings rather than this checked-in fixture, since none of
the five corruption classes below are decode-level errors.

| offset (line) | class (header value) | detail |
|---|---|---|
| 5 | `orphan_item_completed` | `id=4`, `item_id: "i-orphan"` — no preceding `item_started` for that item id. Maps to N-ADV-04 / the "render as recovered block" policy. |
| 6 | `late_delta_after_seal` | `id=5`, `item_id: "i1"` — `i1` was already `item_completed` at offset 4 (`id=3`). Maps to N-SEAL-01: the delta must be dropped, never leak into the sealed block. |
| 7 | `unknown_item_type` | `id=6`, `item_type: "custom_widget"` — outside today's vocabulary (`message \| reasoning \| tool_use \| tool_result`). Decodes fine (payload vocabulary is not decode-validated, only the top-level `Event.type` is); maps to N-FWD-01 (opaque-block render, never a crash). |
| 9 (vs 8) | `out_of_order_id` | offset 8 carries `id=8`; offset 9 carries `id=7` — a lower id arriving after a higher one. Maps to N-ADV-02 (the offending event is dropped, not applied). |
| 10 (vs 8) | `duplicate_id` | offset 8 and offset 10 both carry `id=8` with identical body. Maps to N-ADV-03 (idempotent — second application is a no-op). |
| 12–13 | `missing_turn_started` | `id=10`/`id=11`, `turn_id: "t2"` — an `item_started`/`item_completed` pair for a turn that never opened. Maps to §4.1 "synthetic turn": items attach to a synthesized turn container; diagnostic. Header offset points at 12, the pair's first line. |
| 14 | `trailing_meta` | `id=12`, `gate_decision` from `probe_c1_gate` as the FINAL record of the file. Maps to N-DORM-03: a rebuild-from-offset landing here must not fold it; the resumed view's tip is the prior conversational block (offset 13). |

The `turn_completed` at offset 11 (`id=9`) closes turn `t1`; the file
then deliberately trails with the t2-no-turn_started pair and the meta
record, so the LAST line is non-conversational by construction (the
N-DORM seek target).
