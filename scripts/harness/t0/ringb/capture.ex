defmodule T0.RingB.Capture do
  @moduledoc """
  Pure text-judgment helpers shared by every Ring B claim measurement
  (`T0.RingB.Measurements`). No terminal-specific code lives here — this
  module only knows how to turn a captured text blob (whatever a driver's
  `get_visible/1` or `get_scrollback/1` returned) into the same
  line-oriented shapes `scripts/harness/t0/tmux/run_cell.sh`'s `cell_*`
  functions already judge against tmux's `capture-pane` output.

  Real device-control capture APIs (iTerm2 `contents`, Terminal.app
  `history of tab`, wezterm-cli `get-text`, kitty `get-text`) all differ in
  one detail `tmux capture-pane -p` normalizes away for free: trailing
  whitespace padding per line, and (iTerm2 specifically) a large run of
  blank trailing lines representing unused scrollback capacity below the
  cursor. `viewport/2` is the one function that absorbs both quirks —
  verified empirically against a real iTerm2 capture (2026-07-16): a
  24-row terminal's `contents` property returned 161 total lines with the
  painted footer at lines 62-64 followed by ~97 blank padding lines; after
  dropping trailing blanks and taking the last N lines, the result is
  byte-identical (modulo trailing-space rstrip) to what `tmux
  capture-pane -p` would have shown for the same probe.
  """

  @doc "Splits text into lines, right-stripping trailing whitespace from each."
  @spec lines(String.t()) :: [String.t()]
  def lines(text) when is_binary(text) do
    text
    |> String.split(~r/\r\n|\n/)
    |> Enum.map(&String.trim_trailing/1)
  end

  @doc "Drops a trailing run of blank lines (does not touch leading/interior blanks)."
  @spec drop_trailing_blank([String.t()]) :: [String.t()]
  def drop_trailing_blank(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  The current on-screen viewport: the last `height` lines of `text` after
  dropping trailing blank padding. This is the load-bearing primitive —
  every claim's row/column judgment is a slice of this, never of the raw
  capture (which may carry an arbitrarily large scrollback-capacity tail
  of blank lines past the cursor, or leading shell-startup banner text
  before the probe ever ran).
  """
  @spec viewport(String.t(), pos_integer()) :: [String.t()]
  def viewport(text, height) do
    text
    |> lines()
    |> drop_trailing_blank()
    |> Enum.take(-height)
  end

  @doc "Last N lines of the viewport (bottom-anchored — the C1/C3 footer)."
  @spec footer(String.t(), pos_integer(), pos_integer()) :: [String.t()]
  def footer(text, height, footer_rows) do
    text |> viewport(height) |> Enum.take(-footer_rows)
  end

  @doc "First N lines of the viewport (top-anchored — the N07 inverted footer)."
  @spec header(String.t(), pos_integer(), pos_integer()) :: [String.t()]
  def header(text, height, footer_rows) do
    text |> viewport(height) |> Enum.take(footer_rows)
  end

  @doc "Count of lines anywhere in `text` matching `^LINE-\\d+$` (the P-02/N06 payload marker)."
  @spec line_marker_count(String.t()) :: non_neg_integer()
  def line_marker_count(text) do
    text |> lines() |> Enum.count(&Regex.match?(~r/^LINE-\d+$/, &1))
  end

  @doc "True if `text` contains an exact line equal to `line`."
  @spec has_line?(String.t(), String.t()) :: boolean()
  def has_line?(text, line), do: text |> lines() |> Enum.member?(line)

  @doc "Count of `^LINE-\\d+$` lines within the current viewport only (the C2 tail window)."
  @spec tail_window_rows(String.t(), pos_integer()) :: non_neg_integer()
  def tail_window_rows(text, height) do
    text |> viewport(height) |> Enum.count(&Regex.match?(~r/^LINE-\d+$/, &1))
  end

  @doc """
  Count of lines matching `^<prefix>-\\d+$` anywhere in `text`. Generic
  over the marker prefix so the scrollback-capacity calibration (which
  feeds `CAL-####` lines) can share the same exact-line-match discipline
  as the `LINE-####` payload counting, without the two ever colliding.
  """
  @spec count_prefixed(String.t(), String.t()) :: non_neg_integer()
  def count_prefixed(text, prefix) do
    re = Regex.compile!("^" <> Regex.escape(prefix) <> "-\\d+$")
    text |> lines() |> Enum.count(&Regex.match?(re, &1))
  end
end
