# REPL

Interactive Elixir REPL with an AST-based safety check in front of it. Three levels range from an explicit trusted-local escape hatch to the launcher-default whitelist. Bindings persist between evaluations, IO gets captured, and runaway code hits a timeout. The check is the only thing standing between typed code and the node, so read [Trust boundary](#trust-boundary) before exposing any of this.

## Quick start

```bash
mix raxol.repl                         # strict (default)
mix raxol.repl --sandbox standard      # opt in to the blocklist
mix raxol.repl --sandbox none          # explicit trusted-local escape hatch
mix raxol.repl --timeout 10000         # positive milliseconds only
```

## Evaluator

`Raxol.REPL.Evaluator` is a functional wrapper around `Code.eval_string`. It spawns evaluation in a monitored process with a timeout, swaps the group leader to capture IO, and carries bindings forward between calls.

```elixir
alias Raxol.REPL.Evaluator

evaluator = Evaluator.new()

{:ok, result, evaluator} = Evaluator.eval(evaluator, "x = 1 + 2")
result.value      # => 3
result.output     # => "" (captured IO, empty here)
result.formatted  # => "3"

# Bindings carry over
{:ok, result, evaluator} = Evaluator.eval(evaluator, "x * 10")
result.value      # => 30

# IO gets captured
{:ok, result, _} = Evaluator.eval(evaluator, ~s[IO.puts("hello")])
result.output     # => "hello\n"

# Runaway code times out (default 5000ms)
{:error, "Evaluation timed out after 1000ms", evaluator} =
  Evaluator.eval(evaluator, "Process.sleep(:infinity)", timeout: 1000)

Evaluator.bindings(evaluator)  # => [x: 3]
Evaluator.history(evaluator)   # => [{"x * 10", result}, ...]

evaluator = Evaluator.reset_bindings(evaluator)  # clears bindings, keeps history
evaluator = Evaluator.clear_history(evaluator)    # clears history, keeps bindings
```

### Trust boundary

`Evaluator` applies no restriction of its own. `Code.eval_string/3` gets an unrestricted `Macro.Env`, no AST is inspected, and `File`, `:os.cmd/1`, ports, `Node.connect/1` and `:erlang.halt/0` are all reachable from typed code. The caps (`:timeout`, `:max_heap_bytes`, `:max_result_bytes`, and the capture's output limit) bound the one evaluation process: the timeout kill uses `:kill`, which `Process.flag(:trap_exit, true)` cannot intercept, so an evaluation cannot outlive its own timeout. They bound nothing it spawns, though, and on timeout only that one pid is signalled. Code evaluated here runs with the full authority of the node's OS user.

`Sandbox.check/2` is a separate call the caller makes first. Callers that expose the REPL do (the playground demo gates on `:strict`); `Evaluator` does not call it for you. Real confinement between untrusted principals wants separate OS uids or containers: this is one BEAM, one uid. Tracked in [#1033](https://github.com/DROOdotFOO/raxol/issues/1033).

## Sandbox levels

`Raxol.REPL.Sandbox` walks the AST with `Macro.prewalk` and rejects code that calls blocked modules or functions, before it ever runs.

```elixir
alias Raxol.REPL.Sandbox

Sandbox.check("Enum.map([1,2,3], & &1 * 2)", :standard)  # => :ok
Sandbox.check("System.cmd(\"rm\", [\"-rf\", \"/\"])", :standard)  # => {:error, ["..."]}
```

| Level | What it does | When to use it |
|-------|-------------|----------------|
| `:none` | Allows everything | Explicit opt-in on a local terminal whose user you trust |
| `:standard` | Blocks known-dangerous calls | Explicit opt-in for trusted local use |
| `:strict` | Whitelist-only | Default for every launcher; required for SSH, web, or untrusted input |

Sandbox option values are exact and case-sensitive. Unknown values fail before the terminal starts instead of silently selecting another level. Timeouts must be positive integers.

**Standard** blocks destructive system, file, network, and dynamic-code calls. It also denies process creation and delayed scheduling through the `Task`, `Task.Supervisor`, `Agent`, `GenServer`, `Supervisor`, `DynamicSupervisor`, `PartitionSupervisor`, `Registry`, `:proc_lib`, `:gen`, `:gen_server`, `:gen_event`, `:gen_statem`, `:supervisor`, `:supervisor_bridge`, and `:timer` APIs; every `spawn*` form exposed by `Kernel`, `Node`, or `:erlang`; and module directives that could alias or import those APIs.

**Strict** only allows: `Enum`, `Stream`, `Map`, `Keyword`, `List`, `Tuple`, `MapSet`, `String`, `Integer`, `Float`, `Atom`, `IO`, `Kernel`, `Range`, `Regex`, `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Calendar`, `Access`, `Base`, `URI`, `Jason`, `Inspect`. Everything else gets rejected.

## Over SSH

The playground serves a REPL demo over SSH:

```bash
mix raxol.playground --ssh
```

`:strict` is the minimum for anything exposed to the network, and it is a mitigation rather than a boundary: a gap in the allowlist reaches the node's OS user. Prefer not evaluating untrusted code on a network surface at all.

## Playground demo

The REPL is one of the playground demos (`mix raxol.playground` -> REPL). It has input history (up/down), formatted output, and a bindings panel. Every launcher uses `:strict` unless the local `mix raxol.repl` command receives an exact, explicit `--sandbox standard` or `--sandbox none` option.
