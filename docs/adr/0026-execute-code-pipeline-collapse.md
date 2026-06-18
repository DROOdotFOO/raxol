# ADR-0026: `execute_code` programmatic tool-calling

## Status

Proposed, 2026-06-18. Hermes-extraction Tier 2 ADR (`~/Desktop/hermes-extraction-report.md`, item
H2.3). Builds on the existing REPL (`Raxol.REPL.Evaluator`, `Raxol.REPL.Sandbox`,
`Raxol.REPL.VfsHelpers`), the `Raxol.Agent.Action` behaviour, and ADR-0020's authorization seams.

## Context

An agent calls tools one at a time. To list ten files and grep each, the model emits ten tool calls,
and every result, including bulky intermediates, round-trips back into the context window before the
next call. This is slow (N round-trips) and expensive (intermediates consume tokens even when only a
distilled answer matters).

Hermes's `execute_code` collapses the pipeline: the model writes ONE script that calls tools in
sequence, filters/reduces/branches in code, and returns only the distilled result. The intermediates
stay in the script's runtime and never enter context.

Raxol already has every piece. `Raxol.REPL.Evaluator` (`lib/raxol/repl/evaluator.ex`) wraps
`Code.eval_string` with a `spawn_monitor` timeout, `StringIO` IO capture, and persistent bindings.
`Raxol.REPL.Sandbox` (`lib/raxol/repl/sandbox.ex`) scans an AST via `Macro.prewalk` at three levels
(`:none`, `:standard`, `:strict`) and exposes `check/2`. `Evaluator.with_vfs/1` seeds a VFS binding
and auto-imports `Raxol.REPL.VfsHelpers`. The missing piece is making registered Actions callable
from inside that sandbox.

## Decision

**Add an `execute_code` Action that runs a single agent-authored Elixir script in the
`Raxol.REPL.Evaluator` under a strict `Raxol.REPL.Sandbox` level, with the agent's registered Actions
exposed as callable functions in the prelude. The script calls tools, reduces in code, and returns
one value. Tool calls inside the script flow through the same authorization and audit seams as
direct tool calls.**

### 1. Actions as callable functions in the prelude

`Evaluator.with_vfs/1` already auto-imports `VfsHelpers`. An analogous `Evaluator.with_tools/2`
seeds a `tools` binding (or an imported helper module) where each available Action is a function:
`tools.read_file(%{path: "..."})` invokes `ReadFile.call(params, context)` and returns its result as
a plain Elixir term. The script composes these in code:

```elixir
"skills/**/*.md"
|> tools.glob()
|> Enum.map(&tools.read_file(%{path: &1}))
|> Enum.filter(&String.contains?(&1.content, "deploy"))
|> length()
```

Only the final value (`length`) returns to the agent; the file contents never enter context.

### 2. The `execute_code` Action

A single Action taking a `code` string, reaching the evaluator and the available Actions via
`context`. It runs the code through `Evaluator.eval/3` inside a `spawn_monitor` timeout, captures IO,
and returns `{:ok, %{result, output}}` or a structured error (timeout, sandbox violation, raised
exception). The script runs at `Sandbox` level `:strict` by default (whitelist-only), so it can call
the exposed `tools` but not `System.cmd`, `File.rm`, `Port.open`, or other denied primitives.

### 3. Tool calls keep their guards

A `tools.x(...)` call inside the script is a real Action invocation, so it flows through the same
`CommandHook` chain (ADR-0020) and lands in the `ThreadLog` exactly as a direct tool call would.
`execute_code` does not become a hole around authorization; it is a different surface onto the same
gated Actions.

### 4. Sandbox level is the safety dial

The default is `:strict` (whitelist-only, safe even when an agent is exposed over SSH). A consumer
that trusts its agent more can configure `:standard` (denies the dangerous primitives but allows the
rest). `:none` is never the default and is intended only for fully-trusted, non-exposed use.

## Consequences

### Positive

