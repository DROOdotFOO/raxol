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

Sandbox option values are exact and case-sensitive. Unknown values fail before the terminal starts instead of silently selecting another level, and `Sandbox.check/2` itself raises `ArgumentError` for any level other than `:none`, `:standard` or `:strict`. Timeouts must be positive integers.

**Standard** blocks destructive system, file, network, and dynamic-code calls. It also denies process creation and delayed scheduling through the `Task`, `Task.Supervisor`, `Agent`, `GenServer`, `Supervisor`, `DynamicSupervisor`, `PartitionSupervisor`, `Registry`, `:proc_lib`, `:gen`, `:gen_server`, `:gen_event`, `:gen_statem`, `:supervisor`, `:supervisor_bridge`, and `:timer` APIs; every `spawn*` form exposed by `Kernel`, `Node`, or `:erlang`; and module directives that could alias or import those APIs.

**Strict** only allows: `Enum`, `Stream`, `Map`, `Keyword`, `List`, `Tuple`, `MapSet`, `String`, `Integer`, `Float`, `Atom`, `IO`, `Kernel`, `Range`, `Regex`, `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Calendar`, `Access`, `Base`, `URI`, `Jason`, `Inspect`. Everything else gets rejected.

Strict also refuses forged structs. A map whose `__struct__` key names a module is protocol-dispatched (`Collectable`, `Enumerable`, `String.Chars`, `Inspect`, `Access`) to that module, so `m = %{__struct__: File.Stream, path: p, ...}; Enum.into(["hi"], m)` wrote a file without naming `File`. The key is refused where a map is built: a `:__struct__` or computed key in a map literal or a `put_in`/`update_in`/`get_and_update_in` path, a `%Mod{}` literal or `struct/2` naming anything but `URI`, `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Range` or `MapSet`, a `Map.put`-family call whose key is not a literal, `Map.new/1`, `Map.from_keys/2` or `Enum.into`/`Stream.into` into a map from a computed input, `for ... into:` anything but a list or `MapSet`, and `Map.new/2`, `Map.map/2`, `Map.merge/3` and `Map.intersect/3`, whose functions can rewrite a struct's `__struct__` value. `%{m | a: 1}` stays allowed: an update only replaces keys `m` already has. Build maps from literal keys instead (`Map.put(m, :a, v)`, `%{"a" => v}`, `Enum.into([a: v], %{})`). This covers the forms the source shows; a key that only exists at runtime, in a form not listed, reaches the same implementations, and only the OS-isolated peer node of [#1231](https://github.com/DROOdotFOO/raxol/issues/1231) closes the class. Every `__`-prefixed function or macro of an allowlisted module is refused too, called or captured: the generated `URI.__struct__/1` writes a caller's `:__struct__` pair into the struct it returns.

A key is judged by its top-level form alone. A literal other than `:__struct__` passes, and so does any container (a string or interpolation, a tuple, a list, a map) whatever it holds, since none can evaluate to the atom `:__struct__`; a bare variable or call in key position is refused. A computed key therefore still works wrapped: `%{"#{k}" => v}`, `%{{k} => v}`, `Map.put(m, "#{k}", v)`, `put_in(m, ["#{k}"], v)`, and `Enum.reduce(l, %{}, fn x, acc -> Map.put(acc, {x}, x) end)` in place of a refused `Map.new(l)`. Wrapping does not help `for ... into: %{}`, `Enum.into(l, %{}, fun)` or `Map.new(l, fun)`, whose keys come out of a function body rather than a key position. `Enum.frequencies/1` and `Enum.group_by/2,3` also build maps from computed keys (their values are counts and lists, never a module), and collecting into a list or `MapSet` (`Enum.into(l, MapSet.new())`, `for x <- l, into: [], do: x`) builds no map at all. Every refusal of a computed key names these forms.

