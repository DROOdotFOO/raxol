# Yazi — Aesthetic Dossier

> **Category:** modern pastel / graphics-forward terminal file manager
> **Repo:** https://github.com/sxyazi/yazi · **Docs:** https://yazi-rs.github.io
> **Author:** sxyazi (Rust, async I/O) · **Name:** *yazi* = "duck" (Chinese 鸭子)
> **One-line:** A native-feeling GUI file manager that broke *into* the terminal — real pixels in the grid, a flat Material-adjacent pastel palette, Nerd-Font iconography, and a Miller-column spatial layout.

---

## 0. The thesis: what makes Yazi FEEL different

Most TUI file managers (ranger, nnn, lf, vifm) accept the grid's poverty: they are glyph-only, monochrome-ish, box-drawn, text-first. Yazi rejects the premise. It treats the terminal as a **framebuffer that happens to also hold text**, and its entire aesthetic is organized around one move: *put real images inside the character cells.* Everything else — the flat pastel coloring, the Material-Design icon hexes, the rounded soft duckling mascot, the async non-blocking swap-in of content — exists to make the terminal read as a **modern native desktop app** (think macOS Finder / VS Code sidebar) rather than a 1990s console tool. The sibling it most resembles in ambition is a GUI file manager; the sibling it displaces is ranger.

**Vibe in five words:** flat, pastel, graphics-forward, snappy, native-modern.

---

## 1. Layout & spatial rhythm — the Miller columns

**Technique:** Three vertical panes at ratio `[1, 4, 3]` (`yazi-config/preset/yazi-default.toml`: `ratio = [1, 4, 3]`) — a narrow **parent** column on the left, a dominant **current** column in the middle, a wide **preview** column on the right.

**Effect:** Left-to-right = up-and-down the filesystem tree. Your eye reads the hierarchy as a *physical corridor*: where you came from (left), where you are (center, widest = the focus of attention), what's inside the thing you're pointing at (right). This is the **Miller-column** idiom lifted straight from macOS Finder's column view, and porting it to the terminal is the single biggest reason Yazi "feels native." The 1:4:3 weighting is doing real perceptual work — the parent is a thin memory-jog, the current pane owns the visual center of mass, and the preview is nearly as wide as the current pane so images/code get room to be legible.

**Describe the screen:** A thin gray hairline `│` (`border_symbol = "│"`, `border_style = { fg = "gray" }`) rules between each column — *no boxes, no corners, no double lines.* The panes float in shared whitespace, separated only by these light vertical rules. The result is airy and un-boxed; the density comes from the file rows themselves, not from chrome.

---

## 2. The pixel leap — graphics-protocol previews

**Technique:** The preview pane renders **actual raster images** via whichever terminal graphics protocol is available, auto-detected per emulator (`yazi-adapter/src/drivers/`: `kgp.rs` Kitty unicode placeholders, `kgp_old.rs` Konsole, `iip.rs` iTerm2/WezTerm inline images, `sixel.rs` Sixel for foot/Windows Terminal/Ghostty-via-sixel, `chafa.rs` + `ueberzug.rs` as universal fallbacks). Emulator identity is sniffed in `yazi-emulator/src/brand.rs` (Kitty, Konsole, iTerm2, WezTerm, Foot, Ghostty via `$TERM`, `$TERM_PROGRAM`, and env vars like `KITTY_WINDOW_ID`, `GHOSTTY_RESOURCES_DIR`).

**Effect:** A photograph appears as a *photograph.* A video shows a real decoded frame. A PDF shows the rendered page. This is the aesthetic leap that no glyph-only manager can match — and it reframes the whole app. Once the preview pane can hold pixels, the character-grid columns beside it stop reading as "a terminal" and start reading as "the sidebar of a media app." The `Adapter` even tracks image `collision` and erases overlapping regions on redraw (`adapter.rs`: `ClearInventory`, `image_erase`) so the pixels behave like first-class widgets, not escape-sequence graffiti.

**Contrast with siblings:** ranger/nnn fall back to ASCII-art or nothing; Yazi's default *is* the image. The built-in image decoding + preloading (README: "Built-in Code Highlighting and Image Decoding … greatly accelerates image and normal file loading") means the pixels arrive fast enough to feel like scrolling a native gallery.

---

## 3. Color system — flat, semantic, Material-adjacent

Yazi ships two auto-selected presets — `theme-dark.toml` / `theme-light.toml` — chosen by **querying the terminal's background color** at startup (docs: "automatically detects terminal background color to select appropriate defaults"). No gradients anywhere; every color is a **flat hue mapped to a meaning.**

