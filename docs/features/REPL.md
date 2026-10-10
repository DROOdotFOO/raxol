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

`Sandbox.check/2` is a separate call the caller makes first. `Evaluator` does not call it for you, and it is a mitigation rather than a boundary: every clause resolves a module NAME, so anything that rebinds a name (`import`, `alias`, `require`, `use`, and until #1045 the bare-name capture forms of `apply` and `spawn`) sits underneath the check rather than inside it. What actually keeps an untrusted caller away from the evaluator is the deployment flag, `Raxol.Core.Boundary.Evaluation.exposed?/0`. Real confinement between untrusted principals wants separate OS uids or containers: this is one BEAM, one uid. Tracked in [#1033](https://github.com/DROOdotFOO/raxol/issues/1033).

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
| `:strict` | Whitelist-only | The level every served launch gets, and the minimum for SSH, web, or untrusted input |

Sandbox option values are exact and case-sensitive. Unknown values fail before the terminal starts instead of silently selecting another level. Timeouts must be positive integers.

**Standard** blocks destructive system, file, network, and dynamic-code calls. It also denies process creation and delayed scheduling through the `Task`, `Task.Supervisor`, `Agent`, `GenServer`, `Supervisor`, `DynamicSupervisor`, `PartitionSupervisor`, `Registry`, `:proc_lib`, `:gen`, `:gen_server`, `:gen_event`, `:gen_statem`, `:supervisor`, `:supervisor_bridge`, and `:timer` APIs; every `spawn*` form exposed by `Kernel`, `Node`, or `:erlang`; and module directives that could alias or import those APIs.

**Strict** only allows: `Enum`, `Stream`, `Map`, `Keyword`, `List`, `Tuple`, `MapSet`, `String`, `Integer`, `Float`, `Atom`, `IO`, `Kernel`, `Range`, `Regex`, `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Calendar`, `Access`, `Base`, `URI`, `Jason`, `Inspect`. Everything else gets rejected.

Strict also refuses forged structs. A map whose `__struct__` key names a module is protocol-dispatched (`Collectable`, `Enumerable`, `String.Chars`, `Inspect`, `Access`) to that module, so `m = %{__struct__: File.Stream, path: p, ...}; Enum.into(["hi"], m)` wrote a file without naming `File`. The key is refused where a map is built: a `:__struct__` or computed key in a map literal or a `put_in`/`update_in`/`get_and_update_in` path, a `%Mod{}` literal or `struct/2` naming anything but `URI`, `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Range` or `MapSet`, a `Map.put`-family call whose key is not a literal, `Map.new/1`, `Map.from_keys/2` or `Enum.into`/`Stream.into` into a map from a computed input, `for ... into:` anything but a list or `MapSet`, and `Map.new/2`, `Map.map/2`, `Map.merge/3` and `Map.intersect/3`, whose functions can rewrite a struct's `__struct__` value. `%{m | a: 1}` stays allowed: an update only replaces keys `m` already has. Build maps from literal keys instead (`Map.put(m, :a, v)`, `%{"a" => v}`, `Enum.into([a: v], %{})`). This covers the forms the source shows; a key that only exists at runtime, in a form not listed, reaches the same implementations, and only the OS-isolated peer node of [#1231](https://github.com/DROOdotFOO/raxol/issues/1231) closes the class. Every `__`-prefixed function or macro of an allowlisted module is refused too, called or captured: the generated `URI.__struct__/1` writes a caller's `:__struct__` pair into the struct it returns.

A key is judged by its top-level form alone. A literal other than `:__struct__` passes, and so does any container (a string or interpolation, a tuple, a list, a map) whatever it holds, since none can evaluate to the atom `:__struct__`; a bare variable or call in key position is refused. A computed key therefore still works wrapped: `%{"#{k}" => v}`, `%{{k} => v}`, `Map.put(m, "#{k}", v)`, `put_in(m, ["#{k}"], v)`, and `Enum.reduce(l, %{}, fn x, acc -> Map.put(acc, {x}, x) end)` in place of a refused `Map.new(l)`. Wrapping does not help `for ... into: %{}`, `Enum.into(l, %{}, fun)` or `Map.new(l, fun)`, whose keys come out of a function body rather than a key position. `Enum.frequencies/1` and `Enum.group_by/2,3` also build maps from computed keys (their values are counts and lists, never a module), and collecting into a list or `MapSet` (`Enum.into(l, MapSet.new())`, `for x <- l, into: [], do: x`) builds no map at all. Every refusal of a computed key names these forms.

Both `:standard` and `:strict` refuse syntax that creates atoms from runtime data, since atoms are never collected and persist across evaluations: `~w(#{x})a` (an interpolated word list with the `a` modifier, which calls `String.to_atom/1` at runtime) and computed aliases such as `x.Foo` or `Integer.to_string(i).Foo` (including `__MODULE__.Foo`). `~w(a b)a`, `~w(#{x})` and literal aliases like `Foo.Bar` remain allowed.

## Over SSH, and on any served surface

A served launch evaluates nothing unless the deployment opted in. `Raxol.Playground.Demos.ReplDemo` consults `Raxol.Core.Boundary.Evaluation.exposed?/0` (`RAXOL_REPL_EXPOSED=true`, or `config :raxol_core, :repl_exposed, true`) once, at launch; with the flag unset the demo still renders and Enter reports the flag instead of running the input. The same flag makes `Raxol.Payments.Deployment.assert_signing_isolated!/0` refuse to boot a node that holds signing keys, so the two halves of that rule cannot disagree.

```bash
mix raxol.playground --ssh
```

With the flag set, the level is `:strict`, and `:strict` is a mitigation rather than a boundary: a gap in the allowlist reaches the node's OS user. A served launch cannot lower it or raise the evaluation timeout, because `--sandbox` and `--timeout` are honoured only for a launch that passed `local_operator: true`, which the demo accepts only at `environment: :terminal`. `Raxol.SSH.Session` places `environment: :ssh` ahead of a served app's `:app_opts` and `:tenant_opts` precisely so a served app cannot claim otherwise. Prefer not evaluating untrusted code on a network surface at all.

## Playground demo

The REPL is one of the playground demos (`mix raxol.playground` -> REPL). It has input history (up/down), formatted output, and a bindings panel. Every launcher uses `:strict`; only `mix raxol.repl`, which passes `local_operator: true` from the operator's own terminal, can choose another level with an exact, explicit `--sandbox standard` or `--sandbox none`.
