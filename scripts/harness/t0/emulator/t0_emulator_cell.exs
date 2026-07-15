# T0 — emulator cell (Ring A structural reference, per 01-t0-matrix.md §3).
#
# Drives the EXACT SAME probe byte streams the tmux/real-terminal cells use
# (scripts/harness/t0/probes/*.sh, invoked as external processes so this is
# a byte-for-byte match, never a re-implementation) through
# `Raxol.Terminal.Emulator` via `Raxol.Test.CrossTerminal.AnsiReplayer`, and
# reports the structural (grid-level) invariants the emulator CAN prove:
# footer-pin (C-1), cursor save/restore (C-3), teardown byte shape (C-6),
# and the \\e[2J regression guard (N-06).
#
# Per 01-t0-matrix.md §3.2: this cell CANNOT prove native scrollback-feed
# (C-2) or resize-reflow (C-4) or mode-2026 tearing (C-5-perceptual) —
# `commands/scrolling.ex scroll_up` blanks vacated region rows instead of
# feeding `scrollback_buffer`, so C-2/C-4/C-5 are recorded as :n/a here,
# NEVER :pass. Treating a green emu run as scrollback proof would be the
# most dangerous false positive in this whole plan (verbatim from the
# test-suite design this cell implements).
#
# Usage (from repo root):
#   MIX_ENV=test mix run scripts/harness/t0/emulator/t0_emulator_cell.exs
#
# Prints one JSON CellResult per line to stdout (terminal: "emu").

alias Raxol.Test.CrossTerminal.AnsiReplayer, as: Replayer
alias Raxol.Test.CrossTerminal.SequenceScanner, as: Scanner

# The emulator logs verbosely at :debug (cursor moves, scroll internals).
# Silence it so stdout stays pure JSON Lines -- callers pipe this straight
# into `jq`/`run_matrix.sh`'s aggregator.
Logger.configure(level: :none)

probes_dir = Path.expand("../probes", __DIR__)
evidence_dir = Path.expand("../capture/evidence", __DIR__)
File.mkdir_p!(evidence_dir)

run_probe = fn script, args ->
  {out, 0} =
    System.cmd("bash", [Path.join(probes_dir, script) | args],
      stderr_to_stdout: false
    )

  out
end

row = fn fields ->
  fields
  |> Map.new()
  |> Jason.encode!()
  |> IO.puts()
end

# --- C-1 / C-3 structural: p01 region+footer, replayed through the emulator.

p01_bytes = run_probe.("p01_region_footer.sh", ["24", "3", "40"])
emu = Replayer.replay(p01_bytes, width: 80, height: 24)
grid = Replayer.visible_text(emu)
footer_lines = grid |> String.split("\n") |> Enum.take(-3)

footer_ok =
  footer_lines == ["---STRIP---", "STATUS: idle", "PROMPT> hello"]

File.write!(Path.join(evidence_dir, "emu-c1.txt"), grid)

row.(%{
  terminal: "emu",
  context: "plain",
  transport: "local",
  claim: "C1",
  observable: if(footer_ok, do: "pass", else: "fail"),
  capture: "emulator",
  automation: "ci",
  evidence: "capture/evidence/emu-c1.txt",
  verdict: if(footer_ok, do: "pass", else: "fail"),
  notes:
    "structural half only (footer rows unchanged in the replayed grid); scrollback-feed is NOT provable here, see C2"
})

# --- C-2: explicitly n/a (the documented emulator limitation).

row.(%{
  terminal: "emu",
  context: "plain",
  transport: "local",
  claim: "C2",
  observable: "n/a",
  capture: "emulator",
  automation: "ci",
  evidence: "n/a",
  verdict: "n/a",
  notes:
    "commands/scrolling.ex scroll_up/4 blanks vacated region rows instead of feeding scrollback_buffer (buffer/scroll.ex add_line only wired to full-buffer scroll paths) -- the emulator CANNOT be the C-2 oracle. See TE (optional side-quest) in harness-ui-roadmap.md. Never mark this :pass."
})

# --- C-3 structural: p03 cursor protocol.

p03_bytes = run_probe.("p03_cursor_protocol.sh", ["24", "3"])
emu3 = Replayer.replay(p03_bytes, width: 80, height: 24)
{cur_row, cur_col} = Replayer.cursor(emu3)
# AnsiReplayer.cursor/1 returns {row, col} 0-based per its own doc note.
cursor_ok = {cur_row, cur_col} == {23, 13}

row.(%{
  terminal: "emu",
  context: "plain",
  transport: "local",
  claim: "C3",
  observable: if(cursor_ok, do: "pass", else: "fail"),
  capture: "emulator",
  automation: "ci",
  evidence: "n/a",
  verdict: if(cursor_ok, do: "pass", else: "fail"),
  notes:
    "cursor after two print-above/DECSC-DECRC cycles: got {#{cur_row},#{cur_col}}, expected {23,13} (row24 col14, 1-based)"
})

# --- C-6 structural: teardown byte shape (no 1049h anywhere; CSI r present).

p06_bytes = run_probe.("p06_teardown.sh", ["clean", "24", "3"])
tokens = Scanner.scan(p06_bytes)

has_1049h =
  Enum.any?(tokens, fn
    {:csi, "?1049", "h"} -> true
    _ -> false
  end)

has_region_reset =
  Enum.any?(tokens, fn
    {:csi, "", "r"} -> true
    _ -> false
  end)

teardown_ok = not has_1049h and has_region_reset

row.(%{
  terminal: "emu",
  context: "plain",
  transport: "local",
  claim: "C6",
  observable: if(teardown_ok, do: "clean", else: "stuck_region"),
  capture: "emulator",
  automation: "ci",
  evidence: "n/a",
  verdict: if(teardown_ok, do: "pass", else: "fail"),
  notes:
    "byte-shape guard only (IE-1 shape): zero CSI ?1049h AND a bare CSI r present. Real teardown-under-signal behavior is Ring B only (tmux/real-terminal), not provable by grid replay."
})

# --- N-06: the \\e[2J regression guard (this IS a cheap, high-value Ring-A gate).

n06_bytes = run_probe.("n06_keyframe_clear.sh", ["24", "3", "20"])
n06_tokens = Scanner.scan(n06_bytes)

has_2j =
  Enum.any?(n06_tokens, fn
    {:csi, "2", "J"} -> true
    _ -> false
  end)

# Positive control: the SAME scan against p01 (no keyframe) must NOT fire.
p01_tokens = Scanner.scan(p01_bytes)

p01_has_2j =
  Enum.any?(p01_tokens, fn
    {:csi, "2", "J"} -> true
    _ -> false
  end)

false_positive = p01_has_2j

row.(%{
  terminal: "emu",
  context: "plain",
  transport: "local",
  claim: "N06",
  observable: %{
    keyframe_clear_leak_fixture: has_2j,
    false_positive_on_p01: false_positive
  },
  capture: "emulator",
  automation: "ci",
  evidence: "n/a",
  verdict:
    if(has_2j and not false_positive,
      do: "fail_as_expected",
      else: "detector_broken"
    ),
  notes:
    "N-06's fixture correctly contains \\e[2J (has_2j=#{has_2j}); the clean p01 stream correctly contains none (false_positive=#{false_positive}). This pairing IS the permanent CI regression net (roadmap 'cheapest, highest-value guard'): once T2c exists, assert zero \\e[2J on ITS emit stream using this same scan."
})