### 3a. Filetype coloring (the calm rainbow)
`[filetype].rules` maps MIME/URL patterns to a single fg hue:

| Filetype | Color | Feeling |
|---|---|---|
| `image/*` | yellow | warm, "look-at-me media" |
| `audio,video/*` | magenta | playful, media-second-tier |
| archives (`zip,rar,7z,tar,…`) | red | "sealed / compressed / caution" |
| documents (`pdf,doc,rtf`) | cyan | cool, textual |
| directories (fallback `*/`) | blue | structural, navigable |
| executables (`is = exec`) | green | "go / runnable" |
| orphan/dummy | **red background** | alarm — a broken symlink literally flashes red |

**Effect:** You read filetype by *color before you read the name.* The palette is deliberately flat and low-saturation-per-cell (16-color names like `yellow`/`cyan`/`blue` resolve to the user's terminal palette, so it inherits the user's chosen scheme and stays coherent). The one loud move — `bg = "red"` on orphan/dummy files — is a personality beat: brokenness is the only thing allowed to shout.

### 3b. Nerd-Font icon hexes = Material Design
The `[icon]` table (900+ entries) assigns each filename/extension an icon glyph **and a truecolor hex**, and those hexes are unmistakably the **Material Design palette**: `.config` = `#ff9800` (Material Orange 500), dirs = `#00bcd4`/`#03a9f4` (Cyan/Light-Blue 500), dummy = `#f44336` (Red 500), `.git` = `#00bcd4`. Language icons use brand-accurate colors — Rust `#dea584`, Go `#00add8`, Prettier `#4285f4`, Svelte `#ff3e00`, Python `#ffbc03`.

**Effect:** This is the deep reason Yazi feels "modern app" and not "terminal." The icon colors are the exact flat pastels of a 2016-era Material/Fluent UI. Sitting in a monospace grid, they import the visual language of a graphical desktop wholesale.

---

## 4. Iconography & density — Nerd Fonts as typographic substitute

**Technique:** Every row is composed (`yazi-plugin/preset/components/entity.lua`) as `padding · icon · prefix · highlights(name) · found · symlink`. The icon comes from `th.icon:match(file)` — a Nerd-Font glyph plus its hex color — followed by a space, then the name. Conditional icons in `[icon].conds` cover file *kinds*: `dir` = `` (`#03a9f4`), `dir & hovered` = an *open-folder* glyph `` (the folder opens under your cursor), `exec` = `` green, `link` = `` gray, `orphan` = `` white, block/char/fifo/sock = `` lime `#cddc39`.

**Effect on density perception:** The leading icon+space gives every row a consistent left rail of color and shape. This makes a directory listing read as **denser and more textured** than a plain-text list — the eye gets a shape-cue and a color-cue per line before any text. The **open-folder-on-hover** swap is a micro-interaction: the folder you're pointing at visibly *opens*, a tiny native-app affordance that glyph-only managers never bother with.

**Typography substitutes (no font control in a terminal):**
- **bold** = active/selected weight (mode badge, tab active, find keyword)
- **italic** = "this is a pointer/derived thing" — `symlink_target = { italic = true }`, find_position italic
- **reversed (inverted fg/bg)** = the hover cursor and selected buttons (see §5)
- **underline** = search emphasis and the preview-pane focus indicator (`indicator.preview = { underline = true }`)
- **UPPERCASE** = the modal state badge (NORMAL → `NOR`, SELECT → `SEL`)

---

## 5. The hover cursor & selection — reversed-video as "solid bar"

**Technique:** `[indicator] parent = { reversed = true }`, `current = { reversed = true }`. The hovered row inverts its foreground and background, painting a **solid colored bar** across the row.

**Effect:** This is the tactile heartbeat of the UI. Instead of a `>` marker or a colored `fg`, the whole line becomes a filled block — exactly how a native OS list highlights the selected row. Combined with the open-folder icon swap, the cursor feels like a physical highlight sliding over items, not a text caret. The parent column's own hovered item is *also* reversed, so as you move, the parent shows a synchronized bar tracking which child directory you're inside — reinforcing the spatial "you are here" corridor.

