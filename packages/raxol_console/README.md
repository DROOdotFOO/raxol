# RaxolConsole

Console runtime for Raxol. Boots a Virtuals ACP Console agent package
(`soul.md` + `tasks.json` + `skills/`) onto the gateway stack, making Raxol a
provisionable runtime alongside Hermes and OpenClaw. See `docs/adr/0031`.

## Packaging

The runtime ships as a self-contained executable (Burrito, embedded ERTS) wrapped
in an npm package (`npm/`), so the Console's `acp-cli` installs and runs it like
the Node incumbents. Zig is pinned in `mise.toml` (Burrito requires an exact
version). Build a target and vendor it into the npm package:

```bash
mise install
mise exec -- env BURRITO_TARGET=macos MIX_ENV=prod mix release
npm/scripts/pack.sh
```

Linux binaries build on Linux (CI/Docker); see `npm/README.md` for the why.
