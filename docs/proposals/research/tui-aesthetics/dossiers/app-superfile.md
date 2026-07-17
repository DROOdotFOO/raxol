# Aesthetic Dossier — **superfile**

> "Pretty fancy and modern terminal file manager" — the GitHub repo's own one-line subtitle.

superfile (invoked as `spf`) is a Go + Bubble Tea terminal file manager by **yorukot** (formerly *MHNightCat*). It is the archetype of the **modern pastel / kawaii TUI**: where `ranger`, `lf`, `nnn` and `mc` present as unstyled Unix plumbing, superfile presents as a *designed product* — rounded panels, Catppuccin pastels, colored Nerd-Font glyphs, candy-colored confirm/cancel buttons, gradient progress bars, and a voice that says "Thanks for using superfile!!" with two exclamation marks. It is the clearest case study of a designer-made file manager that consciously refuses the "tool" register in favor of the "app" register.

This dossier reconstructs *which concrete moves* produce *which feelings*, recovered from the source tree (`src/internal/common/style.go`, `src/superfile_config/config.toml`, the 21 shipped `theme/*.toml` files, `src/config/icon/icon.go`, the processbar package), the git history, and the maintainer's own written design statements.

---

## 0. Designer intent (recovered, in his own words)

From `website/src/content/docs/overview.md` — the closest thing to a manifesto:

> "superfile is a **modern terminal file manager crafted with a strong focus on user interface**, functionality, and ease of use. Built with Go and Bubble Tea, it combines a **visually appealing design** with the simplicity of terminal tools, providing a **fresh, accessible approach** to file management."

> "Before creating superfile, **I tried a lot of terminal file managers, but I was often disappointed by their UI design.** So, I built superfile with a **primary focus on delivering a refined, user-friendly interface.**"

> "superfile is **sleek and visually appealing** … While it may not be as feature-packed as some other terminal file managers, **it excels in usability and design.** … If you're looking for a full-featured file manager, I'd recommend tools like Yazi … However, for straightforward tasks with a **clean interface**, superfile is an excellent option."

The tell: the maintainer positions **design as the reason the project exists** — not features, not speed. superfile is explicitly the answer to "TUIs are ugly." Every aesthetic decision below descends from that thesis.

The README closes with a kaomoji: **`༼ つ ◕_◕ ༽つ Please share`** — the friendly, community-coded register carried right into the repo's own copy.

---

## 1. Border language — the single loudest signal

**Technique.** The default border set in `config.toml` is **rounded corners on straight single-weight edges**:

```
border_top='─' bottom='─' left='│' right='│'
border_top_left='╭'  border_top_right='╮'
border_bottom_left='╰' border_bottom_right='╯'
border_middle_left='├' border_middle_right='┤'
```

Every visible container — sidebar, each file panel, the footer/metadata/process bar, every modal — is wrapped in a `╭─────╮ / ╰─────╯` box (rendered through a custom lipgloss `lipgloss.Border` built by `GenerateBorder()` and a bespoke `rendering/border.go` that also inlays a **title** and **info items** *into* the border line: `├ title ┤────────`).

**Feeling.** Rounded corners are the terminal's only available equivalent of a CSS `border-radius`, and superfile spends it everywhere. Sharp `┌┐└┘` corners read as *engineering diagram / system utility*; rounded `╭╮╰╯` read as *soft, friendly, contemporary app chrome* — the same softening that rounded rectangles gave iOS. Because the weight stays single (`─│`, not heavy `━┃` or double `═║`), the boxes feel **light and quiet** rather than industrial. The consistency — *nothing* in the UI has a hard corner — is what sells it as one designed system rather than a grab-bag of widgets.

**Titles inside the border.** Panel names sit *in* the top rule (`╭─┤ path ├────╮`) and file counts / sizes sit in the *bottom* rule as "info items." This is a deliberately GUI move — it mimics a window title bar and a status strip — and it means the whitespace inside the panel is never spent on labels. The frame does the labeling; the interior stays clean.

