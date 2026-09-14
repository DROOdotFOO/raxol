# REPL

Interactive Elixir REPL with an AST-based safety check in front of it. Three levels: wide open for local use, whitelist-only for SSH. Bindings persist between evaluations, IO gets captured, and runaway code hits a timeout. The check is the only thing standing between typed code and the node, so read [Trust boundary](#trust-boundary) before exposing any of this.

## Quick start

```bash
mix raxol.repl
mix raxol.repl --sandbox standard
mix raxol.repl --sandbox strict
mix raxol.repl --timeout 10000
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
{:error, "Evaluation timed out", evaluator} =
  Evaluator.eval(evaluator, "Process.sleep(:infinity)", timeout: 1000)

Evaluator.bindings(evaluator)  # => [x: 3]
Evaluator.history(evaluator)   # => [{"x * 10", result}, ...]

evaluator = Evaluator.reset_bindings(evaluator)  # clears bindings, keeps history
evaluator = Evaluator.clear_history(evaluator)    # clears history, keeps bindings
```

### Trust boundary

`Evaluator` applies no restriction of its own. `Code.eval_string/3` gets an unrestricted `Macro.Env`, no AST is inspected, and `File`, `:os.cmd/1`, ports, `Node.connect/1` and `:erlang.halt/0` are all reachable from typed code. The caps (`:timeout`, `:max_heap_bytes`, `:max_result_bytes`, and the capture's output limit) bound the one evaluation process; they bound nothing it spawns, and on timeout only that one pid is signalled. Code evaluated here runs with the full authority of the node's OS user.

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
| `:none` | Allows everything | Local terminal, you trust the user |
| `:standard` | Blocks known-dangerous calls | Default for interactive use |
| `:strict` | Whitelist-only | SSH, web, untrusted input |

**Standard** blocks: `System.cmd`, `System.shell`, `File.rm`, `File.rm_rf`, `File.write`, `Port.open`, `Code.eval_string`, `Code.eval_quoted`, `:os.cmd`, and friends.

**Strict** only allows: `Enum`, `Stream`, `Map`, `Keyword`, `List`, `Tuple`, `MapSet`, `String`, `Integer`, `Float`, `Atom`, `IO`, `Kernel`, `Range`, `Regex`, `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Calendar`, `Access`, `Base`, `URI`, `Jason`, `Inspect`. Everything else gets rejected.

## Over SSH

The playground serves a REPL demo over SSH:

```bash
mix raxol.playground --ssh
```

`:strict` is the minimum for anything exposed to the network, and it is a mitigation rather than a boundary: a gap in the allowlist reaches the node's OS user. Prefer not evaluating untrusted code on a network surface at all.

## Playground demo

The REPL is one of the playground demos (`mix raxol.playground` -> REPL). It has input history (up/down), formatted output, a bindings panel, and shows the active sandbox level.
