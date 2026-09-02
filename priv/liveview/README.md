# LiveView terminal CSS

`terminal.css` is a standalone stylesheet for rendering terminal UIs in a
browser with character-perfect monospace grid alignment. It is self-contained:
no build step, no framework, no imports.

It is not the asset the shipped LiveView integration serves. That one lives in
the raxol_liveview package, at the path `RaxolLiveView.css_path/0` returns:

```elixir
File.cp!(RaxolLiveView.css_path(), "priv/static/css/raxol_terminal.css")
```

`Raxol.LiveView.TerminalComponent` also injects the styles it needs in its own
render function, so an app embedding the component needs no stylesheet link at
all. Use this file only for a custom renderer that paints the same class
vocabulary itself.

```html
<link rel="stylesheet" href="/path/to/terminal.css">
```

## Classes

Required structure, outermost first: `.raxol-terminal-wrapper`,
`.raxol-terminal`, `.raxol-line`, `.raxol-cell`.

Style modifiers on a cell: `.raxol-bold`, `.raxol-italic`,
`.raxol-underline`, `.raxol-reverse`, `.raxol-cursor`.

Modifiers on the wrapper: `.raxol-crt-mode` (scanlines, phosphor glow,
vignette), `.raxol-high-contrast`.

Accessibility helpers: `.raxol-sr-only`, `.raxol-skip-to-content`.

Reduced motion, print styles, and GPU acceleration hints are built in.

## Fonts

Any monospace font works. The only hard requirement is that a character is
exactly `1ch` wide, or the grid loses alignment. The default stack:

```css
font-family: 'Monaspace Argon', 'JetBrains Mono', 'Fira Code',
             'Cascadia Code', 'Consolas', monospace;
```

Theme colors are generated at runtime by `Raxol.LiveView.Themes`, not shipped
as files. Include theme CSS after this base stylesheet.
