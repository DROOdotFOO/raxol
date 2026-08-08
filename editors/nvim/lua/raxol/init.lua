local M = {}

-- Default configuration
local default_config = {
  treesitter = {
    enabled = true,
    highlight = true,
    incremental_selection = true,
    textobjects = true
  }
}

-- Setup function
function M.setup(opts)
  opts = vim.tbl_deep_extend('force', default_config, opts or {})

  -- Configure treesitter
  if opts.treesitter.enabled then
    M.setup_treesitter(opts.treesitter)
  end

  -- Setup autocommands and keymaps
  M.setup_autocommands()
  M.setup_keymaps()

  -- Setup user commands
  M.setup_commands()
end

-- Treesitter Configuration
function M.setup_treesitter(ts_opts)
  local status_ok, ts_configs = pcall(require, 'nvim-treesitter.configs')
  if not status_ok then
    vim.notify('nvim-treesitter not found, skipping treesitter setup', vim.log.levels.WARN)
    return
  end

  -- Extend Elixir treesitter for Raxol-specific patterns
  ts_configs.setup({
    highlight = {
      enable = ts_opts.highlight,
      additional_vim_regex_highlighting = { 'elixir' },
      custom_captures = {
        ['raxol.component'] = 'RaxolComponent',
        ['raxol.lifecycle'] = 'RaxolLifecycle',
        ['raxol.event'] = 'RaxolEvent'
      }
    },
    incremental_selection = {
      enable = ts_opts.incremental_selection,
      keymaps = {
        init_selection = 'gnn',
        node_incremental = 'grn',
        scope_incremental = 'grc',
        node_decremental = 'grm'
      }
    },
    textobjects = {
      enable = ts_opts.textobjects,
      select = {
        enable = true,
        lookahead = true,
        keymaps = {
          ['af'] = '@function.outer',
          ['if'] = '@function.inner',
          ['ac'] = '@component.outer',
          ['ic'] = '@component.inner',
          ['ae'] = '@event.outer',
          ['ie'] = '@event.inner'
        }
      },
      move = {
        enable = true,
        set_jumps = true,
        goto_next_start = {
          [']m'] = '@function.outer',
          [']c'] = '@component.outer',
          [']e'] = '@event.outer'
        },
        goto_next_end = {
          [']M'] = '@function.outer',
          [']C'] = '@component.outer',
          [']E'] = '@event.outer'
        },
        goto_previous_start = {
          ['[m'] = '@function.outer',
          ['[c'] = '@component.outer',
          ['[e'] = '@event.outer'
        },
        goto_previous_end = {
          ['[M'] = '@function.outer',
          ['[C'] = '@component.outer',
          ['[E'] = '@event.outer'
        }
      }
    }
  })
end

-- Setup autocommands
function M.setup_autocommands()
  local group = vim.api.nvim_create_augroup('RaxolPlugin', { clear = true })

  -- Auto-detect Raxol projects
  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    group = group,
    pattern = '*.ex',
    callback = function()
      -- Check if this is a Raxol component
      local lines = vim.api.nvim_buf_get_lines(0, 0, 10, false)
      for _, line in ipairs(lines) do
        if line:match('use Raxol%.') then
          vim.bo.filetype = 'elixir'
          vim.b.is_raxol_file = true
          break
        end
      end
    end
  })

  -- Template insertion for new component files
  vim.api.nvim_create_autocmd('BufNewFile', {
    group = group,
    pattern = '**/components/**/*.ex',
    callback = function()
      M.insert_component_template()
    end
  })

  -- Highlight Raxol-specific patterns
  vim.api.nvim_create_autocmd('Syntax', {
    group = group,
    pattern = 'elixir',
    callback = function()
      if vim.b.is_raxol_file then
        M.setup_syntax_highlighting()
      end
    end
  })
end

-- Setup keymaps
function M.setup_keymaps()
  -- Global Raxol keymaps
  vim.keymap.set('n', '<leader>rc', M.generate_component, { desc = 'Generate Raxol component' })
  vim.keymap.set('n', '<leader>rp', M.open_playground, { desc = 'Open Raxol playground' })
  vim.keymap.set('n', '<leader>rt', M.run_tests, { desc = 'Run Raxol tests' })
end

-- Setup user commands
function M.setup_commands()
  vim.api.nvim_create_user_command('RaxolGenerateComponent', function(opts)
    M.generate_component(opts.args)
  end, { nargs = '?', desc = 'Generate a new Raxol component' })

  vim.api.nvim_create_user_command('RaxolPlayground', M.open_playground,
    { desc = 'Open Raxol component playground' })

  vim.api.nvim_create_user_command('RaxolTest', M.run_tests,
    { desc = 'Run Raxol tests' })
end

-- Component template insertion
function M.insert_component_template()
  local filename = vim.fn.expand('%:t:r')
  local component_name = filename:gsub('_(%w)', function(c) return c:upper() end)
  component_name = component_name:sub(1, 1):upper() .. component_name:sub(2)

  local template = {
    'defmodule ' .. component_name .. ' do',
    '  @moduledoc """',
    '  ' .. component_name .. ' component.',
    '  """',
    '',
    '  use Raxol.UI.Components.Base.Component',
    '',
    '  def init(props) do',
    '    Map.merge(%{}, props)',
    '  end',
    '',
    '  def mount(state) do',
    '    {state, []}',
    '  end',
    '',
    '  def update(message, state) do',
    '    # Handle component messages here',
    '    state',
    '  end',
    '',
    '  def render(state, context) do',
    '    # Render component UI here',
    '    text("' .. component_name .. '")',
    '  end',
    '',
    '  def handle_event(event, state, context) do',
    '    # Handle UI events here',
    '    {state, []}',
    '  end',
    'end'
  }

  vim.api.nvim_buf_set_lines(0, 0, -1, false, template)
  -- Position cursor at the render function
  vim.api.nvim_win_set_cursor(0, { 20, 4 })
end

-- Syntax highlighting for Raxol patterns
function M.setup_syntax_highlighting()
  vim.cmd([[
    syntax match RaxolComponent /\<\u\w*\>/ contained
    syntax match RaxolLifecycle /\<\(init\|mount\|update\|render\|handle_event\|unmount\)\>/ contained
    syntax match RaxolEvent /\<on_\w\+\>/ contained

    highlight link RaxolComponent Type
    highlight link RaxolLifecycle Function
    highlight link RaxolEvent Constant
  ]])
end

-- Utility functions
function M.generate_component(name)
  if not name or name == '' then
    name = vim.fn.input('Component name: ')
  end

  if name and name ~= '' then
    vim.cmd('terminal mix raxol.gen.component ' .. name)
  end
end

function M.open_playground()
  vim.cmd('terminal mix raxol.playground')
end

function M.run_tests()
  vim.cmd('terminal SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker')
end

return M
