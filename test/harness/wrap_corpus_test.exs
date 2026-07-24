defmodule Raxol.Harness.WrapCorpusTest do
  @moduledoc """
  Width/wrap corpus for the harness text-splitting path.

  Our width-splitting layer is `Raxol.UI.TextLayout` (wrap/truncate/clamp)
  sitting on top of the display-width facade `Raxol.UI.TextMeasure`. This
  corpus translates the *cases* from the xai-ratatui inline `segment.rs`
  `split_into_line_segments` spec -- each is a spot where terminal
  renderers get subtly wrong -- into assertions against OUR code.

  ## Architectural note (read before "fixing" a characterization case)

  In this codebase styling is separated from content: components must
  never embed raw ANSI (`\\e[...m`) in strings passed to `text()`; ANSI is
  applied only at the final `Terminal.Renderer` stage (see CLAUDE.md). So
  `TextLayout` is deliberately **content-only / ANSI-and-control-naive** --
  it wraps plain text and is never fed escape/CR/CRLF bytes on the harness
  path.

  Consequently the corpus splits in two:

    * IN-CONTRACT guarantees (Unicode double-width wrapping, overlong-char
      emission, zero-width merge at fitting width) -- asserted as real
      behavior the wrap layer must keep honoring.
    * CONTENT-ONLY BOUNDARY (trailing ANSI, bare CR, CRLF, dangling ESC) --
      pinned as characterization. The terminal-correct expectation (what a
      real ANSI-aware physical-row splitter does) is documented per case;
      our layer counts escape/control bytes as printable width because such
      bytes never legitimately reach it. These tests lock the boundary: if
      a future refactor accidentally makes `TextLayout` ANSI-aware, they
      break and prompt review.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure

  # `:pre_wrap` preserves content (incl. whitespace) and wraps at display
  # width -- the closest analog to a physical-row splitter, so it is the
  # primary mode exercised here.

  describe "in-contract: Unicode display width is honored when wrapping (spec case 2)" do
    test "CJK double-width content wraps at the cell boundary, not the char count" do
      # "hello 你好" = 6 + 4 = 10 cells; 你 好 are 2 cells each.
      assert TextMeasure.display_width("hello 你好") == 10

      # Exactly fits width 10 -> one line.
      assert TextLayout.wrap("hello 你好", 10, :pre_wrap) == ["hello 你好"]

      # Width 9 cannot hold all 10 cells -> wraps, and the wrap respects
      # that 你好 is 4 cells (does NOT slice a double-width grapheme).
      assert TextLayout.wrap("hello 你好", 9, :pre_wrap) == ["hello ", "你好"]
    end

    test "emoji is double-width for wrap purposes" do
      assert TextMeasure.display_width("😊") == 2
      # "ab😊" = 4 cells; width 3 forces the emoji to the next row.
      assert TextLayout.wrap("ab😊", 3, :pre_wrap) == ["ab", "😊"]
    end

    test ":normal mode fits by display cells too (the old char-count divergence is fixed)" do
      # This pin used to hold the char-count divergence; f99c152ba made
      # `TextWrapping.wrap_line_by_word/2` measure in display columns, so
      # :normal is now CJK-width-safe like :pre_wrap. 10 cells at width 9
      # must wrap (and :normal collapses the boundary space).
      assert TextLayout.wrap("hello 你好", 9, :normal) == ["hello", "你好"]
    end
  end

  describe "in-contract: a single grapheme wider than the whole width still emits (spec case 5)" do
    test "double-width emoji at width 1 is emitted alone -- no infinite loop, no drop" do
      assert TextLayout.wrap("😊", 1, :pre_wrap) == ["😊"]
      assert TextLayout.wrap("😊", 1, :normal) == ["😊"]
    end

    test "double-width CJK at width 1 is emitted alone" do
      assert TextLayout.wrap("中", 1, :pre_wrap) == ["中"]
    end

    test "a run of overlong graphemes each lands on its own line" do
      # Two 2-cell chars, width 1: each emitted alone, sequence terminates.
      assert TextLayout.wrap("中文", 1, :pre_wrap) == ["中", "文"]
    end
  end

  describe "in-contract: zero-width / trailing content merges, no spurious empty row (spec case 7)" do
    test "content that fits stays a single row -- no extra empty segment" do
      # Terminal-correct: a trailing zero-width SGR folds into the current
      # row. Here the whole string fits width 20, so -- escape-naive or not
      # -- it must stay ONE row with no trailing empty line appended.
      out = TextLayout.wrap("line1\e[31m", 20, :pre_wrap)
      assert out == ["line1\e[31m"]
      assert length(out) == 1
    end

    test "empty input yields exactly one empty line, never zero rows" do
      assert TextLayout.wrap("", 10, :pre_wrap) == [""]
    end
  end

  describe "content-only boundary: trailing ANSI on a full-width line (spec case 1)" do
    test "characterization: escape bytes count toward width, so a full line + reset spills" do
      # Terminal-correct (ANSI-aware splitter): "12345678\e[0m" | "90" --
      # the reset SGR folds into the full row WITHOUT counting width.
      #
      # Our content-only layer treats "\e[0m" as 4 printable cells...
      assert TextMeasure.display_width("12345678\e[0m") == 12
      # ...so the reset is pushed onto the next row. Do NOT feed styled
      # bytes to this layer; pass plain content and style at render time.
      assert TextLayout.wrap("12345678\e[0m90", 8, :pre_wrap) ==
               ["12345678", "\e[0m90"]
    end
  end

  describe "content-only boundary: bare CR does not reset the visual column (spec case 3)" do
    test "characterization: CR is counted as a width-1 char, not a column reset" do
      # Terminal-correct: CR resets the cursor to column 0, so "12345\r67"
      # occupies 5 visual cells. Our layer counts CR as 1 cell.
      assert TextMeasure.display_width("\r") == 1
      assert TextMeasure.display_width("12345\r67") == 8

      # At width 10 both interpretations fit, so the row is not split; the
      # CR byte is carried through verbatim rather than resetting anything.
      assert TextLayout.wrap("12345\r67", 10, :pre_wrap) == ["12345\r67"]
    end
  end

  describe "content-only boundary: CRLF handling (spec case 4)" do
    test "characterization: LF splits the line but the bare CR is retained, not stripped" do
      # Terminal-correct: "\r\n" is a line terminator, fully stripped ->
      # ["line1", "line2"]. Our :pre_wrap splits on "\n" only, leaving the
      # "\r" dangling on the first row.
      assert TextLayout.wrap("line1\r\nline2", 20, :pre_wrap) ==
               ["line1\r", "line2"]
    end
  end

  describe "content-only boundary: dangling incomplete escape at EOF (spec case 6)" do
    test "characterization: no crash; the partial escape is carried as content" do
      # Terminal-correct: a dangling "\e[" is an incomplete sequence, left
      # unconsumed / not rendered as width. Our layer neither crashes nor
      # loops -- it carries the bytes through (counting them as width).
      assert TextMeasure.display_width("abc\e[") == 5
      assert TextLayout.wrap("abc\e[", 10, :pre_wrap) == ["abc\e["]
    end
  end
end
