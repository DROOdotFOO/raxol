# Raxol for VS Code

Snippets and mix-task shortcuts for Raxol projects.

This extension ships no language server and no TextMate grammar. Install an
Elixir extension (ElixirLS, Lexical, or Next LS) for syntax highlighting,
completion, and diagnostics; this one sits alongside it. For the coding agent,
see [Coding agent](#coding-agent) below.

`package.json` also declares a `raxol-elixir` language over `.ex`/`.exs` that
carries editing rules only (comment token, bracket pairs, indent patterns) and
no tokenizer. If your Elixir files come up unhighlighted, pin them back with
`"files.associations": { "*.ex": "elixir", "*.exs": "elixir" }`.

## What it does

**Snippets** for the `elixir` language, from `snippets/raxol.json`:

| Prefix | Expands to |
|--------|------------|
| `raxol-component` | `use Raxol.UI.Components.Base.Component` skeleton |
| `raxol-app` | `@behaviour Raxol.Core.Runtime.Application` skeleton |
| `raxol-button` | `button(label, on_click: ...)` |
| `raxol-input` | `text_input(placeholder:, value:, on_change:)` |
| `raxol-table` | `table(data:, columns:)` |
| `raxol-modal` | `modal(visible:, title:, on_close:)` block |
| `raxol-column` | `column [...] do` block |
| `raxol-row` | `row [...] do` block |
| `raxol-event` | `handle_event/3` clause |
| `raxol-update` | `update/2` clause |

**Commands** (command palette, shown when the workspace contains `mix.exs`):

- `Raxol: Generate Component` prompts for a name, then runs
  `mix raxol.gen.component <name>` in a new terminal at the first workspace
  folder. The explorer context-menu entry runs the same thing; it does not
  scope generation to the folder you clicked.
- `Raxol: Open Component Playground` runs `mix raxol.playground` in a new
  terminal at the first workspace folder.

**Component boilerplate**: creating an empty file matching
`**/lib/**/components/**/*.ex` prompts to insert a
`Raxol.UI.Components.Base.Component` skeleton named after the file.

## Building

```bash
cd editors/vscode
npm install
npm run compile   # tsc -p ./, output in out/
```

`npm run watch` recompiles on change. Open `editors/vscode` in VS Code and start
"VS Code Extension Development" from the Run and Debug view to try it in an
Extension Development Host.

## Coding agent

The Raxol coding agent reaches editors over the
[Agent Client Protocol](https://agentclientprotocol.com), which Zed and its
ecosystem speak. This extension wires up no ACP client. From a raxol checkout,
run the agent TUI in the integrated terminal:

```bash
/path/to/raxol/bin/raxol-code
```

Or serve it over ACP to a client that speaks it: `/path/to/raxol/bin/raxol-acp`
(`mix help raxol.acp` has the Zed `agent_servers` snippet). Both need deps
fetched once: `cd packages/raxol_agent && mix deps.get`. See
[`docs/features/CODING_AGENT.md`](../../docs/features/CODING_AGENT.md).

## License

MIT License - see the main Raxol project for details.