---

## 2. Color — Catppuccin as the house palette

**Technique.** The shipped default is `theme = "catppuccin-mocha"`. Its base is the signature Catppuccin dark ground **`#1e1e2e`** (a desaturated blue-charcoal, *not* pure black) with soft grey-lavender text **`#a6adc8`**. Accents are drawn entirely from the Catppuccin pastel set:

| Role | Hex | Catppuccin name | Feeling |
|---|---|---|---|
| File-panel active border | `#b4befe` | Lavender | cool, calm focus |
| Footer active border | `#a6e3a1` | Green | gentle "all good" |
| Sidebar active border | `#f38ba8` | Red/Pink | warm pop |
| Sidebar title | `#74c7ec` | Sapphire | friendly heading |
| Cursor | `#f5e0dc` | Rosewater | warm off-white |
| Selected filename | `#98D0FD` | (bright sky) | spotlight |
| Confirm button bg | `#89dceb` | Sky | candy affirmative |
| Cancel button bg | `#eba0ac` | Maroon/rose | candy negative |
| Correct / error / hint | `#a6e3a1` / `#f38ba8` / `#73c7ec` | green/pink/sky | soft semantics |

**The deliberate move that most utilities *don't* make:** superfile assigns **each panel region a *different* pastel as its active-border color** — file panel glows lavender when focused, the sidebar glows pink, the footer glows green. Focus is communicated by a *color temperature shift on the frame*, not by a harsh inverse bar.

**Feeling.** The whole surface sits in a **narrow, high-lightness, low-saturation band** — pastels on a soft-dark ground. Nothing is a saturated primary; nothing is pure `#000`/`#fff`. Color psychology of the pastel band is *approachable, calm, non-threatening, "cute."* It is the exact opposite of the neon-green-on-black "hacker terminal" or the beige monochrome of `mc`. The multi-hued borders make the app feel **playful and roomy** — like a set of soft-glowing cards — rather than a single monolithic grid.

**Gradient accent.** Each theme also defines a two-stop `gradient_color`; mocha's is **`#89b4fa → #cba6f7` (blue → lavender)**. It is applied via bubbles' scaled progress bar (`progress.WithColors(g0,g1)`, `WithScaled(true)`) so the fill sweeps blue-to-purple as an operation completes — a small hit of *dimensional, almost liquid* color in an otherwise flat palette (§4).

**The 21-theme wardrobe.** superfile ships an unusually large, curated theme set — five Catppuccin flavors (mocha/macchiato/frappé/latte/…), Rosé Pine, Tokyo Night, Nord, Gruvbox (×3), Everforest (×2), Dracula, Monokai, One Dark, Ayu, Poimandres, Kaolin, 0x96f, the community **Sugarplum** (violet-on-indigo, `#111147` ground with `#db7ddd` orchid text), and the joke themes **`blood`** (`#720000→#ff0000`) and **`hacks`** (`#00ff00→#afff00` matrix-green). The *center of gravity* is unmistakably the soft-pastel family; the edgy themes are outliers you opt into. Each theme file is signed and thanked in the header comment — e.g. *"This theme was created by: https://github.com/AnshumanNeon ! Thank you <3"* — the `<3` and the crediting are themselves part of the brand's warm register.

---

## 3. Composition, density & whitespace — "app, not tool"

**Technique.** The default screen is a **three-region composition**:

```
╭─ ┤ ⌂ superfile ├──────╮ ╭─┤ /home/user ├──────────────────────╮
│  ⌂ Home                │ │ > 󰉋 Documents                        │
│  ↓ Downloads           │ │   󰉋 Downloads                        │
│  ♬ Music               │ │   󰈙 notes.md                         │
│  󰐃 Pinned ─────────    │ │    report.pdf                       │
│  󱇰 Disks ──────────    │ │                                      │
│  /dev/sda1  ▓▓▓▓░░ 62%  │ │                                      │
╰────────────────────────╯ ╰──────── 4 items · 2.1 MB ───────────╯
                           ╭─ Metadata ──────╮╭─ Processes ──────╮
                           │ Name  report.pdf ││ 󰥔 Copying file… ││
                           │ Size  1.2 MB     ││ ▓▓▓▓▓▓░░░░ 60%   ││
                           ╰──────────────────╯╰──────────────────╯
```

