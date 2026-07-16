defmodule Raxol.Terminal.InlineDriver.Sequences do
  @moduledoc """
  Pure ANSI byte-sequence constants + builders for the inline driver
  profile (unit T2d, `docs/proposals/in-flight/harness-ui-roadmap.md`).

  Kept separate from the GenServer (`Raxol.Terminal.InlineDriver`) so the
  Tier A suite (`harness-ui-testing/03-lifecycle.md`) can assert on exact
  bytes without a process, a device, or the OS tty -- this module has no
  side effects at all.

  ## The canonical teardown order (pinned, load-bearing)

  Ordering is not cosmetic: the negative suite proves each swap strands the
  cursor or echoes escapes into the restored shell.

    1. **input modes off** (`modes_off/0`) -- while raw mode is still on,
       so the bytes are never echoed back as if typed.
    2. **release the scroll region** (`release_region/0`, `CSI r`) -- BEFORE
       any absolute cursor move, else the move clamps into the old region
       (INV-1).
    3. **autowrap + cursor restore** (`autowrap_cursor/0`) -- before the
       final prompt handoff (INV-2).
    4. **cursor to bottom + fresh line** (`move_bottom/1`) -- unclamped now
       that the region is gone.
    5. **stty restore** -- LAST, after every escape write, else cooked mode
       line-processes the escapes as garbage (INV-3). This step is OS-level
       and lives in `Raxol.Terminal.InlineDriver.emit_teardown/2`, not here.
  """

  # Mouse modes reset defensively (may be left over from a crashed prior
  # session) -- the inline profile never enables them itself, mirroring the
  # existing termbox driver's init-time reset.
  @mouse_reset "\e[?1003l\e[?1006l\e[?1000l"
  @focus_report_on "\e[?1004h"
  @bracketed_paste_on "\e[?2004h"

  # DECOM (origin mode) reset is included defensively, same rationale as
  # @mouse_reset above: this profile never sets DECOM itself, but a prior
  # crashed session may have left it on, which would otherwise clamp the
  # step-4 absolute cursor move (`move_bottom/1`) inside whatever margins
  # were active instead of the real bottom row.
  @modes_off "\e[?2004l\e[?1004l\e[?1003l\e[?1006l\e[?1000l\e[?6l"
  @release_region "\e[r"
  @autowrap_cursor "\e[?7h\e[?25h"

  @doc """
  Startup bytes. Deliberately contains **no** `\\e[?1049h` -- the inline
  profile never owns the alternate screen (LC-P-NOALT, T2d's headline
  invariant). Resets stray mouse modes, then enables focus reporting and
  bracketed paste (both reversed by `modes_off/0` at teardown).
  """
  @spec init_bytes() :: binary()
  def init_bytes, do: @mouse_reset <> @focus_report_on <> @bracketed_paste_on

  @doc "Step 1: disable bracketed paste, focus reporting, and all mouse modes."
  @spec modes_off() :: binary()
  def modes_off, do: @modes_off

  @doc "Step 2: `CSI r` -- reset the scroll region to the full screen."
  @spec release_region() :: binary()
  def release_region, do: @release_region

  @doc "Step 3: re-enable autowrap (DECAWM) and show the cursor."
  @spec autowrap_cursor() :: binary()
  def autowrap_cursor, do: @autowrap_cursor

  @doc """
  Step 4: absolute-move to `(rows, 1)` then CRLF. Safe to be unclamped
  because the scroll region is already gone by this point (step 2).
  """
  @spec move_bottom(pos_integer()) :: binary()
  def move_bottom(rows) when is_integer(rows) and rows > 0 do
    "\e[#{rows};1H\r\n"
  end

  @doc """
  Steps 1-4 concatenated in canonical order. Step 5 (stty restore) is
  OS-level and not modeled here -- see
  `Raxol.Terminal.InlineDriver.emit_teardown/2`.
  """
  @spec teardown_bytes(pos_integer()) :: binary()
  def teardown_bytes(rows) when is_integer(rows) and rows > 0 do
    modes_off() <> release_region() <> autowrap_cursor() <> move_bottom(rows)
  end

  @doc """
  Suspend bytes -- the editor-handoff sibling of `teardown_bytes/1`
  (an external `$EDITOR` process, not process exit, is about to own the
  tty). Steps 1-3 of the canonical teardown order, verbatim
  (`modes_off/0`, `release_region/0`, `autowrap_cursor/0`), plus an
  absolute cursor park at `(rows, 1)` -- WITHOUT step 4's trailing CRLF.

  ## Why steps 1-3 apply unchanged

  Same reasoning as the teardown order: modes must go off WHILE STILL
  RAW (else the escapes echo back as if typed), and `CSI r` must precede
  any absolute cursor move (else the move clamps into the still-active
  old region, INV-1).

  ## Why this DROPS step 4's trailing CRLF

  `move_bottom/1`'s CRLF exists to hand the SHELL a fresh line after this
  process exits for good -- the shell prompt that appears next expects to
  start at column 1 of a blank row. An editor handoff is not that: the
  region has just been released, so a CRLF here would scroll the FULL
  (now region-free) screen up by one line, smearing whatever was on the
  bottom row (a stale footer) into the row above it -- and that row is
  inside the just-released history area, which cannot be re-addressed
  once scrolled (the seal-time-only invariant). The bare park (`CSI
  rows;1 H`, no `\\r\\n`) leaves the cursor at the right row without
  scrolling anything, which is exactly what the editor needs: it will
  clear/redraw its own screen (or, for a non-alt-screen editor, simply
  start typing from wherever the cursor already is) without this driver
  having pre-scrolled a footer row into unreachable history first.

  Never emits `\\e[2J`/`\\e[3J` -- same substrate law as every other
  sequence builder in this module.
  """
  @spec suspend_bytes(pos_integer()) :: binary()
  def suspend_bytes(rows) when is_integer(rows) and rows > 0 do
    modes_off() <> release_region() <> autowrap_cursor() <> "\e[#{rows};1H"
  end
end
