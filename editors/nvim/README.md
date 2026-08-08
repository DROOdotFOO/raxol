# Raxol.nvim

Neovim plugin for Raxol development with LSP and treesitter support.

> **Status:** the LSP half of this plugin points at `mix raxol.lsp`, which is
> not shipped yet; LSP features will not start until it exists. Treesitter
> support, snippets, and commands that do not need the server work today.

## Features

- **LSP Integration**: Full Language Server Protocol support with completion, hover, diagnostics
- **Treesitter Support**: Enhanced syntax highlighting and text objects for Raxol components
- **Component Generation**: Built-in commands for generating new components
- **Playground Integration**: Quick access to Raxol component playground
- **Test Runner**: Integrated test runner with proper environment setup
- **Syntax Highlighting**: Raxol-specific patterns and keywords

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'axol-io/raxol',
  dir = '/path/to/raxol/editors/nvim',
  dependencies = {
    'neovim/nvim-lspconfig',
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
    'neovim/nvim-lspconfig',
    'nvim-treesitter/nvim-treesitter',
    'nvim-treesitter/nvim-treesitter-textobjects', -- optional
  },
  ft = { 'elixir', 'eex', 'heex' },
  config = function()
    require('raxol').setup()
  end
}
```

### Manual Installation

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
  lsp = {
    enabled = true,
    cmd = { 'mix', 'raxol.lsp', '--stdio' },
    filetypes = { 'elixir', 'eex', 'heex' },
    root_patterns = { 'mix.exs', '.raxol.exs', '.git' }
  },
  treesitter = {
    enabled = true,
    highlight = true,
    incremental_selection = true,
    textobjects = true
  },
  completion = {
    enabled = true,
    snippet_support = true
  },
  diagnostics = {
    enabled = true,
    virtual_text = true,
    signs = true
  }
})
```

## Commands

- `:RaxolGenerateComponent [name]` - Generate a new Raxol component
- `:RaxolPlayground` - Open the Raxol component playground
- `:RaxolTest` - Run Raxol tests with proper environment
- `:RaxolRestartLSP` - Restart the Raxol LSP server

## Keymaps

Default keymaps (can be customized):

- `<leader>rc` - Generate component
- `<leader>rp` - Open playground
- `<leader>rt` - Run tests
- `<leader>rl` - Restart LSP

### LSP Keymaps (when attached)

- `gD` - Go to declaration
- `gd` - Go to definition
- `K` - Hover documentation
- `gi` - Go to implementation
- `<C-k>` - Signature help
- `<space>rn` - Rename symbol
- `<space>ca` - Code actions
- `gr` - References
- `<space>f` - Format document

### Treesitter Text Objects

- `af`/`if` - Function outer/inner
- `ac`/`ic` - Component outer/inner
- `ae`/`ie` - Event outer/inner

### Navigation

- `]m`/`[m` - Next/previous function
- `]c`/`[c` - Next/previous component
- `]e`/`[e` - Next/previous event

## Features

### Component Templates

When creating new files in `**/components/**/*.ex`, the plugin automatically offers to insert a Raxol component template.

### Syntax Highlighting

Enhanced syntax highlighting for:

- Raxol component definitions
- Lifecycle methods (`init`, `mount`, `update`, `render`, `handle_event`)
- Event handlers (`on_click`, `on_change`, etc.)
- UI elements (`button`, `text_input`, `table`, etc.)

### LSP Features

- **Autocompletion**: Component names, lifecycle methods, props
- **Hover**: Documentation for components and methods
- **Go to Definition**: Navigate to component definitions
- **Diagnostics**: Component validation and error checking
- **Signature Help**: Parameter hints for component functions

## Requirements

- Neovim >= 0.8.0
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- Raxol framework with LSP server (`mix raxol.lsp`)

## Troubleshooting

### LSP Server Not Starting

1. Ensure the Raxol LSP server is available:

```bash
mix raxol.lsp --help
```

2. Check LSP logs:

```vim
:lua vim.lsp.set_log_level("debug")
:LspLog
```

3. Verify project structure has `mix.exs` or `.raxol.exs`

### Treesitter issues

1. Ensure Elixir parser is installed:

```vim
:TSInstall elixir
```

2. Check treesitter status:

```vim
:TSModuleInfo
```

## Contributing

This plugin is part of the [Raxol framework](https://github.com/axol-io/raxol). Please submit issues and pull requests to the main repository.

## License

MIT License - see the main Raxol project for details.
