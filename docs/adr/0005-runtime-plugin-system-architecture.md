# ADR-0005: Runtime Plugin System Architecture

## Status

Implemented (Retroactive Documentation)

## Context

A terminal framework needs extensibility without bloating the core. The usual approaches all have problems:

- **Static libraries** require recompilation and can't be updated independently
- **Separate binaries** have poor integration and communication overhead
- **Restart-required plugins** disrupt workflow and lose state
- **Embedded scripting** brings security risks and performance overhead

We needed plugins that can be loaded and unloaded at runtime, have full system access within security boundaries, preserve state across reloads, manage dependencies between each other, and support file watching for development-time auto-reload.

## Decision

Build a runtime plugin system on Elixir's native code loading with lifecycle management and security boundaries.

### Architecture

**Plugin Manager** (`lib/raxol/core/runtime/plugins/manager.ex`): central coordinator for plugin lifecycle. Maintains state, metadata, and dependency graphs. Handles hot loading and unloading.

**Plugin Behaviour** (`lib/raxol/core/runtime/plugins/plugin.ex`):

```elixir
@callback init(config :: config()) :: {:ok, state()} | {:error, any()}
@callback terminate(reason :: any(), state :: state()) :: any()
@callback enable(state :: state()) :: {:ok, state()} | {:error, any()}
@callback disable(state :: state()) :: {:ok, state()} | {:error, any()}
@callback filter_event(event :: event(), state :: state()) :: {:ok, event()} | :halt
@callback handle_command(command :: command(), state :: state()) :: {:ok, state()} | {:error, any()}
```

**Lifecycle Management** (`lib/raxol/core/runtime/plugins/lifecycle.ex`) -- handles dependency ordering, circular dependency detection, rollback on failure, and graceful degradation.

**State Management** (`lib/raxol/core/runtime/plugins/state_manager.ex`) -- isolates plugin state from core state. Provides transactional updates, snapshots for rollback, and persistence across reloads.

**Process Isolation** (`lib/raxol/core/runtime/plugins/plugin_supervisor.ex`) -- crash isolation via Task.Supervisor. Configurable timeouts (default 5000ms). Individual failure isolation.

**Dependency Management** (`lib/raxol/core/runtime/plugins/dependency_manager.ex`) -- topological sorting for load order, circular dependency detection, version compatibility checking.

**Security** -- BEAM bytecode analysis detects security-sensitive operations (file access, network access, code injection, system commands). Configurable policies validate plugins before loading. Capability-based permissions with audit logging.

### Writing a Plugin

```elixir
defmodule MyPlugin do
  use Raxol.Plugin

  def init(config) do
    {:ok, %{counter: 0, config: config}}
  end

  def handle_command("increment", state) do
    {:ok, %{state | counter: state.counter + 1}}
  end

  def enable(state) do
    register_command("increment", "Increment counter")
    {:ok, state}
  end

  def disable(state) do
    unregister_command("increment")
    {:ok, state}
  end
end

# Hot reload in development
Raxol.Plugins.reload("my_plugin")
```

### Hot Reloading Flow

1. File watcher detects changes
2. Snapshot current plugin state
3. Gracefully disable and clean up
4. Load new code via Elixir's hot code swapping
5. Apply state migrations if structure changed
6. Re-enable with preserved/migrated state

### Plugin Operations

```elixir
plugins = Raxol.Plugins.discover("/path/to/plugins")
Raxol.Plugins.load_batch(plugins)
Raxol.Plugins.load("plugin_name")
Raxol.Plugins.enable("plugin_name")
Raxol.Plugins.disable("plugin_name")
Raxol.Plugins.unload("plugin_name")
```

## Consequences

### Positive

- New functionality without core changes
- Hot reloading for rapid plugin development
- Clear separation between core and extensions
- Failed plugins don't crash the core system
- Minimal overhead when plugins aren't active

### Negative

- More complex than static linking
- Plugin manager and state isolation use memory
- Plugin API increases the attack surface
- API must be maintained and versioned

### Mitigation

- Plugin system is optional; core works without it
- Security-first API design with BEAM bytecode analysis
- Built-in metrics for monitoring plugin impact

## Validation

### Achieved

- Hot reload time: <500ms with state preservation
- Plugin failures don't affect core stability
- Event processing overhead: <1ms
- No privilege escalation vulnerabilities found in audit
- 46 plugin modules implemented

## Alternatives Considered

**Static plugin loading** -- requires restart for changes. Poor dev experience.

**External process plugins** -- high IPC overhead and integration complexity.

**Embedded scripting languages**: security risks and performance penalty.

**Microservice-based extensions**: over-engineering for a terminal framework.

The runtime approach lets plugins hot-load without process restarts and uses BEAM bytecode analysis to gate sensitive operations, both of which fall out of Elixir's native code-loading and supervision.

## References

- [Plugin Development Guide](../plugins/GUIDE.md)
- [Plugin Manager](../../lib/raxol/core/runtime/plugins/plugin_manager.ex)
- [Plugin Behaviour](../../lib/raxol/core/runtime/plugins/plugin.ex)
- [Lifecycle Management](../../lib/raxol/core/runtime/plugins/lifecycle.ex)
- [State Management](../../lib/raxol/core/runtime/plugins/state_manager.ex)
- [Dependency Manager](../../lib/raxol/core/runtime/plugins/dependency_manager.ex)
- [Plugin Supervisor](../../lib/raxol/core/runtime/plugins/plugin_supervisor.ex)
- [BEAM Analyzer](../../lib/raxol/core/runtime/plugins/security/beam_analyzer.ex)
- [Capability Detector](../../lib/raxol/core/runtime/plugins/security/capability_detector.ex)

---

**Decision Date**: 2025-06-20 (Retroactive)
**Implementation Completed**: 2025-08-10
