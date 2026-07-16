defmodule T0.RingB.Driver do
  @moduledoc """
  Behaviour for a real-terminal device-control driver: the thing that
  turns `t0-runbook.md`'s manual per-terminal recipes (osascript for
  iTerm2/Terminal.app, `wezterm cli` for WezTerm, `kitty @` remote control
  for kitty) into a uniform Elixir API `T0.RingB.Measurements` can drive
  without knowing which terminal it's talking to.

  Every callback that can legitimately fail on a given terminal (no
  cursor-position API, no resize primitive) returns `{:error, :unsupported}`
  rather than raising — `Measurements` treats that as "this claim's
  strict form is un-automatable on this terminal" and records a
  documented residual instead of a fake pass/fail.

  `session()` is driver-private (a map/struct only that driver's own
  functions interpret) — callers never pattern-match its shape.
  """

  @type session :: term()
  @type reason :: term()

  @doc "Stable terminal identifier, matches append_result.sh's TERMINAL enum."
  @callback name() :: atom()

  @doc "capture_method value for append_result.sh (native_gettext | ...)."
  @callback capture_method() :: String.t()

  @doc """
  Cheap, side-effect-free (no window spawned) check for whether this
  terminal is installed/drivable in the current environment.
  """
  @callback available?() :: boolean()

  @doc """
  Opens a new window/pane running an interactive shell and returns a
  session handle. Callers must NOT send a command immediately — some
  terminals (observed empirically on iTerm2) corrupt the first few
  characters typed before the shell has finished initializing; drivers
  are responsible for their own settle delay before returning.
  """
  @callback spawn_session(opts :: keyword()) ::
              {:ok, session()} | {:error, reason()}

  @doc "Runs a shell command line inside the session (as though typed + Enter)."
  @callback run_command(session(), String.t()) :: :ok | {:error, reason()}

  @doc """
  Types `text` into the session with NO trailing newline/Enter — lands
  exactly at wherever the terminal's real cursor currently is. Used to
  infer cursor position textually (C3) on terminals with no direct
  cursor-position query.
  """
  @callback mark_cursor(session(), text :: String.t()) ::
              :ok | {:error, reason()}

  @doc "The terminal's own idea of everything recoverable (scrollback + screen)."
  @callback get_scrollback(session()) :: {:ok, String.t()} | {:error, reason()}

  @doc """
  The current screen contents. On terminals whose capture API doesn't
  distinguish visible-from-history (iTerm2/WezTerm/kitty all return one
  unified buffer), this is allowed to return the SAME text as
  `get_scrollback/1` — callers slice the viewport out via
  `T0.RingB.Capture.viewport/2` rather than assuming this is exactly
  `height` lines.
  """
  @callback get_visible(session()) :: {:ok, String.t()} | {:error, reason()}

  @doc "Cursor position as {row, col}, 1-based, or {:error, :unsupported}."
  @callback get_cursor(session()) ::
              {:ok, {non_neg_integer(), non_neg_integer()}}
              | {:error, :unsupported | reason()}

  @doc "Resizes the terminal to (cols, rows), or {:error, :unsupported}."
  @callback resize(session(), cols :: pos_integer(), rows :: pos_integer()) ::
              :ok | {:error, :unsupported | reason()}

  @doc "Closes the window/pane. Must not raise even if the session is already gone."
  @callback close(session()) :: :ok

  @doc """
  True if the window/pane is STILL open. Load-bearing for
  `T0.RingB.Guard.safe_teardown/3`: observed live (Terminal.app,
  2026-07-16) that `close` can return immediately (exit 0, no error)
  while a "terminate running processes?" confirmation SHEET appears
  moments later and leaves the window physically open until a human (or
  a synthetic Return keystroke) dismisses it — a synchronous timeout on
  the `close` call itself never catches this, because the call was
  never blocking in the first place. Callers must verify closure
  actually happened rather than trusting `close/1`'s return value alone.
  """
  @callback still_open?(session()) :: boolean()
end