**Selection markers** (`[mgr]`): a thin `marker_symbol = "│"` painted at the row's left edge in a bright pastel — `marker_selected` lightyellow, `marker_copied` lightgreen, `marker_cut` lightred, `marker_marked` lightcyan (each sets *both* fg and bg to the same bright color, making a solid 1-cell color chip). **Effect:** multi-selection reads as a **colored gutter stripe** down the left of chosen rows — calm, unobtrusive, but unmistakable; cut vs copy vs select are distinguished purely by hue.

---

## 6. The status bar — Vim-modal powerline

**Technique** (`yazi-plugin/preset/components/status.lua` + `[status]`/`[mode]` theme keys): a powerline-style bar. Left segment order = **mode badge · size · name**; right = **permissions · percent · position.**

- **Mode badge:** `tostring(mode):sub(1,3):upper()` → `NOR` / `SEL` / `UNS`, wrapped in ` `-padding, painted as a reversed solid block, flanked by powerline separator glyphs (`status.sep_left.open`/`.close`). Color shifts by mode: **normal = blue bg bold**, **select = red bg bold**, **unset = red bg**. The badge's separator arrow inherits the badge bg on one side and the "alt" bg on the other, producing the seamless powerline chevron.
- **Permissions:** rendered *character-by-character* with per-glyph color (`Status:perm()`): type = green, `r` = yellow, `w` = red, `x/s/t` = cyan, `-` = dim `darkgray`. So `rwxr-xr-x` becomes a tiny **traffic-light strip** — write bits glow red, exec bits cyan.
- **Percent:** `" Top "` / `" Bot "` / `" 42% "` scroll position, in the alt block.

**Effect:** The bottom of the screen announces *what mode your hands are in* the way Vim's statusline does — the loud blue→red color flip on entering visual/select mode is a whole-screen mood change, an identity beat borrowed from modal editors. The per-character permission coloring is a piece of gratuitous craft: it turns a boring `rwx` string into a legible, glanceable chip. This modal-editor DNA is a core part of Yazi's personality — it signals "this is a keyboard-driven power tool" to the exact audience that already loves Vim.

---

## 7. Header / breadcrumb & tabs

**Header** (`header.lua` + `[mgr].cwd = { fg = "cyan" }`): the current path, `readable_path`-shortened, in cyan, **right-truncated (`rtl = true`)** so the *tail* of the path stays visible when it overflows — you always see where you are, not where you started. Active flags append in parens: `~/projects (search: content, filter: .rs, find: foo)`. On the right, a **count badge**: selected count in a `black`-on-`yellow` solid chip (`count_selected`), or yanked-copy count on `green`, cut count on `red` — the same cut/copy/select hue language as the markers.

**Tabs** (`[tabs]`): `active = { bg = "blue", bold = true }`, `inactive = { fg = "blue", bg = "gray" }`, with `sep_inner`/`sep_outer` powerline separators (empty glyphs in the default preset — a restrained default — but the hook is there and flavors fill them with `` chevrons). **Effect:** tabs read as a browser tab-strip; the active tab is a filled blue pill, inactive tabs recede to blue-on-gray.

---

## 8. Motion language — async smoothness *is* the animation

**Technique:** Yazi has almost **no decorative animation** — no spinners in the core preview path. Empty/loading states are plain centered text: `"Loading..."`, `"No items"`, `"Error: %s"` (`components/current.lua`, `plugins/folder.lua`, aligned `ui.Align.CENTER`). The motion story lives entirely in the async architecture (README: "Full Asynchronous Support… non-blocking async I/O"; blog *Why is Yazi Fast?*): scrolling never blocks on I/O, previews **stream in and swap** the moment they're ready, and long operations report via the task manager with "real-time progress updates."

**Effect:** The perceptual signature is **weightlessness / instant swap**, not easing curves. You jump between huge directories and the list snaps; you move the cursor over a 4K image and the preview *appears* rather than *wipes in.* The absence of spinners is itself the aesthetic statement — a spinner is an apology for waiting, and Yazi's async model is designed so you rarely wait. When content genuinely isn't ready, it shows a mute centered `Loading...` and then replaces it in one frame. This "no ceremony, just result" cadence is the terminal-native equivalent of a 120fps native app that never beach-balls.

**Progress** does get color: `progress_normal = { fg = "green", bg = "black" }`, `progress_error = { fg = "yellow", bg = "red" }` — task success is green, failure flips to an alarming yellow-on-red.

---

## 9. Overlays — which-key, confirm, notifications

