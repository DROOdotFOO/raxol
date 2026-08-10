# Screenshot recording

Fixtures and notes for capturing the MCP-client screenshots used in directory
listings (glama.ai, awesome-mcp-clients) and the docs.

`workspace/` is the demo working directory. Its `.mcp.json` declares two
tokenless servers (filesystem, memory), so nothing secret can appear on camera
and the `/mcp` panel shows real third-party connections rather than raxol
talking to itself.

## Recording

Drive the TUI by hand and record it:

```bash
npx -y @modelcontextprotocol/server-filesystem --help   # warm the npx cache
cd assets/tapes/workspace
asciinema rec --window-size 100x30 -c "raxol code" /tmp/mcp.cast
```

Then, in the session: wait for the servers to connect, run `/mcp`, ask for
something that calls an MCP tool, answer the approval prompt with `a`, and quit.

Render stills from the cast:

```bash
agg --font-size 20 --theme dracula /tmp/mcp.cast /tmp/mcp.gif
magick /tmp/mcp.gif -coalesce -delete 0--2 shot.png   # last frame
magick '/tmp/mcp.gif[120]' shot.png                    # a specific frame
```

## Why this is driven by hand

Three automated drivers were tried and none can type into this TUI:

- **VHS / ttyd** renders the TUI but never puts the terminal into raw mode, so
  keystrokes echo to the shell instead of reaching the app.
- **`asciinema rec --headless`** forwards stdin but leaves the pty at 80x24
  regardless of `--window-size`, and the app renders against the wrong size.
- **A hand-rolled `pty.fork` harness** with `TIOCSWINSZ` set correctly still
  leaves the model's `input` field empty after writing bytes to the master fd.

A human at a real terminal is unaffected; only unattended drivers are. If you
automate this later, assert on something that can only come from the app --
the typed token appearing in the model's `input` field, say. Asserting on
`"filesystem"` or `●` appearing anywhere in the stream false-passes, because
both also occur in the model-state dump the app prints.

Also note the packaged binary is built with `skip_nifs: true`
(`packages/raxol_cli/mix.exs`), so it has no termbox2 NIF and renders through a
fallback path. Recordings of `burrito_out/raxol_cli_macos` show misaligned box
borders and replacement glyphs; a source run does not. Record from a source
build, or fix the packaging first.
