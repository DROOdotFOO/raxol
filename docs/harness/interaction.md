# Harness Interaction: transcript, input, commands, approvals

## Transcript marks

The transcript is a list of blocks, and `Raxol.UI.Components.Harness.Block`
renders each header as a fold icon plus a one-cell kind glyph plus a truncated
summary. The glyph vocabulary is fixed: `»` message, `∴` reasoning, `⚙` tool
call, `±` diff, `⚑` approval, and `◆` for anything the reader does not
recognize (the `:opaque` forward-compatibility kind an unknown wire `kind`
normalizes to). The fold icon is `▾` expanded, `▸` folded.

- The header prefix is budgeted with `Raxol.UI.TextMeasure.display_width/1`,
  never `String.length/1`, so a CJK summary cannot overrun its row.
- The glyph carries kind; color carries prominence. A header fades toward the
  neutral chrome baseline `#B4B4B4` when `context[:prominence]` says to, and
  its style is byte-identical at full prominence.
- A user prompt is never a block. `turn_started` is structural and produces
  nothing in the fold (`Raxol.Harness.Projection.BlockBuilder`); the export
  path re-attaches it, heading each turn's blocks with `"> " <> prompt`
  (`Raxol.Agent.Code.Replay.transcript_text/1`).

## The input zone

`Raxol.UI.Components.Harness.Composer` wraps
`Raxol.UI.Components.Input.MultiLineInput` with harness submit semantics; it
does not reimplement editing. Cursor movement, selection, and text mutation
stay in MultiLineInput. No absolute width is persisted on the composer struct:
`render/2` derives MultiLineInput's width from `context[:available_width]` on
every call and re-wraps, so a resize cannot leave a stale wrap behind.

