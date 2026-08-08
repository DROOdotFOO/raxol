# Raxol.nvim

Neovim plugin for Raxol development: component scaffolding, treesitter setup,
and shortcuts to the Raxol mix tasks.

There is no Raxol language server. Use ElixirLS, Lexical, or Next LS for
completion, hover, and diagnostics; this plugin does not configure or
replace them. For the coding agent inside your editor, see
[Coding agent](#coding-agent) below.

## Features

- **Component generation**: `mix raxol.gen.component` from a command or keymap
- **Playground integration**: `mix raxol.playground`, the Component catalog
- **Test runner**: `mix test` with the environment the suite expects
- **Component templates**: boilerplate written when you create a file under
  `**/components/**/*.ex`
- **Treesitter setup**: turns on nvim-treesitter highlight, incremental
  selection, and text objects for you

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'axol-io/raxol',
  dir = '/path/to/raxol/editors/nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'nvim-treesitter/nvim-treesitter-textobjects', -- optional
  },
  ft = { 'elixir', 'eex', 'heex' },
  config = function()
    require('raxol').setup({
      -- Configuration options here
    })
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'axol-io/raxol',
  requires = {
    'nvim-treesitter/nvim-treesitter',
    'nvim-treesitter/nvim-treesitter-textobjects', -- optional
  },
  ft = { 'elixir', 'eex', 'heex' },
  config = function()
    require('raxol').setup()
  end
}
```

### Manual installation

1. Clone or copy the plugin to your Neovim configuration:

```bash
# For Neovim data directory
mkdir -p ~/.local/share/nvim/site/pack/raxol/start/
cp -r /path/to/raxol/editors/nvim ~/.local/share/nvim/site/pack/raxol/start/raxol.nvim
```

2. Add to your `init.lua`:

```lua
require('raxol').setup()
```

## Configuration

Default configuration:

```lua
require('raxol').setup({
  treesitter = {
    enabled = true,
    highlight = true,
    incremental_selection = true,
    textobjects = true
  }
})
```

`setup_treesitter` calls `nvim-treesitter.configs.setup`, so the `treesitter`
block reconfigures treesitter globally, not only for Elixir buffers. Set
`treesitter.enabled = false` if you configure nvim-treesitter yourself.

## Commands

- `:RaxolGenerateComponent [name]` - `mix raxol.gen.component <name>`, prompting
  for the name when you omit it
- `:RaxolPlayground` - `mix raxol.playground`
- `:RaxolTest` - `SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --exclude slow
  --exclude integration --exclude docker`

Each command runs its mix task in a `:terminal` buffer in the current window.

## Keymaps

Default keymaps (can be customized):

- `<leader>rc` - Generate component
- `<leader>rp` - Open playground
- `<leader>rt` - Run tests

### Treesitter text objects

- `af`/`if` - Function outer/inner
- `]m`/`[m` - Next/previous function

`af`/`if` and `]m`/`[m` resolve against `@function.outer`/`@function.inner`,
which nvim-treesitter-textobjects ships for Elixir. The plugin also binds
`ac`/`ic`, `ae`/`ie`, `]c`/`[c`, and `]e`/`[e` to `@component.*` and `@event.*`
captures; no `textobjects.scm` here defines those, so those bindings are inert
until one does.

## Details

### Component templates

When creating new files in `**/components/**/*.ex`, the plugin replaces the
empty buffer with a `Raxol.UI.Components.Base.Component` skeleton: `init/1`,
`mount/1`, `update/2`, `render/2`, and `handle_event/3`.

### Treesitter queries

`queries/elixir/raxol.scm` holds Raxol-shaped captures for the Elixir parser:
`use Raxol.UI.Components.*` and `use Raxol.UI` calls, the lifecycle callbacks
(`init`, `mount`, `update`, `render`, `handle_event`, `unmount`), `on_*` event
keys, and UI element calls (`button`, `text_input`, `table`, `modal`, `column`,
`row`, `text`).

Neovim loads queries by kind, not by plugin name: it reads
`queries/elixir/highlights.scm`, `textobjects.scm`, `injections.scm`, `locals.scm`,
`folds.scm`, and `indents.scm` off the runtimepath. `raxol.scm` matches none of
those names, so nothing loads it. To use these patterns, copy them into a
`queries/elixir/highlights.scm` starting with `; extends` and give each capture
a highlight group.

## Coding agent

The Raxol coding agent reaches editors over the
[Agent Client Protocol](https://agentclientprotocol.com), which Zed and its
ecosystem speak. Point an ACP client at the `bin/raxol-acp` shim in a raxol
checkout; `mix help raxol.acp` has the Zed `agent_servers` snippet. Turns on
that surface run a read-only toolset: `list_dir`, `read_file`, `file_stat`,
`grep`, `glob`.

Without an ACP client, run the full agent TUI in a terminal split:

```vim
:terminal /path/to/raxol/bin/raxol-code
```

Both entrypoints need a raxol checkout with deps fetched
(`cd packages/raxol_agent && mix deps.get`). See
[`docs/features/CODING_AGENT.md`](../../docs/features/CODING_AGENT.md).

## Requirements

- Neovim >= 0.8.0
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with
  the Elixir parser installed
- `mix` on `PATH`, for the command and keymap wrappers

## Troubleshooting

### Treesitter issues

1. Ensure Elixir parser is installed:

```vim
:TSInstall elixir
```

2. Check treesitter status:

```vim
:TSModuleInfo
```

### Commands do nothing

The commands shell out to `mix`. Run them by hand from the project root to see
the error: `mix raxol.gen.component Foo`, `mix raxol.playground`.

## Contributing

This plugin is part of the [Raxol framework](https://github.com/axol-io/raxol).
Please submit issues and pull requests to the main repository.

## License

MIT License - see the main Raxol project for details.
