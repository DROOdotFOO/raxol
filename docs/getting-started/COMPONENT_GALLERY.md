# Component Gallery

All Components are available via the View DSL after `use Raxol.Core.Runtime.Application`. Layout containers (`column`, `row`, `box`) use `do` block syntax. Everything else is a plain function call.

To see them all running: `mix raxol.playground` (interactive demos across all categories).

---

## Layout

Layout Components arrange children on screen. These are the skeleton of every Raxol UI.

### column

Vertical stack. Children are arranged top-to-bottom.

```elixir
column style: %{gap: 1, padding: 1, align_items: :center} do
  [
    text("Header", style: [:bold]),
    divider(),
    text("Body content"),
    spacer(),
    text("Footer", style: [:dim])
  ]
end
```

Style options: `gap`, `padding`, `align_items` (`:start`, `:center`, `:end`, `:stretch`), `flex`, `width`, `height`.

### row

Horizontal stack. Children are arranged left-to-right.

```elixir
row style: %{gap: 2, align_items: :center} do
  [
    text("Status:"),
    text("Online", style: %{fg: :green, bold: true}),
    spacer(),
    button("Refresh", on_click: :refresh)
  ]
end
```

Same style options as `column`. Use `spacer()` to push items apart.

### box

Container with optional border and padding. Good for grouping related content.

```elixir
box style: %{border: :single, padding: 1, width: 40} do
  column style: %{gap: 1} do
    [
      text("User Profile", style: [:bold]),
      text("Name: #{model.name}"),
      text("Email: #{model.email}")
    ]
  end
end
```

Border styles: `:single`, `:double`, `:rounded`, `:bold`, `:ascii`.

### spacer

Flexible space that fills available room. Useful for pushing items to opposite ends of a row or column.

```elixir
row do
  [text("Left"), spacer(), text("Right")]
end
```

Options: `size` (integer, default 1), `direction` (`:vertical` or `:horizontal`).

### divider

Horizontal line separator.

```elixir
column do
  [text("Section A"), divider(), text("Section B")]
end
```

Options: `char` (string, default `"-"`), `style`.

### split_pane

Resizable split layout with two panes.

```elixir
split_pane(
  direction: :horizontal,
  ratio: {1, 2},
  min_size: 10,
  children: [left_panel, right_panel]
)
```

Options: `direction` (`:horizontal` or `:vertical`), `ratio` (tuple, default `{1, 1}`), `min_size` (integer, default 5).

---

## Text & Display

Components for showing information to the user. These are all display-only -- no user interaction.

### text

Styled text content. The most basic Component.

```elixir
# Style atoms
text("Bold text", style: [:bold])
text("Dimmed", style: [:dim])
text("Warning", style: [:bold, :underline])

# Color via style map
text("Error", style: %{fg: :red, bold: true})
text("Success", style: %{fg: :green, bg: :black})

# fg/bg also work as keyword opts
text("Custom", fg: :cyan, bg: :blue)
```

Style atoms: `:bold`, `:dim`, `:italic`, `:underline`, `:strikethrough`, `:reverse`.

Colors: `:black`, `:red`, `:green`, `:yellow`, `:blue`, `:magenta`, `:cyan`, `:white`, plus RGB tuples `{r, g, b}` and hex strings `"#ff6600"`. Auto-downsampled to whatever the terminal supports.

### label

Alias for text with an explicit `content` key.

```elixir
label(content: "Field name:", style: %{bold: true})
```

### progress

Progress bar indicator.

```elixir
progress(value: 65, max: 100)
```

The underlying component module (`Raxol.UI.Components.Display.Progress`) supports more options when used directly: `show_percentage`, `label`, `animated`, `width`.

### list

Render a list of items, with optional selection highlighting.

```elixir
list(items: ["Elixir", "Rust", "Go", "Zig"])
list(items: model.todos, selected: model.selected_index)
```

### table