- **Sidebar** (`sidebar_width = 20`, configurable) with ordered sections **Home → Pinned → Disks**, each introduced by a colored icon+label divider (`⌂ Home ─────`, `󰐃 Pinned ─────`), and disks shown with a usage meter.
- One or more **file panels** (tabbed/multi-column) that own the center.
- A **footer row** split into **Metadata** and **Processes** sub-panels (`show_panel_footer_info = true` by default), each its own rounded box.

**Feeling.** This is a **GUI file-manager mental model transplanted into cells** — the Finder/Nautilus "places sidebar + main pane + info strip" — where the sibling utilities give you a single bare column of filenames. The **generous fixed sidebar** and the **dedicated metadata panel** are, in pure information terms, "wasteful" of columns; that spend is exactly the point. Whitespace and multi-panel framing are the terminal's way of saying *"I am a spacious application, I am not in a hurry, I have room for you."* A sparse `lf` says *tool*; superfile's padded, paneled, labeled layout says *product*.

**Icons carry the density.** Nerd Fonts on by default (`nerdfont = true`). Every directory, file type, sidebar entry, disk and operation gets a glyph — `⌂` home, `↓` downloads, `♬` music, `󰐃` pinned, `󱇰` disk, `󰉋` folder, plus a full `ls-go`-derived per-extension icon map where **each file type gets its own branded, individually-colored glyph** (`.css` blue `#2d53e5`, `.rs` orange, `.py` etc.). The effect is a **colorful, textured column** that reads almost like a GUI icon grid — the single biggest reason a superfile screenshot doesn't look like a terminal at first glance.

---

## 4. Motion language

superfile's motion is small but deliberate — it never animates for spectacle, only to signal *life and progress*.

- **Gradient progress bars (the charm move).** File operations (copy/cut/delete/compress/extract) each spawn a bubbles `progress.Model` filled with the theme's two-stop gradient, `WithScaled(true)` so the color sweep is anchored to real percentage. Watching `▓▓▓▓▓▓░░░░` fill from blue into lavender is the app's signature bit of *fluid, almost tactile* motion.
- **Stateful process icons + present-tense verbs.** Each process line leads with a state glyph and a *live gerund*: `󰥔 Copying report.pdf`, `Compressing…`, then on completion flips to `Copied 4 files` / ` Compressed`. States map to icons — **in-operation = clock `󰥔`** (hint/sky color), **success = check `` (green), **fail = warn `` (pink/error), **cancel = `` (cancel-rose)**. The verb *changing tense* ("Copying" → "Copied") is a tiny piece of narrative motion that makes the app feel like it's *talking you through* the work.
- **Loading placeholders.** Metadata resolves through `󰥔 Loading metadata…`; the preview pane shows `Loading…`. The clock icon reused as a "working" marker gives a consistent "thinking" vocabulary.
- **Redraw cadence.** Bubble Tea's diff-render keeps motion flicker-free; the demo tapes (`vhs/demo.tape`) reveal the *intended* pacing — `Sleep 500–1500ms` between actions at 15fps — an unhurried, legible rhythm rather than a frantic one.

**Feeling.** Motion here reads as **attentive and gentle**: the gradient bar and the narrating verbs turn a blocking file copy into a small, friendly progress story. It is "charm" in the literal Charm-libraries sense — the same house style as `gum`/`glow`.

---

## 5. Typography substitutes & the font tell

With one monospace weight to work with, superfile leans on **glyphs and color** far more than on bold/italic/casing:

