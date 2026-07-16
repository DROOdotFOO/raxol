defmodule T0.RingB.Drivers.Ghostty do
  @moduledoc """
  Ghostty driver — deliberately capture-incapable.

  Checked live (2026-07-16, `sdef /Applications/Ghostty.app`): this
  Ghostty build DOES have a real scripting dictionary — `new window`,
  `input text` (paste-as-if-typed), `send key`, `send mouse *` — enough
  to DRIVE it. But there is no `get text`/`contents`/`history` command
  anywhere in the dictionary, and no CLI equivalent (`ghostty` has no
  `cli get-text` subcommand). Every claim this unit automates needs a
  capture step, so Ghostty cannot produce a ground-truth row for any of
  them — this is a genuine capability gap, not a driver bug to fix.

  `available?/0` reports the app is present (so the runner can list it
  as "installed but screenshot-residual" rather than silently omitting
  it), but every other callback returns `{:error, :unsupported}` —
  `T0.RingB.Measurements` treats this driver as skip-only and never
  even spawns a window for it (no capture is possible regardless of
  what's on screen, so there is nothing to gain from opening one).

  Ghostty is tier-1 per the resolver's `@tier1` list — this is exactly
  why the resolver's own two-terminal floor and "all four measured"
  requirement for a DEFINITIVE D-PA cannot be satisfied by automation
  alone: Ghostty legitimately reaches ground truth only via `human_eye`
  (screenshot + manual scrollback check), same conclusion the sandboxed
  T0 run already documented in `t0-verdict-schema.md` §4.1.
  """

  @behaviour T0.RingB.Driver

  @impl true
  def name, do: :ghostty

  @impl true
  def capture_method, do: "human_eye"

  @impl true
  def available?, do: File.dir?("/Applications/Ghostty.app")

  @impl true
  def spawn_session(_opts \\ []), do: {:error, :unsupported}

  @impl true
  def run_command(_session, _cmd), do: {:error, :unsupported}

  @impl true
  def mark_cursor(_session, _text), do: {:error, :unsupported}

  @impl true
  def get_scrollback(_session), do: {:error, :unsupported}

  @impl true
  def get_visible(_session), do: {:error, :unsupported}

  @impl true
  def get_cursor(_session), do: {:error, :unsupported}

  @impl true
  def resize(_session, _cols, _rows), do: {:error, :unsupported}

  @impl true
  def close(_session), do: :ok

  @impl true
  def still_open?(_session), do: false
end