Tabular data display with headers.

```elixir
table(
  headers: ["Name", "Role", "Status"],
  rows: [
    ["Alice", "Admin", "Active"],
    ["Bob", "User", "Idle"],
    ["Carol", "User", "Active"]
  ]
)
```

The component module (`Raxol.UI.Components.Display.Table`) supports much more when used directly: `column_widths` (`:auto` or explicit list), `border_style`, `sortable`, `filterable`, `selectable`, `striped`, `alignments`. Handles keyboard navigation for row selection.

### tree

Hierarchical tree view with expand/collapse. Component module only -- not available as a View DSL function.

```elixir
alias Raxol.UI.Components.Display.Tree

nodes = [
  %{id: "src", label: "src/", children: [
    %{id: "lib", label: "lib/", children: [
      %{id: "app", label: "app.ex", children: []}
    ]},
    %{id: "test", label: "test/", children: []}
  ]}
]

# In init/1:
{:ok, tree_state} = Tree.init(%{id: "file_tree", nodes: nodes})

# In view/1 (render the tree state):
Tree.render(model.tree_state, context)
```

Keyboard: Up/Down (navigate), Right (expand), Left (collapse/go to parent), Enter/Space (select), Home/End (jump).

Options: `indent_size`, `on_select`, `on_expand`, `on_collapse`.

### viewport

Scrollable container for content larger than the visible area. Component module only.

```elixir
alias Raxol.UI.Components.Display.Viewport

{:ok, vp} = Viewport.init(%{
  id: "log_view",
  children: log_lines,
  visible_height: 20,
  show_scrollbar: true
})

# Scroll programmatically:
vp = Viewport.update({:scroll_by, 5}, vp)
vp = Viewport.update({:scroll_to, 0}, vp)
```

### status_bar

Fixed status bar for key-value display. Component module only.

```elixir
alias Raxol.UI.Components.Display.StatusBar

{:ok, bar} = StatusBar.init(%{
  id: "status",
  items: [
    %{key: "branch", label: "main"},
    %{key: "tests", label: "5484 passing"},
    %{key: "mode", label: "INSERT"}
  ],
  separator: " | "
})
```

### code_block

Syntax-highlighted code display. Uses Makeup for Elixir highlighting, falls back to plain text for other languages. Component module only.

```elixir
alias Raxol.UI.Components.CodeBlock

{:ok, block} = CodeBlock.init(%{
  content: ~s|defmodule Hello do\n  def world, do: :ok\nend|,
  language: "elixir"
})
```

### markdown_renderer

Renders markdown text with terminal formatting. Supports headings, bold, italic, inline code, lists, and blockquotes. Component module only.

```elixir
alias Raxol.UI.Components.MarkdownRenderer

{:ok, md} = MarkdownRenderer.init(%{
  markdown_text: "# Hello\n\nThis is **bold** and *italic*.\n\n- Item one\n- Item two",
  width: 60
})
```

Uses EarmarkParser when available, falls back to regex-based parsing.

### image

Inline terminal image display. Supports Kitty, iTerm2, and Sixel protocols.

```elixir
image(src: "logo.png", width: 30, height: 15)
image(src: raw_png_binary, protocol: :kitty, preserve_aspect: true)
```

Options: `protocol` (`:kitty`, `:iterm2`, `:sixel` -- auto-detected if omitted), `preserve_aspect` (default true).

---

## Input

Components that accept user interaction. These handle keyboard events and fire callbacks.

### button

Clickable button that sends a message to `update/2` on press.

```elixir
button("Save", on_click: :save)
button("Delete", on_click: {:delete, item.id})
```

The component module (`Raxol.UI.Components.Input.Button`) supports: `role` (`:primary`, `:secondary`, `:danger`, `:success`), `disabled`, `shortcut`, `tooltip`.

Keyboard: Enter or Space to activate.

### text_input

Single-line text input field.

