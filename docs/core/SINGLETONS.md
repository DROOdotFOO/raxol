# VM-Singleton GenServer Audit

Every named-singleton (`name: __MODULE__`) process in the Raxol codebase,
classified **intentional** or **questionable**, with the reasoning. Issues
#228 and #229 surfaced because the runtime had *latent* singletons: modules
registered as VM-wide names that were actually meant to support multiple
concurrent instances. Making the contract explicit means the same class of
bug cannot repeat without a deliberate decision.

## Why this matters

`GenServer.start_link(name: __MODULE__)` collides on the second call from
the same VM with `{:error, {:already_started, _}}`. For a process designed
to be VM-wide (one config store, one rate limiter), that's correct. For a
process designed to be per-instance (one Dispatcher per Raxol Lifecycle,
one PluginManager per app), it's a latent multi-tenancy bug that surfaces
the moment two SSH sessions, two LiveView mounts, or two agents run
concurrently in the same node.

Raxol explicitly supports concurrent SSH (`Raxol.SSH.Session` per channel),
agent fan-out (`Raxol.Agent.Team`), and multi-mount LiveView. Every named
singleton is a constraint on that surface.

## Policy

1. **Supervisors** may use `name: __MODULE__`; canonical and harmless.
2. **VM-wide services** (config, registries, accessibility queues, rate
   limiters, dev tools) may use `name: __MODULE__`. Document the "why this
   is one-per-VM" reasoning here.
3. **Per-instance processes** (Dispatcher, Lifecycle, anything spawned per
   app/session/channel) MUST accept `[name: nil]` and be addressable by pid
   from the parent's state. Hardcoding `name: __MODULE__` for these is a
   bug.
4. New `name: __MODULE__` registrations must update this file.

A CI grep guard at `scripts/check_singletons.sh` enforces (4) by failing
when the set of singleton-registering call sites diverges from the
allowlist below.

## Allowlist

### Supervisors (canonical)

| Module | Path |
|--------|------|
| `Raxol.Core.CoreSupervisor` | `lib/raxol/core/core_supervisor.ex` |
| `Raxol.Core.Runtime.RuntimeSupervisor` | `lib/raxol/core/runtime/runtime_supervisor.ex` |
| `Raxol.Core.ServerRegistry` | `lib/raxol/core/server_registry.ex` |
| `Raxol.DynamicSupervisor` | `lib/raxol/dynamic_supervisor.ex` |
| `Raxol.Terminal.Supervisor` | `packages/raxol_terminal/lib/raxol/terminal/terminal_supervisor.ex` |
| `Raxol.Core.Runtime.Plugins.PluginSupervisor` | `packages/raxol_core/lib/raxol/core/runtime/plugins/plugin_supervisor.ex` |
| `Raxol.Agent.Supervisor` | `packages/raxol_agent/lib/raxol/agent/supervisor.ex` |
| `Raxol.MCP.Supervisor` | `packages/raxol_mcp/lib/raxol/mcp/supervisor.ex` |
| `Raxol.Speech.Supervisor` | `packages/raxol_speech/lib/raxol/speech/supervisor.ex` |
| `Raxol.Telegram.Supervisor` | `packages/raxol_telegram/lib/raxol/telegram/supervisor.ex` |
| `Raxol.Watch.Supervisor` | `packages/raxol_watch/lib/raxol/watch/supervisor.ex` |

### VM-wide services (intentional)

| Module | Why one-per-VM |
|--------|----------------|
| `Raxol.RBAC` | One role/permission set per node |
| `Raxol.RateLimit` | VM-wide rate limiting Agent |
| `Raxol.Dev.CodeReloader` | One reloader watches the VM in dev |
| `Raxol.Core.Runtime.ProcessStore` | Explicit Process-dictionary replacement; VM-wide by design |
| `Raxol.Core.Config.ConfigStore` | VM-wide config |
| `Raxol.Core.Accessibility.Announcements` | One global accessibility queue |
| `Raxol.Core.Runtime.Plugins.PluginLifecycle` | Plugins shared across Lifecycles; ETS-backed Registry, plugin_id-namespaced state. Confirmed by #229. |
| `Raxol.Core.Runtime.Plugins.ResourceBudget` | One budget shared across plugins |
| `Raxol.Speech.Recognizer` | One Whisper model per VM |
| `Raxol.Speech.Listener` | One microphone per host |
| `Raxol.Speech.Speaker` | One TTS pipeline per VM |
| `Raxol.Speech.TTS.OsSay` | OS process owns audio device |
| `Raxol.Speech.TTS.Noop` | Test stub |
| `Raxol.Telegram.SessionRouter` | One bot router per VM (re-evaluate if multi-bot needed) |
| `Raxol.Watch.Notifier` | Push fan-out via DeviceRegistry; only one notifier needed |
| `Raxol.Watch.DeviceRegistry` | ETS-backed device list |
| `Raxol.Watch.Push.Noop` | Test stub |
| `Raxol.Symphony.Runners.Noop` | Test stub |

### Questionable (re-evaluate when next touched)

| Module | Concern |
|--------|---------|
| `Raxol.Demo.SessionManager` | Manages demo sessions, but registered VM-wide. Two demo apps would collide. Likely OK in practice, but confirm. |
| `Raxol.Core.Metrics.MetricsCollector` | Metrics collector is VM-wide (intentional), but per-Lifecycle metric isolation may be wanted. |
| `Raxol.Recording.Recorder` | Singleton recorder; multi-session recording would interleave. Investigate before exposing recording over SSH. |
| `Raxol.Terminal.Buffer.SafeManager` | Registered as `__MODULE__` but the underlying module is `ScreenBuffer.Manager`. Buffer-per-emulator scenarios may want per-instance. |

## CI guard

`scripts/check_singletons.sh` greps the first-party tree for
`GenServer\|Agent\|Supervisor\|DynamicSupervisor\.start_link.*name: __MODULE__`
and diffs the result against `scripts/.singletons-allowlist`. To add a new
singleton:

1. Implement the registration.
2. Add the file path to `scripts/.singletons-allowlist`.
3. Document the reasoning in this file under "Allowlist" above.

If you're tempted to add a registration but the process is per-instance,
follow the `:agent`/`:liveview`/`:ssh` pattern in
`Raxol.Core.Runtime.Lifecycle.Initializer.start_dispatcher/5`: accept
`[name: nil]` from the caller and skip name registration in those envs.

## Related

- #228: Dispatcher singleton blocked concurrent SSH (fixed in #232)
- #229: PluginManager `already_started` adoption (fixed in #233)
