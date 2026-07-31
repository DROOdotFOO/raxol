# raxol-console

The Raxol runtime for the Virtuals ACP Console, packaged for npm. It wraps a
self-contained BEAM release (built with [Burrito](https://github.com/burrito-elixir/burrito),
embedded ERTS, no host Erlang needed) so the Console's `acp-cli` installs and runs
it out of the box, like the Node incumbents.

## Run

```bash
npm install raxol-console
RAXOL_CONSOLE_PACKAGE=/path/to/agent-package npx raxol-console start
```

`raxol-console` (or `raxol-console start`) starts the runtime in the foreground.
The launcher selects the binary for the current platform and forwards stdio and
the environment.

## Configuration (environment)

| Variable                      | Purpose                                                     |
| ----------------------------- | ----------------------------------------------------------- |
| `RAXOL_CONSOLE_PACKAGE`       | Path to the agent package (`soul.md`, `tasks.json`, ...).   |
| `RAXOL_CONSOLE_WORKSPACE`     | Workspace root (filesystem MCP scope, agent cwd).           |
| `RAXOL_CONSOLE_DEFAULT_TARGET`| Default delivery target for scheduled output.               |
| `RAXOL_CONSOLE_BUNDLE_MCP`    | `true`/`false`: bundle the default MCP servers at boot.     |

## Supported platforms

`darwin-arm64`, `linux-x64`, `linux-arm64`. The launcher errors clearly on an
unsupported platform or a missing binary.

## Building the binaries

Binaries live in `vendor/` (git-ignored, shipped in the published tarball). Build
a target from the Elixir package and vendor it:

```bash
cd ..                       # packages/raxol_console
mise install                # Zig pinned in mise.toml (Burrito requires an exact version)
mise exec -- env BURRITO_TARGET=macos MIX_ENV=prod mix release
npm/scripts/pack.sh         # copies burrito_out/* into npm/vendor/
```

Linux binaries build on Linux (CI/Docker): the termbox NIF's Makefile keys a
macOS-only link flag off the build host's `uname`, so a macOS to Linux
cross-compile would inject a Mach-O flag into an ELF link. CI builds each host's
target and merges `vendor/` before publishing.