```elixir
text_input(value: model.name, placeholder: "Enter name...")
```

The component module (`Raxol.UI.Components.Input.TextInput`) supports: `on_change`, `on_submit`, `on_cancel`, `mask_char` (for passwords), `max_length`, `validator` (function).

### textarea

Multi-line text area.

```elixir
textarea(
  value: model.notes,
  placeholder: "Write something...",
  rows: 8
)
```

For the full-featured editor with undo/redo, selection, and text wrapping, use the `MultiLineInput` component module directly.

### checkbox

Toggle checkbox.

```elixir
checkbox(checked: model.agreed, label: "I agree to the terms")
```

The component module (`Raxol.UI.Components.Input.Checkbox`) supports: `on_toggle`, `disabled`, `required`, `tooltip`.

Keyboard: Space or Enter to toggle.

### radio_group

Radio button group for single selection from a set of options.

```elixir
radio_group(
  options: ["Small", "Medium", "Large"],
  selected: model.size
)
```

Options: `on_change`.

### select / select_list

Dropdown selection. The DSL `select/1` creates a simple dropdown. The component module (`Raxol.UI.Components.Input.SelectList`) is a full-featured scrollable list with search, pagination, and multi-select.

```elixir
# Simple DSL dropdown
select(
  options: ["Elixir", "Rust", "Go"],
  selected: model.language,
  placeholder: "Pick a language..."
)
```

```elixir
# Full component with search and multi-select
alias Raxol.UI.Components.Input.SelectList

{:ok, sl} = SelectList.init(%{
  id: "lang_picker",
  options: [{"Elixir", :elixir}, {"Rust", :rust}, {"Go", :go}],
  enable_search: true,
  multiple: true,
  max_height: 10,
  on_select: :language_selected
})
```

Keyboard: Up/Down (navigate), Enter (select), PageUp/PageDown, Home/End, type to search.

### tabs

Tab navigation bar.

```elixir
tabs(tabs: ["Overview", "Details", "Settings"], active: model.active_tab)
```

The component module (`Raxol.UI.Components.Input.Tabs`) supports: `on_change`, keyboard Left/Right (with wrap), Home/End, 1-9 (direct select).

### menu

Nested dropdown/context menu with submenus. Component module only.

```elixir
alias Raxol.UI.Components.Input.Menu

items = [
  %{id: :file, label: "File", children: [
    %{id: :new, label: "New", shortcut: "Ctrl+N"},
    %{id: :open, label: "Open", shortcut: "Ctrl+O"},
    %{id: :save, label: "Save", shortcut: "Ctrl+S", disabled: true}
  ]},
  %{id: :edit, label: "Edit", children: [
    %{id: :undo, label: "Undo", shortcut: "Ctrl+Z"},
    %{id: :redo, label: "Redo", shortcut: "Ctrl+Y"}
  ]}
]

{:ok, menu} = Menu.init(%{id: "main_menu", items: items, on_select: :menu_action})
```

Keyboard: Up/Down (skip disabled items), Right (open submenu), Left (close submenu), Enter (select), Escape (close).

### multi_line_input

Full text editor with undo/redo, selection, and word wrapping. Component module only.

```elixir
alias Raxol.UI.Components.Input.MultiLineInput

{:ok, editor} = MultiLineInput.init(%{
  id: "code_editor",
  value: "defmodule Hello do\n  def world, do: :ok\nend",
  width: 60,
  height: 20,
  wrap: :word
})
```

Options: `wrap` (`:none`, `:char`, `:word`), `on_change`, `on_submit`.

Features: cursor movement, shift-select, undo/redo history, line wrapping.

---

## Overlay

Components that float above the main content.

### modal

Modal dialog that overlays the current view.

```elixir
# Simple alert
modal(visible: model.show_confirm, title: "Confirm", content: text("Delete this item?"))
```

The component module (`Raxol.UI.Components.Modal`) supports multiple types:

