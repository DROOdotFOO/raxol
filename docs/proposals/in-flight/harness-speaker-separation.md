# Harness Speaker Separation — replacing the `[assistant]` tagline

Date: 2026-07-17 · Status: proposal, decision-ready for V · Lane: harness-ui
Question: how should user vs assistant turns be visually separated in the transcript?
Trigger: the `[assistant]`/`[user]` tagline above message bodies reads mechanistic and spends a row.
Evidence: `docs/proposals/research/tui-aesthetics/` corpus · `harness-visual-doctrine.md` · `harness-ui-north-star.md` · current code.

---

## 1. What the corpus does (per-tool mechanics)

| Tool | User turn | Assistant turn | Tool/system nesting | Turn rhythm | Cost | Register |
|---|---|---|---|---|---|---|
| Claude Code | rounded input box live; **historical echo undocumented in corpus** | bare prose, no glyph, no box; streams then freezes to static markdown | `⏺` dot at margin, result hung under `  ⎿  `, dim | blank line between turns — "the page breathes" | ~1 row/turn, ~0 cols; tools 2–5 col hang | chromeless literate |
| aider | prompt `format> ` retained in scrollback; user text **green**, markdown-lexed | bare prose, **blue/cyan** — "two-voice call-and-response" | terminal-default fg, flush, no nesting grammar | one tinted `console.rule()` per turn — "logbook rhythm" | 1 row/turn, 0 cols | austere craftsman |
| Gemini CLI | open-sided rounded rule around input; **history treatment undocumented** | streaming reflow documented; no speaker grammar recorded | banners/boxes for notices only | n/a (corpus gap) | n/a | consumer brand |
| Grok Build | heavy `┃` rail, **gray** (user = neutral chrome); sticky, editable prompts; `❯` in live input | `┃` rail **magenta** — "the colored actor" | gray rail; `▸/▾` folds; subagent sub-cockpits | bordered blocks + outer margins | heaviest: rail + pads + frame cols, block rows | mission-control cockpit |
| Crush | `▌` left half-block rail, violet | `▌` rail, muted mint (shared with tools); glamour markdown | tool state via `●`/`✓`/`×` glyphs on the rail register | rail-per-message, no boxes | 1–2 cols/message | synthwave maximal |
| (ancestors) | ptpython green `in`/red `out` "traffic-light IO"; shell transient prompts collapse past turns to a minimal stub, `❯` as the modern-minimal sigil | | | leading blank line "chunks scrollback into paragraphs" | | |

Cross-tool: the majority (Claude Code, aider, Crush) render the assistant as **bare markdown prose with no prefix**; **no tool boxes messages**; tool output is always visually subordinate to speech. The three separation grammars: whitespace-as-punctuation, ruled line, colored authorship rail. Note: every colored grammar (aider two-voice, Grok/Crush rails) encodes speaker in hue — which our doctrine forbids.

## 2. What doctrine already rules vs what is open

**Ruled (not re-litigable here):**
- §4.1 — *color encodes state, never speaker*. Kills aider's two-voice palette and Grok/Crush colored rails as-is. Also indicts the **current tagline**, which is role-colored (green/cyan).
- §2 — log register is zen-literate, prose-shaped, chromeless, left-anchored, never repainted. §4.2 — no boxes in the log; nesting via dot-and-hang. Kills Grok's bordered blocks.
- §4.3 — four channels, one meaning each: bold=structure, dim=supporting, italic=in-flight, reverse=selected.
- North star §3.3/§4 — blocks stay semantic units; no decoration that answers nothing.

**Genuinely open:** the *achromatic* carrier of authorship — glyph rhythm vs rail vs rule — and how the user echo relates to the composer.

**Current mechanics:** `MessageBlock.role_header/1` renders `"[#{role}]"` dim+role-colored above the markdown body; mounted by `BodyProvider.build_view(:message, …)` on expanded message blocks. Folded blocks render `Block.header_view/3`: `▸ » first-line summary`. Known gap: `Block.extract_content/2` never populates `:role`, so history currently taglines everything `[assistant]` — the tagline is both mechanistic *and* mostly constant.

## 3. Options

### A. Prompt-echo rhythm (chevron user, bare assistant)
User turn = the composer's sigil echoed into history: `❯ ` + text, hang-indented on wrap. Assistant = bare prose after a blank line, no marker at all. Authorship is carried entirely by the echo rhythm: *chevron-prefixed = you; glyph-headed (`⚙ ± ∴ ⚑`) = machinery; bare prose = the machine's voice.* Three-way partition, zero color, zero chrome.

```
❯ why does the settle step double-debit on resume?

Looking at the ledger fold, the debit replays because the seal
frontier is consulted after the fold, not before it.

▸ ⚙ mix test test/ledger_test.exs · exit 0 · 4.2s

Fixed: the fold now starts at the frontier offset. One debit,
offset 4182.
```

