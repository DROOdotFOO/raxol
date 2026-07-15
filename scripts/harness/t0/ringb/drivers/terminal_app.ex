defmodule T0.RingB.Drivers.TerminalApp do
  @moduledoc """
  Apple Terminal.app driver — AppleScript. Not a tier-1 terminal (the
  resolver's `@tier1` is kitty/iTerm2/WezTerm/Ghostty only), so this
  driver's results never move D-PA — it's still a real, useful data
  point recorded under `terminal=apple`.

  Verified live (2026-07-16):

    * Terminal.app's `tab` class has NO `id` property (only `window` does
      — confirmed via `sdef`) — sessions are tracked by WINDOW id, and
      each spawned window is assumed to hold exactly one tab (`tab 1`).
    * `do script "cmd"` always appends Return and there is no raw
      "write without executing" command — `mark_cursor/2` (needed for
      the strict C3 cursor-column check) has no clean primitive here.
      C3 is therefore text-only on this driver: it verifies the footer
      content is intact, not the exact cursor column (see
      `T0.RingB.Measurements` — `apple` gets a documented `partial`
      verdict for C3, never a false `pass`).
    * `history of tab 1 of window id X` returns the FULL scrollback
      (verified: painted footer text was recoverable at a mid-buffer
      line, matching the same viewport-tail-of-buffer shape as iTerm2).
    * **The modal that motivated `T0.RingB.Guard`**: closing a window
      while its tab's foreground job (here: the probe's `sleep` under
      `T0_HOLD_SECONDS`) is still alive pops "Do you want to terminate
      the running processes...?" — a blocking dialog. `Guard.kill_marker/1`
      must run (and the process must actually be dead) before `close/1`
      is ever called; `close/1` itself does not attempt to work around
      a live process, by design (see the runner's `safe_teardown`).
  """

  @behaviour T0.RingB.Driver
  alias T0.RingB.Osa

  @settle_ms 1400

  @impl true
  def name, do: :apple

  @impl true
  def capture_method, do: "native_gettext"

  @impl true
  def available? do
    File.dir?("/System/Applications/Utilities/Terminal.app") or
      File.dir?("/Applications/Utilities/Terminal.app")
  end

  @impl true
  def spawn_session(_opts \\ []) do
    # Bind to the window CONTAINING the tab `do script` just created
    # (`first window whose tabs contains theTab`), NOT `front window`.
    # `front window` is positional: a 0.2s focus race (the user clicking
    # another Terminal window, or Spaces/Mission-Control shuffling
    # frontmost) could bind us to a window we did not create and later
    # close it out from under the user. `do script` RETURNS the created
    # tab, so the containing window is a creation-derived handle — the
    # never-touch-user-windows rule, matching the iTerm2 driver's
    # `create window`-returned handle. Verified live 2026-07-16.
    script = """
    tell application "Terminal"
      activate
      set theTab to do script
      delay 0.2
      set theWindow to (first window whose tabs contains theTab)
      return id of theWindow
    end tell
    """

    case Osa.run(script) do
      {:ok, wid} ->
        Process.sleep(@settle_ms)
        {:ok, %{window_id: String.trim(wid)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def run_command(%{window_id: wid}, cmd) do
    script = """
    tell application "Terminal"
      do script "#{Osa.escape(cmd)}" in (tab 1 of window id #{wid})
    end tell
    """

    case Osa.run(script) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  # No non-executing raw-write AppleScript command exists for Terminal.app
  # (`do script` always appends Return) — cursor-column inference via
  # marker injection is not available on this driver (see moduledoc).
  def mark_cursor(_session, _text), do: {:error, :unsupported}

  @impl true
  def get_scrollback(%{window_id: wid}) do
    Osa.run(
      ~s(tell application "Terminal" to return history of tab 1 of window id #{wid})
    )
  end

  @impl true
  def get_visible(%{window_id: wid}) do
    Osa.run(
      ~s(tell application "Terminal" to return contents of tab 1 of window id #{wid})
    )
  end

  @impl true
  def get_cursor(_session), do: {:error, :unsupported}

  @impl true
  def resize(%{window_id: wid}, cols, rows) do
    script = """
    tell application "Terminal"
      set number of columns of tab 1 of window id #{wid} to #{cols}
      set number of rows of tab 1 of window id #{wid} to #{rows}
    end tell
    """

    case Osa.run(script) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(%{window_id: wid}) do
    _ =
      Osa.run(
        ~s(tell application "Terminal" to close window id #{wid} saving no)
      )

    :ok
  end

  @impl true
  def still_open?(%{window_id: wid}) do
    script = ~s[tell application "Terminal" to return (exists window id #{wid})]

    case Osa.run(script) do
      {:ok, "true"} -> true
      _ -> false
    end
  end
end