- **Casing.** The wordmark is **always lowercase `superfile`** — the branding page's hard rule: *"Pair the logo with the lowercase name: superfile."* Lowercase reads soft, modern, unintimidating (the `stripe`/`figma`/`npm` lowercase-brand convention).
- **The superfile mark.** Sidebar title renders **` superfile`** — the Nerd-Font superfile logo glyph (``) as a persistent brand bug top-left, the terminal equivalent of an app icon in a title bar.
- **Bold/dim** used sparingly for hierarchy; the heavy lifting is color and icon, not weight.
- **The marketing-font tell.** The demo GIFs are recorded (`vhs/demo.tape`) in **`Comic Mono`** (fallback `RobotoMono Nerd Font`) at FontSize 20–30. Choosing *Comic Mono* — a monospace cut of Comic Sans — to present the product is a loud, self-aware declaration of the **cute/friendly** brand. superfile literally shows itself off in the friendliest possible typeface.

**Feeling.** Lowercase + logo-bug + Comic-Mono screenshots + colored icons = a **soft, contemporary, indie-product identity**. Nothing shouts; the personality lives in glyphs, hue, and the deliberate lowercase hush.

---

## 6. Voice & copywriting

superfile's copy is unmistakably **warm, personal, and slightly non-native-English — and it keeps the imperfection because it reads as sincere**:

- **First-run modal** (`introduceModalRender`): *"**Thanks for using superfile!!**"* → *"You can read the following information before starting to use it!"* → numbered `(1)…(4)` tips → closes with *"**Thank you again for using superfile.** If you have any questions, please feel free to ask … Of course, you can always open a new issue to share your idea or report a bug!"* The double `!!`, the direct gratitude, the personal "I/you" — this is a *host welcoming a guest*, not a man page.
- **Endearing imperfect English as personality.** When you shrink the window: **"You change your terminal size too small:"** and **"Terminal size too small:"** The slightly-off grammar is *charming*, not sloppy — it signals a real, human, one-person project and a maintainer whose warmth outweighs polish.
- **Error personality.** Config/theme/hotkey errors render as **`■ ERROR: `** — a filled red square bullet (`#FF5555`) — with the offending value spotlighted in **cyan `#00D9FF`**: *`■ ERROR: Theme value for "xyz" is invalid : …`*. Even the error state is *styled and colored*, not a raw stack trace.
- **Kaomoji in the README** (`༼ つ ◕_◕ ༽つ Please share`) and **`Thank you <3`** in every theme file header. The affection is baked into the source, not just the marketing.
- **Website chrome** uses code-comment section labels like **`// brand assets`** — a small wink to the developer audience while staying playful.

**Feeling.** The voice is **friend, not manual.** Where `rsync`/`mc` speak in terse imperatives and error codes, superfile says thank you, apologizes for small windows, and signs its themes with hearts. This is the single strongest thing separating its *feel* from its category siblings.

---

## 7. Identity moments (where the personality concentrates)

- **Sidebar logo-bug:** persistent ` superfile` top-left — the app-icon-in-the-corner.
- **Adaptive brand logo:** ships light/dark SVG marks (`superfile-day.svg` / `superfile-night.svg`) that swap on system theme — a web-grade branding nicety rare for a TUI.
- **First-run welcome modal:** the "Thanks for using superfile!!" onboarding card (§6) — the app's handshake.
- **Candy confirm/cancel buttons:** modals render **`( ) Create`** on a **sky `#89dceb`** pill and **`( ) Cancel`** on a **rose `#eba0ac`** pill, both with dark text — literal candy-colored GUI buttons, the most kawaii single element in the UI.
- **Chevron spotlight cursor:** the focused row is marked by a **`` chevron** (``) in warm **Rosewater `#f5e0dc`**, and the selected filename recolors to **bright sky `#98D0FD`** — a *soft, colored* focus indicator rather than a hard inverse bar. (Some themes, e.g. Sugarplum, swap to a filled background bar `bg #53b397` for a stronger spotlight; the default keeps it gentle.)
- **Signature color:** Catppuccin's `#1e1e2e` ground + lavender/pink/sky accent triad is the "superfile look" people screenshot.
- **Themed disk meters, colored dividers, per-filetype icon colors** — density that reads as care.
- **Community theme credits with `<3`** — every `theme/*.toml` names and thanks its author.

