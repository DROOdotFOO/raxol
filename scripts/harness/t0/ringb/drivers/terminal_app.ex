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

  Every `Osa.run/1` call below except `close/1`/`still_open?/1` (already
  bounded one layer up, in `T0.RingB.Guard.safe_teardown/3`) goes
  through the private `guarded_osa/1`, which wraps it in
  `T0.RingB.Guard.with_timeout/2` (RB review FIX-NOW #1) —
  `spawn_session/1`, `run_command/2`, `get_visible/1`, `get_scrollback/1`,
  and `resize/3` can no longer hang the whole matrix run indefinitely on
  a wedged `osascript` (e.g. a TCC Automation permission prompt nobody
  has clicked yet — see `T0.RingB.Osa`'s moduledoc for why the bound
  lives here rather than inside `Osa` itself).
  """

  @behaviour T0.RingB.Driver
  alias T0.RingB.Guard
  alias T0.RingB.Osa

  @settle_ms 1400
  @osa_timeout_ms 5_000

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
    script = """
    tell application "Terminal"
      do script "#{Osa.escape(cmd)}" in (tab 1 of window id #{wid})
    end tell
    """

    case guarded_osa(script) do
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
    guarded_osa(
      ~s(tell application "Terminal" to return history of tab 1 of window id #{wid})
    )
  end

  @impl true
  def get_visible(%{window_id: wid}) do
    guarded_osa(
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

    case guarded_osa(script) do
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

  # --- internal ------------------------------------------------------------

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
