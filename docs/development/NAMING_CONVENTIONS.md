# Naming Conventions

Filename standards for modules in the Raxol codebase, plus the checker that
finds violations.

## The rule

Source files are named `<domain>_<function>.ex`. The domain prefix
disambiguates: several directories need a "manager", and a tree full of files
called `manager.ex` breaks IDE navigation, makes search results ambiguous, and
makes code review harder to follow.

```
packages/raxol_terminal/lib/raxol/terminal/cursor/cursor_manager.ex
packages/raxol_terminal/lib/raxol/terminal/buffer/buffer_server.ex
packages/raxol_core/lib/raxol/core/events/event_manager.ex
```

This governs the **filename**. The module name follows the directory
namespace, which already carries the domain, so the module is free to drop the
prefix. Both forms are in use and both are fine:

| File | Module |
| --- | --- |
| `terminal/cursor/cursor_manager.ex` | `Raxol.Terminal.Cursor.Manager` |
| `terminal/buffer/buffer_server.ex` | `Raxol.Terminal.Buffer.BufferServer` |
| `core/events/event_manager.ex` | `Raxol.Core.Events.EventManager` |

## Patterns by kind

| Kind | Filename | Examples |
| --- | --- | --- |
| Managers | `<domain>_manager.ex` | `cursor_manager.ex`, `plugin_manager.ex` |
| GenServers | `<domain>_server.ex` | `buffer_server.ex`, `command_server.ex` |
| Handlers | `<domain>_handler.ex` (singular) | `cursor_handler.ex`, `device_handler.ex` |
| Core modules | `<domain>_core.ex` | `updater_core.ex`, `modal_core.ex` |
| State | `<domain>_state.ex` | `terminal_state.ex`, `parser_state.ex` |
| Config | `<domain>_config.ex` | `terminal_config.ex`, `integration_config.ex` |
| Validators | `<domain>_validation.ex` | `view_validation.ex`, `config_validation.ex` |

## Names to avoid for new files

`manager.ex`, `handler.ex`, `server.ex`, `supervisor.ex`, `renderer.ex`,
`processor.ex`, `validator.ex`, `buffer.ex`, `parser.ex`, `state.ex`,
`types.ex`, `config.ex`, `client.ex`, `worker.ex`.

Instead, prefix with the enclosing domain:

| Generic | Context | Use |
| --- | --- | --- |
| `manager.ex` | `terminal/buffer/` | `buffer_manager.ex` |
| `handler.ex` | `core/events/` | `event_handler.ex` |
| `server.ex` | `ui/focus/` | `focus_server.ex` |
| `processor.ex` | `terminal/ansi/` | `ansi_processor.ex` |
| `validator.ex` | `terminal/config/` | `config_validator.ex` |

Some of these bare names predate the convention and are still in the tree.
They are grandfathered, not endorsed: rename opportunistically when you are
already editing the file, and do not add new ones.

## Checker

`scripts/check_duplicate_filenames.exs` reports duplicate basenames, grouped
by severity, and exits non-zero when it finds any.

```bash
elixir scripts/check_duplicate_filenames.exs
elixir scripts/check_duplicate_filenames.exs --fix-suggestions
```

Severities:

- **CRITICAL**: one of the bare generic names listed above.
- **WARNING**: any basename with 4 or more copies.
- **INFO**: any basename with 2 or 3 copies. Often acceptable in context.

Two limits worth knowing before you read its output:

- It scans the root `lib/` and `test/` only, so the extracted packages under
  `packages/*/lib/` are outside its view.
- It is not wired into `mix credo`, `mix raxol.check`, or CI, and there is no
  `.credo.exs` entry for it. Run it by hand, or add it to a hook yourself.

## Why this matters

- No filename collisions across the codebase
- Purpose is clear from the filename alone
- Better editor autocomplete and file navigation
- Easier to grep for specific functionality
