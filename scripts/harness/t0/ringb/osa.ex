defmodule T0.RingB.Osa do
  @moduledoc """
  Shared osascript plumbing for the two AppleScript-driven drivers
  (iTerm2, Terminal.app). Scripts are written to a unique temp file and
  run via `osascript path.applescript` rather than `-e` — verified
  empirically that a multi-line `-e` string is fragile to quote/escaping
  edge cases, while a file avoids the whole class of problem and lets us
  write natural multi-line `tell` blocks.

  `run/1`'s output is `String.trim_trailing/1`'d only for the trailing
  newline osascript itself appends to stdout — callers must NOT further
  trim per-line whitespace here (that's `T0.RingB.Capture`'s job, and
  doing it twice would silently absorb real terminal padding
  differences between drivers into this "shared" layer instead of
  leaving it visible in the driver-specific evidence dump).

  `run/1` ITSELF is intentionally unbounded — `T0.RingB.Guard` is loaded
  AFTER this module in `T0.RingB.Boot.require_all!/1`'s fixed load order
  (`Guard.dismiss_modal_best_effort/1` calls back into `Osa.run/1`, so
  the dependency has to point one way through `Code.require_file/2`'s
  strictly sequential, non-whole-graph loading — unlike a normal
  `mix compile`, forcing a cycle here would just relocate the forward-
  reference warning instead of fixing anything). The bound lives one
  layer up instead: every AppleScript driver call site (`spawn_session/1`,
  `run_command/2`, `get_visible/1`, `get_scrollback/1`, `mark_cursor/2`,
  `resize/3`) wraps its own `Osa.run/1` call in
  `T0.RingB.Guard.with_timeout/2` (RB review FIX-NOW #1) — see
  `T0.RingB.Drivers.Iterm2` and `T0.RingB.Drivers.TerminalApp`'s private
  `guarded_osa/1`. `close/1` and `still_open?/1` were already bounded
  one layer further up still, in `T0.RingB.Guard.safe_teardown/3`.

  Accepted caveat either way: force-killing the supervising Task does
  not (and cannot) reap an orphaned `osascript` OS process still stuck
  on a one-time macOS TCC Automation permission prompt — the guarantee
  is that THIS RUN stays bounded, not that the orphan is cleaned up.
  That first-run TCC prompt (for Terminal/iTerm2/System Events
  automation control) must be clicked by a human the first time this
  harness runs on a given machine; a watched run is exactly the context
  that expects it, and every subsequent run is unattended.
  """

  @spec run(String.t()) :: {:ok, String.t()} | {:error, term()}
  def run(script) do
    path = tmp_path()

    try do
      File.write!(path, script)

      case System.cmd("osascript", [path], stderr_to_stdout: false) do
        {out, 0} -> {:ok, String.trim_trailing(out, "\n")}
        {out, code} -> {:error, {:osascript_exit, code, String.trim(out)}}
      end
    rescue
      e -> {:error, {:osascript_raised, Exception.message(e)}}
    after
      File.rm(path)
    end
  end

  @doc "Escapes a value for embedding inside a double-quoted AppleScript string literal."
  @spec escape(String.t()) :: String.t()
  def escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "t0-ringb-#{System.unique_integer([:positive])}.applescript"
    )
  end
end
