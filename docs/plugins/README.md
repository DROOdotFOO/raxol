# Plugin Documentation

This directory covers plugin development for the Raxol terminal emulator.

## Guides

### [GUIDE.md](GUIDE.md) - development guide

Plugin development from basics to advanced: quick start, lifecycle states, event system, the manifest schema, security analysis, and process isolation.

### [PLUGIN_TEMPLATES.md](PLUGIN_TEMPLATES.md) - Templates

Working templates for common plugin types: basic, background (periodic tasks), and file system (file watching).

### [TESTING.md](TESTING.md) - testing guide

Testing strategies: unit and integration tests, event filtering tests, property-based testing, performance testing.

## Quick start

1. Read [GUIDE.md](GUIDE.md) for the full lifecycle and development model
2. Pick a template from [PLUGIN_TEMPLATES.md](PLUGIN_TEMPLATES.md)
3. Write tests using patterns from [TESTING.md](TESTING.md)

## Example plugins

Runnable starting points live in [`examples/plugins/`](../../examples/plugins/): a
[basic plugin](../../examples/plugins/basic_plugin.exs), a
[background task plugin](../../examples/plugins/background_task_plugin.exs), a
[file system plugin](../../examples/plugins/file_system_plugin.exs), and a
[test suite](../../examples/plugins/plugin_test.exs). See
[Plugin Templates](PLUGIN_TEMPLATES.md).

## Plugin system architecture

### Core components

- **[Plugin Manager](../../packages/raxol_core/lib/raxol/core/runtime/plugins/plugin_manager.ex)** - Lifecycle and dependency management
- **[Plugin Behaviour](../../packages/raxol_core/lib/raxol/core/runtime/plugins/plugin.ex)** - Interface all plugins must implement
- **[Plugin Reloader](../../packages/raxol_core/lib/raxol/core/runtime/plugins/plugin_reloader.ex)** - Live plugin updates
- **[Plugin Registry](../../packages/raxol_core/lib/raxol/core/runtime/plugins/plugin_registry.ex)** - Plugin registration and lookup

## Create a plugin

```bash
cp lib/raxol/plugins/examples/rainbow_theme_plugin.ex lib/raxol/plugins/my_plugin.ex
MIX_ENV=test mix test test/raxol/plugins/my_plugin_test.exs
```

## Further reading

- Study existing plugins in `lib/raxol/plugins/examples/`
- Review test patterns in `test/raxol/plugins/`
