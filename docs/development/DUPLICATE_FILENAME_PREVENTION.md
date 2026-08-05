# Duplicate Filename Prevention

Tooling to detect and prevent duplicate filenames across `lib/` and `test/`.

Multiple files named `manager.ex` or `handler.ex` break IDE navigation, produce ambiguous search results, and make code review confusing.

## Example problematic pattern

```bash
# Before - confusing duplicate names
lib/raxol/terminal/buffer/manager.ex      # which manager?
lib/raxol/terminal/cursor/manager.ex      # which manager?
lib/raxol/core/config/manager.ex          # which manager?
lib/raxol/core/events/manager.ex          # which manager?

# After - clear, contextual names
lib/raxol/terminal/buffer/buffer_manager.ex
lib/raxol/terminal/cursor/cursor_manager.ex
lib/raxol/core/config/config_manager.ex
lib/raxol/core/events/event_manager.ex
```

## Tools

### Standalone script

`scripts/check_duplicate_filenames.exs` scans `lib/` and `test/`, categorizes duplicates by severity (`[CRITICAL]`, `[WARNING]`, `[INFO]`), suggests rename targets, and exits non-zero on findings for CI integration.

```bash
mix run scripts/check_duplicate_filenames.exs
mix run scripts/check_duplicate_filenames.exs --fix-suggestions
```

## Status

This check is not wired into `mix credo` or `mix raxol.check`, and there is no
`.credo.exs` entry for it. The standalone script above is the only tool; run it
manually, or add it to a pre-commit hook or CI step. Prevention otherwise rests
on the naming convention below.

## Problematic patterns

The check flags these commonly duplicated filenames:

### Critical

Files that almost always cause navigation issues: `manager.ex`, `handler.ex`, `server.ex`, `supervisor.ex`, `renderer.ex`, `processor.ex`, `validator.ex`, `buffer.ex`, `parser.ex`, `state.ex`, `types.ex`, `config.ex`, `client.ex`, `worker.ex`.

### Warning

Any filename with 4+ duplicates regardless of name.

### Info

Filenames with 2-3 duplicates. May be acceptable depending on context.

## Naming conventions

Pattern: `{context}_{function}.ex`. Instead of generic names, use domain-specific prefixes:

| Generic Name    | Context              | Suggested Name        |
| --------------- | -------------------- | --------------------- |
| `manager.ex`    | `terminal/buffer/`   | `buffer_manager.ex`   |
| `handler.ex`    | `core/events/`       | `event_handler.ex`    |
| `server.ex`     | `ui/focus/`          | `focus_server.ex`     |
| `processor.ex`  | `terminal/ansi/`     | `ansi_processor.ex`   |
| `validator.ex`  | `terminal/config/`   | `config_validator.ex` |

## Example output

```bash
[CHECK] Checking for duplicate filenames...
Scanning directories: lib, test

[CRITICAL] 'validator.ex' (2 files):
  - lib/raxol/terminal/extension/validator.ex
  - lib/raxol/terminal/config/validator.ex
  Suggested renames:
    extension/validator.ex -> extension_validator.ex
    config/validator.ex    -> config_validator.ex

[WARNING] 'manager_test.exs' (21 files):
  - test/raxol/core/runtime/plugins/manager_test.exs
  - test/raxol/core/events/manager_test.exs
  - test/raxol/terminal/split/manager_test.exs
  ...

[INFO] 'schema.ex' (2 files):
  - lib/raxol/config/schema.ex
  - lib/raxol/terminal/config/schema.ex
```

## Workflow

There is no automated integration today: wire the standalone script into a pre-commit hook or CI step if you want it enforced. When adding new files, use descriptive, contextual names so duplicates do not appear in the first place.
