# Duplicate Filename Prevention

Tooling to detect and prevent duplicate filenames across `lib/` and `test/`.

Multiple files named `manager.ex` or `handler.ex` break IDE navigation, produce ambiguous search results, and make code review confusing.

## Example Problematic Pattern

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

### Standalone Script

`scripts/quality/check_duplicate_filenames.exs` scans `lib/` and `test/`, categorizes duplicates by severity (`[CRITICAL]`, `[WARNING]`, `[INFO]`), suggests rename targets, and exits non-zero on findings for CI integration.

```bash
mix run scripts/quality/check_duplicate_filenames.exs
mix run scripts/quality/check_duplicate_filenames.exs --fix-suggestions
```

### Credo Integration

`lib/raxol/credo/duplicate_filename_check.ex` runs the same check inline during `mix credo`.

```bash
mix credo
mix credo --only Raxol.Credo.DuplicateFilenameCheck
```

## Configuration

In `.credo.exs`:

```elixir
{Raxol.Credo.DuplicateFilenameCheck, [
  exclude_files: ["mix.exs", "README.md", ".gitignore"],
  max_duplicates: 1,
  include_tests: true
]}
```

Options:

- `exclude_files` -- files to ignore (default: `["mix.exs", "README.md", ".gitignore"]`)
- `max_duplicates` -- maximum allowed duplicates before flagging (default: `1`)
- `include_tests` -- whether to check test files (default: `true`)

## Problematic Patterns

The check flags these commonly duplicated filenames:

### Critical

Files that almost always cause navigation issues: `manager.ex`, `handler.ex`, `server.ex`, `supervisor.ex`, `renderer.ex`, `processor.ex`, `validator.ex`, `buffer.ex`, `parser.ex`, `state.ex`, `types.ex`, `config.ex`, `client.ex`, `worker.ex`.

### Warning

Any filename with 4+ duplicates regardless of name.

### Info

Filenames with 2-3 duplicates. May be acceptable depending on context.

## Naming Conventions

Pattern: `{context}_{function}.ex`. Instead of generic names, use domain-specific prefixes:

| Generic Name    | Context              | Suggested Name        |
| --------------- | -------------------- | --------------------- |
| `manager.ex`    | `terminal/buffer/`   | `buffer_manager.ex`   |
| `handler.ex`    | `core/events/`       | `event_handler.ex`    |
| `server.ex`     | `ui/focus/`          | `focus_server.ex`     |
| `processor.ex`  | `terminal/ansi/`     | `ansi_processor.ex`   |
| `validator.ex`  | `terminal/config/`   | `config_validator.ex` |

## Example Output

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

The Credo check runs inline in editors that integrate with Credo and during the standard `mix raxol.check` pipeline. Wire the standalone script into a pre-commit hook or CI step if you want it separate.

False positives: add files to `exclude_files`. When adding new files: use descriptive, contextual names and let `mix credo` flag duplicates before committing.
