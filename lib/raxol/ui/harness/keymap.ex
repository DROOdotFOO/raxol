defmodule Raxol.UI.Harness.Keymap do
  @moduledoc """
  Harness keybind layer: canonical input event + mode context → typed
  command, or `:passthrough`. T12 in `harness-ui-roadmap.md`.

  ## The seam this closes

  `Raxol.UI.Harness.InputEvent` (T27) already reduces every driver key-event
  shape to one canonical `t()`. This module is the next layer: it decides
  what a *normalized* keypress *means* -- interrupt the running turn, queue
  a steer, toggle a block's fold, move focus between blocks -- without
  knowing anything about drivers, terminals, or ANSI. `resolve/2` is a pure
  function: `(InputEvent.t(), context()) -> command() | :passthrough`. It
  never touches process state, never renders, never calls into a live
  component.

  ## Why a data table, not a `cond`/`case` ladder

  `binds/0` returns the keymap as a plain list of maps -- match spec +
  guard name + command type, no closures. `resolve/2` walks it. Two things
  fall out of that for free:

    * **tui-steal rule** (chords replace keys later without restructuring
      the dispatch logic -- a bind's `match` grows a `mods:` requirement,
      the walking loop does not change). This is not aspirational: a
      `key:`-kind bind with no declared `mods:` matches only a BARE
      keypress (no ctrl/alt/meta held) -- Ctrl+Tab, Alt+Tab, and Meta+Tab
      all fall through to `:passthrough` rather than firing `:steer`,
      because they are shortcuts wired to something else, not "Tab". An
      entry that DOES declare `mods:` (a full `InputEvent.mods()` map)
      requires an EXACT match against the normalized event's `mods`
      instead of the bare-keypress default -- that is the chord's match
      spec growing a field, per the promise above, with `resolve/2`'s
      walking loop untouched. Shift alone is not restricted by the
      bare-keypress default (mirrors `InputEvent.text?/1`: shift-only is
      not a shortcut), so Shift+Tab still resolves through the plain
      `:tab` bind. `char:`-kind binds need no separate mods check --
      `InputEvent.printable_char/1` already returns `nil` whenever
      ctrl/alt/meta is held, so a modifier-qualified letter never reaches
      the char-kind match branch in the first place.
    * **Invocation parity with the command palette**: the palette
      enumerates `palette_binds/0` (the labeled subset of `binds/0`) and
      invokes `command_for/2` on any entry directly (a command palette is
      just another way to select a bind, not a second source of truth for
      what commands exist). `command_types/0` is the exact union this
      module can ever emit -- there are no commands hiding outside the
      table.

  ## The composer-focus guard

  Two classes of bind:

    * **Always live** -- fire regardless of `context.composing?`. ESC
      (`:interrupt`), the steer-submit key (`:tab`, `:steer`), and the
      Ctrl+E chord (`:edit_draft` -- hand the composer draft to
      `$EDITOR`) are in this class, because all three are non-printable
      control keys/chords that can never be part of typed text, and ESC
      in particular must never be swallowed by whatever currently has
      focus (AD-1: interrupt is a supervised kill now, not a cooperative
      flag queued behind typing). Ctrl+E is the first `char:`-kind chord
      in the table -- a `char:` bind that declares `mods:` requires an
      EXACT modifier match against the normalized event (mirroring the
      `key:`-kind rule below) instead of the printable-char path, which
      is nil under ctrl by design.
    * **Guarded by `not composing?`** -- the block-navigation binds
      (`fold-toggle`, `jump_next`, `jump_prev`, `expand_diff`). These use
      plain printable letters (`z`/`j`/`k`/`e`), and a prior flat-keymap
      prototype's named bug (see `harness-ui-STATE.md`, "the demo's flat
      keymap steals j/k/s/z from typing") was firing them unconditionally,
      stealing those letters out of the composer's typed text. Gating them
      on `composing?` is the fix: they only resolve to a command when
      focus is NOT the composer (browsing the transcript), and fall
      through to `:passthrough` (ordinary character insertion) while
      composing. An OPEN OVERLAY suppresses them the same way (the guard
      consults `overlay_open?` too): with a picker open, `z`/`j`/`k`/`e`
      are filter text the overlay must receive, never commands fired at
      the transcript hidden behind it -- and the picker's natural open
      path is exactly transcript-browse mode (`composing?: false`), where
      a composing?-only guard would fire them (see the "overlay-open ESC
      capture" section). `e` (expand the focused diff block full-screen)
      rides the exact same guard for the exact same reason: it is plain
      typed text while composing, and `Raxol.Harness.Surface` reports its
      own footer-region expansion through the SAME `overlay_open?` context
      flag an open overlay picker already uses (see that module's "Full-
      screen diff expansion" section) -- so `e` is suppressed while an
      expansion is already open too, not just while an overlay is. It
      cannot collide with the Ctrl+E editor-handoff chord below:
      `InputEvent.printable_char/1` is `nil` whenever ctrl is held, so a
      Ctrl+E keypress never reaches this bind's `char:`-only match clause
      at all -- the two live on entirely disjoint matching paths, not a
      priority order. The same `:not_composing` guard governs the
      picker-opening binds below (`g`/`s`/`/` -- jump, session, and
      search) for the identical reason: each is a plain printable letter
      that must resolve to typed text while composing, and to filter text
      -- never a second picker opening underneath the first -- while an
      overlay is already open.

  ## The overlay-open ESC capture (order is load-bearing)

  An open `Raxol.UI.Harness.OverlayPicker` (hosted by
  `Raxol.Harness.Surface.open_overlay/3`) needs ESC to close ITSELF, not
  fire the global interrupt -- an overlay is transient UI-local state, and
  a stray ESC-while-picking must never look like a supervised kill of the
  running turn. `binds/0`'s FIRST entry (`%{key: :escape, command_type:
  :overlay_dismiss, guard: :overlay}`) captures exactly that, ahead of the
  `:always`-guarded `%{key: :escape, command_type: :interrupt}` entry
  later in the table -- `resolve/2` walks `@binds` in order and takes the
  first match, so this is the one place in this module where table ORDER
  is part of the contract, not incidental (and it is enforced
  structurally: a compile-time check below `@binds` raises if the two
  escape entries are ever reordered or a third appears). The guarded
  transcript binds honor the overlay too -- `:not_composing`'s guard
  consults `overlay_open?` alongside `composing?`, so `z`/`j`/`k` with a
  picker open are filter text even from transcript-browse mode
  (`composing?: false`), never fold/jump commands fired at state hidden
  behind the overlay. Enter/printable chars/arrows
  are deliberately NOT added to the table for the overlay: they stay
  `:passthrough` even with `context.overlay_open?: true` (see
  `matches?/3`'s test coverage) -- the assembly layer (`Surface`) is the
  one that already has the picker's state and routes those to
  `Raxol.UI.Harness.OverlayPicker.handle_key/2` itself.

  The `guard: :overlay` fail-safe direction is the OPPOSITE of
  `:not_composing`'s, and deliberately so: `guard_passes?/2` reads
  `Map.get(context, :overlay_open?, false)` -- absent or `false` means
  "no overlay is open," so ESC falls through to the `:always` interrupt
  bind exactly as it always has. A caller that never sets `overlay_open?`
  (every existing caller, before this change) is completely unaffected --
  nothing load-bearing changes for them. Only an explicit
  `overlay_open?: true` opts INTO the dismiss reading. This is the safe
  direction here for the reason `:not_composing`'s fail-safe is the
  OPPOSITE way: the dangerous failure mode for THIS guard is silently
  swallowing the global ESC-interrupt when no overlay is actually open (a
  caller bug would make ESC do nothing at all, a much worse silent
  failure than dead navigation keys), so the guard must default to
  "closed" and require an explicit opt-in to ever capture ESC.

  ### Fail-safe default: missing `composing?` means composing

  A caller that omits `composing?` from `context()` entirely (forgets it,
  or is a code path -- palette invocation, a future non-composer
  interaction -- that never renders a composer at all) gets the
  fail-SAFE reading: **treated as composing**, so the guarded binds
  (`fold-toggle`, `jump_next`, `jump_prev`) resolve to `:passthrough`,
  never firing. This is deliberately asymmetric with what would be
  simplest to implement (`Map.get(context, :composing?, false)`, "missing
  means not composing"), because the two failure directions are not
  equally bad:

    * **Fail-safe (this module's choice)**: a caller that never sets
      `composing?` gets dead `j`/`k`/`z` navigation. That is immediately
      discoverable -- the keys visibly do nothing -- and ESC/Tab are
      unaffected (`:always` binds never consult `composing?`), so nothing
      load-bearing is silently broken.
    * **Fail-open (the rejected alternative)**: a caller that never sets
      `composing?` gets the guarded binds firing unconditionally --
      exactly the named prototype bug this module exists to fix (see
      below), except now triggered by an *absent* flag instead of a
      flat keymap with no guard at all. Typed `j`/`k`/`z` would silently
      turn into fold-toggle/jump commands instead of inserting characters,
      with no crash and no visible error -- the worst kind of bug, because
      it looks like normal typing until content goes missing.

  Only an explicit `composing?: false` opts a caller INTO guarded-bind
  resolution. `context()` also normalizes a bare `nil` (e.g. "no block
  focused" callers that pass `nil` instead of `%{}`) to `%{}` before any
  guard consults it, so the crash surface is not bind-dependent -- see
  `resolve/2`'s doc.

  `context()` is deliberately small: `composing?` (is the composer
  focused/receiving text), `streaming?` (is a turn currently running), and
  `focused_block_id` (which block, if any, a fold/jump command should
  target). `streaming?` does not gate ESC -- interrupt is unconditional and
  immediate (roadmap: "ESC during streaming emits interrupt, not
  buffered"); sending it when nothing is running is a harmless no-op
  downstream, and NEVER emitting it because of a mode check is the failure
  mode AD-1 exists to rule out.

  ## Steer-submit: why Tab, not a modified Enter

  Plain Enter (single-line, non-empty buffer) already submits as `:prompt`
  entirely inside `Raxol.UI.Components.Harness.Composer` (T11) -- that
  path never reaches this module. Steer needs a *different* key, and it
  must be one that can fire *while the user is mid-composing* (queuing a
  steer message is the whole point), so it cannot be a plain printable
  character (those are text, full stop -- see the guard above). `Tab` is
  the documented precedent for exactly this shape of decision
  (`harness-spec-protocol.md` / `harness-spec-frontend.md`: "the corpus's
  named steer-vs-interrupt primitive (Tab=queue / Enter=now)"); it also has
  a first-class canonical key atom (`:tab`) verified across the real
  termbox and ANSI wires by T27, and Composer does not otherwise bind it.

  ## Command shape: reusing U3's channel without a compile-time dependency

  `packages/raxol_agent` owns the live command struct
  (`Raxol.Agent.Command`, `%Command{type: atom(), payload: map()}`,
  U3/#543) and the harness protocol's validation seam (`decode/1`). Main
  `raxol` does not (and per the package dependency graph, must not) depend
  on `raxol_agent` -- this module ships in the harness-UI lane, which is
  fixture-driven and requires no agent lane (T13a's own acceptance: "No
  agent lane required"). Per the documented cross-package convention
  (`CLAUDE.md`: "Struct patterns across package boundaries use map
  patterns... instead of struct patterns"), `command()` here is a **plain
  map** with the *same field names* U3 shipped -- `%{type: atom(), payload:
  map()}` -- not the struct. This is not a parallel command type: it is the
  identical wire shape, one `struct(Raxol.Agent.Command, cmd)` away from
  the real thing at the one boundary (T13b's live wiring) that actually
  depends on `raxol_agent`.

  `:interrupt` mirrors U3's existing type verbatim (empty payload, same as
  U3's own `:interrupt` validation). `:steer` mirrors the protocol spec's
  documented (not yet decoded by U3) `steer` type
  (`harness-spec-protocol.md` §4: `%{text}`) -- T12 emits an empty payload
  since it has no access to composer text (a pure keymap, per the roadmap,
  takes the event + a *small* mode context, not component state); the
  assembly layer that already has the composer's buffer fills `payload.text`
  in before dispatch. `:fold_toggle` / `:jump_next` / `:jump_prev` are new
  vocabulary this unit adds (the task's own named example of "a needed
  command kind [that] doesn't exist yet") -- transcript-navigation actions
  that never need to leave the UI lane, so they ride the same channel for
  the command palette's invocation parity without ever being routed to
  `raxol_agent`. `:open_palette` / `:open_jump_picker` /
  `:open_session_picker` / `:open_search_picker` are the same kind of
  UI-local vocabulary, added for the pickers below -- `:open_search_picker`
  (`/`) is gated `:not_composing` exactly like `:open_jump_picker`/
  `:open_session_picker` (`g`/`s`): transcript-browse only, filter text
  while an overlay is open, typed text while composing.

  ## Palette derivation (the `label` field)

  A bind opts into the command palette by declaring a `label:` -- a short,
  human-readable string. `palette_binds/0` is exactly the labeled subset
  of `binds/0`, in table order; nothing else decides what appears in the
  palette. The overlay-only `:overlay_dismiss` bind is deliberately left
  unlabeled: the palette IS itself an overlay, so listing "dismiss the
  overlay" as something the palette can invoke on itself would be
  nonsensical. Every other bind that names a discrete, invokable action
  carries a label; adding a new labeled bind to the table is the only
  change needed to make it appear in the palette.
  """

  alias Raxol.UI.Harness.InputEvent

  @type context :: %{
          optional(:composing?) => boolean(),
          optional(:streaming?) => boolean(),
          optional(:focused_block_id) => term(),
          optional(:overlay_open?) => boolean(),
          optional(:approval_pending?) => boolean(),
          optional(:composer_empty?) => boolean()
        }

  @type command_type ::
          :interrupt
          | :steer
          | :edit_draft
          | :fold_toggle
          | :jump_next
          | :jump_prev
          | :overlay_dismiss
          | :open_palette
          | :open_jump_picker
          | :open_session_picker
          | :open_panel
          | :expand_diff
          | :open_search_picker
          | :approval_answer
          | :scroll_up
          | :scroll_down
          | :scroll_to_tail

  @type command :: %{type: command_type(), payload: map()}

  @type guard :: :always | :not_composing | :overlay | :awaiting_approval

  @type bind :: %{
          required(:command_type) => command_type(),
          optional(:key) => atom(),
          optional(:char) => String.t(),
          optional(:guard) => guard(),
          optional(:mods) => InputEvent.mods(),
          optional(:label) => String.t(),
          optional(:payload) => map()
        }

  # The live-approval answer binds (Track D). All plain printable keys,
  # all guarded `:awaiting_approval` -- they resolve to an answer ONLY when
  # a live approval block is holding the frontier AND the composer is not
  # focused, so they never steal a letter or digit out of typed text (the
  # exact no-steal contract `:not_composing` enforces for `z`/`j`/`k`,
  # tightened further by also requiring a pending question). `y`/`n` are
  # aliases for the first allow/deny option; `1`-`9` pick the Nth option by
  # position. The payload carries the raw ANSWER HINT; `Raxol.Harness.
  # Surface` resolves it against the live block's actual options into a
  # concrete `option_id` (the referent), refusing honestly if it cannot.
  # Deliberately UNLABELED (no palette entry): an answer is meaningful only
  # against a live question on screen, never as a free-floating palette
  # action -- same reasoning that leaves `:overlay_dismiss` unlabeled.
  @approval_binds [
    %{
      char: "y",
      command_type: :approval_answer,
      guard: :awaiting_approval,
      payload: %{answer: :allow}
    },
    %{
      char: "n",
      command_type: :approval_answer,
      guard: :awaiting_approval,
      payload: %{answer: :deny}
    }
    | for {digit, index} <-
            Enum.with_index(~w(1 2 3 4 5 6 7 8 9)) do
        %{
          char: digit,
          command_type: :approval_answer,
          guard: :awaiting_approval,
          payload: %{answer: {:option, index}}
        }
      end
  ]

  # Plain keys only (v1) -- see moduledoc's "tui-steal rule": a future chord
  # (e.g. requiring :ctrl) is a new field on the matching entry, not a
  # restructure of `resolve/2`. Order matters for exactly ONE reason now
  # (see the moduledoc's "overlay-open ESC capture" section): the
  # `guard: :overlay` escape entry MUST precede the `guard: :always`
  # escape entry, so `resolve/2`'s first-match walk resolves ESC to
  # `:overlay_dismiss` while the overlay is open before ever reaching the
  # interrupt bind. Every other pair of entries still can never both
  # match a single normalized event, so their relative order remains
  # incidental.
  @binds [
           %{key: :escape, command_type: :overlay_dismiss, guard: :overlay},
           %{
             key: :escape,
             command_type: :interrupt,
             guard: :always,
             label: "interrupt turn"
           },
           %{
             key: :tab,
             command_type: :steer,
             guard: :always,
             label: "queue steer"
           },
           # Ctrl+E: hand the composer draft to $EDITOR. A `char:`-kind bind that
           # DECLARES `mods:` -- the tui-steal promise cashing in for char-kind
           # binds (see the moduledoc): the match spec grew a `mods:` field, the
           # walking loop did not change. A ctrl chord can never be typed text
           # (`InputEvent.printable_char/1` is nil under ctrl), so this is
           # `:always`, same class as ESC/Tab; the command acts on the composer's
           # buffer whether or not the composer has focus.
           %{
             char: "e",
             mods: %{ctrl: true, alt: false, shift: false, meta: false},
             command_type: :edit_draft,
             guard: :always,
             label: "edit draft in external editor"
           },
           # Scrollback for the `:full_viewport` surface's owned virtual
           # scrollback (inert in the inline/flat tiers, which use the
           # terminal's OWN native scrollback). PgUp/PgDn are ALWAYS live
           # (non-printable named keys -- they can never be typed text, and
           # transcript scroll takes priority over a multi-line draft's own
           # paging while composing, V's ruling). No `label:` -- they are
           # live keys, not palette entries (a palette entry inert in three
           # of four modes would be dishonest). See
           # `Raxol.Harness.Surface`'s `:scroll_up`/`:scroll_down`/
           # `:scroll_to_tail` dispatch.
           %{key: :page_up, command_type: :scroll_up, guard: :always},
           %{key: :page_down, command_type: :scroll_down, guard: :always}
           # The live-approval answer binds are spliced in HERE, ahead of every
           # `:not_composing` letter bind below. Order is load-bearing for exactly
           # one collision: `n` is also the plan-panel bind further down. First
           # match wins (`resolve/2` walks in order), so while a question is live
           # (`:awaiting_approval` passing) `n` must resolve to DENY, not open the
           # plan panel -- putting the approval binds first guarantees it, and
           # when no question is live the `:awaiting_approval` guard fails and `n`
           # falls straight through to the plan-panel bind exactly as before.
         ] ++
           @approval_binds ++
           [
             %{
               char: "z",
               command_type: :fold_toggle,
               guard: :not_composing,
               label: "toggle fold"
             },
             %{
               char: "j",
               command_type: :jump_next,
               guard: :not_composing,
               label: "next block"
             },
             %{
               char: "k",
               command_type: :jump_prev,
               guard: :not_composing,
               label: "previous block"
             },
             # Expand the focused diff block full-screen (see the moduledoc's
             # `:not_composing` bullet). Plain "e" cannot collide with the Ctrl+E
             # chord above: `InputEvent.printable_char/1` is nil whenever ctrl is
             # held, so a Ctrl+E keypress never reaches this bind's match clause.
             %{
               char: "e",
               command_type: :expand_diff,
               guard: :not_composing,
               label: "expand diff full-screen"
             },
             # Ctrl+P: same chord shape as Ctrl+E above -- a ctrl chord is never
             # typed text, so this is `:always` too.
             %{
               char: "p",
               mods: %{ctrl: true, alt: false, shift: false, meta: false},
               command_type: :open_palette,
               guard: :always,
               label: "command palette"
             },
             %{
               char: "g",
               command_type: :open_jump_picker,
               guard: :not_composing,
               label: "jump to block"
             },
             %{
               char: "s",
               command_type: :open_session_picker,
               guard: :not_composing,
               label: "switch session"
             },
             # Printable-letter binds, same guard class as z/j/k: they only resolve
             # in transcript-browse mode, never stealing a letter out of the
             # composer's typed text. The `label:` makes them palette entries
             # automatically (palette_binds/0 derives from labels). "p" is NOT
             # used for plan -- Ctrl+P is the palette chord, and a bare "p" beside
             # it invites slips -- so "n" is used instead. The payload discriminates
             # which panel kind one shared :open_panel command type opens.
             %{
               char: "w",
               command_type: :open_panel,
               guard: :not_composing,
               payload: %{panel: :worktracks},
               label: "worktracks panel"
             },
             %{
               char: "m",
               command_type: :open_panel,
               guard: :not_composing,
               payload: %{panel: :memory},
               label: "memory panel"
             },
             %{
               char: "n",
               command_type: :open_panel,
               guard: :not_composing,
               payload: %{panel: :plan},
               label: "plan panel"
             },
             %{
               char: "/",
               command_type: :open_search_picker,
               guard: :not_composing,
               label: "search transcript"
             },
             # Return the `:full_viewport` scroll window to the tail. `End`
             # and vim-style `G`, both `:not_composing` so the composer
             # keeps `End` (end-of-line) and a typed `G` while the composer
             # has focus -- scroll-to-tail while composing is served by
             # PgDn (always-live) above. No `label:`, same rationale as the
             # PgUp/PgDn binds.
             %{key: :end, command_type: :scroll_to_tail, guard: :not_composing},
             %{char: "G", command_type: :scroll_to_tail, guard: :not_composing}
           ]

  # Structural guard for the one load-bearing ordering above: the
  # `:overlay` escape bind must precede the `:always` escape bind, or an
  # open overlay's ESC-to-close silently becomes an interrupt. Prose and
  # a behavioral test alone would let a future reorder (or a third
  # escape entry) slip through to runtime; this raises at COMPILE time
  # instead.
  case for %{key: :escape, guard: guard} <- @binds, do: guard do
    [:overlay, :always] ->
      :ok

    other ->
      raise CompileError,
        description:
          "Keymap.@binds escape ordering violated: expected exactly " <>
            "[:overlay, :always] (the :overlay dismiss bind must precede " <>
            "the :always interrupt bind -- first match wins), got " <>
            "#{inspect(other)}. See the moduledoc's \"overlay-open ESC " <>
            "capture\" section before changing this."
  end

  @doc """
  The keymap as data -- one entry per v1 bind. Exposed so T15's command
  palette can enumerate every invokable command without a second table.
  """
  @spec binds() :: [bind()]
  def binds, do: @binds

  @doc """
  The exact set of command types this module can ever emit -- the union
  `binds/0` declares, nothing hidden outside the table. Used by the
  invocation-parity test and available to T15 for the same reason.
  """
  @spec command_types() :: [command_type()]
  def command_types, do: @binds |> Enum.map(& &1.command_type) |> Enum.uniq()

  @doc """
  The labeled subset of `binds/0` -- a bind opts into palette listing by
  declaring a `label:`; derived from the table, never a parallel list.
  See `picker_binds_test.exs`'s "palette derivation" describe.
  """
  @spec palette_binds() :: [bind()]
  def palette_binds, do: Enum.filter(@binds, &Map.has_key?(&1, :label))

  @doc """
  Emits the exact command `resolve/2` would dispatch for an event matching
  `bind`, without needing a live `InputEvent.t()` -- this is what makes the
  command palette's invocation parity real: it can invoke any
  `palette_binds/0` entry directly instead of needing to fabricate a
  matching keypress. A bare `nil` context normalizes to `%{}`, same as
  `resolve/2`. `:fold_toggle` threads `context.focused_block_id` into the
  payload exactly like a live keypress would (see
  `picker_binds_test.exs`'s "command_for/2 threads context into
  :fold_toggle's payload" case).
  """
  @spec command_for(bind(), context() | nil) :: command()
  def command_for(bind, context \\ %{})

  def command_for(bind, nil), do: command_for(bind, %{})
  def command_for(bind, context), do: build_command(bind, context)

  @doc """
  Resolve a normalized `InputEvent.t()` (see `Raxol.UI.Harness.InputEvent`
  -- callers normalize first; this module never sees a raw driver event) +
  a mode context into a typed command, or `:passthrough` when no bind
  applies (composer-focus guard blocked it, or the key simply isn't bound).

  A bare `nil` context (e.g. "no block focused" callers that pass `nil`
  instead of `%{}`) normalizes to `%{}` before any guard consults it --
  every field then falls back to its documented default (see the
  moduledoc's fail-safe-default section for `composing?`) instead of the
  guard raising on a non-map.

  Pure: no process state, no side effects, never raises on a well-formed
  `InputEvent.t()`.
  """
  @spec resolve(InputEvent.t(), context() | nil) :: command() | :passthrough
  def resolve(norm, context \\ %{})

  def resolve(norm, nil), do: resolve(norm, %{})

  def resolve(norm, context) do
    case Enum.find(@binds, &matches?(&1, norm, context)) do
      nil -> :passthrough
      bind -> build_command(bind, context)
    end
  end

  @doc false
  # Exposed (not `defp`) so the modifier-exact-match branch is directly
  # unit-testable against a fixture bind without adding a chord to the
  # shipped v1 table -- see keymap_test.exs's "modifier-aware key binds".
  @spec matches?(bind(), InputEvent.t(), context()) :: boolean()
  def matches?(%{key: key} = bind, norm, context) do
    InputEvent.key(norm) == key and mods_match?(bind, norm) and
      guard_passes?(bind, context)
  end

  # A `char:`-kind bind that DECLARES `mods:` is a chord: match on the raw
  # normalized `char` + an EXACT `mods` map, NOT via
  # `InputEvent.printable_char/1` -- which is deliberately `nil` whenever
  # ctrl/alt/meta is held (that nil is exactly why undeclared-mods char
  # binds below never see chords, and it stays untouched). This clause
  # must precede the plain char clause: a bind map carrying both `:char`
  # and `:mods` would otherwise fall into the printable_char path and
  # never match its own chord.
  def matches?(%{char: char, mods: required_mods} = bind, norm, context) do
    match?(%{kind: :char, char: ^char}, norm) and norm.mods == required_mods and
      guard_passes?(bind, context)
  end

  def matches?(%{char: char} = bind, norm, context) do
    InputEvent.printable_char(norm) == char and guard_passes?(bind, context)
  end

  # -- private --

  # `key:`-kind binds are modifier-aware (see moduledoc's tui-steal rule):
  # no declared `mods:` means "bare keypress only" -- ctrl/alt/meta held
  # fails the match (Ctrl+Tab/Alt+Tab/Meta+Tab are shortcuts, not Tab).
  # Shift is deliberately excluded from that check (mirrors
  # `InputEvent.text?/1`: shift-only is not a shortcut), so Shift+Tab
  # still resolves through the plain `:tab` bind. A bind that DOES
  # declare `mods:` requires an EXACT match against the normalized
  # event's `mods` map instead.
  defp mods_match?(%{mods: required_mods}, norm), do: norm.mods == required_mods

  defp mods_match?(_bind, norm) do
    not (norm.mods.ctrl or norm.mods.alt or norm.mods.meta)
  end

  defp guard_passes?(%{guard: :always}, _context), do: true

  # Missing `composing?` defaults to `true` (composing) -- the fail-safe
  # direction. See moduledoc's "Fail-safe default" section: a caller must
  # opt IN to guarded-bind resolution with an explicit `composing?: false`.
  # An OPEN OVERLAY also suppresses the guarded transcript binds: with a
  # picker open, `z`/`j`/`k` are FILTER TEXT the overlay must receive as
  # `:passthrough`, never fold/jump commands fired at transcript state
  # hidden BEHIND the overlay. Consulting only `composing?` here was the
  # named routing desync (adversarial review, CRITICAL): the natural
  # open path for a jump/search picker is transcript-browse mode
  # (`composing?: false` -- the exact mode these binds exist for), so an
  # overlay opened from it would silently lose `j`/`k`/`z` from its
  # filter query while mutating fold/jump state out of sight. The
  # `overlay_open?` read keeps the same fail-safe default as the
  # `:overlay` guard's (absent = closed): a caller that never sets the
  # flag gets exactly the pre-overlay behavior.
  defp guard_passes?(%{guard: :not_composing}, context) do
    composing? = Map.get(context, :composing?, true)
    overlay_open? = Map.get(context, :overlay_open?, false)
    not (composing? or overlay_open?)
  end

  # The live-approval answer guard (Track D): passes only when a live
  # approval is holding the frontier (`approval_pending?: true`) AND the
  # composer DRAFT IS EMPTY (`composer_empty?: true`) AND no overlay is
  # open. The empty-draft condition -- NOT `not composing?` -- is the
  # reachability fix: after a submit the composer keeps focus, so requiring
  # an unfocused composer made `y` type into the draft instead of
  # answering; keying on emptiness means an operator who hasn't typed
  # anything answers with `y`/`n`/digits, while an operator MID-DRAFT keeps
  # every letter as text (an empty draft = not mid-thought). All three
  # flags default to the "do NOT fire the answer" direction -- absent
  # `approval_pending?`/`composer_empty?` are `false`, absent `overlay_open?`
  # is `false` -- so a caller that never sets them gets inert answer keys,
  # never a spurious answer. Strictly tighter than `:not_composing`: an
  # answer key is meaningful ONLY against a live question with an empty
  # draft, and stays passthrough everywhere else.
  defp guard_passes?(%{guard: :awaiting_approval}, context) do
    approval_pending? = Map.get(context, :approval_pending?, false)
    composer_empty? = Map.get(context, :composer_empty?, false)
    overlay_open? = Map.get(context, :overlay_open?, false)
    approval_pending? and composer_empty? and not overlay_open?
  end

  # Missing `overlay_open?` defaults to `false` (no overlay) -- the
  # OPPOSITE fail-safe direction from `:not_composing`, deliberately (see
  # moduledoc's "overlay-open ESC capture" section): the caller must opt
  # IN with an explicit `overlay_open?: true` before ESC captures as
  # `:overlay_dismiss` instead of falling through to the `:always`
  # interrupt bind. Silently swallowing interrupt for a caller that never
  # sets this flag would be the dangerous direction; dead navigation keys
  # (the `:not_composing` failure mode) are merely inert by comparison.
  defp guard_passes?(%{guard: :overlay}, context),
    do: Map.get(context, :overlay_open?, false)

  # `:expand_diff` reuses `:fold_toggle`'s exact payload shape --
  # `%{block_id: ...}` -- both name the CURRENTLY FOCUSED block; there is
  # no reason for a second payload vocabulary here.
  defp build_command(%{command_type: type}, context)
       when type in [:fold_toggle, :expand_diff] do
    %{type: type, payload: %{block_id: Map.get(context, :focused_block_id)}}
  end

  defp build_command(%{command_type: type} = bind, _context) do
    %{type: type, payload: Map.get(bind, :payload, %{})}
  end
end