- **Submit.** Enter submits when the draft is a single logical line (no
  embedded newline, regardless of visual wrap) and non-empty after trimming.
  Shift+Enter or Alt+Enter inserts a newline. Many terminals do not encode
  those distinctly, so the modifier-independent inlet is backslash
  continuation: a line ending in `\` plus Enter consumes the backslash and
  inserts a newline. The escape rule counts the trailing backslash run, odd
  continues and even submits with the run halved, so a literal trailing
  backslash round-trips. `force_submit/1` is exposed for a consumer to wire an
  unconditional submit key.
- Every incoming event is normalized through
  `Raxol.UI.Harness.InputEvent.normalize/1` first, so a keypress from the
  termbox driver, the ANSI parser, and `Event.key_event/3` in tests all reduce
  to one shape before anything decides what it means.
- Bracketed paste routes `%Event{type: :paste}` straight into MultiLineInput's
  `{:clipboard_content, text}` message, so pasted newlines are inserted
  verbatim in one edit and never reach the submit decision.
- Input history recall is a bounded ring (default 100), walked by Up at the
  first visual line and Down at the last; the in-progress draft is saved on
  the first Up so Down restores it.
- The queued-steer banner is one dim truncated line above the prompt,
  `⏸ steer queued for next boundary: <text>`.
- `$EDITOR` handoff is the Ctrl+E chord. `Raxol.Harness.EditorSuspend` is the
  pure suspend/resume state machine (step sequence and per-step compensation
  as plain data, no IO); `Raxol.Harness.EditorSession` is the thin impure
  runner that interprets each step against the real device. On editor exit 0
  the edited draft replaces the composer value; any other outcome keeps the
  original and surfaces a one-frame footer notice.
- Input is pinned at the screen bottom: the composer lives in the DECSTBM
  footer, outside the scrolling history region.

## Keymap and command routing

- **Keymap first.** `Raxol.UI.Harness.Keymap.resolve/2` is a pure
  `(InputEvent, context) -> command | :passthrough` over the `binds/0` data
  table, and `Raxol.Harness.Surface.handle_input/2` calls it before ever
  touching the Composer. Only `:passthrough` reaches
  `Composer.handle_event/3`. The `:always` binds (ESC interrupt, Tab steer,
  Ctrl+E edit draft, Ctrl+P palette) fire regardless of `composing?`, because
  ESC must never be swallowed by whatever holds focus: interrupt is a
  supervised kill and must reach the lane rather than queue behind typing.
  Clause order in `binds/0` is load-bearing: the `guard: :overlay` ESC entry
  precedes the `guard: :always` ESC entry, so ESC dismisses an open overlay
  before it can interrupt a turn.
- **Command bifurcation.** A resolved command is a plain
  `%{type: atom(), payload: map()}` map, the same field names
  `Raxol.Agent.Command` uses, so main raxol mints one without depending on
  `raxol_agent`. `:interrupt` and `:steer` are the lane-crossing types and
  leave through the `:command_sink` closure onto `Raxol.Harness.SessionLane`;
  `:fold_toggle`, `:jump_next`, `:jump_prev`, `:expand_diff`, `:open_panel`,
  `:overlay_dismiss`, `:open_palette`, and the three `:open_*_picker` types
  never leave the UI lane.
- The Surface checks belief before acting on a command: an open overlay
  freezes the composer buffer mid-pick, so a `:steer` or `:edit_draft` built
  from that hidden state is dropped rather than sent, and a second
  `:open_palette` while an overlay or a diff expansion is open answers with a
  typed refusal (`:overlay_already_open`, `:expansion_open`).
- A fresh session is the default per launch; resuming is explicit.
  `Raxol.Agent.Code.Launcher` parses `--continue` (most recently updated
  session), `--resume ID`, `--sessions`, and `--replay ID`.
- **The command palette.** Ctrl+P opens it, and its entries are exactly
  `Keymap.palette_binds/0`, the labeled subset of the bind table in table
  order, plus the two focus transitions that exist only at the assembly layer.
  A bind opts in by declaring a `label:`, so nothing decides palette
  membership except the table itself. Picking an entry dispatches through the
  same path a keypress takes, so there is no second execution mechanism a
  palette pick could diverge on.
- **Slash commands** are a separate vocabulary, owned by the coding TUI rather
  than by the keymap. `Raxol.Agent.Code.App` routes any submitted line
  starting with `/` into per-command function clauses: `/help`, `/login`,
  `/logout`, `/model`, `/plan`, `/clear`, `/compact`, `/rewind`, `/context`,
  `/usage`, `/sessions`, `/resume`, `/fork`, `/rename`, `/export`,
  `/transcript`, `/copy`, `/find`, `/share`, `/mcp`, `/hooks`, `/inspect`. An
  unmatched name answers with an `unknown command` notice pointing at
  `/help`. In a jailed multi-tenant session `/login`, `/logout`, and `/copy`
  refuse, because they reach host-global state the keyboard principal does not
  own.

## The approval footer

Two approval surfaces ship, for two different hosts.

`Raxol.UI.Components.Harness.ApprovalPrompt` is the Component-tree one: it
renders the action, its blast radius (an embedded
`Raxol.UI.Components.Harness.BlastRadiusPreview`), and four options matching
the `:once`/`:session`/`:root` scopes plus deny. Up/Down and the digit keys
`1`-`9` move the selection and digits jump straight to an index rather than
acting as a shortcut, so Enter is the one and only way to confirm and a
mistimed digit cannot fire a decision by itself. It is controlled: state
arrives as props, and `handle_event/3` emits
`{:approval_decision, %{decision, scope}}` for the host to act on. No option
carries color-by-danger; the only visual differentiator between rows is which
one holds keyboard focus, so the safe default is never fighting the
destructive one visually.

`Raxol.Agent.Code.App` uses a one-line footer instead, naming the tool and
its three answers, answered by `a` (allow once), `s` (always), `d` (deny),
with `y`/`n` aliases, or by Escape. While an approval is pending, printable
characters, Enter, and Backspace are all inert, so an answer cannot be typed
into the prompt buffer by accident.

Both shapes park a blocked tool worker and release it with the answer, and each
owns its own park. `Raxol.Agent.Code.App` keeps `pending_approval` as
`%{ref, from, name}` and answers with `{:authorize_decision, ref, verdict}` to
the worker that asked; Escape denies. `Raxol.Agent.Harness.SessionInbox` is the
other one: it parks on a `GenServer.call` keyed by `request_id` before the
consequential tool and replies to that caller later, and its `pending` never
outlives the turn that parked it, including a die-mid-approval `:DOWN`. Nothing
outside its test starts a `SessionInbox` yet, so the TUI path is the one in use.

## Navigation

- One picker shape serves every pick-one-of-N on the footer substrate.
  `Raxol.UI.Harness.OverlayPicker` is the pure primitive: a query row plus a
  scrollable window of matches, anchored above the composer, never a centered
  modal over history. The command palette (Ctrl+P), jump (`g`), the session
  picker (`s`), and transcript search (`/`, labeled from
  `Block.search_text/1`, so it matches kind, summary, and body text) all opt
  into `OverlayPicker.fuzzy_filter/3`, the `Raxol.UI.ListScorer` adapter;
  hosts that do not opt in keep the substring default. `g`, `s`, and `/` are
  plain letters gated `:not_composing`, so they never steal a character out of
  the composer. `Raxol.UI.Components.Harness.Picker` is the sibling for the
  other substrate, the Component-tree variant that ranks with
  `ListScorer.rank/4` directly.
- One overlay is open at a time; the second one is refused, by name, instead
  of stacking.
- Returning is evidential: `Raxol.Harness.UnreadDivider` records exactly one
  "N new since you looked" span when the operator looks away (`blur/2`) and
  completed blocks keep arriving, rendered as a full-width rule (`line/2`) in
  the repaintable footer and never in sealed history. Every decision in it is
  a pure function of caller-injected block offsets: no clock, no timestamp, no
  gap threshold.
