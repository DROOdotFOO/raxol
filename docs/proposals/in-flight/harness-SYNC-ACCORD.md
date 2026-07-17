# Harness SYNC ACCORD (2026-07-17) — cross-lane binding terms

Status: **BINDING on both lane sessions** (harness-agent × harness-ui).
Provenance: this file is a reconstruction from the ratified memory summary
(`harness-sync-accord` memory, origin session `c76f1d5f`). The full negotiated
text lived in the mediation job's tmp directory and was **not recovered** when
the docs corpus was assembled (2026-07-18); every binding term below is
verbatim from the summary the lanes ratified. If the full text resurfaces, it
supersedes this reconstruction; the terms themselves do not change.

2026-07-17: mediated delegate negotiation between lanes converged fully.

**Unblocks:** T13b SPLIT — T13b-live (stream+kill+steer) builds NOW vs merged
U1.5/SS/U5/U6; T13b-reattach residual rides U4-green. T19 build now (done_gate
`turn_completed{final:true, refs:[offsets]}`). T22 builds vs frozen
U11-CONTRACT extract/residual shapes + agent fixtures, merges only vs real
shapes. T23 still blocked (via T22). T18 blocked on U4-green; must render
`{:tip_uncertain, reason}` first-class.

**U4:** agent adds repeat-attach idempotence red, #586 undrafted in 48h; UI
files determinism reds ≤2d after merge; U4-green PR ≤7d after. **U14:** full
unit GATED behind eval-first Wave-4 ruling (V-only lift); new unit **U14-proj**
(projection read-models + state_change emission, no LLM/swap) outside gate,
PR ≤14d after U4-green.

**Codified:** item_delta = per-chunk publish, single-publisher order,
ephemeral, reconstruct from item_completed (goes into protocol §5). Six
goldens = shared conformance corpus, decode-reject = negotiated fix. Tolerant
reading = skip-unknown ONLY; malformed known shapes = red test vs codec, never
UI workaround. L5 confirmed (T17 client-local offset disclosed, non-durable).

**Checkout protocol:** root → master/clean/read-only after UI dirt triage;
in-flight docs committed ≤1 day; NO git clean until corpus PR; stash@{0} NOT
dropped until corpus lands (untracked parent 0c64eaba1 = 65 agent-lane doc
files, maybe sole copies; use `git stash branch`); worktree prune by
namespace, target <10; namespaces: agent = feat/harness-u[0-9]*, red/*,
docs/harness* (excl -ui); UI = feat/harness-ui*, pr/r1-*, T-units; protocol
spec agent-owned with UI required reviewer, frontend spec reciprocal;
own-lane ledgers only, ledger row in same PR as unit.

**Docs:** merge #569 as-is, then ONE joint docs-corpus PR ≤48h committing all
untracked in-flight docs (both lanes, own files each). *(The corpus in
`docs/harness/` + the committed `docs/proposals/` tree is the harness-ui-lane
side of that commitment.)*

**Why:** ledgers were 2 days / ~35 merges stale; negotiation established
PR-verified reality as baseline.

**How to apply:** each lane session reads this on start, executes its §8
dated commitments, never re-litigates §9 V-escalations lane-to-lane (D-PA
retroactive ratification, PA-2..PA-5, full-U14 gate, one-way doors, salience
constants, golden re-bless, T22 scope). Related: `harness-session-split`
memory, `harness-freeze-decisions` memory, `harness-eval-first-ruling` memory.
