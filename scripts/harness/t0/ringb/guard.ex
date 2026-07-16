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

  @doc """
  Same close-and-verify teardown as `safe_teardown/3`, WITHOUT the
  `kill_marker/1` step — for callers whose command already ran to
  completion (synchronously, with no `T0_HOLD_SECONDS` hold) before
  teardown is ever reached, so there is never a live marked process left
  to find. `T0.RingB.Measurements`'s capacity-gate calibration is the
  one caller of this: its plain `for`/`printf` loop is typed directly at
  the session's own interactive prompt (not spawned as a separately
  addressable process the way the held probes are), so a marker embedded
  in that command text would never show up in `ps` output for
  `kill_marker/1`'s `pkill -f` to match in the first place — calling
  `safe_teardown/3` there was documented as matching NOTHING (RB review
  FIX-NOW #2) and gave a false impression of protection this path never
  had. `close_only/2` is the honest version: it still closes and
  verifies the window is gone, bounded exactly like `safe_teardown/3`,
  it just doesn't pretend to kill a process that was never trackable.
  """
  @spec close_only(module(), term()) :: :ok
  def close_only(driver, session) do
    close_until_gone(driver, session, @max_close_attempts)
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
  Runs an external command bounded by `with_timeout/2`, normalizing
  `System.cmd/3`'s `{out, exit_code}` result to
  `{:ok, out} | {:error, reason}` so callers don't need to
  special-case a timeout vs. a nonzero exit vs. an in-task raise
  themselves. Shared by the CLI-driven drivers (WezTerm, kitty) — RB
  review FIX-NOW #1 bounds every `spawn_session/1`, `run_command/2`,
  `get_visible/1`, and `get_scrollback/1` call site, and pulling the
  common wrapper here (instead of each driver keeping its own copy)
  is what keeps that fix from being duplicated code across both.

  The middle clause's `is_integer(code)` guard matters: if
  `System.cmd/3` itself raises inside the guarded task, `with_timeout/2`'s
  own internal rescue already converts that to
  `{:ok, {:error, {:raised, message}}}` (a graceful, non-crashing
  result, NOT a timeout) — without the guard, that inner
  `{:error, {:raised, _}}` tuple would itself match the bare
  `{out, code}` shape (`out` bound to `:error`) and blow up in
  `String.trim/1` on the second clause instead of surfacing the real
  error via the third.
  """
  @spec run_cmd(String.t(), [String.t()], keyword(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def run_cmd(bin, args, opts \\ [stderr_to_stdout: false], timeout_ms \\ 5_000) do
    case with_timeout(fn -> System.cmd(bin, args, opts) end, timeout_ms) do
      {:ok, {out, 0}} ->
        {:ok, out}

      {:ok, {out, code}} when is_integer(code) ->
        {:error, {:exit, code, String.trim(out)}}

      {:ok, {:error, _} = err} ->
        err

      :timeout ->
        {:error, {:timeout, timeout_ms}}
    end
  end

  @doc """
  Last-resort modal dismissal for the two AppleScript-driven terminals
  (iTerm2, Terminal.app), reached ONLY after `kill_marker/1`, `close/1`,
  and one `still_open?/1` verification have ALL already failed to clear
  the window, and only inside a watched run (RB review FIX-NOW #4 —
  stated plainly here, not just implied): this dismissal is APP-scoped,
  not sheet-scoped. `activate` brings `app_name` (the whole application
  — "iTerm2" or "Terminal", not a specific window/sheet handle) to the
  front, then sends a bare `keystroke return` via System Events, which
  per the observed Terminal.app dialog is bound to "Terminate" (the
  destructive but automation-correct choice — we already tried to kill
  the process ourselves; if a sheet is up anyway, the safest exit is to
  let it proceed). Because the keystroke is app-scoped rather than
  addressed to the exact sheet, IF that application has more than one
  window open with a confirmation sheet showing simultaneously, this
  could in principle dismiss the wrong one — a real, accepted limitation
  of automating through System Events rather than the Accessibility API
  directly. A sheet-scoped version (targeting the specific window/sheet
  element instead of "whatever is frontmost for this app") is DEFERRED,
  not implemented here: it needs to be validated against a real modal in
  a watched live matrix run before it replaces this app-scoped fallback,
  and this module does not attempt that rework.

  The explicit `activate` matters even at app scope: `keystroke` goes to
  whatever is frontmost SYSTEM-WIDE at that instant, not necessarily the
  sheet-bearing app — a bare `keystroke return` with no prior activation
  was observed to be unreliable (the window sometimes stayed open for
  many seconds after a "successful" dismiss call).

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
