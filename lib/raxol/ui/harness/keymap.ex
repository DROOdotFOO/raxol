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
    * **Invocation parity with T15's palette**: the palette can enumerate
      `binds/0` and invoke `command_for/2` on any entry directly (a command
      palette is just another way to select a bind, not a second source of
      truth for what commands exist). `command_types/0` is the exact union
      this module can ever emit -- there are no commands hiding outside the
      table.

  ## The composer-focus guard

  Two classes of bind:

    * **Always live** -- fire regardless of `context.composing?`. Only ESC
      (`:interrupt`) and the steer-submit key (`:tab`, `:steer`) are in this
      class, because both are non-printable control keys that can never be
      part of typed text, and ESC in particular must never be swallowed by
      whatever currently has focus (AD-1: interrupt is a supervised kill
      now, not a cooperative flag queued behind typing).
    * **Guarded by `not composing?`** -- the block-navigation binds
      (`fold-toggle`, `jump_next`, `jump_prev`). These use plain printable
      letters (`z`/`j`/`k`), and a prior flat-keymap prototype's named bug
      (see `harness-ui-STATE.md`, "the demo's flat keymap steals j/k/s/z
      from typing") was firing them unconditionally, stealing those letters
      out of the composer's typed text. Gating them on `composing?` is the
      fix: they only resolve to a command when focus is NOT the composer
      (browsing the transcript), and fall through to `:passthrough`
      (ordinary character insertion) while composing.

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
  is part of the contract, not incidental. Enter/printable chars/arrows
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
  T15 invocation-parity without ever being routed to `raxol_agent`.
  """

  alias Raxol.UI.Harness.InputEvent

  @type context :: %{
          optional(:composing?) => boolean(),
          optional(:streaming?) => boolean(),
          optional(:focused_block_id) => term(),
          optional(:overlay_open?) => boolean()
        }

  @type command_type ::
          :interrupt
          | :steer
          | :fold_toggle
          | :jump_next
          | :jump_prev
          | :overlay_dismiss

  @type command :: %{type: command_type(), payload: map()}

  @type guard :: :always | :not_composing | :overlay

  @type bind :: %{
          required(:command_type) => command_type(),
          optional(:key) => atom(),
          optional(:char) => String.t(),
          optional(:guard) => guard(),
          optional(:mods) => InputEvent.mods()
        }

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
    %{key: :escape, command_type: :interrupt, guard: :always},
    %{key: :tab, command_type: :steer, guard: :always},
    %{char: "z", command_type: :fold_toggle, guard: :not_composing},
    %{char: "j", command_type: :jump_next, guard: :not_composing},
    %{char: "k", command_type: :jump_prev, guard: :not_composing}
  ]

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
  defp guard_passes?(%{guard: :not_composing}, context),
    do: not Map.get(context, :composing?, true)

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

  defp build_command(%{command_type: :fold_toggle}, context) do
    %{
      type: :fold_toggle,
      payload: %{block_id: Map.get(context, :focused_block_id)}
    }
  end

  defp build_command(%{command_type: type}, _context) do
    %{type: type, payload: %{}}
  end
end
