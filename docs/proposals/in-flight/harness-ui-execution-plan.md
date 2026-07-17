# Harness UI — Execution Plan (max-parallelization, model-assigned)

Date: 2026-07-15 · Status: ACTIVE. Operationalizes `harness-ui-roadmap.md` (v2)
under `harness-ui-methodology.md` (changeset-fusion). Ledger: `harness-ui-STATE.md`.

## Roles

| tag | model | does | never |
|---|---|---|---|
| [S] | Sonnet | implementation, code, one changeset per unit | design decisions |
| [O] | Opus | scouting, per-PR review, integration review | writes code |
| [F] | Fable | decisions at crucial points only: D-PA verdict, gate go/no-go, T13a/b acceptance, R2/R3 conflicts, salience tuning | routine ops |
| [L] | grok -p longcat | alternate-POV critique on drift-prone units (T2b, T23) | — |
| [3] | grok triad | wave-boundary re-audits: D-PA, GATE-M1, GATE-M2 | per-unit work |
| [V] | human | Ring B real-terminal runs, M1 playground eyes, salience sign-off | toil |

Ops (fusion rebuilds, PR projection, STATE updates) = scripted, run by the
orchestrator or an ops-[S]; never spends [F] tokens.

## The wave plan

```
W0 ─ TODAY ─ 7 build lanes parallel ─────────────── peak: 7×[S] + [O] pool
    T0[S+V+O] · TB[S] · TP[S] · TF[S] · T1[S] · T4[S] · T11[S]
    T0 → D-PA verdict [F] ◄─ critique [3]
    ══ GATE-1: D-PA binds T2*, T8/T9 scope, T14 substrate, T3 tiers ══
W1 ─ T2d[S] → T2a[S]     ∥  T8[S] · T7[S] · T26[S] · T14[S]
W2 ─ T2b[S+O+L] → T2c[S] · T3[S]   ∥  T9[S] · T10[S] · T5[S] (EXT PRs)
W3 ─ T13a[S+O+F] ∥ T12 · T25 · T20 · T15 · T16 · T24 · T17 (each [S])
    ══ GATE-M1: [3] re-audit + [V] playground + [F] go ══
W4 ─ T13b[S+O+F] (needs U1.5+SS+U5+U6) ∥ T18 · T19 · T21 · salience [V+F]
    ══ GATE-M2/S1: [3] + [F] ship call ══
W5 ─ T22[S] · T23[S+L]
```

Bottleneck honesty: T0→T2d→T2a→T2b is serial [S] regardless of fleet width.
W0 front-loads everything parallelizable so the fusion shows the whole
product minus the substrate by the time T2b starts.

## W0 dispatch record (2026-07-15)

Seven [S] builders, worktree-isolated, branch `feat/harness-ui-<T>` off
`origin/master`, one commit each, no push (PR projection is ops):

| unit | write-set (allowlist) |
|---|---|
| T0 | `scripts/harness/t0/**`, `docs/proposals/in-flight/t0-*` |
| TB | `lib/raxol/ui/rendering/paint_authority.ex`, `test/support/harness/**`, `test/harness/tb_*` |
| TP | `test/support/harness/pty/**`, `test/harness/tp_*` |
| TF | `lib/raxol/harness/**`, `lib/mix/tasks/raxol.harness.fixtures.bless.ex`, `test/fixtures/harness/**`, `test/harness/tf_*` |
| T1 | `packages/raxol_terminal/lib/raxol/terminal/capabilities/**`, `.../driver/background_query.ex`, `packages/raxol_terminal/test/**` (new files) |
| T4 | `lib/raxol/ui/components/harness/block*.ex`, `test/raxol/ui/components/harness/block_test.exs` |
| T11 | `lib/raxol/ui/components/harness/composer.ex`, `test/raxol/ui/components/harness/composer_test.exs` |

Namespace calls (parked question resolved): components →
`Raxol.UI.Components.Harness.*`; fixture/test infra → `Raxol.Harness.*`;
paint authority → `Raxol.UI.Rendering.PaintAuthority`; capability slice →
`Raxol.Terminal.Capabilities.*`.

T0 scope note: [S] builds probe scripts + matrix runner + capture writer and
runs the automatable cells (tmux proxy, emulator cell); Ring B real-terminal
cells ship as a runbook (`t0-runbook.md`) for [V]; [O] analyzes results; [F]
issues the D-PA verdict; [3] critiques it before it binds.

## Gates recap

- GATE-1 (D-PA): nothing in T2\* commits before the verdict; T8/T14 may
  prototype, not commit.
- Suite-first: T2a/T2b/T1 fail-on-master anchors demonstrated red before
  implementation; suite+impl one changeset; red run recorded in PR body.
- Every changeset: `MIX_ENV=test mix compile --warnings-as-errors` + tests +
  format + mix.lock checkout + conflict-marker grep. Fusion: full suite +
  playground smoke + `merge-base --is-ancestor` per branch.
