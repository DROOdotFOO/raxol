# Harness Interaction: speakers, input, commands, approvals

## Speaker separation

Mirrored outer-contour chevrons carry authorship, and nothing else does. The
user is `❯` at column 0, touching the border; the assistant is `❮` at the same
outer position; all dialogue content sits at one uniform 2-cell indent. Both
sigils are **bold** (the structure channel) with **zero color**: color encodes
state, never speaker.

- The pair degrades together: `❯`/`❮` fall back to `>`/`<` under
  `unicode: :none`, and all four are single-cell (pinned through
  `Raxol.UI.TextMeasure`).
- There is one sigil source per speaker (`model.sigil` / `model.reply_sigil`),
  and the live composer's `❯` shares that constant, so a sealed chevron in the
  transcript can never drift from the prompt that produced it.
- Machinery blocks (a tool `⚙`, system glyphs) keep the plain margin: dialogue
  is marked at the contour, machinery stays inside the frame. A blank-row rhythm
  separates turns.

The primitive is `Raxol.UI.Components.Harness.Indication.speaker/3`, laid out by
`Raxol.UI.Components.Harness.TranscriptView`.

## The input zone

`Raxol.UI.Components.Harness.Composer` wraps
`Raxol.UI.Components.Input.MultiLineInput` with harness submit semantics; it
does not reimplement editing. The composer is the single truth of the *logical*
draft (the visual rows are re-derived from a WrapMap on every render and never
written back) so readers read the logical value and writers make surgical
logical edits, never whole-buffer rewrites.

- **Submit.** Enter submits when the draft is a single logical line.
  Shift+Enter or Alt+Enter inserts a newline; where a terminal cannot encode
  those (tmux, SSH, mosh), a trailing backslash before Enter is the
  modifier-independent inlet to the first newline.
- Every incoming event is normalized through
  `Raxol.UI.Harness.InputEvent.normalize/1` first, so a keypress from the
  termbox driver, the ANSI parser, and the test API all reduce to one shape
  before anything decides what it means.
- Bracketed-paste fidelity, input-history recall, and a queued-steer banner
  live here. `$EDITOR` suspend and resume run through the pump's editor bracket.
- Input is pinned at the screen bottom (chat semantics).

## Keymap and command routing

- **Keymap first.** `Raxol.UI.Harness.Keymap.resolve/2` is a pure
  `(InputEvent, context) -> command | :passthrough` over a data table, not a
  `cond` ladder: a chord later grows a match field without restructuring
  dispatch. The always-live binds (ESC = interrupt, Tab = steer, Ctrl+E = edit
  the draft in `$EDITOR`) fire regardless of `composing?`, because ESC must
  never be swallowed by whatever holds focus: interrupt is a supervised kill,
  not a cooperative flag queued behind typing.
- **Command bifurcation.** Lane-crossing commands (interrupt, steer, submit,
  approval) leave as `Raxol.Harness.Directive.Lane`; fold, jump, and scroll
  stay surface-local. `update/2` checks belief *before* minting a directive: 
  a submit during a running turn, or a second steer while one is in flight,
  renders an honest notice instead of a directive.
- ^C is always a double-press; `q`-on-empty is a single-press. A fresh session
  is the default per launch; resuming is always explicit.
- **Slash commands.** `Raxol.UI.Harness.CommandRegistry` is the typed
  vocabulary. `/help`, the autocomplete popup
  (`Raxol.UI.Components.Harness.CommandAutocomplete`), and the executed behavior
  all read the same registry, so what the popup offers is provably what
  `run/1` would find. The popup can never show a command that would not run.

## The approval footer

An approval is answered by `Raxol.UI.Components.Harness.ChoicePrompt`: a
confirm/cancel pair plus a free-text third way, every row fronted by the
dialogue chevron (a live question keeps the chevron, extended rather than
replaced).

```
❯ confirm [enter]
❯ cancel [escape]
❯ ▏explain what to do instead
```

- **Idle** (empty draft): `[enter]` confirms and `[escape]` cancels, from
  anywhere.
- **Typing** (non-empty draft): the hints disappear because the keys are
  repurposed: Enter submits the draft, Escape clears it (and the hints
  return). Shift/Alt+Enter inserts a newline; the third way is a real
  multi-line `Composer`, so it is never more than one keystroke away.
- **Arrows** move focus `confirm ⇅ cancel ⇅ input`; inside a multi-line draft
  the arrows navigate the text first and only hop out at the boundary.

The component is controlled (state in via props, commands out
(`{:component_event, id, :confirm | :cancel | {:submit, text}}`)) and the host
owns the lifecycle. The answer resolves through the existing approval pipeline:
`Raxol.Agent.Harness.SessionInbox` parked the tool loop on a blocking await
keyed by `request_id`, and the answer replies to it and unblocks the tool.
Prominence follows the question: the focused row's chevron and the `[enter]` /
`[escape]` hints are bold at full strength (they are the answer affordances) 
while unfocused rows and the placeholder sit at the faded register.

## Navigation

- One picker shape serves every pick-one-of-N:
  `Raxol.UI.Components.Harness.Picker` over `Raxol.UI.ListScorer`: the command
  palette, jump, the session picker, and transcript search (fuzzy over block
  content) are all the same code path. One overlay is open at a time.
- Returning is evidential: `Raxol.Harness.UnreadDivider` marks where you left
  off, and the restoration on reattach renders what changed as evidence, never
  a success toast. An uncertain or gapped tip is rendered as uncertain rather
  than silently presented as canonical.
