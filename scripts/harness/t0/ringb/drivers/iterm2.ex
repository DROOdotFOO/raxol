defmodule T0.RingB.Drivers.Iterm2 do
  @moduledoc """
  iTerm2 driver — AppleScript (`tell application "iTerm2"`), verified live
  on this machine (iTerm2 3.6.11, 2026-07-16):

    * `create window with default profile` + `unique id` of the current
      session gives a stable handle; `window id <id>` re-addresses it
      from a LATER, separate `osascript` invocation (each callback here
      is its own process — there is no persistent AppleScript session).
    * `write text "cmd"` == typing `cmd` + Enter. `write text "x" newline no`
      types `x` with NO trailing Enter — lands exactly at the current
      cursor, which is how `mark_cursor/2` infers cursor column (C3)
      without any cursor-position AppleScript property — iTerm2's sdef
      has none (`cursor color` exists, `cursor row`/`cursor column` do
      not; confirmed via `sdef`).
    * `contents` of a session returns scrollback + screen as ONE blob
      (calibrated separately: printing 500 lines recovered 501) — there
      is no visible-only AppleScript property, so `get_visible/1` and
      `get_scrollback/1` are the same call; `T0.RingB.Capture.viewport/2`
      is what carves the current screen back out.
    * `set columns to N` / `set rows to N` on a session resizes the
      window in cells (verified: 80x24 -> 120x30).
    * A window created via `create window` must NOT be written to
      immediately — sending text within the same beat as window
      creation observably corrupted the first several characters (shell
      not yet ready for input); a short settle delay after spawn fixes
      this reliably.

  Every `Osa.run/1` call below except `close/1`/`still_open?/1` (already
  bounded one layer up, in `T0.RingB.Guard.safe_teardown/3`) goes
  through the private `guarded_osa/1`, which wraps it in
  `T0.RingB.Guard.with_timeout/2` (RB review FIX-NOW #1) — `spawn_session/1`,
  `run_command/2`/`mark_cursor/2` (`write/2`), `get_visible/1`/
  `get_scrollback/1` (`get_contents/1`), and `resize/3` can no longer
  hang the whole matrix run indefinitely on a wedged `osascript` (e.g. a
  TCC Automation permission prompt nobody has clicked yet — see
  `T0.RingB.Osa`'s moduledoc for why the bound lives here rather than
  inside `Osa` itself).
  """

  @behaviour T0.RingB.Driver
  alias T0.RingB.Guard
  alias T0.RingB.Osa

  @settle_ms 1400
  @osa_timeout_ms 5_000

  @impl true
  def name, do: :iterm2

  @impl true
  def capture_method, do: "native_gettext"

  @impl true
  def available? do
    File.dir?("/Applications/iTerm.app") or
      File.dir?(Path.expand("~/Applications/iTerm.app"))
  end

  @impl true
  def spawn_session(_opts \\ []) do
    script = """
    tell application "iTerm2"
      set newWin to (create window with default profile)
      return (id of newWin as string)
    end tell
    """

    case guarded_osa(script) do
      {:ok, wid} ->
        Process.sleep(@settle_ms)
        {:ok, %{window_id: String.trim(wid)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def run_command(%{window_id: wid}, cmd) do
    write(wid, cmd, newline: true)
  end

  @impl true
  def mark_cursor(%{window_id: wid}, text) do
    write(wid, text, newline: false)
  end

  @impl true
  def get_scrollback(session), do: get_contents(session)

  @impl true
  def get_visible(session), do: get_contents(session)

  @impl true
  def get_cursor(_session), do: {:error, :unsupported}

  @impl true
  def resize(%{window_id: wid}, cols, rows) do
    script = """
    tell application "iTerm2"
      tell current session of (window id #{wid})
        set columns to #{cols}
        set rows to #{rows}
      end tell
    end tell
    """

    case guarded_osa(script) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(%{window_id: wid}) do
    _ = Osa.run(~s[tell application "iTerm2" to close (window id #{wid})])
    :ok
  end

  @impl true
  def still_open?(%{window_id: wid}) do
    script = ~s[tell application "iTerm2" to return (exists (window id #{wid}))]

    case Osa.run(script) do
      {:ok, "true"} -> true
      _ -> false
    end
  end

  # --- internal ------------------------------------------------------------

  defp write(wid, text, newline: newline?) do
    newline_clause = if newline?, do: "", else: " newline no"

    script = """
    tell application "iTerm2"
      tell current session of (window id #{wid})
        write text "#{Osa.escape(text)}"#{newline_clause}
      end tell
    end tell
    """

    case guarded_osa(script) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_contents(%{window_id: wid}) do
    script = """
    tell application "iTerm2"
      tell current session of (window id #{wid})
        return contents
      end tell
    end tell
    """

    guarded_osa(script)
  end

  # Bounds every `Osa.run/1` call above at `@osa_timeout_ms` (RB review
  # FIX-NOW #1) — see moduledoc for why the bound lives here rather
  # than inside `T0.RingB.Osa` itself (load-order/no-cycle constraint of
  # `T0.RingB.Boot.require_all!/1`'s sequential `Code.require_file/2`).
  # `Osa.run/1` never raises on its own (it has its own internal
  # try/rescue), so this never needs to disambiguate a raised-inside-
  # the-task result from a timeout the way the CLI drivers' `guarded_cmd/3`
  # helpers do.
  defp guarded_osa(script) do
    case Guard.with_timeout(fn -> Osa.run(script) end, @osa_timeout_ms) do
      {:ok, result} -> result
      :timeout -> {:error, :osascript_timeout}
    end
  end
end
