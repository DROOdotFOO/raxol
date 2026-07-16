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
      the walking loop does not change).
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
          optional(:focused_block_id) => term()
        }

  @type command_type ::
          :interrupt | :steer | :fold_toggle | :jump_next | :jump_prev

  @type command :: %{type: command_type(), payload: map()}

  @type guard :: :always | :not_composing

  @type bind :: %{
          required(:command_type) => command_type(),
          optional(:key) => atom(),
          optional(:char) => String.t(),
          optional(:guard) => guard()
        }

  # Plain keys only (v1) -- see moduledoc's "tui-steal rule": a future chord
  # (e.g. requiring :ctrl) is a new field on the matching entry, not a
  # restructure of `resolve/2`. Order matters only in that the first match
  # wins; the table is designed so no two entries can ever both match a
  # single normalized event, so today the order is not load-bearing.
  @binds [
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
  def command_types, do: Enum.map(@binds, & &1.command_type)

  @doc """
  Resolve a normalized `InputEvent.t()` (see `Raxol.UI.Harness.InputEvent`
  -- callers normalize first; this module never sees a raw driver event) +
  a mode context into a typed command, or `:passthrough` when no bind
  applies (composer-focus guard blocked it, or the key simply isn't bound).

  Pure: no process state, no side effects, never raises on a well-formed
  `InputEvent.t()`.
  """
  @spec resolve(InputEvent.t(), context()) :: command() | :passthrough
  def resolve(norm, context \\ %{}) do
    case Enum.find(@binds, &matches?(&1, norm, context)) do
      nil -> :passthrough
      bind -> build_command(bind, context)
    end
  end

  # -- private --

  defp matches?(%{key: key} = bind, norm, context) do
    InputEvent.key(norm) == key and guard_passes?(bind, context)
  end

  defp matches?(%{char: char} = bind, norm, context) do
    InputEvent.printable_char(norm) == char and guard_passes?(bind, context)
  end

  defp guard_passes?(%{guard: :always}, _context), do: true

  defp guard_passes?(%{guard: :not_composing}, context),
    do: not Map.get(context, :composing?, false)

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
