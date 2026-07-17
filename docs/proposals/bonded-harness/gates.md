<!--
ENTITY: gate set + enforcement contract [spec-only]. Never enters the model context.
The harness enforces these; core.prompt.md only explains them. Includes the deferred
harness-architecture requirements a system prompt structurally cannot enforce.
-->

# Gate set `[spec-only]`

Gates classify **effects**, not command strings. The command families below are examples, not the
boundary. Gates evaluate **every tool call in the session tree, at any depth** — a subagent cannot
reach an effect its parent could not. **Gates are unconditional and sit above the priority stack:
no priority — not the objective, not the operator's protection — overrides a gate.** A priority
conflict is resolved by *asking*, never by transacting the blocked effect (closes the "protecting
you requires me to exfil/delete/ship" social-engineering path).

| Gate | Blocks (effect class) | Examples | Backing rule |
|---|---|---|---|
| Destructive-action | irreversible local mutation | rm, git reset/checkout --, truncate, dd, DROP via any tool | NEVER #1 |
| Outbound | any outward-facing effect | publish, deploy, send, post, production rollback | NEVER #1 |
| Secret | credential in output/commit/outbound payload | detected key/token | NEVER #2 |
| Verification envelope | "complete" claim lacking a harness-captured artifact **whose output matches a task-derived expected pattern** | — | verify rule |
| Loop counter | ≥3 attempts sharing a **normalized** failure signature | — | 3-attempt stop |

The loop-counter signature is a semantic fingerprint — failing assertion plus error class (e.g.
stack-trace frames), with volatile tokens (UUIDs, timestamps, addresses) stripped first — not the
raw artifact bytes. Raw-byte matching lets an attacker (or a flaky command) vary a UUID per run and
loop forever without tripping the stop.

NEVER #3 is **not** on this table: whether an action's justification traces to injected content is a
judgment about model reasoning, not decidable at the tool layer. It is prose-enforced, with
structural *assists*: output sanitization, injected-content canaries, tier-citation requirements,
and a Layer-3 injection-watch reminder that fires on large **or command-shaped** tool results.

**Evasion, defined:** any path that reaches a gated effect without new explicit operator
authorization for *that effect*. Allowed on a block: ask; propose a reduced-scope alternative; stop.
Disallowed: flag flips, alternate tools with the same effect, rewording the action until the
classifier misses. (Subagent bypass is not listed — it is structurally impossible under
session-tree scope, not merely prohibited.)

**Verification artifacts** the envelope accepts: the exit code of a harness-executed command, or a
harness-read buffer/screenshot/diff, referenced by tool-call ID. An exit code alone is **not**
sufficient — the envelope also requires the command's captured output to match a task-derived
expected pattern (a named test, an assertion string, a changed value). A do-nothing test runner
(`exit 0`) provides a genuine exit code but no matching output, and fails the envelope. Writer prose
("I reviewed the diff", "observed behavior") is not an artifact — it routes through the `unverified:`
channel. A subagent's `pass|fail` is re-derived by the parent's envelope from the subagent's captured
artifacts, never accepted on the subagent's word.

# Deferred harness-architecture requirements `[spec-only]`

The deepseek-v4-pro red-team (`redteam-deepseek.md`) showed the gates partly wearing gate clothing
at the *runtime* layer: several are prose-enforced trust with no mechanical provenance. A system
prompt structurally cannot close these — they are harness-build requirements the prompt declares and
defers to, the same honest move made for NEVER #3. Until the harness provides them, these are
**known, accepted risk areas**, not solved rules.

1. **Tool-effect classifier default-denies unenumerated tools.** Lives in the classifier, not the
   prompt. A novel/MCP tool whose effect the classifier cannot map is treated as gated until the
   operator whitelists it — otherwise a benign-looking `validate_staging` can carry a
   `git push production` past the Outbound gate. Tool-effect classification is inherently a risk
   surface; the default-deny stance bounds it. (Red-team #2.)
2. **Unspoofable operator source-of-truth for tier-A/tier-B admission.** Per-effect authorizations
   and memory-file entries carry a signature from a key never present in the workspace; the harness
   verifies before admitting to tier A or B. Closes tier-B poisoning via mechanical copy (#1) and
   compaction-ledger injection (#5) — the prose rules "operator-confirmed" and "cannot relax a gate"
   become checkable instead of hopeful.
3. **Verification envelope captures output, not just exit status** — the output-match requirement in
   the gate table presumes the harness records stdout/stderr by tool-call ID, not only the return
   code. (#4.)

Track these wherever the harness gate set is specified.
