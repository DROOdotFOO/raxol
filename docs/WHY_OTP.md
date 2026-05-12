# Why OTP for multi-surface apps

Most UI frameworks implement crash recovery with try/catch, state management with global stores, concurrency with goroutines or async/await, distribution with gRPC. Raxol gets all of that from OTP.

## The Natural Mapping

| OTP concept   | TUI equivalent            | What you get                                                     |
| ------------- | ------------------------- | ---------------------------------------------------------------- |
| GenServer     | Elm update loop           | `init/1 -> update/2 -> view/1`, managed by the runtime           |
| Process       | Component                 | Each Component can run in its own process                        |
| Supervisor    | Crash recovery            | A Component crashes, it restarts. The rest of the UI doesn't notice |
| Hot code swap | Live reload               | Change `view/1`, save, running app updates. No restart           |
| `:ssh`        | SSH serving               | Built into Erlang. No dep, no daemon, just `:ssh.daemon`         |
| `libcluster`  | Node discovery            | Gossip, DNS, Tailscale. Nodes find each other automatically      |
| `send/2`      | Inter-component messaging | No event bus library. Just processes sending messages            |
| ETS           | State management          | Fast shared state without serialization overhead                 |

These aren't analogies. They're the actual implementations.

## What This Means in Practice

### Crash isolation

In Ratatui or Bubble Tea, if a component panics, your whole app dies. In Raxol:

```elixir
process_component(UnstableWidget, %{path: "/dev/random"})
```

The supervisor restarts the component and renders the next frame. OTP was built for this.

### Hot reload

Erlang's code server supports hot swapping at the module level. Save a file, and the running app picks up the new `view/1` on the next render cycle. No reconnection, no state loss. Same mechanism that lets telecom switches upgrade without dropping calls.

### SSH serving

Erlang ships with a full SSH server. Raxol wraps it:

```elixir
Raxol.SSH.serve(MyApp, port: 2222)
```

Each connection gets its own Lifecycle process with its own state. The whole thing is 4 modules, ~400 lines, because the hard part is in Erlang's `:ssh`.

Textual added SSH in 2024 via `textual-serve`, wrapping an external library. Bubble Tea and Ratatui have community wrappers.

### Distribution

BEAM was designed for distributed systems. Raxol's swarm module builds on that:

```elixir
Raxol.Swarm.Discovery.start_link(strategy: :tailscale, node_basename: "raxol")
Raxol.Swarm.TacticalOverlay.update_entity(:unit_1, %{position: {10.0, 20.0, 0.0}})
```

Nodes are BEAM nodes. Messages are Erlang messages. CRDTs merge with pure functions.

### Three rendering targets

A TEA module is `init/1`, `update/2`, `view/1`. The rendering target is a runtime decision:

- **Terminal**: Lifecycle renders to a screen buffer, diffs, writes ANSI
- **Browser**: `Raxol.LiveView.TEALive` hosts the same module in Phoenix, bridges events
- **SSH**: `Raxol.SSH.Session` wraps Lifecycle per-connection

One app, three outputs.

### AI agents

An agent is a TEA module where input comes from LLMs. Same `init/update/view`, same supervision. The framework is ~300 lines because most of it is OTP:

- `Agent.Session` is a GenServer wrapping Lifecycle
- `Agent.Team` is a Supervisor
- `Agent.Comm` is `GenServer.call`/`cast` with Registry lookups
- `Agent.Backend.HTTP` is `Stream.resource` over SSE

Agents are processes. Teams are supervision trees.

## The Tradeoff

Raxol is slower per-operation than Rust (Ratatui) or Go (Bubble Tea). Buffer creation is 25us vs 0.5us. But a full frame still completes in 2.1ms, leaving 87% of the 60fps budget for your code.

You give up raw microbenchmark speed. You get process isolation, hot reload, distribution, SSH, and multi-target rendering. For anything that has to keep running while you change it, that's a good trade.

## Further Reading

- [Architecture](core/ARCHITECTURE.md): how the render pipeline works
- [Agent Framework](features/AGENT_FRAMEWORK.md): AI agents as TEA apps
- [Distributed Swarm](features/DISTRIBUTED_SWARM.md): CRDTs and node discovery
- [SSH Deployment](cookbook/SSH_DEPLOYMENT.md): serving apps over SSH
