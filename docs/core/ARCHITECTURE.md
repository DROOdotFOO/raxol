# Architecture

How Raxol works, from application model to terminal output.

## The Big Picture

```elixir
Your App (TEA)          Raxol (Framework)           Rendering Targets
┌─────────────┐    ┌───────────────────────┐    ┌─────────────┐
│ init/1      │    │ Lifecycle (GenServer) │    │ termbox2 NIF│
│ update/2    │───>│ Rendering Engine      │───>│ IOTerminal  │
│ view/1      │    │ Layout Engine         │    │ LiveView    │
│ subscribe/1 │    │ Event Dispatcher      │    │ SSH         │
│             │    │ MCP Tool Deriver      │───>│ MCP (tools) │
└─────────────┘    └───────────────────────┘    └─────────────┘
```

Your app provides pure functions. Raxol manages the runtime loop, layout, rendering, and I/O. You never write ANSI escape codes.

## Application Model: TEA

Every Raxol app implements The Elm Architecture:

```elixir
use Raxol.Core.Runtime.Application

def init(context) -> model                    # Initial state
def update(message, model) -> {model, cmds}   # State transitions
def view(model) -> view_tree                  # Declarative UI
def subscribe(model) -> [subscription]        # External events
```

The runtime calls `view(model)` after every `update`, diffs the resulting Element tree against the previous one, and renders only what changed. Same diffing idea as React's virtual DOM, but the Element tree describes terminal cells, not HTML nodes.

## Layer Stack

### 1. View DSL -> Element Tree

The `view/1` callback uses macros to build a tree of plain maps:

```elixir
column style: %{padding: 1} do
  [
    text("Hello", fg: :cyan),
    row do
      [button("+", on_click: :inc), button("-", on_click: :dec)]
    end
  ]
end
```

Produces: `%{type: :column, children: [%{type: :text, ...}, %{type: :row, ...}], ...}`

### 2. Preparer -> Measured Element Tree