```elixir
alias Raxol.UI.Components.Modal

# Alert with buttons
{:ok, m} = Modal.init(%{
  id: "confirm",
  type: :alert,
  title: "Delete Item",
  content: "This cannot be undone.",
  buttons: [
    %{label: "Cancel", action: :cancel},
    %{label: "Delete", action: :delete}
  ]
})

# Prompt with input
{:ok, m} = Modal.init(%{
  id: "rename",
  type: :prompt,
  title: "Rename",
  input_value: model.current_name
})

# Form with validation
{:ok, m} = Modal.init(%{
  id: "settings",
  type: :form,
  title: "Settings",
  fields: [%{name: "timeout", label: "Timeout (ms)"}],
  validate: &validate_settings/1
})
```

---

## Progress Indicators

Show how far along something is, or that work is happening.

### progress (DSL)

Standard horizontal progress bar. This is the DSL entry point.

```elixir
progress(value: 65, max: 100)
```

### Progress.Bar, Progress.Spinner, Progress.Circular

Component modules for more control. Not separate DSL functions.

```elixir
# Animated bar with percentage label
alias Raxol.UI.Components.Display.Progress

{:ok, bar} = Progress.init(%{
  id: "upload",
  progress: 0.65,
  width: 40,
  show_percentage: true,
  label: "Uploading...",
  animated: true
})
```

```elixir
# Spinner (stateless utility -- call each frame)
alias Raxol.UI.Components.Progress.Spinner

# Available styles: :dots, :line, :circle, :arrow, :bounce,
#                   :pulse, :wave, :dots3, :square, :flip
frame = Spinner.spinner(:tick, 0, style: :dots, text: "Loading...")
```

| Module              | Use case                                                  |
| ------------------- | --------------------------------------------------------- |
| `Progress.Bar`      | Determinate progress with known completion                |
| `Progress.Spinner`  | Indeterminate -- something is happening, unknown duration |
| `Progress.Circular` | Circular/ring-style progress indicator                    |

---

## Charts

Streaming data visualization. All chart functions render braille or block characters and compose naturally in `view/1`.

### sparkline

Minimal inline chart -- a line with no axes or legend.

```elixir
sparkline(data: model.cpu_history, width: 30, height: 3, color: :green)
```

### line_chart

Braille line chart with multi-series support.

```elixir
line_chart(
  series: [
    %{name: "CPU", data: model.cpu_history, color: :cyan},
    %{name: "Memory", data: model.mem_history, color: :magenta}
  ],
  width: 60,
  height: 15,
  show_axes: true,
  show_legend: true
)
```

### bar_chart

Block-character bar chart. Vertical or horizontal, grouped multi-series.

```elixir
bar_chart(
  series: [
    %{name: "Q1", data: [42, 67, 55], color: :blue},
    %{name: "Q2", data: [50, 72, 61], color: :green}
  ],
  width: 50,
  height: 12,
  orientation: :vertical,
  show_values: true,
  show_legend: true
)
```

Options: `bar_gap` (gap within group), `group_gap` (gap between groups).

### scatter_chart

Braille 2D scatter plot.

```elixir
scatter_chart(
  series: [
    %{name: "Cluster A", data: [{1.2, 3.4}, {2.1, 4.5}, {1.8, 3.9}], color: :cyan},
    %{name: "Cluster B", data: [{5.0, 1.2}, {4.8, 1.5}, {5.3, 0.9}], color: :yellow}
  ],
  width: 50,
  height: 15,
  show_axes: true,
  x_range: {0, 7},
  y_range: {0, 6}
)
```

### heatmap

2D grid with color intensity.

```elixir
heatmap(
  data: [
    [0.1, 0.4, 0.9, 0.6],
    [0.3, 0.8, 0.5, 0.2],
    [0.7, 0.2, 0.3, 0.8]
  ],
  width: 40,
  height: 6,
  color_scale: :warm,
  show_values: true
)
```