- **Round-trips collapse.** One `execute_code` call replaces a chain of tool calls; the model reasons
  once and lets code do the iteration.
- **Bulky intermediates stay out of context.** Only the distilled return enters the window, cutting
  token cost on data-heavy pipelines.
- **Reuses a proven sandbox.** The evaluator's timeout/IO-capture and the AST scanner already exist
  and are tested; this adds a tool binding, not a new execution engine.
- **No authorization bypass.** Tool calls inside the script are the same gated Actions, logged the
  same way.

### Negative

- **Arbitrary code execution is a sharp tool.** Even at `:strict`, a whitelist must be correct;
  exposing tools as functions widens what a script can reach.
- **Errors are harder to attribute.** A failure inside a multi-step script is one tool result, so the
  agent sees less granular feedback than from separate calls.
- **The AST scanner is the trust boundary.** A gap in `Sandbox.check/2` is a sandbox escape.

### Mitigation

- Default to `:strict`; require an explicit config to relax it; never default to `:none`.
- Return structured errors (which line/stage failed, captured output) so the agent can recover.
- Keep `execute_code` itself gated by an Authorization policy (ADR-0020) so a consumer can set it to
  ASK or DENY; pair it with the containerized execution backend (ADR-0024) for defense in depth.

### What this ADR does not decide

- **Languages other than Elixir.** The REPL evaluates Elixir; a polyglot `execute_code` (Python,
  shell) would run in the execution backend (ADR-0024), a different surface.
- **Persistent script state across calls.** Each `execute_code` runs fresh; carrying bindings between
  calls is out of scope (the agent passes data via its prompt instead).
- **A new sandbox level.** The three existing levels suffice; this ADR only adds the tools binding.

## Alternatives considered

### Keep one-tool-at-a-time and compress results instead

Summarize tool results before they enter context. Rejected: summarization is lossy and still pays N
round-trips. `execute_code` removes both the round-trips and the intermediates.

### A bespoke DSL instead of Elixir

Invent a restricted expression language for tool composition. Rejected: Elixir in the existing
sandbox already gives composition, the safety levels, and the timeout/IO machinery for free; a new
DSL is a parser and an interpreter to build and secure from scratch.

### Run the script in the execution backend (ADR-0024) instead of the REPL

Shell out to a container. Rejected as the default: the in-process REPL is lower latency and already
sandboxed for Elixir, and tool calls there keep their BEAM-native authorization. The container path
is the right home for *non-Elixir* `execute_code`, noted above.

## Validation

- **Existing behavior unchanged.** With no `execute_code` Action exposed, the REPL and Actions behave
  exactly as today.
- **Pipeline-collapse test:** a script that globs, reads, filters, and reduces returns only the
  reduced value; the intermediate file contents are not in the result.
- **Sandbox test:** a script calling `System.cmd`/`File.rm` at `:strict` returns a sandbox violation
  and runs nothing.
- **Authorization test:** a `tools.x(...)` call inside the script produces the same `CommandHook` and
  `ThreadLog` events as a direct `x` tool call; a DENY policy on `x` blocks it inside the script too.
- **Timeout test:** an infinite loop in the script is killed by the evaluator's timeout and returns a
  structured error.

## References

- `~/Desktop/hermes-extraction-report.md` (item H2.3; Hermes `execute_code`)
- ADR-0020: Agent Sandbox, ThreadLog, declarative Policies (the authorization the script's tool calls
  flow through)
- ADR-0024: Execution backends (the home for non-Elixir `execute_code`)
- `lib/raxol/repl/evaluator.ex` (`new/1`, `with_vfs/1`, `eval/3`; the runtime the script runs in)
- `lib/raxol/repl/sandbox.ex` (`check/2`, the three AST-scan levels)
- `lib/raxol/repl/vfs_helpers.ex` (the prelude-injection precedent the `tools` binding follows)
- `packages/raxol_agent/lib/raxol/agent/action.ex` (the Actions exposed as callable functions)
