# RaxolCli

The `raxol` command: an interactive AI agent and Raxol toolkit in your terminal.
Ships as a self-contained binary (Burrito) wrapped in the `@raxol/cli` npm
package (`npm/`), so `npm i -g @raxol/cli` puts `raxol` on your PATH. See docs/adr/0031 for the
packaging approach.

## Commands

    raxol            # interactive AI agent (default)
    raxol agent      # same, explicit
    raxol playground # interactive component catalog
    raxol new <name> # scaffold a new Raxol app
    raxol mcp        # serve Raxol apps as MCP tools on stdio (for OMP)
    raxol help

## `raxol mcp`

Serves Raxol apps as MCP tools on stdin/stdout to the client that spawned it,
such as OMP. stdout carries JSON-RPC only; logs and anything an app prints go
to stderr. It exits 0 at end of input, 1 when it refuses to serve (each
refusal is one line on stderr), and 64 for unknown arguments.

    raxol mcp [--expect-version X] [--no-derived] [--bench-dump PATH]

- `--expect-version X` refuses to serve unless this binary is version `X`.
- `--no-derived` lists and allows only the static tools, not a session's
  widget tools, and denies the session resources that list tools
  (`raxol://session/<id>/context`, `/tools`, `/resources`, `/prompts`).
- `--bench-dump PATH` writes every running session's model to `PATH` at end
  of input (`:erlang.term_to_binary(%{session_id => model})`), after the
  journals are flushed. It is written whole or not at all; a session that does
  not answer within 500 ms leaves no file and exit 1.

Run by hand, set `RAXOL_MODE=mcp` (the binary also recognizes `raxol mcp` from
its own arguments; `mix run` does not). With `RAXOL_MODE=mcp` set, no other
`raxol` command runs. It starts only the modules on the startable list (the
playground demos unless `config :raxol, :headless_startable` says otherwise),
refuses `raxol_start`'s `path`, and serves `resources/read`,
`resources/subscribe` and `resources/unsubscribe` only for the sessions it
started. It refuses to start while `RAXOL_CLI_INSTALL_DIR` is set, because the
launcher then prints to stdout. One connection may run up to half the server's
32 concurrent calls at once; the rest are answered `server_busy`.
