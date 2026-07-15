defmodule T0.RingB.Guard do
  @moduledoc """
  Non-negotiable safety net for closing a real GUI terminal window/pane.

  Observed live on this machine (2026-07-16): closing a Terminal.app
  window while the probe's HOLD `sleep` is still the foreground job pops
  a MODAL ("Do you want to terminate the running processes...?") that
  blocks on a human click forever — exactly the kind of hang a headless
  automation run must never produce. The fix has three layers:

    1. Kill the probe's own process by its unique marker BEFORE closing,
       so nothing is alive in the window's job list when we ask the
       terminal to close it (this is the one that should always fire).
    2. Wrap the close call itself in a bounded timeout — if it hangs
       (meaning a modal appeared anyway, e.g. from a source outside our
       control), don't block the whole matrix run waiting for a human.
    3. Last resort: send Return via System Events (the modal's default
       button is "Terminate" per the observed dialog), then retry the
       close once more. If even that doesn't clear it, give up on THIS
       window (log it, move on) rather than hang — a single stuck
       window is a bounded, visible cost; a hung automation run is not.

  A SECOND, subtler failure mode was found empirically while validating
  this exact fix (Terminal.app, 2026-07-16): `close` can return
  IMMEDIATELY (exit 0, no AppleScript error) while the confirmation
  sheet appears moments later ASYNCHRONOUSLY, leaving the window
  physically open — a synchronous timeout on the `close` call itself
  never detects this, because the call was never blocking to begin
  with. The fix is `still_open?/1`: after calling `close`, verify the
  window is ACTUALLY gone (not just that the call returned without
  error), and if it is not, THEN send the dismissal keystroke and
  retry — bounded, never indefinite.

  Every function here is total: it never raises, and it never leaves a
  process alive that the caller intended to be dead.
  """

  alias T0.RingB.Osa

  @doc """
  Generates a marker token safe to embed as a trailing shell argv token
  (probes ignore extra positional args) and to `pkill -f` against later.
  Includes the driver/claim for readable `ps` output during debugging.
  """
  @spec marker(atom(), String.t()) :: String.t()
  def marker(driver_name, claim) do
    "ringb-#{driver_name}-#{claim}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Kills any process whose command line contains `marker` (the probe
  script invocation, still possibly inside its HOLD `sleep`). Idempotent
  and silent if nothing matches (already exited on its own).
  """
  @spec kill_marker(String.t()) :: :ok
  def kill_marker(marker) when is_binary(marker) do
    _ = System.cmd("pkill", ["-f", marker], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @max_close_attempts 4
  @close_settle_ms 500

  @doc """
  Runs the driver's teardown for one session: kill the marker's process,
  then close the window/pane and VERIFY it is actually gone
  (`still_open?/1`) — not merely that `close/1` returned without error.
  Handles both observed failure modes: a `close` call that itself hangs
  (bounded via `with_timeout/2`) and one that returns immediately while
  a confirmation sheet appears asynchronously afterward (caught by the
  `still_open?/1` retry loop below). Never raises; always returns `:ok`,
  even if the window could not be confirmed closed after
  `@max_close_attempts` tries (a bounded, visible residual is
  acceptable; hanging the whole matrix run is not).
  """
  @spec safe_teardown(module(), term(), String.t()) :: :ok
  def safe_teardown(driver, session, marker) do
    kill_marker(marker)
    # Give the killed process a beat to actually leave the job table
    # before asking the terminal to close the window it was running in.
    Process.sleep(200)

    close_until_gone(driver, session, @max_close_attempts)
    # One more unconditional settle: dismissing a sheet is itself
    # asynchronous (the window can take a beat to actually leave the
    # app's window list after the keystroke registers) — give the last
    # attempt's dismissal, if any, room to land before this function
    # returns and the caller moves on to the next window.
    Process.sleep(@close_settle_ms)
    :ok
  rescue
    _ -> :ok
  end

  # Tries `close`, then verifies with `still_open?/1`. If still open,
  # dismisses (targeting the RIGHT app — a bare keystroke with no prior
  # `activate` was empirically unreliable: the keystroke goes to
  # whatever happens to be frontmost system-wide at that instant, not
  # necessarily the sheet-bearing window) and gives it one more full
  # settle before the FINAL verification — this is the one place the
  # original version under-counted: recursing straight to the `0`
  # base case after the last dismiss skipped re-checking whether that
  # last dismiss actually worked.
  defp close_until_gone(driver, session, attempts_left)
       when attempts_left > 0 do
    _ = with_timeout(fn -> driver.close(session) end, 3_000)
    Process.sleep(@close_settle_ms)

    if still_open?(driver, session) do
      dismiss_modal_best_effort(app_name_for(driver))
      Process.sleep(@close_settle_ms)
      close_until_gone(driver, session, attempts_left - 1)
    else
      :ok
    end
  end

  defp close_until_gone(_driver, _session, 0), do: :ok

  defp app_name_for(driver) do
    case driver.name() do
      :iterm2 -> "iTerm2"
      :apple -> "Terminal"
      # wezterm/kitty have no GUI confirmation dialog to dismiss (their
      # close paths are plain CLI calls) — nil short-circuits the
      # dismissal below to a no-op.
      _ -> nil
    end
  end

  defp still_open?(driver, session) do
    case with_timeout(fn -> driver.still_open?(session) end, 2_000) do
      {:ok, bool} when is_boolean(bool) -> bool
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Runs `fun` in a supervised task; returns `{:ok, result}` if it
  completes within `timeout_ms`, `:timeout` (and force-kills the task)
  otherwise. Never raises — an exception inside `fun` is caught and
  reported as `{:ok, {:error, {:raised, message}}}` so callers can log
  it without the guard itself ever propagating a crash.
  """
  @spec with_timeout((-> term()), timeout()) :: {:ok, term()} | :timeout
  def with_timeout(fun, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          e -> {:error, {:raised, Exception.message(e)}}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} -> {:ok, result}
      nil -> Task.shutdown(task, :brutal_kill) && :timeout
    end
  end

  @doc """
  Last-resort modal dismissal for the two AppleScript-driven terminals
  (iTerm2, Terminal.app): activates `app_name` FIRST, then sends Return
  via System Events — which per the observed Terminal.app dialog is
  bound to "Terminate" (the destructive but automation-correct choice —
  we already tried to kill the process ourselves; if a sheet is up
  anyway, the safest exit is to let it proceed).

  The explicit `activate` matters: `keystroke` goes to whatever is
  frontmost SYSTEM-WIDE at that instant, not necessarily the
  sheet-bearing window — a bare `keystroke return` with no prior
  activation was observed to be unreliable (the window sometimes
  stayed open for many seconds after a "successful" dismiss call).

  `app_name` of `nil` (wezterm/kitty — no GUI confirmation dialog
  exists for either's plain CLI close path) short-circuits to a no-op.
  Best-effort: swallows every failure (missing Accessibility
  permission, app already gone, etc.) rather than raising.
  """
  @spec dismiss_modal_best_effort(String.t() | nil) :: :ok
  def dismiss_modal_best_effort(nil), do: :ok

  def dismiss_modal_best_effort(app_name) do
    script = """
    tell application "#{Osa.escape(app_name)}" to activate
    delay 0.2
    tell application "System Events" to keystroke return
    """

    _ = Osa.run(script)
    :ok
  rescue
    _ -> :ok
  end
end