Strict `IO` calls may only name the evaluation's own output as a device, written as a literal: `:stdio` or `:standard_io`. Any other device (a registered name, a pid, a variable) is a process `IO` sends an io request to, so `IO.write(Raxol.Payments.Wallets.Op, "x")` messaged the process `Kernel.send/2` is refused for, and its output skipped the capture. `:stderr`/`:standard_error` and `IO.warn/1,2` are refused as well: they write to the node's real stderr, which the capture never sees. The default-device forms (`IO.puts(x)`, `IO.inspect(x, label: "a")`, `x |> IO.inspect()`) are unaffected; `dev |> IO.write("x")` and `&IO.write/2` are refused, as is `IO.getn(a, b)` unless `b` is a literal count or `:eof` (the prompt form) or `a` is `:stdio`/`:standard_io`. `IO.stream` and `IO.binstream` are refused at every arity, `:stdio` included: each returns an `IO.Stream` whose `device` field is what its `Enumerable` and `Collectable` impls send to, and `%{s | device: name}` or `Map.put(s, :device, name)` re-points it without naming a device in any `IO` call.

Both `:standard` and `:strict` refuse syntax that creates atoms from runtime data, since atoms are never collected and persist across evaluations: `~w(#{x})a` (an interpolated word list with the `a` modifier, which calls `String.to_atom/1` at runtime), its spelled-out form `Kernel.sigil_w("#{x}", [?a])`, and computed aliases such as `x.Foo` or `Integer.to_string(i).Foo` (including `__MODULE__.Foo`). `~w(a b)a`, `~w(#{x})` and literal aliases like `Foo.Bar` remain allowed.

Both levels also refuse the remote spellings of the definition macros and `use`: `defmodule`, `defimpl`, `defprotocol` and `use` are `Kernel` macros, so `Kernel.defmodule(Zzz, do: ...)`, `Kernel.defimpl(String.Chars, for: Reference, do: ...)` and `Kernel.use(Bitwise)` do exactly what the bare forms, which were already refused, do.

Both levels refuse `Calendar.put_time_zone_database/1`. It replaces the time zone database for the whole node, and the setting outlives the evaluation: every later `DateTime` zone operation in every process would call the module passed in. `Calendar.get_time_zone_database/0` remains allowed. At `:standard` this refuses the function by name only: `:standard` allows every module it does not deny, so `Application.put_env(:elixir, :time_zone_database, m)` and `:application.set_env/3` still write the same setting there. Only `:strict`, whose allowlist excludes `Application` and `:application`, keeps the setting out of reach.

Strict also refuses a sorter that could name a module chosen at runtime. `Enum.sort/2`, `Enum.sort_by/3`, `Enum.max`/`min`/`min_max` and their `_by` forms, and `List.keysort/3` call `module.compare/2` when the sorter is a module, so `Enum.sort(l, m)` dispatches to whatever `m` holds. The sorter must be written out as a function or capture, `:asc`/`:desc`, a whitelisted module (`Enum.sort(dates, Date)`) or a direction tuple of those (`{:desc, Date}`); a variable is refused even when it would hold a function, and captures such as `&Enum.sort/2` that hide the sorter are refused.

