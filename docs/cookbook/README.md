# Cookbook

Practical recipes for building terminal applications with Raxol.

## Guides

- [Building Apps](BUILDING_APPS.md) -- TEA patterns, state machines, scrollable lists, key chords, testing
- [Custom Components](CUSTOM_COMPONENTS.md) -- author your own Components
- [Configuration](CONFIG.md) -- TOML config, environment overrides
- [SSH Deployment](SSH_DEPLOYMENT.md) -- Serve apps over SSH, production setup, Fly.io
- [Theming](THEMING.md) -- Terminal colors, theme system, LiveView CSS, accessibility
- [LiveView Integration](LIVEVIEW_INTEGRATION.md) -- Embed terminals in Phoenix LiveView
- [Performance Optimization](PERFORMANCE_OPTIMIZATION.md) -- 60fps rendering, diffing, caching

## Examples

Complete applications are in the [`examples/`](../../examples/README.md) directory:

- `examples/getting_started/counter.exs` -- Minimal TEA app
- `examples/demo.exs` -- Live BEAM dashboard with sparklines
- `examples/apps/file_browser.exs` -- File browser with tree navigation
- `examples/apps/todo_app.ex` -- Todo list
- `examples/ssh/ssh_counter.exs` -- SSH-served counter
