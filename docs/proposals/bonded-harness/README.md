# Bonded Harness

A fused system prompt for a bonded agentic harness — an autonomous engineering agent (code +
general control) that partners a single operator. The character is not painted onto the harness;
it is emitted by it (see `journey.md`). Persona, safety, and control flow are one object.

## Entities (load / link directly)

| File | Kind | What it is |
|---|---|---|
| [`core.prompt.md`](core.prompt.md) | `[core]` prompt | The byte-stable Layer-0 system prompt. Fill slots, load directly. |
| [`subagent.prompt.md`](subagent.prompt.md) | `[core]` prompt | Worker-tier prompt — rules only, persona never inherited. |
| [`conditional.md`](conditional.md) | `[conditional]` | Per-session assembly: Layer 1 memory contract, Layer 2 sections, Layer 3 reminders, tuning state. |
| [`slots.md`](slots.md) | spec | The `{{slots}}`, the AX-7 reference fill, and how to run it live (Grok Build override). |
| [`gates.md`](gates.md) | `[spec]` | Gate set, evasion definition, verification artifacts, deferred harness-architecture requirements. Harness-enforced; never enters model context. |
| [`evals.md`](evals.md) | `[spec]` | Failure-class table, eval packs + pass bars, anti-pattern assertions. |
| [`design.md`](design.md) | `[spec]` | Design rationale: isomorphism map, assembly-function contract, per-model variants, maintenance loop. |
| [`journey.md`](journey.md) | notes | The build story — two materials, the BT-7274 spine, the roleplay→processing-strategy discovery, the review/red-team/dogfood gauntlet. |
| [`failure-patterns.md`](failure-patterns.md) | notes | 9 recurring system-prompt failure generators + a 10-check pre-flight. Reusable on any prompt spec. |
| [`redteam-deepseek.md`](redteam-deepseek.md) | notes | Runtime attack pass — the exploitation surface behind the deferred harness requirements. |

## Section-tag legend

- `[core]` — renders into the byte-stable prompt above the cache boundary (the prompt entities).
- `[conditional]` — assembled per-session below the boundary (env, tools, dials, reminders).
- `[spec]` / `[spec-only]` — design and CI material; **never enters the model context.**

## Assembly order

`assemble(core, memory[], conditional{}, reminders[]) → messages[]` — contract in `design.md`.
Mandatory: `core.prompt.md` + the environment block (fail closed if missing). Everything else is
omit-when-empty. Fill the slots (`slots.md`) first.

## Where the rev-history lives

Nowhere in the entity files — they carry only the current contract. The full build/journey and
every revision's reasoning is in `journey.md`. That separation is deliberate: the spec files stay
loadable, the story stays a story.
