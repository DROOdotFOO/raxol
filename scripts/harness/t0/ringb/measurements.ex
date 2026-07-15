defmodule T0.RingB.Measurements do
  @moduledoc """
  Per-claim judgment logic: drives a `T0.RingB.Driver` through one probe
  script (`scripts/harness/t0/probes/*.sh`) and judges the capture
  against the exact expected shapes `scripts/harness/t0/tmux/run_cell.sh`
  already validated in the sandboxed proxy cell — see each `measure_*`
  function's moduledoc reference for which `cell_*` it mirrors.

  Every measurement:

    1. Builds a HELD probe invocation (`T0_HOLD_SECONDS=N bash probe.sh
       args ringb-marker`) — the trailing marker is an inert extra
       positional argument every probe ignores, present only so
       `T0.RingB.Guard.kill_marker/1` can find and end this exact
       process later (never a longer-lived one from a prior/concurrent
       measurement).
    2. Sends it via `driver.run_command/2`.
    3. Polls `driver.get_visible/1` (bounded, `@poll_timeout_ms`) until
       the expected content shows up or the budget runs out — this
       replaces a long fixed sleep with "wait for the actual thing to
       be true," so the common case (content appears in well under a
       second) doesn't pay for the worst case, and the worst case is
       still bounded.
    4. Judges the final capture.

  Callers (the runner) own spawning the session and are responsible for
  `T0.RingB.Guard.safe_teardown/3` afterward — this module never closes
  a session itself, so a measurement failure never leaves teardown
  half-done.
  """

  alias T0.RingB.Capture
  alias T0.RingB.Guard

  # HOLD comfortably outlasts the poll deadline (with margin) so a slow
  # `get_visible` call under system load (observed: kitty's CLI round
  # trip can run several hundred ms per call when many other GUI
  # terminals/processes are already up) can never let the shell resume
  # and repaint over the measured state before polling gives up.
  @hold_seconds 8
  @poll_timeout_ms 6_000
  @poll_interval_ms 200

  @footer_c1 ["---STRIP---", "STATUS: idle", "PROMPT> hello"]
  @footer_n07 ["---STRIP---", "STATUS: idle", "PROMPT>"]

  # Drivers with a verified, cell-exact resize primitive (iTerm2's
  # `set columns/rows`, Terminal.app's `set number of columns/rows`).
  # wezterm-cli has no resize subcommand at all; kitty's only resize
  # primitive operates on pixel/OS-panel geometry, not cells — both
  # documented residuals rather than a runtime probe (calling a driver's
  # resize/3 with a throwaway session to "check" support would crash on
  # drivers that pattern-match a real session shape).
  @resize_capable ~w(iterm2 apple)a

  @doc "Which claims this driver can attempt at all, given its declared capabilities."
  @spec available_claims(module()) :: [String.t()]
  def available_claims(driver) do
    base = ~w(C1 C2 C3 N06 N07)
    if driver.name() in @resize_capable, do: base ++ ["C4"], else: base
  end

  @doc "C1 — region orientation & footer pin. Mirrors run_cell.sh's cell_c1."
  @spec measure_c1(module(), term(), String.t(), keyword()) :: map()
  def measure_c1(driver, session, probes_dir, opts \\ []) do
    height = Keyword.get(opts, :height, 24)
    footer_rows = Keyword.get(opts, :footer_rows, 3)
    marker = Guard.marker(driver.name(), "C1")

    probe = Path.join(probes_dir, "p01_region_footer.sh")
    cmd = held_cmd(probe, [height, footer_rows, 40], marker)

    with :ok <- driver.run_command(session, cmd),
         {:ok, text} <-
           poll_visible(driver, session, fn t ->
             Capture.footer(t, height, footer_rows) == @footer_c1
           end) do
      footer = Capture.footer(text, height, footer_rows)
      verdict = if footer == @footer_c1, do: "pass", else: "fail"

      %{
        claim: "C1",
        verdict: verdict,
        observable: verdict,
        notes:
          "footer tail=#{inspect(footer)} (expected #{inspect(@footer_c1)})",
        marker: marker,
        evidence: text
      }
    else
      {:error, reason} -> error_row("C1", reason, marker)
    end
  end

  @doc """
  C2 — native scrollback feed, the keystone measurement. Mirrors cell_c2.

  The fed COUNT is judged from `get_scrollback/1` (the full history), NOT
  `get_visible/1` — a ~24-row visible capture caps at ~20/100 and could
  never reach `fed` even on a terminal that HAS a full history API
  (Terminal.app `history of tab`), which would be an honestly-labeled-
  WRONG measurement. The tail window (sealed rows still ON-SCREEN above
  the footer, feeding D-PA option B) is a genuinely visible-only quantity
  and is captured separately from `get_visible/1`.

  Precondition (capacity gate, R8 calibration discipline): before the
  keystone feed, `capacity_gate/2` proves the session's scrollback holds
  at least `count` lines. Without it, a profile whose scrollback limit is
  below `count` would under-count and be recorded as a feed FAILURE
  (partial/lost) when the feed actually worked — a false negative. If the
  gate fails, this returns a `%{skip: true}` row (`:insufficient_
  scrollback`) with a clear reason rather than a bogus `lost`.
  """
  @spec measure_c2(module(), term(), String.t(), keyword()) :: map()
  def measure_c2(driver, session, probes_dir, opts \\ []) do
    height = Keyword.get(opts, :height, 24)
    footer_rows = Keyword.get(opts, :footer_rows, 3)
    count = Keyword.get(opts, :count, 100)
    marker = Guard.marker(driver.name(), "C2")

    case capacity_gate(driver, count) do
      {:ok, _depth} ->
        run_c2_feed(
          driver,
          session,
          probes_dir,
          height,
          footer_rows,
          count,
          marker
        )

      {:insufficient, info} ->
        %{
          skip: true,
          claim: "C2",
          reason:
            "insufficient_scrollback: session profile retained only " <>
              "#{info.retained} of #{count} calibration lines, so a C2 under-count would " <>
              "reflect scrollback DEPTH, not feed failure — skipped rather than recording a " <>
              "false `lost` (capacity gate, R8 discipline)."
        }

      {:error, reason} ->
        error_row("C2", {:capacity_gate_error, reason}, marker)
    end
  end

  defp run_c2_feed(
         driver,
         session,
         probes_dir,
         height,
         footer_rows,
         count,
         marker
       ) do
    probe = Path.join(probes_dir, "p02_scrollback_feed.sh")
    cmd = held_cmd(probe, [height, footer_rows, count], marker)

    with :ok <- driver.run_command(session, cmd),
         {:ok, scrollback} <-
           poll_scrollback(driver, session, fn t ->
             Capture.line_marker_count(t) >= count
           end) do
      found = Capture.line_marker_count(scrollback)

      first_last_ok =
        Capture.has_line?(scrollback, "LINE-0001") and
          Capture.has_line?(scrollback, line_n(count))

      # Tail window is an on-screen quantity — grab it from the visible
      # screen (still within the probe's HOLD, since the scrollback poll
      # above returns fast). Best-effort: a failed visible read only
      # zeroes the secondary tail metric, never the fed verdict.
      tail_window =
        case driver.get_visible(session) do
          {:ok, visible} -> Capture.tail_window_rows(visible, height)
          {:error, _} -> 0
        end

      verdict =
        cond do
          found >= count and first_last_ok -> "fed"
          found > 0 -> "partial"
          true -> "lost"
        end

      %{
        claim: "C2",
        verdict: verdict,
        observable: %{"status" => verdict, "tail_window_rows" => tail_window},
        notes:
          "found=#{found}/#{count} lines in FULL scrollback (get_scrollback); " <>
            "tail_window_rows=#{tail_window} (sealed LINE- rows still in visible viewport above footer)",
        marker: marker,
        evidence: scrollback
      }
    else
      {:error, reason} -> error_row("C2", reason, marker)
    end
  end

  @doc """
  C3 — print-above cursor protocol. Mirrors cell_c3, but the strict
  cursor-column assertion needs either a native cursor API or
  `mark_cursor/2` (a no-newline write that lands exactly at the current
  cursor) — drivers without either (Terminal.app) get a `partial`
  verdict that verifies footer content only, never a false `pass`.
  """
  @spec measure_c3(module(), term(), String.t(), keyword()) :: map()
  def measure_c3(driver, session, probes_dir, opts \\ []) do
    height = Keyword.get(opts, :height, 24)
    footer_rows = Keyword.get(opts, :footer_rows, 3)
    marker = Guard.marker(driver.name(), "C3")

    probe = Path.join(probes_dir, "p03_cursor_protocol.sh")
    cmd = held_cmd(probe, [height, footer_rows], marker)

    with :ok <- driver.run_command(session, cmd),
         {:ok, _settled} <-
           poll_visible(driver, session, fn t ->
             Capture.footer(t, height, footer_rows) == @footer_c1
           end) do
      case mark_and_capture(driver, session, height, footer_rows) do
        {:ok, footer, marker_char} ->
          expected = [
            Enum.at(@footer_c1, 0),
            Enum.at(@footer_c1, 1),
            "PROMPT> hello" <> marker_char
          ]

          verdict = if footer == expected, do: "pass", else: "fail"

          %{
            claim: "C3",
            verdict: verdict,
            observable: verdict,
            notes:
              "cursor-marker footer=#{inspect(footer)} (expected #{inspect(expected)})",
            marker: marker,
            evidence: Enum.join(footer, "\n")
          }

        {:unsupported, text} ->
          footer = Capture.footer(text, height, footer_rows)
          verdict = if footer == @footer_c1, do: "partial", else: "fail"

          %{
            claim: "C3",
            verdict: verdict,
            observable: verdict,
            notes:
              "#{driver.name()} has no cursor-position API and no non-executing raw-write " <>
                "primitive — verified footer content only (#{inspect(footer)}); the strict " <>
                "cursor-column assertion is un-automatable on this driver (documented residual, not a guess).",
            marker: marker,
            evidence: text
          }
      end
    else
      {:error, reason} -> error_row("C3", reason, marker)
    end
  end

  @doc """
  C4 — resize. Only attempted on drivers with a real resize primitive
  (see available_claims/1). Content-preservation is judged from
  `get_scrollback/1`, not `get_visible/1`, for the same reason as C2: the
  streamed markers live in history, and a ~24-row visible capture would
  under-count them regardless of whether the resize preserved anything —
  an honestly-labeled-wrong reading (this is what produced the earlier
  `apple:ghost` result: Terminal.app's `contents` is visible-only while
  its `history` holds the full stream). The capacity gate runs first so a
  shallow-scrollback profile skips rather than false-fails.
  """
  @spec measure_c4(module(), term(), String.t(), keyword()) :: map()
  def measure_c4(driver, session, probes_dir, opts \\ []) do
    height = Keyword.get(opts, :height, 24)
    footer_rows = Keyword.get(opts, :footer_rows, 3)
    count = Keyword.get(opts, :count, 30)
    marker = Guard.marker(driver.name(), "C4")

    # Cheap capability check before spending a capacity feed: a driver
    # with a real resize primitive proceeds through the gate; any other
    # driver skips immediately.
    if driver.name() in @resize_capable do
      gate_then_resize(
        driver,
        session,
        probes_dir,
        height,
        footer_rows,
        count,
        marker
      )
    else
      %{
        skip: true,
        claim: "C4",
        reason: "#{driver.name()} has no resize primitive"
      }
    end
  end

  defp gate_then_resize(
         driver,
         session,
         probes_dir,
         height,
         footer_rows,
         count,
         marker
       ) do
    case capacity_gate(driver, count) do
      {:ok, _depth} ->
        run_c4_resize(
          driver,
          session,
          probes_dir,
          height,
          footer_rows,
          count,
          marker
        )

      {:insufficient, info} ->
        %{
          skip: true,
          claim: "C4",
          reason:
            "insufficient_scrollback: retained #{info.retained} of #{count} calibration " <>
              "lines — a resize content-preservation check would reflect scrollback depth, " <>
              "not resize behaviour (capacity gate, R8 discipline)."
        }

      {:error, reason} ->
        error_row("C4", {:capacity_gate_error, reason}, marker)
    end
  end

  defp run_c4_resize(
         driver,
         session,
         probes_dir,
         height,
         footer_rows,
         count,
         marker
       ) do
    probe = Path.join(probes_dir, "p02_scrollback_feed.sh")
    cmd = held_cmd(probe, [height, footer_rows, count], marker)

    with :ok <- driver.run_command(session, cmd),
         {:ok, before_text} <-
           poll_scrollback(driver, session, fn t ->
             Capture.line_marker_count(t) >= count
           end),
         :ok <- driver.resize(session, 120, 30),
         {:ok, after_text} <- driver.get_scrollback(session) do
      before_found = Capture.line_marker_count(before_text)
      after_found = Capture.line_marker_count(after_text)
      preserved? = before_found >= count and after_found >= count

      verdict = if preserved?, do: "reflow", else: "ghost"

      %{
        claim: "C4",
        verdict: verdict,
        observable: verdict,
        notes:
          "resize 24x80 -> 30x120 during stream; content-preservation from FULL scrollback " <>
            "(before=#{before_found}, after=#{after_found} LINE- markers); perceptual reflow " <>
            "QUALITY (clean re-wrap vs ghost columns) is a screenshot residual, not asserted here.",
        marker: marker,
        evidence: after_text
      }
    else
      {:error, :unsupported} ->
        %{
          skip: true,
          claim: "C4",
          reason: "#{driver.name()} has no resize primitive"
        }

      {:error, reason} ->
        error_row("C4", reason, marker)
    end
  end

  @doc """
  N06 — full-screen clear (`\\e[2J`) history-wipe trigger. Mirrors
  cell_n06, adapted for drivers whose single capture API blurs
  visible-vs-scrollback (iTerm2/WezTerm/kitty all return one buffer —
  see `T0.RingB.Driver`'s `get_visible/1` doc). Reports what IS
  automatable (does the content survive somewhere, recoverable from
  this one capture) and documents what stays human-eye (the
  instantaneous visible-grid wipe, which needs two temporally distinct
  captures this API can't give us).
  """
  @spec measure_n06(module(), term(), String.t(), keyword()) :: map()
  def measure_n06(driver, session, probes_dir, opts \\ []) do
    height = Keyword.get(opts, :height, 24)
    footer_rows = Keyword.get(opts, :footer_rows, 3)
    count = Keyword.get(opts, :count, 20)
    marker = Guard.marker(driver.name(), "N06")

    probe = Path.join(probes_dir, "n06_keyframe_clear.sh")
    cmd = held_cmd(probe, [height, footer_rows, count], marker)

    with :ok <- driver.run_command(session, cmd),
         {:ok, text} <-
           poll_visible(driver, session, fn t ->
             Enum.member?(Capture.lines(t), "STATUS: post-keyframe")
           end) do
      found = Capture.line_marker_count(text)
      history_survives = if found >= count, do: "yes", else: "no"
      footer = Capture.footer(text, height, footer_rows)
      post_keyframe_painted = Enum.member?(footer, "STATUS: post-keyframe")

      %{
        claim: "N06",
        verdict: "fail",
        observable: %{
          "live_view_wiped" => "human_eye_required",
          "history_survives" => history_survives
        },
        notes:
          "trigger keyframe_clear_leak: single unified capture API on #{driver.name()} can't " <>
            "distinguish the instantaneous visible-grid wipe from scrollback (needs two temporally " <>
            "distinct captures a screenshot pass could give) -- recorded verdict:fail per the " <>
            "roadmap's convention (N06 is always a documented trigger, never a pass) with the " <>
            "automatable half measured: found=#{found}/#{count} LINE- markers recoverable " <>
            "post-clear (history_survives=#{history_survives}), post-keyframe footer repainted=#{post_keyframe_painted}",
        marker: marker,
        evidence: text
      }
    else
      {:error, reason} -> error_row("N06", reason, marker)
    end
  end

  @doc "N07 — inverted region negative control. Mirrors cell_n07."
  @spec measure_n07(module(), term(), String.t(), keyword()) :: map()
  def measure_n07(driver, session, probes_dir, opts \\ []) do
    height = Keyword.get(opts, :height, 24)
    footer_rows = Keyword.get(opts, :footer_rows, 3)
    marker = Guard.marker(driver.name(), "N07")

    probe = Path.join(probes_dir, "n07_inverted_region.sh")
    cmd = held_cmd(probe, [height, footer_rows, 40], marker)

    with :ok <- driver.run_command(session, cmd),
         {:ok, text} <-
           poll_visible(driver, session, fn t ->
             Capture.header(t, height, footer_rows) == @footer_n07
           end) do
      header = Capture.header(text, height, footer_rows)
      survived = if header == @footer_n07, do: "yes", else: "no"

      %{
        claim: "N07",
        verdict: "pass",
        observable: survived,
        notes:
          "detector-validation cell (not a fallback trigger itself): footer_survived=#{survived} -- " <>
            "confirms rows OUTSIDE the active region stay static even when the region is placed at " <>
            "the bottom (inverted), header=#{inspect(header)}",
        marker: marker,
        evidence: text
      }
    else
      {:error, reason} -> error_row("N07", reason, marker)
    end
  end

  # --- internal ----------------------------------------------------------------

  defp held_cmd(probe, args, marker) do
    arglist = Enum.join(args, " ")
    "T0_HOLD_SECONDS=#{@hold_seconds} bash '#{probe}' #{arglist} #{marker}"
  end

  defp line_n(n),
    do: "LINE-" <> String.pad_leading(Integer.to_string(n), 4, "0")

  defp cal_line(n),
    do: "CAL-" <> String.pad_leading(Integer.to_string(n), 4, "0")

  # Scrollback-capacity precondition (R8 calibration discipline). Runs in
  # its OWN throwaway session, NOT the caller's measurement session:
  # scrollback depth is a profile-level property (identical across every
  # session of the same driver), so a separate window measures it
  # faithfully — and, crucially, without perturbing the keystone feed.
  # (Feeding the calibration into the measurement session was observed to
  # clip one line off C2's own feed: 100 CAL lines + interstitials ahead
  # of the 100 LINE lines cost Terminal.app exactly one row, turning a
  # true `fed` into a false `partial` — the very false-negative this gate
  # exists to prevent, self-inflicted. A pristine session gives 100/100.)
  #
  # Feeds `needed` plain `CAL-####` lines (no region — this isolates pure
  # scrollback DEPTH from the region-scroll-to-history behavior that is
  # itself the C2 claim; a region probe would conflate the two) and checks
  # whether the OLDEST (CAL-0001) survived in history: if it did, the
  # buffer retains at least `needed` lines, so a later C2/C4 under-count is
  # a real feed failure, not a capacity artifact. If it was evicted, the
  # profile's scrollback is shallower than the feed and the keystone claim
  # would false-negative — the caller skips (`:insufficient_scrollback`).
  #
  # No driver here exposes a runtime scrollback-DEPTH setter through its
  # automation surface (verified: iTerm2's AppleScript session has no
  # scrollback property; wezterm/kitty set it only via config files, not
  # `cli`; mutating Terminal.app's profile `settings set` would edit the
  # user's saved profile) — so this is a calibration/assert gate, not a set.
  defp capacity_gate(driver, needed) do
    case driver.spawn_session([]) do
      {:ok, cal_session} ->
        marker = Guard.marker(driver.name(), "CAP")

        try do
          calibrate(driver, cal_session, needed)
        after
          Guard.safe_teardown(driver, cal_session, marker)
        end

      {:error, reason} ->
        {:error, {:calibration_spawn_failed, reason}}
    end
  end

  defp calibrate(driver, cal_session, needed) do
    cmd = "for i in $(seq 1 #{needed}); do printf 'CAL-%04d\\n' \"$i\"; done"

    with :ok <- driver.run_command(cal_session, cmd),
         {:ok, scrollback} <-
           poll_scrollback(driver, cal_session, fn t ->
             Capture.has_line?(t, cal_line(needed))
           end) do
      if Capture.has_line?(scrollback, "CAL-0001") do
        {:ok, %{depth_confirmed: needed}}
      else
        {:insufficient,
         %{needed: needed, retained: Capture.count_prefixed(scrollback, "CAL")}}
      end
    end
  end

  # Polls the VISIBLE screen (`get_visible/1`) until `pred.(text)` holds
  # or the wall-clock deadline passes. For claims judged against what is
  # on-screen in the held state (C1/C3/N06/N07 footer/marker checks, the
  # C2 tail window).
  defp poll_visible(driver, session, pred),
    do: poll_capture(fn -> driver.get_visible(session) end, pred)

  # Polls the FULL scrollback (`get_scrollback/1`). For claims that must
  # count the entire fed history, not just what fits on the visible grid
  # (C2's keystone feed count, C4's content-preservation, the capacity
  # calibration) — a ~24-row terminal's visible capture caps at ~20/100
  # and could never reach `fed` from `get_visible/1`, even when the
  # terminal HAS a full history API (Terminal.app `history of tab`).
  defp poll_scrollback(driver, session, pred),
    do: poll_capture(fn -> driver.get_scrollback(session) end, pred)

  # `getter` is a 0-arity `{:ok, text} | {:error, reason}` capture thunk.
  # Always returns the LAST capture taken so callers can judge (and log)
  # the best-effort final state even on a poll timeout.
  #
  # Deliberately tracks a real `System.monotonic_time/1` deadline, not a
  # "budget_ms -= @poll_interval_ms per iteration" counter — the latter
  # silently assumes every capture call itself takes ~0ms, which is false
  # under load (observed: a CLI round trip can take several hundred ms
  # when many GUI terminal processes are already running). With the naive
  # counter, a slow driver call could make the REAL elapsed time balloon
  # past the probe's own `T0_HOLD_SECONDS` window while still reporting
  # "20 iterations left" — polling right past the held state into the
  # shell's post-hold repaint and recording a false failure. Tracked
  # live: this is exactly what happened on kitty before the fix (footer
  # captured as the corrupted post-hold prompt line, not the held state,
  # despite HOLD demonstrably working when tested by hand).
  defp poll_capture(getter, pred) do
    deadline_ms = System.monotonic_time(:millisecond) + @poll_timeout_ms
    poll_capture(getter, pred, deadline_ms)
  end

  defp poll_capture(getter, pred, deadline_ms) do
    result = getter.()
    expired? = System.monotonic_time(:millisecond) >= deadline_ms

    case result do
      {:ok, text} ->
        cond do
          pred.(text) ->
            {:ok, text}

          expired? ->
            {:ok, text}

          true ->
            Process.sleep(@poll_interval_ms)
            poll_capture(getter, pred, deadline_ms)
        end

      {:error, reason} ->
        if expired? do
          {:error, reason}
        else
          Process.sleep(@poll_interval_ms)
          poll_capture(getter, pred, deadline_ms)
        end
    end
  end

  # Sends a printable marker char with no trailing newline (mark_cursor/2)
  # and re-captures; drivers without that primitive (Terminal.app) report
  # {:unsupported, text} using whatever the last poll already captured.
  defp mark_and_capture(driver, session, height, footer_rows) do
    marker_char = "#"

    case driver.mark_cursor(session, marker_char) do
      :ok ->
        Process.sleep(300)

        case driver.get_visible(session) do
          {:ok, text} ->
            {:ok, Capture.footer(text, height, footer_rows), marker_char}

          {:error, _} ->
            {:ok, [], marker_char}
        end

      {:error, :unsupported} ->
        case driver.get_visible(session) do
          {:ok, text} -> {:unsupported, text}
          {:error, _} -> {:unsupported, ""}
        end

      {:error, _reason} ->
        case driver.get_visible(session) do
          {:ok, text} -> {:unsupported, text}
          {:error, _} -> {:unsupported, ""}
        end
    end
  end

  defp error_row(claim, reason, marker) do
    %{
      claim: claim,
      verdict: "fail",
      observable: "fail",
      notes: "driver error: #{inspect(reason)}",
      marker: marker,
      evidence: ""
    }
  end
end