`Raxol.UI.Layout.Preparer` walks the element tree and pre-measures all text nodes via `Raxol.UI.TextMeasure`, producing a `PreparedElement` tree with cached display widths. This is the "prepare" phase of a two-phase prepare/layout architecture (inspired by [Pretext](https://github.com/nicklockwood/Pretext)):

- Text measurement handles CJK double-width characters, fullwidth symbols, and combining characters correctly via `Raxol.Terminal.CharacterHandling`
- On terminal resize, only the layout phase re-runs -- text measurements are cached and reused when content hasn't changed
- `prepare_incremental/2` compares content hashes to skip re-measurement of unchanged nodes
- `PreparedElement` also carries `animation_hints` -- declarative metadata attached via `Raxol.Animation.Helpers.animate/2` in `view/1`. These hints flow through to backends untouched; the Preparer just preserves them alongside measurements

### 3. Layout Engine -> Positioned Elements

`Raxol.UI.Layout.Engine` takes the element tree and computes `{x, y, width, height}` for every node. Uses cached measurements from the Preparer when available. Supports:

- **Flexbox**: `row`/`column` with `flex`, `gap`, `align_items`, `justify_content`
- **CSS Grid**: `grid` with `template_columns`, `template_rows`
- **Box model**: `padding`, `border`, `margin`, `width`, `height`

### 4. Composer -> Cell Grid

`Raxol.UI.Rendering.Composer` walks the positioned tree and produces cell tuples:

```elixir
{x, y, char, fg_color, bg_color, attrs}
```

Each cell is one character at one position with its styling. Cell x-positions account for character display width -- CJK characters advance x by 2, not 1.

### 5. Screen Buffer -> Diff

`Raxol.Terminal.ScreenBuffer` holds the current and previous frame. Only changed cells produce output.

### 6. Terminal Backend -> Output

Platform-detected backend writes ANSI escape sequences:

- **Unix/macOS**: Native C NIF via termbox2 (`lib/termbox2_nif/c_src/`)
- **Windows**: Pure Elixir `IOTerminal` using `IO.write/1`
- **Browser**: LiveView bridge via PubSub (`Raxol.LiveView.TEALive` in `raxol_liveview` package). When positioned elements carry animation hints, `TerminalBridge.animation_css/1` emits CSS `transition` rules targeting `data-raxol-id` selectors, plus a `prefers-reduced-motion` media query. The browser handles interpolation client-side instead of re-rendering every frame from the server.
- **SSH**: Erlang `:ssh` module (`Raxol.SSH.Server`)
- **Telegram**: Buffer-to-plaintext via an `io_writer` callback (`Raxol.Core.Runtime.Rendering.Backends.render_to_telegram/2`)
- **MCP**: Tool/resource derivation from Component tree (`Raxol.MCP.Server`, see ADR-0012). `StructuredScreenshot` includes animation hints in JSON Component summaries so agents can reason about animated state.

### MCP as Rendering Target (ADR-0012)

MCP is a first-class rendering target alongside terminal, LiveView, and SSH. Instead of rendering pixels, it renders capabilities: tools and resources derived from the Component tree.

```
view(model) -> Component tree -> ToolProvider per Component -> MCP tool set
                              -> app projections            -> MCP resources
```

Each Component type implements `Raxol.MCP.ToolProvider`, mapping its state to MCP tools (e.g., TextInput -> type_into/clear/get_value, Table -> sort/filter/select_row). A focus lens filters to ~10 relevant tools per interaction. The context tree assembles model, Components, agents, swarm topology, and notifications into browsable MCP resources.

This means every Raxol app is AI-controllable with zero glue code. Package: `raxol_mcp` (depends on `raxol_core`). See `docs/adr/0012-mcp-as-rendering-target.md` for full details.

## Event Flow

```
Terminal Input
  -> Driver (raw bytes -> Event struct)
  -> Dispatcher (GenServer)
  -> Capture phase (root -> target, W3C-style)
  -> Target handlers (on_click, on_change)
  -> Bubble phase (target -> root)
  -> Component handle_event/3
  -> App update/2
```

Events bubble through the view tree. Any handler can return `:stop` to halt propagation or `:passthrough` to continue. Unhandled events reach `update/2`.

## OTP Architecture

Every Raxol app runs as a supervision tree:

```
Application Supervisor
├── Lifecycle (GenServer) -- owns the TEA loop
├── Dispatcher (GenServer) -- event routing
├── FocusManager (GenServer) -- tab order, focus state
├── Rendering.Engine -- view -> layout -> render -> output
├── ThemeManager -- ETS-backed theme registry
├── I18nServer -- ETS-backed translations
└── [ProcessComponent supervisors] -- optional per-Component processes
```

### Process-Per-Component (Optional)

Any Component can run in its own process via `process_component/2`:

```elixir
process_component(ExpensiveChart, data: sensor_feed)
```

The component gets its own GenServer under a DynamicSupervisor. If it crashes, it restarts without affecting the rest of the UI. State is preserved in ETS across restarts.

### Hot Code Reload (Dev Only)

`Raxol.Dev.CodeReloader` watches `.ex` files via FileSystem, debounces changes, recompiles, and sends `:render_needed` to the Lifecycle. Your app updates in-place without restart.

## Performance Design

- **Two-phase rendering**: Text measurement (expensive, Unicode-aware) is cached separately from layout (cheap arithmetic). On resize, only layout re-runs.
- **Buffer diff**: Only changed cells are written. ~2ms for 80x24.
- **ETS for reads**: Theme, i18n, config, and metrics use ETS tables. Reads bypass GenServer serialization entirely.
- **Synchronized output**: Uses DEC mode 2026 (`\e[?2026h`) to batch terminal writes, preventing flicker.
- **Damage tracking**: `DamageTracker` computes rectangular dirty regions. `RenderBatcher` coalesces rapid updates into single frames at 60fps.
- **Color downsampling**: `Raxol.Style.Colors.Adaptive` detects terminal capabilities and maps 24-bit colors to 256 or 16 colors automatically.
- **Lazy scroll content**: `ScrollContent` behaviour enables cursor-based streaming for large datasets in `Viewport` -- only the visible slice is materialized.

## Terminal Compatibility

- **Unicode width**: `TextMeasure` delegates to `CharacterHandling` for correct CJK double-width, combining characters, fullwidth symbols, and emoji width calculation across layout, rendering, and text wrapping
- **Border fallback**: Box drawing uses ASCII (`+-|`) when Unicode isn't supported
- **Color detection**: `COLORTERM`, `TERM`, capability queries for truecolor/256/16/mono

## Key Modules

| Module                                 | Role                                |
| -------------------------------------- | ----------------------------------- |
| `Raxol.Core.Runtime.Lifecycle`         | TEA loop GenServer                  |
| `Raxol.Core.Runtime.Events.Dispatcher` | Event routing + bubbling            |
| `Raxol.Core.Runtime.Rendering.Engine`  | view -> prepare -> layout -> render |
| `Raxol.UI.TextMeasure`                 | Unicode display width (facade)      |
| `Raxol.UI.Layout.Preparer`            | Pre-measure text, cache widths      |
| `Raxol.UI.Layout.Engine`               | Flexbox/Grid layout computation     |
| `Raxol.UI.Layout.ScrollContent`       | Cursor-based lazy scroll behaviour  |
| `Raxol.UI.Rendering.Composer`          | Element tree -> cell grid           |
| `Raxol.Terminal.ScreenBuffer`          | Double-buffered cell storage        |
| `Raxol.Terminal.CharacterHandling`     | CJK/Unicode width (wcwidth)         |
| `Raxol.Terminal.Renderer`              | Cell grid -> ANSI string            |
| `Raxol.Terminal.Driver`                | Platform backend selection          |
| `Raxol.Core.Renderer.View`             | View DSL macros                     |
| `Raxol.Animation.Helpers`              | `animate/2`, `stagger/2`, `sequence/2` for view hints |
| `Raxol.Animation.Hint`                 | Hint struct, CSS property/timing mapping |

## References

- [Buffer API](./BUFFER_API.md)
- [Quickstart Guide](../getting-started/QUICKSTART.md)
- [Component Gallery](../getting-started/COMPONENT_GALLERY.md)
- [Theming Cookbook](../cookbook/THEMING.md)
