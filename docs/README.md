# Raxol Documentation

Raxol is a multi-surface application runtime for Elixir. One TEA module renders to terminal, browser, SSH, and MCP.

## Start here

- [Quickstart](getting-started/QUICKSTART.md): build a terminal app
- [Build Your First Agent](getting-started/BUILD_AN_AGENT.md): add tools, memory, and a learning loop
- [Core Concepts](getting-started/CORE_CONCEPTS.md): understand TEA, Components, and the runtime
- [Component Gallery](getting-started/COMPONENT_GALLERY.md): browse Components and examples

## Cookbook

- [Building Apps](cookbook/BUILDING_APPS.md): TEA patterns, state machines, scrollable lists
- [SSH Deployment](cookbook/SSH_DEPLOYMENT.md): serve apps over SSH, Fly.io
- [Theming](cookbook/THEMING.md): colors, theme system, accessibility
- [LiveView Integration](cookbook/LIVEVIEW_INTEGRATION.md): embed terminals in Phoenix
- [Performance](cookbook/PERFORMANCE_OPTIMIZATION.md): 60fps rendering, diffing, caching

## Features

See the [feature catalog](features/README.md) for agents, MCP, commerce,
distributed systems, developer tools, and alternate surfaces.

## Guides

- [Surfaces](guides/SURFACES.md): write once, render to every surface
- [Skill Authoring](guides/SKILL_AUTHORING.md): write a reusable `SKILL.md`
- [Custom Components](cookbook/CUSTOM_COMPONENTS.md)

## Design

- [Why OTP](WHY_OTP.md): why the BEAM changes what a UI runtime can do
- [Why Raxol](WHY_RAXOL.md): comparison with Python agent stacks
- [Philosophy](PHILOSOPHY.md): the projection law behind rendering decisions

## Reference

- [Architecture](core/ARCHITECTURE.md)
- [Harness Architecture](harness/architecture.md): the agent-session engine, its contract and journal
- [Buffer API](core/BUFFER_API.md)
- [Tool/Action Catalog](reference/TOOL_CATALOG.md): every LLM-callable tool, generated
- [Architecture Decisions](adr/)
- [Plugin Development](plugins/)
- [Benchmarks](bench/README.md)
- [Development](development/README.md): setup, commands, troubleshooting
- [Testing](testing/README.md): running tests, helpers, property-based testing
- [Configuration](cookbook/CONFIG.md): TOML config, environment overrides

## Examples

- [Examples Learning Path](../examples/README.md): runnable examples, beginner to advanced
- `mix raxol.playground`: interactive Component catalog with 40 demos

## Documentation ownership

| Content | Canonical home |
| --- | --- |
| User tasks and concepts | `getting-started/`, `cookbook/`, `guides/` |
| Capability details | `features/` |
| Stable internals and API contracts | `core/`, `harness/`, `reference/` |
| Accepted design decisions | `adr/` |
| Current work | [`ROADMAP.md`](../ROADMAP.md) |

Keep proposals only while a decision is in flight. Once code, an ADR, or a
canonical guide absorbs the decision, Git history is the archive.

## Project

- [API Docs](https://hexdocs.pm/raxol)
- [GitHub](https://github.com/DROOdotFOO/raxol)
- [Roadmap](../ROADMAP.md)
- [Issues](https://github.com/DROOdotFOO/raxol/issues)
