# Shiki-Quality Syntax Highlighting in Elixir: Analysis & Recommendation

**Status:** analysis complete, recommendation at end
**Context:** the terminal diff-viewer component needs per-token syntax highlighting.
Raxol constraint: components emit styled spans (`text(content, fg: "#hex" | atom, style: [...])`);
raw ANSI is applied only at the final `Terminal.Renderer` stage. So the highlighter
**must yield structured tokens** — `{text, color, style}` — never pre-rendered ANSI/HTML strings.

---

## 1. How Shiki works (and what a port would cost)

Shiki is not itself a tokenizer. It is a thin orchestration layer over the actual
VS Code highlighting engine:

```
source ──► vscode-textmate (tokenizer, TS)
              │  drives per-line regex matching using…
              ▼
           vscode-oniguruma (Oniguruma regex engine compiled to WASM)
              │  emits per line: [{text, scopeStack}]
              ▼
           theme resolver: VS Code JSON theme (tokenColors: scope selector → {foreground, fontStyle})
              │  scope-stack matching, most-specific selector wins
              ▼
           ThemedToken { content, offset, color: "#rrggbb", fontStyle: bitflag }
```

Key facts:

- **Grammars are TextMate grammars** — large JSON/plist files of Oniguruma regexes
  with `begin`/`end`/`while` rules, captures, includes, and *injections* (one grammar
  injecting rules into another, e.g. HTML inside Markdown fences).
- **The regex engine is Oniguruma**, shipped as WASM. TextMate grammars depend on
  Oniguruma-specific semantics: `\G` anchors, variable-length lookbehind, possessive
  quantifiers, backreferences into `begin` captures substituted into the `end` regex
  (`\1` back-substitution). PCRE-compatible engines (and Erlang's `:re`) cannot run
  a large fraction of real-world TextMate grammars correctly.
- **Themes are VS Code JSON themes.** Resolution walks the token's *scope stack*
  (e.g. `source.ts meta.function entity.name.function.ts`) against theme selectors,
  applying specificity rules (deepest matching scope, parent-scope qualifiers).
- **Tokenization is stateful per line.** `vscode-textmate` tokenizes line-by-line but
  threads a rule-stack (`grammarState`) from one line to the next — that is how
  multi-line strings/comments stay correct.
- **The structured-token API exists and is first-class**: `codeToTokens` returns
  `TokensResult{ tokens: ThemedToken[][] (per line), fg, bg, themeName, grammarState }`,
  with `ThemedToken = { content, offset, color?, bgColor?, fontStyle? }`. This — not
  the HTML — is what "Shiki-grade" means for us: hex color + font style per token.

### What a straight Elixir port would require

| Piece | Portable? |
| --- | --- |
| Theme JSON parsing, scope→color resolution | Yes — pure data transformation, ~a few hundred LOC |
| Tokenizer driver (rule stack, begin/end/while, captures) | Painful but possible (~vscode-textmate is ~10k LOC of subtle logic) |
| Oniguruma regex semantics | **No.** Erlang `:re` is PCRE-ish; grammars break. You'd need an Oniguruma NIF (the C library exists, but then you're maintaining a NIF + the tokenizer + grammar loading) |
| Grammar injections / embedded languages | Reimplementation of underdocumented vscode-textmate behavior |

Verdict: a faithful port is a multi-month project whose hardest 20% (Oniguruma
semantics, injection, scope-stack specificity) is exactly the part that produces
"Shiki-quality." Nobody in the BEAM ecosystem has done it. **Do not port.**

---

## 2. Elixir/BEAM ecosystem survey

### 2.1 `makeup` family — pure Elixir, token-stream native ✅