Strict refuses the other arguments a call turns into a call of the module they hold. `raise m`, `raise m, attrs` and `reraise` call `m.exception/1`, so their first argument must be a string literal (interpolation included) or an audited exception module written out: `raise "boom"`, `raise "boom #{x}"` and `raise ArgumentError, message: "x"` work. The audited modules are `ArgumentError`, `ArithmeticError`, `BadBooleanError`, `BadFunctionError`, `BadMapError`, `CaseClauseError`, `CondClauseError`, `Enum.EmptyError`, `Enum.OutOfBoundsError`, `KeyError`, `MatchError`, `RuntimeError`, `SystemLimitError`, `TryClauseError` and `WithClauseError`; other Elixir exceptions are refused because `raise E, attrs` sets their fields and their `message/1` calls a module a field holds (`Protocol.UndefinedError`'s `protocol:`, `UndefinedFunctionError`'s `module:`). The attributes must be a string, where the exception has a `:message` field, or a keyword list written out that names only the exception's own audited fields (`raise MatchError, term: x`): on Elixir 1.17 the default `exception/1` passes an unknown key to `IO.warn`, which writes to the node's stderr past the output capture, so `raise ArgumentError, zzz: x` and a computed `raise ArgumentError, attrs` are refused. Any other expression in the exception slot is refused, since the checker cannot tell a string from a module: a variable (`raise msg`, or re-raising a rescued exception with `reraise e, __STACKTRACE__`), a call, `<>` or a sigil. Interpolate a computed message instead: `raise "#{msg}"`. A calendar argument (`Date.new/4`, `NaiveDateTime.convert/2`, both arguments of `Calendar.compatible_calendars?/2` and every other allowlisted function whose spec takes one) must be written out as `Calendar.ISO`, and a time zone database argument (`DateTime.now/2`, `DateTime.shift_zone/3`, ...) as `Calendar.UTCOnlyTimeZoneDatabase`. Each slot accepts only what its own spec lists: the time units in `DateTime.utc_now/1` (and the `Time` and `NaiveDateTime` forms) and `:extended`/`:basic` in `DateTime.from_iso8601/2`, so `Date.new(2020, 1, 1, :basic)` and `DateTime.now("Etc/UTC", Calendar.ISO)` are refused. The shorter arities that default the argument stay allowed. `~D`, `~T`, `~N` and `~U` may name no calendar suffix but `Calendar.ISO`, since the sigil calls the suffix's parse function while it expands, and their macros may only be reached through sigil syntax: `Kernel.sigil_D("2020-01-01 M", [])` is refused. `Map.from_struct/1` takes only a map or struct written out (`Map.from_struct(%URI{})`): given a module it calls `module.__struct__/0` and, on Elixir 1.18 and later, writes a deprecation to the node's stderr past the output capture. `Map.delete(s, :__struct__)` does the same job for a struct held in a variable. Captures of these functions are refused. Not covered: any map with a `:calendar` key reaches the same callbacks, because `Date` and `Calendar` match on `%{calendar: calendar}` rather than on a struct. A plain map literal does it (`Date.leap_year?(%{calendar: m, year: 2020})`, `Calendar.strftime(%{year: 2020, month: 1, day: 1, calendar: m}, "%u")`), as do a struct literal (`%Date{year: 2020, month: 1, day: 1, calendar: m}`), an update (`%{date | calendar: m}`), a key writer (`Map.put(date, :calendar, m)`) and a struct held in a `raise` attribute, which the exception's `message/1` interpolates or inspects (`raise BadBooleanError, operator: %Date{..., calendar: m}`) ([#1282](https://github.com/DROOdotFOO/raxol/issues/1282)); only an OS-isolated evaluator ([#1231](https://github.com/DROOdotFOO/raxol/issues/1231)) closes that.

## Over SSH, and on any served surface

A served launch evaluates nothing unless the deployment opted in. `Raxol.Playground.Demos.ReplDemo` consults `Raxol.Core.Boundary.Evaluation.exposed?/0` (`RAXOL_REPL_EXPOSED=true`, or `config :raxol_core, :repl_exposed, true`) once, at launch; with the flag unset the demo still renders and Enter reports the flag instead of running the input. The same flag makes `Raxol.Payments.Deployment.assert_signing_isolated!/0` refuse to boot a node that holds signing keys, so the two halves of that rule cannot disagree.

```bash
mix raxol.playground --ssh
```

With the flag set, the level is `:strict`, and `:strict` is a mitigation rather than a boundary: a gap in the allowlist reaches the node's OS user. A served launch cannot lower it or raise the evaluation timeout, because `--sandbox` and `--timeout` are honoured only for a launch that passed `local_operator: true`, which the demo accepts only at `environment: :terminal`. `Raxol.SSH.Session` places `environment: :ssh` ahead of a served app's `:app_opts` and `:tenant_opts` precisely so a served app cannot claim otherwise. Prefer not evaluating untrusted code on a network surface at all.

## Playground demo

The REPL is one of the playground demos (`mix raxol.playground` -> REPL). It has input history (up/down), formatted output, and a bindings panel. Every launcher uses `:strict`; only `mix raxol.repl`, which passes `local_operator: true` from the operator's own terminal, can choose another level with an exact, explicit `--sandbox standard` or `--sandbox none`.
