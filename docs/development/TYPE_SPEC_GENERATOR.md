# Type Spec Generator

`mix raxol.gen.specs` generates type specifications for private functions in Elixir modules. It infers types from naming conventions, pattern matching, and guard clauses.

## Usage

```bash
# Single file
mix raxol.gen.specs lib/raxol/terminal/buffer.ex

# Recursive directory
mix raxol.gen.specs lib/raxol/terminal --recursive
```

### Options

- `--dry-run`: preview without modifying files
- `--recursive`: process all `.ex` files recursively
- `--filter PATTERN`: only functions matching the pattern
- `--interactive`: confirm each spec before adding
- `--backup`: create `.backup` files before modifying

### Examples

```bash
# Preview changes
mix raxol.gen.specs lib/raxol/core/state.ex --dry-run
# [DRY RUN] Would add 15 specs to lib/raxol/core/state.ex:
#   handle_state_change/2: @spec handle_state_change(map(), any()) :: {:ok, map()} | {:error, any()}
#   validate_transition/2: @spec validate_transition(map(), atom()) :: boolean()

# Only validation functions
mix raxol.gen.specs lib/raxol --recursive --filter validate_

# Interactive, confirm each
mix raxol.gen.specs lib/raxol/ui/components.ex --interactive

# With backup
mix raxol.gen.specs lib/raxol/critical_module.ex --backup
# Restore: cp lib/raxol/critical_module.ex.backup lib/raxol/critical_module.ex
```

## Type Inference Rules

### Function Name -> Return Type

| Pattern | Inferred Return Type |
|---------|---------------------|
| `validate_*` | `{:ok, any()} \| {:error, any()}` |
| `parse_*` | `{:ok, any()} \| {:error, any()}` |
| `is_*` | `boolean()` |
| `has_*` | `boolean()` |
| `get_*` | `any() \| nil` |
| `set_*` | `any()` |
| `update_*` | `any()` |
| `handle_*` | `{:ok, any()} \| {:error, any()} \| {:reply, any(), any()} \| {:noreply, any()}` |
| `format_*` | `String.t()` |
| `build_*` | `any()` |
| `create_*` | `any()` |
| `*?` | `boolean()` |
| `*!` | `any() \| no_return()` |

### Argument Name -> Type

| Pattern | Inferred Type |
|---------|--------------|
| `state` | `map()` |
| `buffer` | `Raxol.Terminal.ScreenBuffer.t()` |
| `cursor` | `Raxol.Terminal.Cursor.t()` |
| `opts` | `keyword()` |
| `config` | `map()` |
| `metadata` | `map()` |
| `errors` | `[String.t()]` |
| `path` | `String.t()` |
| `x`, `y` | `non_neg_integer()` |
| `width`, `height` | `pos_integer()` |
| `count`, `size`, `index` | `non_neg_integer()` |
| `is_*`, `has_*` | `boolean()` |
| `pid` | `pid()` |
| `ref` | `reference()` |

### Guard Clauses and Pattern Matching

The generator handles these correctly:

```elixir
# Guard clause
defp validate(x) when is_integer(x) and x > 0, do: :ok
# => @spec validate(integer()) :: :ok

# Struct pattern matching
defp process(%State{} = state, opts \\ [])
# => @spec process(State.t(), keyword()) :: any()
```

## Limitations

- Complex return types default to `any()`
- May not recognize all domain-specific types
- Won't overwrite existing specs
- Doesn't generate specs for macros

## Workflow

Start with a dry run, review the output, then apply:

```bash
mix raxol.gen.specs lib/critical.ex --dry-run
mix raxol.gen.specs lib/critical.ex --backup
```

Work incrementally: do core modules first, then expand:

```bash
mix raxol.gen.specs lib/raxol/core --recursive
mix raxol.gen.specs lib/raxol/terminal --recursive
```

After adding specs, validate with Dialyzer:

```bash
mix dialyzer
```

## Extending the Generator

Add project-specific inference patterns by editing `infer_single_arg_type/3` and `infer_return_type/1` in `lib/mix/tasks/raxol.gen.specs.ex`.

## CI Integration

```yaml
# .github/workflows/specs.yml
- name: Generate missing specs
  run: mix raxol.gen.specs lib --recursive --dry-run

- name: Check spec coverage
  run: mix dialyzer
```

## Tracking Coverage

```bash
grep -r "@spec" lib/raxol | wc -l                    # functions with specs
grep -r "defp " lib/raxol | wc -l                    # all private functions
mix raxol.gen.specs lib/raxol --recursive --dry-run | grep "Would add" | awk '{sum += $3} END {print "Missing specs:", sum}'
```

## Troubleshooting

**Compilation errors after generation:** Restore from backup (`cp module.ex.backup module.ex`) or fix the spec manually.

**Incorrect type inference:** Use consistent naming, add explicit type annotations for complex types, and define `@type` for domain types.

**Large codebases:** Process in batches:
```bash
find lib -name "*.ex" -type f | head -100 | xargs -I {} mix raxol.gen.specs {}
```
