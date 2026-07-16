defmodule Raxol.Property.RendererT2cReviewFixesTest do
  @moduledoc """
  Footer `ContentGuard`: `repaint/2`/`keyframe/2` do not write
  agent/LLM-originated footer lines verbatim, so a footer line smuggling a
  control sequence cannot defeat the footer-confinement invariant FROM THE
  INSIDE -- the same threat class already closed on the history append
  path. Also covers the `needs_keyframe` latch: a geometry-changing
  `resize/3` can relocate the footer's on-screen rows while their
  logical content is unchanged; a diff-only `repaint/2` immediately after
  would otherwise see a no-op diff and write nothing, leaving ghost
  content at the new position.

  Each `describe` block below is a RED/GREEN pair: RED demonstrates the
  raw/pre-guard bytes are a real, oracle-visible (or content-visible)
  threat before GREEN shows the same payload, routed through the real
  `repaint/2`/`keyframe/2`, emerges neutralized.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Buffer.Queries
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.Rendering.PaintAuthority.Dialect
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 40
  @height 10
  @footer_rows 2
  @region_top 8

  defp new_authority(opts \\ []) do
    {:ok, device} = StringIO.open("")
    {device, InlineAuthority.new(device, @width, @height, @footer_rows, opts)}
  end

  # A second `new_authority` for tests exercising non-fixed geometry (the
  # degenerate zero-footer-capacity case) -- module-level `new_authority/1`
  # above is pinned to the fixed 10/2/40 geometry every other test relies on.
  defp new_authority(width, rows, footer_rows, opts \\ []) do
    {:ok, device} = StringIO.open("")
    {device, InlineAuthority.new(device, width, rows, footer_rows, opts)}
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp footer_range(authority) do
    top = InlineAuthority.region_top(authority)
    count = InlineAuthority.footer_row_count(authority)
    (top + 1)..(top + count)//1
  end

  defp delta(all_bytes, prior_size) do
    binary_part(all_bytes, prior_size, byte_size(all_bytes) - prior_size)
  end

  defp strip_cursor_bracket(bytes) do
    save = Dialect.cursor_save()
    restore = Dialect.cursor_restore()

    bytes
    |> strip_prefix(save)
    |> strip_suffix(restore)
  end

  defp strip_prefix(bytes, prefix) do
    if String.starts_with?(bytes, prefix) do
      binary_part(
        bytes,
        byte_size(prefix),
        byte_size(bytes) - byte_size(prefix)
      )
    else
      bytes
    end
  end

  defp strip_suffix(bytes, suffix) do
    if String.ends_with?(bytes, suffix) do
      binary_part(bytes, 0, byte_size(bytes) - byte_size(suffix))
    else
      bytes
    end
  end

  # The rendered TEXT of one wire-format (1-based) row, padded to `width`
  # with spaces past the written content's end -- same convention
  # `renderer_footer_property_test.exs` uses for content-level footer
  # assertions.
  defp footer_row_text(raw_bytes, row_1_based) do
    raw_bytes
    |> SealOracle.replay(width: @width, height: @height)
    |> Emulator.get_screen_buffer()
    |> Queries.get_text_at(0, row_1_based - 1, @width)
  end

  # ---------------------------------------------------------------------
  # ContentGuard neutralizes control bytes embedded IN footer content --
  # the same threat class as the history-side fix, applied to the footer
  # path.
  # ---------------------------------------------------------------------

  describe "\\e[3;1H (a HISTORY row CUP) smuggled in a footer line" do
    test "RED: raw bytes (what an unguarded repaint/2 would emit) let the smuggled CUP address a row outside the footer range" do
      {device, authority} = new_authority()
      prior_size = device |> raw() |> byte_size()

      footer_top = @region_top + 1
      malicious = "status: \e[3;1Hforged history write"

      # Reproduces exactly what footer_row_bytes/2 would emit for this
      # content IF repaint/2 skipped ContentGuard -- CUP to the correct
      # footer row, per-row clear, then the untouched, hostile line.
      IO.write(device, [
        Dialect.cursor_position(footer_top),
        "\e[K",
        malicious
      ])

      new_bytes = delta(raw(device), prior_size)
      rows = SealOracle.cup_rows(new_bytes)

      refute Enum.all?(rows, &(&1 in footer_range(authority))),
             "fail-first: the row scanner must be ABLE to catch a CUP " <>
               "smuggled inside footer CONTENT (not just a buggy emitter), " <>
               "or the GREEN result below is meaningless"
    end

    test "GREEN: the same content, through the real repaint/2, stays confined to the footer range and leaves the residue visible" do
      {device, authority} = new_authority()
      prior_size = device |> raw() |> byte_size()

      malicious = "status: \e[3;1Hforged history write"
      authority = InlineAuthority.repaint(authority, [malicious])

      new_bytes = delta(raw(device), prior_size)
      rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()

      assert Enum.all?(rows, &(&1 in footer_range(authority)))

      footer_top = InlineAuthority.region_top(authority) + 1

      assert footer_row_text(raw(device), footer_top) ==
               String.pad_trailing("status: [3;1Hforged history write", @width)
    end
  end

  describe "\\e[2J (full-screen clear) smuggled in a footer line" do
    test "RED: raw bytes (what an unguarded repaint/2 would emit) trigger the full-clear oracle" do
      {device, authority} = new_authority()
      prior_size = device |> raw() |> byte_size()

      footer_top = InlineAuthority.region_top(authority) + 1
      malicious = "composer \e[2J wipe"

      IO.write(device, [
        Dialect.cursor_position(footer_top),
        "\e[K",
        malicious
      ])

      new_bytes = delta(raw(device), prior_size)

      assert SealOracle.emits_full_clear?(new_bytes),
             "fail-first: the full-clear oracle must be ABLE to catch a " <>
               "\\e[2J smuggled inside footer CONTENT, or the GREEN result " <>
               "below is meaningless"
    end

    test "GREEN: the same content, through the real repaint/2, never triggers the full-clear oracle" do
      {device, authority} = new_authority()
      prior_size = device |> raw() |> byte_size()

      malicious = "composer \e[2J wipe"
      authority = InlineAuthority.repaint(authority, [malicious])

      new_bytes = delta(raw(device), prior_size)
      refute SealOracle.emits_full_clear?(new_bytes)

      footer_top = InlineAuthority.region_top(authority) + 1

      assert footer_row_text(raw(device), footer_top) ==
               String.pad_trailing("composer [2J wipe", @width)
    end

    test "GREEN: keyframe/2 with the same content also never triggers the full-clear oracle" do
      {device, authority} = new_authority()
      prior_size = device |> raw() |> byte_size()

      malicious = "composer \e[2J wipe"
      authority = InlineAuthority.keyframe(authority, [malicious])

      new_bytes = delta(raw(device), prior_size)
      refute SealOracle.emits_full_clear?(new_bytes)

      footer_top = InlineAuthority.region_top(authority) + 1

      assert footer_row_text(raw(device), footer_top) ==
               String.pad_trailing("composer [2J wipe", @width)
    end
  end

  describe "\\e[K (erase-line) smuggled in a footer line" do
    test "RED: raw bytes let the smuggled EL execute silently -- it vanishes instead of appearing as text" do
      {device, _authority} = new_authority()

      footer_top = @region_top + 1
      # An EL embedded mid-content: if executed, "before" survives (already
      # written, ahead of the erase point) but the ESC+[+K token itself
      # produces no glyphs of its own -- unlike ordinary printable text, it
      # does not survive as characters on the row.
      malicious = "before\e[Kafter"

      IO.write(device, [
        Dialect.cursor_position(footer_top),
        "\e[K",
        malicious
      ])

      text = footer_row_text(raw(device), footer_top)

      refute text =~ "[K",
             "fail-first: an unguarded \\e[K must be ABLE to execute (and " <>
               "vanish) instead of surviving as literal text, or the GREEN " <>
               "residue assertion below is meaningless"

      assert text == String.pad_trailing("beforeafter", @width)
    end

    test "GREEN: the same content, through the real repaint/2, leaves the ESC+[+K residue visible instead of executing it" do
      {device, authority} = new_authority()

      malicious = "before\e[Kafter"
      authority = InlineAuthority.repaint(authority, [malicious])

      footer_top = InlineAuthority.region_top(authority) + 1

      assert footer_row_text(raw(device), footer_top) ==
               String.pad_trailing("before[Kafter", @width)
    end
  end

  describe "a legitimately styled footer line stays styled (SGR passes through byte-identical)" do
    test "GREEN: \\e[1;31m...\\e[0m survives repaint/2 unchanged" do
      {device, authority} = new_authority()
      bytes_before = raw(device)

      styled = "\e[1;31malert\e[0m"
      _ = InlineAuthority.repaint(authority, [styled])

      all_bytes = raw(device)
      new_bytes = delta(all_bytes, byte_size(bytes_before))

      assert new_bytes =~ styled
    end

    test "GREEN: \\e[1;31m...\\e[0m survives keyframe/2 unchanged" do
      {device, authority} = new_authority()
      bytes_before = raw(device)

      styled = "\e[1;31malert\e[0m"
      _ = InlineAuthority.keyframe(authority, [styled])

      all_bytes = raw(device)
      new_bytes = delta(all_bytes, byte_size(bytes_before))

      assert new_bytes =~ styled
    end
  end

  describe "footer content sanitization runs BEFORE padding/diffing (footer_lines only ever holds sanitized content)" do
    test "footer_diff/2 never sees the raw ESC -- a stored footer_lines entry is already sanitized" do
      {_device, authority} = new_authority()

      authority = InlineAuthority.repaint(authority, ["plain \e[2J line"])

      assert authority.footer_lines == [
               "plain [2J line",
               ""
             ]
    end
  end

  # ---------------------------------------------------------------------
  # needs_keyframe latch: a geometry-changing resize/3 relocates the
  # footer's on-screen rows; the NEXT repaint/2 must not trust a diff
  # against content whose position moved.
  # ---------------------------------------------------------------------

  describe "needs_keyframe latch: resize/3 sets it, repaint/2 self-promotes and clears it" do
    test "RED: without the latch, a diff-only repaint of UNCHANGED content after a geometry-changing resize emits zero bytes -- the ghost-content bug" do
      {device, authority} = new_authority()
      authority = InlineAuthority.repaint(authority, ["live tail", "composer"])

      resized = InlineAuthority.resize(authority, @width, 20)
      assert resized.needs_keyframe

      # Simulate the PRE-FIX world: resize/3 without the needs_keyframe
      # latch left no signal that geometry changed, so the following
      # repaint/2 ran its ordinary diff-only path.
      unlatched = %{resized | needs_keyframe: false}

      prior_size = device |> raw() |> byte_size()
      _ = InlineAuthority.repaint(unlatched, ["live tail", "composer"])

      assert delta(raw(device), prior_size) == "",
             "fail-first: a diff-only repaint of unchanged content right " <>
               "after a geometry-changing resize must be ABLE to emit zero " <>
               "bytes, or the GREEN result below is meaningless"
    end

    test "GREEN: the real resize/3 leaves the latch set, so repaint/2 fully re-renders the footer even though content is unchanged" do
      {device, authority} = new_authority()
      authority = InlineAuthority.repaint(authority, ["live tail", "composer"])

      resized = InlineAuthority.resize(authority, @width, 20)
      assert resized.needs_keyframe

      prior_size = device |> raw() |> byte_size()
      final = InlineAuthority.repaint(resized, ["live tail", "composer"])

      new_bytes = delta(raw(device), prior_size)

      assert new_bytes != "",
             "needs_keyframe latch failed: repaint/2 right after a " <>
               "geometry-changing resize must fully re-render the footer " <>
               "even when content is unchanged"

      rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()

      assert MapSet.new(rows) == MapSet.new(footer_range(final)),
             "the self-promoted keyframe must touch EVERY footer row, not " <>
               "a diff subset"

      refute final.needs_keyframe,
             "the latch must clear once the self-promoted keyframe runs"
    end

    test "GREEN: a stale blank row still gets its own \\e[K at the NEW footer position after resize" do
      {device, authority} = new_authority()
      # Only one line -- pad_rows/2 makes the second footer row "" already,
      # both before and after the upcoming resize.
      authority = InlineAuthority.repaint(authority, ["only line"])

      resized = InlineAuthority.resize(authority, @width, 20)
      prior_size = device |> raw() |> byte_size()

      # Same single line again -- logically UNCHANGED (row 2 is "" both
      # before and after), which a diff-only repaint would skip entirely.
      final = InlineAuthority.repaint(resized, ["only line"])

      new_bytes = delta(raw(device), prior_size)
      new_footer_top = InlineAuthority.region_top(final) + 1
      stale_row = new_footer_top + 1

      rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()
      assert stale_row in rows

      expected_fragment = Dialect.cursor_position(stale_row) <> "\e[K"
      assert String.contains?(new_bytes, expected_fragment)
    end

    test "a width-only resize now sets needs_keyframe (footer re-truncation + reflow seam)" do
      # width 40 -> 80, height unchanged: `history_bottom` is row-based, so the
      # REGION needs no re-emit (the append path's pinned regression, below, still holds) --
      # but the footer may need re-truncation to the new width, and reflow-capable
      # terminals rewrap sealed history on a WIDTH change. The latch keys on the
      # width axis too, not just the vertical geometry, so the first repaint after
      # a width resize fully re-renders rather than diffing against stale-width state.
      {_device, authority} = new_authority()
      widened = InlineAuthority.resize(authority, 80, @height)

      assert widened.needs_keyframe
    end

    test "reflow_capable_resize telemetry fires on a WIDTH-only resize (the axis reflow actually happens on)" do
      {_device, authority} = new_authority()
      authority = %{authority | reflow_capable?: true}

      ref = make_ref()
      handler = {__MODULE__, ref}

      :telemetry.attach(
        handler,
        [:raxol, :ui, :paint_authority, :reflow_capable_resize],
        fn _event, _measure, meta, {pid, r} -> send(pid, {:reflow, r, meta}) end,
        {self(), ref}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # Width 40 -> 30 (SHRINK, the reflow-triggering direction), height
      # unchanged. `history_bottom` is identical, so the old vertical-only gate
      # never fired this event -- reflow happens on the horizontal axis, so the
      # seam the future (B) reflow unit gates on must observe the width delta.
      InlineAuthority.resize(authority, 30, @height)

      assert_receive {:reflow, ^ref, meta}
      assert meta.old_width == @width
      assert meta.new_width == 30
    end

    test "resize/3 emits ONLY the DECSTBM re-set even with the latch change (the append path's pinned regression is untouched)" do
      {device, authority} = new_authority()
      bytes_before = raw(device)

      resized = InlineAuthority.resize(authority, @width, 20)

      all_bytes = raw(device)
      new_bytes = delta(all_bytes, byte_size(bytes_before))

      assert new_bytes == Dialect.region_set(1, 20 - @footer_rows)
      assert resized.needs_keyframe
    end
  end

  # ---------------------------------------------------------------------
  # Bundled trivials
  # ---------------------------------------------------------------------

  describe "footer_diff/2: explicit ArgumentError on length mismatch" do
    test "raises ArgumentError (not a bare FunctionClauseError), naming the fix" do
      assert_raise ArgumentError, ~r/same length/, fn ->
        InlineAuthority.footer_diff(["a", "b"], ["only one"])
      end
    end
  end

  describe "keyframe/2: zero footer rows early-returns with no bracket at all" do
    test "on degenerate geometry with zero footer capacity, keyframe/2 emits nothing" do
      {device, authority} = new_authority(40, 1, 2)
      assert InlineAuthority.footer_row_count(authority) == 0

      prior_size = device |> raw() |> byte_size()
      _ = InlineAuthority.keyframe(authority, ["anything", "at all"])

      assert delta(raw(device), prior_size) == ""
    end
  end

  describe "repaint/2: the no-op branch still normalizes footer_lines to the current padded length" do
    test "a no-op repaint writes back the padded footer_lines even though nothing changed" do
      {_device, authority} = new_authority()

      # Directly construct the invariant this fix protects: footer_lines
      # shorter than the CURRENT footer row count (as if the row count had
      # changed without this field ever catching up).
      stale = %{authority | footer_lines: ["only one line"]}

      final = InlineAuthority.repaint(stale, ["only one line"])

      assert final.footer_lines == ["only one line", ""]

      assert length(final.footer_lines) ==
               InlineAuthority.footer_row_count(final)
    end
  end

  describe "history_bottom rename follow-through" do
    test "InlineAuthority.region_top/1 delegates to ScrollRegionManager.history_bottom/1, not a stale region_top/1" do
      {_device, authority} = new_authority()
      assert InlineAuthority.region_top(authority) == @region_top
    end
  end
end
