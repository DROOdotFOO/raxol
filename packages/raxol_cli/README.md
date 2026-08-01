# RaxolCli

The `raxol` command: an interactive AI agent and Raxol toolkit in your terminal.
Ships as a self-contained binary (Burrito) wrapped in the `raxol` npm package
(`npm/`), so `npm i -g raxol` puts `raxol` on your PATH. See docs/adr/0031 for the
packaging approach.

## Commands

    raxol            # interactive AI agent (default)
    raxol agent      # same, explicit
    raxol playground # interactive component catalog
    raxol new <name> # scaffold a new Raxol app
    raxol help