- **Which-key menu** (`[which]`): a 3-column candidate grid over a **masked (dimmed) background** (`mask = { bg = "black" }`), keys in `lightcyan` (`cand`), remaining chords `darkgray` (`rest`), descriptions `lightmagenta` (`desc`). **Effect:** press a prefix key and the screen dims to a modal palette while a tidy pastel cheat-sheet blooms — discoverability rendered as a deliberate mood-shift.
- **Confirm dialog** (`[confirm]`): blue border + blue title, buttons labeled `"  [Y]es  "` / `"  (N)o  "` with the keybind baked into the label, active button `reversed`. **Effect:** the bracketed hotkey *is* the button text — economical, unmistakable, keyboard-first personality.
- **Notifications** (`[notify]`): toast titles colored by level — info green `` , warn yellow `` , error red `` — each with its own Nerd-Font icon. Popups (input, pick, tasks, help, spot) uniformly use a **blue border + blue title**, giving every modal a single consistent frame color so overlays feel like one family.

---

## 10. Code preview & palette cohesion — the tmTheme tie-in

**Technique:** Syntax highlighting in file previews runs through Sublime-Text `.tmTheme` files (`syntect_theme` in `[mgr]`; flavors ship a `tmtheme.xml`). A **flavor** (Yazi's packaged theme unit, `*.yazi/` dir with `flavor.toml` + `tmtheme.xml` + `README.md` + `preview.png`, introduced v0.2.4) bundles the UI colors *and* the code-highlight colors together.

**Effect:** the code you preview and the chrome around it are **cut from one palette.** A Catppuccin flavor's mauve accents show up in both the border and the keywords. This cohesion is what separates Yazi from managers that bolt a generic highlighter onto a themed shell — the whole screen is one color system, which is exactly the discipline a native design system enforces.

**Flavor vs theme split** (design intent, docs): flavors are pre-made and updateable via the package manager; the user's `theme.toml` *merges over* the flavor so personal tweaks survive `git pull`. This is a deliberate layering — preset (dark/light) → flavor → user override — mirroring how design tokens cascade in a real design system.

---

## 11. Line modes — toggleable density

**Technique** (`linemode.lua`, `[mgr].linemode = "none"` default): an optional right-aligned per-row metadata column — `size`, `mtime`/`btime`, `permissions`, `owner`. Dates use a modern compact format: `%m/%d %H:%M` for this year, `%m/%d  %Y` for older — the same "smart relative date" a native file manager shows.

**Effect:** density is a *dial.* Default `none` keeps rows clean (icon + name only) for a calm, spacious feel; switch to `size` or `mtime` and each row grows a muted metadata tail, turning the list into a details-view table without changing layout. The user chooses between airy and information-dense.

---

## 12. Identity moments — the duck

- **Mascot:** `assets/logo.png` is a **plump, glossy pastel-yellow rubber duckling** — soft rounded body, orange beak and feet, one dark navy eye, a blush of peach on the cheek — centered on a **warm orange radial-gradient circle.** It is unmistakably a *modern flat-illustration app icon* (the visual language of a phone home-screen), not a hacker logo. This is the whole thesis compressed into one image: cute, soft, modern-native, warm.
- **Name:** *yazi* literally means **duck** (鸭子). The mascot is not decoration — it *is* the name.
- **Signature color:** warm **orange** (the logo field, `#ff9800` recurring in `.config`/icon hexes) is the brand accent, even though the in-app chrome leans blue/cyan.
- **Tagline voice:** "⚡️ **Blazing Fast** Terminal File Manager." The copy is emoji-forward, breathless, benefit-first (README bullets: 🚀 💪 🖼️ 🌟 🔌 ☁️ 📡 📦). The voice is **enthusiastic modern-OSS**, not terse-unix.
- **Empty states:** deliberately plain — centered `No items` for an empty folder, `Loading...` mid-fetch, `Error: <msg>` on failure. Understated, no personality clowning in the failure path (the mascot's warmth lives in branding, not in error copy).
- **Error personality:** restrained and functional — a broken symlink gets a **red background chip** in the listing and a `` orphan glyph; a failed task turns the progress bar **yellow-on-red.** Alarm is expressed through color inversion, not words.

---

## 13. Border / box-drawing summary

- **Style:** single, light, **vertical-only** — `│` (U+2502) in gray. No horizontal rules, no corners, no double/heavy boxes in the default preset.
- **Feeling:** un-boxed and airy. Columns are separated by hairlines; overlays get a full blue border but the main workspace does not. This is a modern-minimal choice — the opposite of the heavy double-line `╔═╗` boxes of classic DOS-era managers (Norton Commander, Midnight Commander), and a quiet way of saying "this is a 2020s app."
- **Powerline chevrons** (`` etc.) appear only in status/tab separators, and are *empty by default*, filled by flavors — so the base install is clean, and powerline flourish is opt-in.

---

## 14. Lineage & influences

- **Miller columns** ← macOS Finder column view (the spatial parent/current/preview corridor).
- **Modal statusline + hjkl navigation** ← Vim / ranger (the NOR/SEL badge, blue→red mode flip).
- **Nerd-Font icons + Material hexes** ← the nvim-web-devicons / VS Code file-icon-theme ecosystem (the icon table is essentially the devicons dataset with Material colors).
- **Graphics-protocol previews** ← Kitty graphics protocol (kovidgoyal), iTerm2 inline images, Sixel — Yazi's differentiator is supporting *all* of them behind one auto-detecting adapter.
- **Flavor/theme cascade + package manager** ← the plugin-manager culture of Neovim (ya pack), applied to visual theming.
- **Displaces:** ranger, lf, nnn, vifm — same category, but those are glyph-first; Yazi is pixel-first and design-system-first.

---

## 15. Notable quotes & sources

- README: *"Yazi (means "duck") is a terminal file manager written in Rust, based on non-blocking async I/O. It aims to provide an efficient, user-friendly, and customizable file management experience."*
- README: *"🖼️ Built-in Support for Multiple Image Protocols: Also integrated with Überzug++ and Chafa, covering almost all terminals."*
- README: *"🌟 Built-in Code Highlighting and Image Decoding: Combined with the pre-loading mechanism, greatly accelerates image and normal file loading."*
- Docs (flavors): *"The 'flavor' is a pre-made Yazi theme… The purpose of separating them is to allow users to customize their preferences more conveniently on top of an existing flavor, without having to modify those flavor files."*
- Docs (theming): the system *"automatically detects terminal background color to select appropriate defaults."*

### Source links
- Repo: https://github.com/sxyazi/yazi
- Theme preset (dark): https://github.com/sxyazi/yazi/blob/main/yazi-config/preset/theme-dark.toml
- Flavors overview: https://yazi-rs.github.io/docs/flavors/overview/
- theme.toml docs: https://yazi-rs.github.io/docs/configuration/theme/
- "Why is Yazi Fast?": https://yazi-rs.github.io/blog/why-is-yazi-fast
- Community flavors: https://github.com/yazi-rs/flavors
- DeepWiki (theming): https://deepwiki.com/sxyazi/yazi/3.2-theming-and-flavors
- Local source read: `yazi-config/preset/{theme-dark,theme-light,yazi-default}.toml`, `yazi-adapter/src/drivers/*`, `yazi-emulator/src/brand.rs`, `yazi-plugin/preset/components/{status,header,entity,linemode,tabs,tab}.lua`, `assets/logo.png`

> **Research note:** the repo was shallow-cloned (`--depth 1`), so full commit-history intent reconstruction was unavailable — design intent here is recovered from the *current* theme presets, Lua UI components, adapter/emulator source, docs, and the mascot asset rather than the commit log.

---

## 16. Technique → feeling cheat sheet (for a builder)

| Technique | Feeling it produces |
|---|---|
| Miller 1:4:3 parent/current/preview columns | native Finder-style spatial navigation; "you are here" corridor |
| Real image/Sixel/Kitty previews in the grid | GUI-broke-into-terminal; media app, not console tool |
| Flat semantic filetype hues (img=yellow, dir=blue, exec=green) | read type by color before name; calm, legible |
| Material-Design icon hexes (#ff9800, #03a9f4, #f44336) | imports 2016 flat-app visual language into monospace |
| Reversed-video hover row (solid bar) | tactile native list-selection, not a text caret |
| Colored left-gutter marker stripe (cut=red/copy=green/select=yellow) | multi-select reads as a quiet color gutter |
| Vim-modal powerline badge, blue→red on select | whole-screen mood flip; "keyboard power tool" identity |
| Per-character rwx permission coloring | boring string becomes a glanceable traffic-light chip |
| Single gray `│` hairlines, no boxes | airy, un-boxed, modern-minimal |
| Async instant-swap previews, no spinners | weightlessness; "never beach-balls" |
| tmTheme-unified code + chrome palette | one cohesive color system, design-system discipline |
| Open-folder-on-hover icon swap | micro-affordance; the folder "opens" under you |
| Plump pastel duck app-icon on orange | cute, warm, modern-native brand core |