Cost: 0 extra rows (blank-line rhythm already exists), 2 cols on user lines only. Tools/system stay flush-left glyph-headed blocks under the assistant prose, dot-and-hang inside. Narrow widths: unaffected (2-col hang). ANSI16/ASCII: `❯` → `>`, nothing else degrades. Folds: a folded user paste is `▸ ❯ first line…` (role glyph replaces the `»` kind glyph); assistant folded stays `▸ » summary`. Prominence dimming applies to the whole line uniformly (chevron fades with its block, matching `Block`'s single-fg rule); unread divider is an unrelated dim rule and coexists.

### B. Achromatic user rail
User turns carry a dim `▌` rail + space (2 cols), body indented; assistant flush-left bare prose. Grok/Crush's rail with the hue removed — authorship by *weight and position*.

```
▌ why does the settle step double-debit on resume?
▌ it only happens after a crash mid-settlement.

Looking at the ledger fold, the debit replays because…

▸ ⚙ mix test test/ledger_test.exs · exit 0 · 4.2s
```

Cost: 2 cols on every user line (multi-line prompts pay per row); 0 rows. Degrades: `▌` → `|`; fine at 80 cols. Folds/salience as in A. Risk: a dim gray rail is exactly one hue away from Crush/Grok — themes will be tempted to color it, and §4.1 then erodes by costume. Also the rail is a *rim* idiom (heavy rails = ownership/selection, §4.2) bleeding into the log.

### C. Ruled turn boundary (aider)
One dim hairline `─────` row before each user turn; both voices otherwise bare.

```
────────────────────────────────────────
why does the settle step double-debit on resume?

Looking at the ledger fold, the debit replays because…
```

Cost: 1 row per turn, 0 cols. Degrades to `----`. But the rule marks *where* turns break, not *who* speaks — user and assistant prose remain typographically identical, so it needs a second device anyway; and a full-width rule collides with the unread divider's vocabulary (two different dim horizontal lines meaning different things = channel overload).

## 4. Recommendation: A — RATIFIED, then AMENDED by V (2026-07-17)

**V's outer-contour amendment (ratified; supersedes "assistant = bare
unmarked prose"; landed on `integration/harness-endgame`):**

1. Dialogue markers live in the **outer contour**: the user's `❯` sits at
   column 0, touching the border (inside the 1-cell margin area), user
   text at the 2-cell content indent (column 2), wraps hang-aligned at
   column 2.
2. **Assistant turns carry the inverse chevron `❮`** at the same outer
   position; assistant prose at column 2. The mirrored pair IS the
   speaker grammar — all dialogue content sits uniformly at the 2-cell
   indent.
3. Capability fallback degrades the pair together: `❯`/`❮` → `>`/`<`
   under `unicode: :none`; all four single-cell (TextMeasure-pinned).
4. The composer's live `❯` already sat at column 0 with the draft at
   column 2 — unchanged; one sigil source per speaker (`model.sigil` /
   `model.reply_sigil`, decided once from the capability record).
5. Both sigils bold (structure channel), zero color. Sigil fade is bound
   to the block's own body fade (single-fg rule): the mounted message
   body is unfaded today, so sigils are bold-only — additionally forced
   by the live/fixture byte-parity guard (seal-time prominence grade is
   reveal-cadence-dependent; sealed bytes must not be). Blank-row rhythm
   unchanged as the turn separator.
6. Machinery blocks (tool/system glyph headers) keep the plain 1-column
   margin — dialogue is marked at the contour, machinery stays inside
   the frame. Folded headers (`▸ ❯ …` / `▸ » …`) keep the margined
   header column.

*(Original pre-amendment recommendation kept below for the record.)*

- **Closes the loop with the composer.** The live prompt sigil collapsing into a `❯`-echo in history is the transient-prompt principle the corpus names explicitly ("reserve ornament for the present; collapse past turns to minimal stubs" — gap-prompt-statusline §3/§13). The echo is evidence of what you said, in the register you said it.
- **It is the trusted register.** The chromeless-literate grammar (bare assistant prose, subordinated glyph-headed machinery) is the majority convention and the corpus's most-loved reading rhythm; we get it without the hue-coded speakers the doctrine forbids. The identity inversion survives achromatically: the *user* gets the one glyph, the machine speaks unmarked — mirror-image of Grok's "you are neutral chrome," fitting a harness whose voice dominates the log.
- **Cheapest and most degradable.** 2 cols, 0 rows, one ASCII fallback; nothing for flat mode to apologize for.
- B is the fallback if V wants user turns findable in a fast vertical scan of a very long transcript (a rail reads at higher speed than a first-line glyph for multi-line prompts). C is not recommended.
- Typography: chevron **bold** (structure channel), user text normal weight. No color on either role; the hue budget stays with state.

## 5. Mechanical changes

1. `lib/raxol/ui/components/harness/message_block.ex` — delete `role_header/1`/`role_accent/1`; `render/2` branches on role: `:assistant` → body only; `:user` → `❯ `-prefixed first line with 2-col hang indent (share the sigil constant with `Composer` so echo and prompt can never drift).
2. `lib/raxol/ui/components/harness/block.ex` — populate `:role` in `extract_content(:message, …)` (closes the documented gap in `body_provider.ex`); `kind_glyph/1` for `:message` becomes role-aware (`❯` user / `»` assistant) so folded headers stay honest.
3. `body_provider.ex` — thread the now-real `:role` (no more constant `:assistant` default in practice); moduledoc gap note removed.
4. Blank-line rhythm between turns: confirm the surface emits it (it is the load-bearing separator now); pin in a buffer test alongside ANSI16 `>` fallback and prominence-fade of the chevron.

Corpus gaps flagged for honesty: Claude Code's and Gemini's *historical* user-echo styling are undocumented in the dossiers; the recommendation leans on aider, Grok, and the transient-prompt doctrine instead.