Color scales: `:warm` (yellow -> red), `:cool` (cyan -> blue), `:diverging` (blue -> white -> red), or a custom `fn(value, min, max) -> {r, g, b}`.

---

## Advanced

### process_component

Run any component in its own supervised process for crash isolation. If it crashes, it restarts automatically without affecting the rest of the app.

```elixir
# In your view:
process_component(MyExpensiveComponent, %{path: "/var/log"})
```

### focus_ring

Visual focus indicator for accessibility. Highlights the currently focused component.

Component module: `Raxol.UI.Components.FocusRing`

Options: `color`, `width`, `offset`, `style` (`:solid`), `components` (list of component IDs to track).

---

## Using Components Directly

The View DSL functions cover most needs. When you need full control -- handling events, managing component state, accessing all options -- use the component modules directly:

```elixir
alias Raxol.UI.Components.Input.TextInput

# Initialize with full options
{:ok, state} = TextInput.init(%{
  id: "search",
  value: "",
  placeholder: "Search...",
  max_length: 100,
  on_submit: :do_search
})

# Handle an event
state = TextInput.handle_event(event, state, context)

# Render
rendered = TextInput.render(state, context)
```

All component modules follow the same pattern: `init/1` -> `handle_event/3` -> `render/2`.

---

## Quick Reference

| Component     | DSL function      | Module path            | Interactive? |
| ------------- | ----------------- | ---------------------- | ------------ |
| column        | `column do`       | --                     | No           |
| row           | `row do`          | --                     | No           |
| box           | `box do`          | --                     | No           |
| spacer        | `spacer/1`        | --                     | No           |
| divider       | `divider/1`       | --                     | No           |
| split_pane    | `split_pane/1`    | `UI.Layout.SplitPane`  | No           |
| text          | `text/1`          | --                     | No           |
| label         | `label/1`         | --                     | No           |
| list          | `list/1`          | --                     | No           |
| progress      | `progress/1`      | `Display.Progress`     | No           |
| table         | `table/1`         | `Display.Table`        | Yes          |
| tree          | --                | `Display.Tree`         | Yes          |
| viewport      | --                | `Display.Viewport`     | Yes          |
| status_bar    | --                | `Display.StatusBar`    | No           |
| code_block    | --                | `CodeBlock`            | No           |
| markdown      | --                | `MarkdownRenderer`     | No           |
| image         | `image/1`         | --                     | No           |
| button        | `button/1`        | `Input.Button`         | Yes          |
| text_input    | `text_input/1`    | `Input.TextInput`      | Yes          |
| textarea      | `textarea/1`      | `Input.MultiLineInput` | Yes          |
| checkbox      | `checkbox/1`      | `Input.Checkbox`       | Yes          |
| radio_group   | `radio_group/1`   | --                     | Yes          |
| select        | `select/1`        | `Input.SelectList`     | Yes          |
| tabs          | `tabs/1`          | `Input.Tabs`           | Yes          |
| menu          | --                | `Input.Menu`           | Yes          |
| modal         | `modal/1`         | `Modal`                | Yes          |
| sparkline     | `sparkline/1`     | --                     | No           |
| line_chart    | `line_chart/1`    | --                     | No           |
| bar_chart     | `bar_chart/1`     | --                     | No           |
| scatter_chart | `scatter_chart/1` | --                     | No           |
| heatmap       | `heatmap/1`       | --                     | No           |
| spinner       | --                | `Progress.Spinner`     | No           |
| focus_ring    | --                | `FocusRing`            | No           |

All component module paths are under `Raxol.UI.Components.*`.

---

## Running Examples

```bash
# Interactive playground with all demos
mix raxol.playground

# Flagship demo (dashboard, sparklines, live stats)
mix run examples/demo.exs

# Simple starting point
mix run examples/getting_started/counter.exs

# Full Component showcase
mix run examples/apps/showcase_app.exs
```