---

## 8. Lineage & influences

- **Charm stack (Bubble Tea / Lipgloss / Bubbles).** superfile is a flagship of the Charm aesthetic — rounded lipgloss borders, gradient bubbles progress bars, the "make the terminal delightful" ethos. Its softness is downstream of Charm's design language, pushed further toward *cute*.
- **Catppuccin.** Adopting a Catppuccin flavor as the *default* (not merely an option) ties superfile to the entire pastel-terminal-dotfiles movement; there is an official `catppuccin/superfile` port ("📂 Soothing pastel theme for Superfile").
- **`ls-go`** (`acarl005/ls-go`) — the source of the per-extension colored icon map, credited in `icon.go` (*"thanks for the great work!!"*).
- **Sibling contrast (self-declared):** the maintainer names **Yazi** as the "full-featured" alternative and cedes feature-completeness to it — superfile's differentiator is *interface warmth*, deliberately. Against `ranger`/`lf`/`nnn`/`mc` (bare, monochrome, utility-first), superfile is the "designed" one.

---

## 9. What makes superfile FEEL different from its siblings

| Dimension | Typical TUI file manager (`lf`,`nnn`,`ranger`,`mc`) | superfile |
|---|---|---|
| Corners | sharp `┌┐└┘` or none | **rounded `╭╮╰╯` everywhere** |
| Palette | 16-color / monochrome / neon | **Catppuccin pastels, per-region accent hues** |
| Layout | single filename column | **sidebar + panels + metadata + process footer** |
| Icons | none or one glyph | **per-filetype *colored* Nerd-Font glyphs** |
| Progress | text `%` or nothing | **gradient-swept scaled progress bars** |
| Buttons | key hints | **candy-colored sky/rose confirm-cancel pills** |
| Voice | man-page terse / error codes | **"Thanks for using superfile!!", `<3`, kaomoji** |
| Brand | none | **lowercase wordmark, adaptive logo, Comic-Mono demos, logo-bug** |

The through-line: superfile applies the **grammar of a friendly consumer GUI** — rounded cards, pastel accents, spacious chrome, warm microcopy, a logo — to a character grid, and does it *consistently enough* that the whole thing coheres into a single soft, approachable identity. It doesn't look like a power-user's Unix tool; it looks like *an indie app that happens to live in your terminal.*

---

## Sources

- Repo (cloned & read): `github.com/yorukot/superfile` — `src/superfile_config/config.toml` (rounded-border defaults, `nerdfont`, sidebar sections), `src/superfile_config/theme/*.toml` (21 themes, gradient stops, credits), `src/internal/common/style.go` + `style_function.go` (per-region border colors, error styling), `src/internal/ui/rendering/border.go` (in-border titles/info items), `src/internal/ui/processbar/{process,operation}.go` (gradient bars, state icons, present-tense verbs), `src/config/icon/icon.go` (Nerd-Font glyph + per-filetype color map), `src/internal/model_render.go` (welcome modal, "terminal too small"), `vhs/demo.tape` (Comic Mono, pacing).
- `website/src/content/docs/overview.md` — maintainer design manifesto (quoted §0).
- `website/src/pages/branding.astro` — lowercase-wordmark rule, logo guidance, `// brand assets` label.
- README.md — repo tagline, `༼ つ ◕_◕ ༽つ` kaomoji, adaptive day/night logo, community/sponsor framing.
- https://github.com/yorukot/superfile — "Pretty fancy and modern terminal file manager."
- https://superfile.dev/ — docs/landing.
- https://github.com/catppuccin/superfile — "Soothing pastel theme for Superfile."
- https://github.com/yorukot/superfile/discussions/186 — community theme list.
- https://www.x-cmd.com/pkg/superfile/ — third-party writeup on superfile's UI focus, mouse support, GUI-like feel.
