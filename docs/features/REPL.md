# REPL

Interactive Elixir REPL with AST-based sandboxing. Three safety levels: wide open for local use, locked down for SSH. Bindings persist between evaluations, IO gets captured, and runaway code hits a timeout.

## Quick Start

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

## Sandbox Levels

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

Use `:strict` sandbox for anything exposed to the network.

## Playground Demo

The REPL is one of the playground demos (`mix raxol.playground` -> REPL). It has input history (up/down), formatted output, a bindings panel, and shows the active sandbox level.
