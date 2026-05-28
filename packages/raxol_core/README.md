# Raxol Core

Core behaviours, utilities, events, config, accessibility, and plugin infrastructure for Raxol. One runtime dependency (telemetry).

## Install

```elixir
{:raxol_core, "~> 2.4"}
```

## What's Included

- **Behaviours**: BaseManager, BaseRegistry, BaseServer, Lifecycle, Metrics, StateManager
- **Runtime.Log**: Centralized structured logging with context, timing, and module detection
- **Utils**: Debounce, ErrorPatterns, GenServerHelpers, TimerManager, TimerUtils, Validation
- **Events**: EventManager, subscriptions, telemetry adapter
- **Config**: Config, ConfigServer, ConfigStore
- **Accessibility**: Screen reader support, announcements, focus management, metadata registry
- **Focus/Keyboard**: FocusManager, KeyboardShortcuts, KeyboardNavigator
- **Standards**: CodeGenerator, CodeStyle, ConsistencyChecker
- **Preferences**: UserPreferences with debounced persistence
- **Plugin Infrastructure**: Plugin lifecycle, registry, supervisor, security (BEAM analyzer, capability detector), command system, dependency resolution, event filtering
- **Error Handling**: ErrorHandler (macros), ErrorHandling (safe_call), ErrorRecovery (circuit breaker, retry, cleanup)
- **I18n**: Internationalization server
- **Telemetry**: TraceContext

## Usage

GenServers defined here are started by the parent application's supervision tree. This package does not auto-start any processes.

```elixir
# In your Application supervisor
children = [
  Raxol.Core.Events.EventManager,
  {Raxol.Core.UserPreferences, [name: Raxol.Core.UserPreferences]},
  Raxol.Core.Runtime.Plugins.PluginSupervisor
]
```

See [main docs](../../README.md) for the full Raxol framework.