- **What:** Pygments-modeled highlighter. v1.2.2 (2026-07-01), ~91M all-time
  downloads, maintained by José Valim + Tiago Barroso (it's what ExDoc uses).
  Lexers are pure Elixir `nimble_parsec` parsers — no NIF, no external runtime.
- **Architecture is exactly what we need:** lexer → token list → (formatter we ignore).

  ```elixir
  @callback lex(String.t(), list) :: [Makeup.Lexer.Types.token()]
  # token :: {type_atom, meta_map, iodata}
  ElixirLexer.lex("def foo, do: :ok")
  # => [{:keyword_declaration, %{}, "def"}, {:whitespace, %{}, " "},
  #     {:name_function, %{}, "foo"}, {:punctuation, %{}, ","}, ...]
  ```

  Token types are the full Pygments hierarchy (verified in
  `deps/makeup/lib/makeup/token/utils.ex`): `:keyword_declaration < :keyword`,
  `:string_double < :string`, `:name_function < :name`, etc. — ~70 types in a tree,
  which gives us clean style fallback (unstyled subtype inherits from parent type).
- **Themes:** 34 built-in `Makeup.Styles.HTML.Style` structs (Pygments ports incl.
  `one_dark`, `dracula`, `monokai`, `vs`, `tango`). Each is
  `%Style{styles: %{token_type_atom => %TokenStyle{color: "#rrggbb", font_weight:, font_style:, text_decoration:}}}`.
  That is a ready-made token-type → hex-color table. `TokenStyle.from_string("bold #ff0000")`
  parses Pygments specs, so custom themes are trivial data.
- **Language coverage (the gap):** pure-Elixir lexers exist for ~15 languages:
  elixir, erlang, eex/heex, html, json, c, diff, sql (`makeup_sql`), graphql, js
  (`makeup_js`), ts (`makeup_ts`), css (`makeup_css`), gleam, swift.
  **Missing: python, go, rust (repo archived 2025), yaml, bash, markdown, ruby, java…**
- Already a dependency of this repo (`mix.exs`: `makeup ~> 1.2`, `makeup_elixir ~> 1.0.1`),
  and `Raxol.UI.Components.CodeBlock` already calls Makeup — badly (it renders HTML
  and strips the tags, discarding all color; only Elixir is mapped).

### 2.2 `makeup_syntect` — the gap-filler ✅

- **What:** v0.1.4 (2025-12-30), MIT, maintained by José Valim + Steffen Deusch.
  Rustler NIF wrapping **syntect** (the Rust library behind `bat`; uses Sublime
  Text `.sublime-syntax` grammars — the closest widely-ported cousin of TextMate
  grammars, with a real Oniguruma-class regex engine).
- **Ships precompiled binaries** via `rustler_precompiled ~> 0.9` (`rustler` is
  optional) — users need no Rust toolchain. Verified in its `mix.exs`.
- **205 syntaxes** (python, go, rust, yaml, bash, markdown, ruby… via syntect +
  two-face syntax sets). Elixir/Erlang/HTML-EEx are disabled by default because the
  native Makeup lexers are better — i.e. it is *designed* to coexist with 2.1.
- **Critically: it emits the same Makeup token stream.**
  `MakeupSyntect.tokenize(text, language: "python")` → `[{type_atom, meta, iodata}]`.
  The syntect-scope → Pygments-atom mapping happens inside the NIF; the Elixir side
  sees one uniform token model regardless of which lexer ran. It also auto-registers
  all 205 syntaxes into Makeup's lexer registry, so `Makeup.Registry` lookup by
  language name/extension covers everything with one code path.

### 2.3 `autumn` — best engine, wrong output shape ❌ (for now)

- **What:** Rust NIF (precompiled), currently powered by **tree-sitter + Neovim
  themes** (it migrated from its earlier engine; current docs: "powered by
  Tree-sitter and Neovim themes"). ~70 languages, **120+ bundled Neovim themes**,
  custom themes via `Autumn.Theme.from_file/from_json`.
- **Output formats:** `:html_inline`, `:html_linked`, `:html_multi_themes`, and
  `:terminal` (truecolor ANSI, e.g. `\e[38;2;229;192;123m`).
- **The disqualifier:** `Autumn.highlight/2` returns `{:ok, String.t()}` — always a
  pre-rendered string. **There is no public token-level API.** No function returns
  `{text, color, style}` structures. To use it we'd have to parse its ANSI output
  back into spans — brittle, and inverts the codebase rule that ANSI exists only at
  the renderer boundary.
- Highlight quality (tree-sitter) is arguably Shiki-class, and the Neovim theme
  library is the best theme selection on the BEAM. If autumn ever grows a token
  formatter (worth an upstream issue/PR — the Rust side plainly has the spans before
  formatting), it becomes a serious contender. Today it's usable only as a
  last-resort ANSI-parsing fallback, which we don't need given 2.2.

### 2.4 Tree-sitter bindings — immature ❌

- `ex_tree_sitter_highlight` v0.2.2 (2024-03) — outputs **HTML only**, ~550 all-time
  downloads, stale >2 years.
- `treesitter_elixir` v0.1.6 (2026-07, active but tiny) — raw parse trees, "small
  subset of the tree-sitter API"; we'd have to build the entire highlight-query +
  theme layer ourselves. ~520 downloads.

### 2.5 Chroma / bat / silicon — no ❌

- **chroma** (Go): no Elixir port or NIF exists; would mean a Go subprocess and
  output parsing.
- **bat**: subprocess emitting ANSI — would require ANSI re-parsing (lossy, and the
  same shape problem as autumn but with process-management cost on top).
- **silicon**: renders PNGs. Irrelevant for a cell renderer.

### 2.6 Node sidecar running actual Shiki — honest but heavy ❌

Real Shiki via the `nodejs` hex package (supervised Node worker pool,
`NodeJS.call/3`). `codeToTokens` would give us genuine `ThemedToken` JSON — perfect
fidelity, every VS Code theme and grammar.

Operational cost: ship & supervise a Node runtime inside a terminal framework;
per-call JSON IPC latency; cold-start; a second package ecosystem to version; breaks
`mix raxol.playground --ssh`-style single-binary deployment stories; absurd
dependency weight for highlighting a diff. Justifiable only if pixel-perfect VS Code
theme parity became a product requirement. It isn't.

### 2.7 Survey summary

| Option | Engine | Langs | Themes | Structured tokens? | Maint. | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| makeup (+lexers) | pure Elixir (nimble_parsec) | ~15 | 34 Pygments styles | **yes** `{atom, meta, text}` | Valim/Barroso, active, 91M dl | core |
| makeup_syntect | Rust syntect NIF (precompiled) | 205 | (uses makeup styles) | **yes** — same tuple | Valim/Deusch, active | gap-filler |
| autumn | tree-sitter NIF | ~70 | 120+ Neovim | **no** — strings only (HTML/ANSI) | active | rejected (output shape) |
| tree-sitter bindings | tree-sitter NIF | many in theory | none | no / DIY | stale or embryonic | rejected |
| chroma/bat/silicon | subprocess | many | many | no (ANSI/PNG) | n/a | rejected |
| Shiki via Node | vscode-textmate + Oniguruma | 200+ | all VS Code | yes (over IPC) | upstream | rejected (ops cost) |
| straight port | — | — | — | — | — | rejected (Oniguruma) |

---

## 3. Terminal mapping (this codebase)

Everything needed already exists in Raxol; no renderer work is required.

- **Components emit spans, not ANSI.** `Raxol.View.Components.text/1` carries
  `fg`/`bg`/`style` through the pipeline; `fg` accepts an atom, `0..255`, `{r,g,b}`,
  or `"#rrggbb"` (see `Raxol.Core.Renderer.Color.to_ansi/1`).
- **Truecolor:** hex fg flows to `\e[38;2;r;g;bm` in `Terminal.Renderer` /
  `Renderer.Color` — theme hex colors map 1:1, no loss.
- **256-color fallback:** `Raxol.Style.Colors.Formats.rgb_to_ansi/1` already
  implements the standard quantization (6×6×6 cube `16 + 36i_r + 6i_g + i_b` +
  grayscale ramp `232..255`). Capability detection decides when to quantize; the
  highlighter never needs to know.
- **Token → span:** the diff viewer converts each themed token to
  `text(content: tok.text, fg: tok.color, style: tok.styles)` where
  `styles ⊆ [:bold, :italic, :underline]` from the theme's `TokenStyle`
  (`font_weight: "bold"` → `:bold`, etc.). Token `bg` is left nil so the diff
  row background (add/remove tint) stays owned by the diff component —
  syntax fg over diff bg composes for free in the cell model.

Proposed intermediate shape (the whole contract between highlighter and any
component):

```elixir
@type themed_token :: %{text: String.t(), fg: String.t() | nil, styles: [:bold | :italic | :underline]}
@spec highlight_lines(source :: String.t(), lang :: String.t(), theme :: Style.t()) ::
        [[themed_token()]]   # outer list = lines, like Shiki's TokensResult.tokens
```

---

## 4. Diff-context tokenization pattern

Requirement: the diff viewer renders line-by-line rows, independently, from two file
versions (old, new). Two candidate patterns:

1. **Per-line tokenization** — lex each visible line in isolation. **Wrong.**
   Lexers are stateful across lines: a line inside a heredoc, multi-line string,
   or block comment tokenizes as garbage without the preceding context. (Shiki
   itself threads `grammarState` between lines for exactly this reason.)
2. **Tokenize whole file version once, then split into per-line runs.** **Right.**
   - Run `lex/2` (or `MakeupSyntect.tokenize/2`) on the *full text of each version*
     (old text once, new text once — two lex passes per file pair).
   - Post-process the flat token list into `[[token]]` per line: walk tokens,
     splitting any token whose text contains `\n` into per-line fragments that keep
     the same type (Makeup token values are iodata and can span lines — multi-line
     strings, comments, whitespace runs).
   - Resolve theme colors once per token type (the type→`TokenStyle` map lookup,
     with hierarchy fallback, is cheap and memoizable).
   - Cache the resulting `lines :: [[themed_token]]` keyed by
     `{content_hash, lang, theme}` — content is immutable per diff view, so this is
     computed once per file version, then each rendered row is `lines[row_index]`,
     an O(1) slice. Scrolling, partial rendering, and the r1 incremental-render
     row path all get correct tokens with zero re-lexing.

Unchanged/context lines appear in both versions; take them from whichever version's
cache the row is attributed to (they tokenize identically unless surrounding context
differs — which is precisely when per-version tokenization is the correct behavior).

Failure containment: lexing runs at diff-load time, not render time; wrap it so a
lexer crash/timeout degrades to unstyled lines (single `%{text: line, fg: nil}` per
line), never a broken frame.

---

## 5. Recommendation

**Use the Makeup token model: `makeup` + native lexers for BEAM-family languages,
`makeup_syntect` for everything else. Don't port Shiki; don't adopt autumn (yet).**

### Why

1. **It is the only option that natively yields structured tokens** — the hard
   requirement. One uniform `{type_atom, meta, text}` tuple whether the lexer is
   pure Elixir or the syntect NIF; every alternative hands us pre-rendered strings.
2. **Coverage is solved**: 205 syntect syntaxes + best-in-class native Elixir/Erlang/
   HEEx lexers, coexisting by design through `Makeup.Registry` (syntect even disables
   its own Elixir grammar in deference to `makeup_elixir`).
3. **Zero toolchain cost**: makeup is pure Elixir and already in `mix.exs`;
   makeup_syntect ships precompiled NIFs.
4. **Pedigree**: both maintained by José Valim et al.; makeup is ExDoc's engine
   (91M downloads). This will not rot.
5. Grammar fidelity: syntect ≈ Sublime grammars ≈ 90–95% of Shiki's TextMate
   accuracy in practice (it's the `bat` engine). Tree-sitter (autumn) or real Shiki
   are marginally better on exotic nesting, but neither exposes tokens.

### API sketch

```elixir
defmodule Raxol.UI.SyntaxHighlighter do
  alias Makeup.Registry
  alias Makeup.Styles.HTML.{Style, StyleMap}

  @type token :: %{text: String.t(), fg: String.t() | nil,
                   styles: [:bold | :italic | :underline]}

  @spec highlight_lines(String.t(), String.t(), Style.t() | atom()) :: [[token]]
  def highlight_lines(source, language, theme \\ :one_dark) do
    style = resolve_style(theme)                       # Style struct or StyleMap fn
    case Registry.fetch_lexer_by_name(language) do     # covers native + syntect
      {:ok, {lexer, opts}} ->
        source
        |> lexer.lex(opts)                             # [{type, meta, iodata}]
        |> split_lines()                               # [[{type, text}]] per line
        |> Enum.map(fn line ->
          Enum.map(line, fn {type, text} -> theme_token(type, text, style) end)
        end)
      :error ->
        source |> String.split("\n") |> Enum.map(&[%{text: &1, fg: nil, styles: []}])
    end
  end

  # Theme resolution: exact token type, else walk up the Pygments hierarchy
  # (:string_double -> :string -> default fg). Memoized per {theme, type}.
  defp theme_token(type, text, style) do
    ts = style.styles[type] || style.styles[parent_of(type)]  # hierarchy walk
    %{text: text, fg: ts && ts.color,
      styles: font_styles(ts)}   # font_weight "bold" -> :bold, etc.
  end
end
```

The diff viewer then does, per rendered row:
`for tok <- lines[row], do: text(content: tok.text, fg: tok.fg, style: tok.styles)`.

### Theme handling

- Phase 1: ship makeup's 34 Pygments styles (`one_dark`, `dracula`, `monokai`,
  `vs`, …) — they are literal `token_type => hex` maps, and should be bridged into
  `Raxol.UI.Theming` so the diff theme and syntax theme switch together.
- Phase 2 (optional, cheap, closes the "real editor themes" gap): a VS Code theme
  JSON importer — a fixed ~40-entry table mapping TextMate scope prefixes
  (`keyword.control`, `entity.name.function`, `string`, `comment`, …) to Pygments
  token atoms, emitting a `%Style{}`. That buys arbitrary VS Code themes without
  buying the tokenizer.

### Language coverage for the realistic set

| Language | Lexer | Quality |
| --- | --- | --- |
| elixir / heex | makeup_elixir / makeup_eex (native) | best available anywhere |
| js / ts | makeup_ts (native) or syntect | good |
| python | makeup_syntect | good (bat-grade) |
| go | makeup_syntect | good |
| rust | makeup_syntect (native lexer archived) | good |
| json | makeup_json (native) | good |
| yaml | makeup_syntect | good |
| markdown | makeup_syntect | good |
| html / css | makeup_html / makeup_css (native) | good |
| sql | makeup_sql (native) or syntect | good |
| bash | makeup_syntect | good |

**Unknown-language fallback:** `Registry` miss → whole line as one unstyled token
(shown plain, still diff-tinted). Optionally try syntect's extension-based detection
first; never error.

### Risks (main one first)

1. **Token-type granularity < scope stacks.** Pygments atoms (~70 types) are coarser
   than TextMate scope stacks, so themes can't distinguish e.g. "function call" vs
   "function definition" in some grammars. This is the real fidelity delta vs Shiki
   — visible mostly to people diffing their own editor side-by-side. Accepted; the
   Phase-2 VS Code importer can't fix it (it's a lexer-side ceiling), only autumn
   growing a token API or a Shiki sidecar could.
2. `makeup_syntect` is v0.1.x — young API surface, though the engine (syntect) and
   maintainers are proven. Pin minor version; the token tuple shape is makeup's
   stable contract, not syntect's.
3. NIF footprint: syntect NIF is the first native highlighting dep in main raxol.
   If a target platform lacks a precompiled artifact, `rustler` builds from source
   (needs cargo). Keep the dep optional (`Code.ensure_loaded?` guard, like the
   existing `CodeBlock` does for Makeup) so raxol works highlight-degraded without it.
4. Very large files: full-file lexing per version is O(file); cache by content hash
   and lex off the render path (see §4). Add a size cutoff (e.g. >1 MB → plain).

### Follow-ups worth filing

- Fix `Raxol.UI.Components.CodeBlock`: it currently strips Makeup's HTML back to
  plain text (all color discarded). It should sit on the same
  `SyntaxHighlighter.highlight_lines/3` and emit styled spans.
- Upstream issue on `autumn` requesting a structured-token formatter; if accepted,
  re-evaluate as an alternative backend behind the same `highlight_lines/3` contract.

---

### Sources

- Shiki: https://shiki.style/guide/install, token types:
  https://github.com/shikijs/shiki (packages/types/src/tokens.ts — `ThemedToken`, `TokensResult`)
- Makeup: https://hex.pm/packages/makeup, https://makeup.hexdocs.pm/Makeup.Lexer.html,
  token hierarchy verified locally in `deps/makeup/lib/makeup/token/utils.ex`
- makeup_syntect: https://github.com/elixir-makeup/makeup_syntect (205 syntaxes;
  `rustler_precompiled` confirmed in mix.exs), https://hex.pm/packages/makeup_syntect
- Autumn: https://autumn.hexdocs.pm/Autumn.html (formatters `:html_inline`,
  `:html_linked`, `:html_multi_themes`, `:terminal`; no token API),
  https://github.com/leandrocp/autumn
- Tree-sitter bindings: https://hex.pm/packages/ex_tree_sitter_highlight,
  https://hex.pm/packages/treesitter_elixir
- Raxol internals: `lib/raxol/core/renderer/color.ex`,
  `lib/raxol/style/colors/formats.ex`, `lib/raxol/view/components.ex`,
  `lib/raxol/ui/components/code_block.ex`
