# Naming Conventions

Standardized naming for all modules in the Raxol codebase. Established during Sprint 22-23 refactoring.

## General Rule

All modules follow: `<domain>_<function>.ex`

### Correct

- `lib/raxol/terminal/cursor/cursor_manager.ex` -> `Raxol.Terminal.Cursor.CursorManager`
- `lib/raxol/core/events/event_manager.ex` -> `Raxol.Core.Events.EventManager`
- `lib/raxol/terminal/buffer/buffer_server.ex` -> `Raxol.Terminal.Buffer.BufferServer`

### Wrong (previously used)

- `lib/raxol/terminal/cursor/manager.ex` -> `Raxol.Terminal.Cursor.Manager`
- `lib/raxol/core/events/manager.ex` -> `Raxol.Core.Events.Manager`
- `lib/raxol/terminal/buffer/server.ex` -> `Raxol.Terminal.Buffer.Server`

## Specific Patterns

### Managers: `<domain>_manager.ex`

`cursor_manager.ex`, `color_manager.ex`, `plugin_manager.ex`

### Servers (GenServer): `<domain>_server.ex`

`buffer_server.ex`, `emulator_server.ex`, `accessibility_server.ex`

### Handlers: `<domain>_handler.ex` (singular, not plural)

`cursor_handler.ex`, `events_handler.ex`, `device_handler.ex`

### Core Modules: `<domain>_core.ex`

`terminal_core.ex`, `renderer_core.ex`, `cloud_core.ex`

### State: `<domain>_state.ex`

`emulator_state.ex`, `parser_state.ex`, `terminal_state.ex`

### Config: `<domain>_config.ex`

`terminal_config.ex`, `cloud_config.ex`, `raxol_config.ex`

### Validators: `<domain>_validation.ex`

`view_validation.ex`, `config_validation.ex`, `lifecycle_validation.ex`

## Nested Modules

Filenames reflect the full context:

```
lib/raxol/terminal/graphics/kitty/
├── kitty_protocol.ex      -> Raxol.Terminal.Graphics.Kitty.KittyProtocol
├── kitty_renderer.ex      -> Raxol.Terminal.Graphics.Kitty.KittyRenderer
└── kitty_config.ex        -> Raxol.Terminal.Graphics.Kitty.KittyConfig
```

## What to Avoid

Never use bare generic names:
- `manager.ex` -> use `<domain>_manager.ex`
- `server.ex` -> use `<domain>_server.ex`
- `handler.ex` -> use `<domain>_handler.ex`
- `core.ex` -> use `<domain>_core.ex`

## Why this matters

- No filename collisions across the codebase
- Purpose is clear from the filename alone
- Better IDE autocomplete and file navigation
- Easier to grep for specific functionality

## Status

All 154+ duplicate filenames were resolved in Sprint 22-23. Zero compilation warnings from naming conflicts. All module references and tests updated. Test files follow the same convention in `test/`.

Last updated: 2025-09-10 (Sprint 26)
