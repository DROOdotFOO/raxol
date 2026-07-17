defmodule Raxol.Harness.T13aSurfaceTest do
  @moduledoc """
  Acceptance suite for the assembled harness (golden-fixture assembly):
  the `Raxol.Harness.Surface` app composed end-to-end against replayed
  fixture sessions.

  Per the "don't duplicate" principle (the append path's, footer
  viewport's, and degradation ladder's own suites already exhaustively
  prove seal-once/footer-confinement/no-full-clear/cursor-balance/
  exactly-once-DECSTBM at the `InlineAuthority`/`ScrollRegionManager`
  level, with paired regression tests for every named violation class),
  this suite focuses on COMPOSITION -- does the assembled surface
  correctly route mode-pick -> authority construction -> per-advance
  seal/repaint calls -> fold/jump -> resize, driving the REAL
  `InlineAuthority`/`FlatAuthority` through a `StringIO` device and the
  REAL fixture-loading + `Raxol.Harness.Projection` pipeline -- rather
  than re-proving the substrate's own byte invariants in isolation.

  Acceptance -> test mapping:

    1. "fixture session renders full chrome" -> `describe "1. full chrome"`
    2. "sealed blocks in native scrollback" -> `describe "2. native scrollback"`
    3. "byte-capture asserts the append-path/footer-viewport invariants
       end-to-end" -> `describe "3. end-to-end invariants"`
    4. "fold/jump on replayed content ... sealed blocks never repaint" ->
       `describe "4. fold and jump"`
    5. "flat-mode parity" -> `describe "5. flat-mode parity"`
    6. "paired failure-injecting regression per invariant class" -> `describe "6. mechanical-assert regressions"`

  Research-feedback hardening (2026-07-16, external audit of comparable
  TUI harnesses -- Ink's erase-redraw memory pathology, among others):
  this lane was ahead on render COST but untested on memory RESIDENCY and
  the composer-echo LATENCY path. Three additions, none renumbering the
  acceptance list above:

    7. "unicode end-to-end" -> `describe "7. unicode end-to-end"`
       (predates this hardening pass but was never added to this list)
    8. memory residency budget (the block builder's block list + this
       module's own `events`/`projection` never virtualized) ->
       `describe "8. memory residency"`
    9. composer-echo byte/latency bounds (the keystroke path: input
       normalization -> Keymap `:passthrough` -> Composer insert ->
       footer repaint) -> `describe "9. composer-echo bounds"`
    10. `:binary.copy/1` at seal -- proving the sub-binary-pinning fix in
        `Raxol.Harness.Surface.detach_content/1` actually detaches ->
        `describe "10. binary detachment at seal"`
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.TextMeasure

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows
  @fixtures_dir Path.join(["test", "fixtures", "harness", "sessions"])

  # Word size (bytes) for converting `:erts_debug.size/1`'s word-count
  # result into bytes -- shared by describe "8. memory residency".
  @word_size :erlang.system_info(:wordsize)

  # Derived from measurement (see describe "9. composer-echo bounds"):
  # driving single ASCII keystrokes through the REAL
  # `Surface.handle_input/2` path at `@width` columns, one changed footer
  # row costs (cursor-save/restore bracket, 4 bytes) + (CUP, <=10 bytes
  # for a 1-3 digit row) + (`\e[K`, 3 bytes) + (up to `@width` bytes of
  # ASCII content) -- comfortably under `2 * @width + 24` with the
  # observed real-world max (67 bytes at width 60, ~50-char buffer). This
  # budget keeps ~2x margin over that measured worst case for ONE changed
  # row while staying tight enough to catch a regression that touches
  # more than the composer's own row.
  @echo_byte_budget 2 * @width + 24

  # -- shared harness helpers ------------------------------------------

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp load_fixture!(name) do
    path = Path.join(@fixtures_dir, "#{name}.jsonl")
    {:ok, session} = Fixture.load(path)
    session
  end

  defp new_model(session, opts) do
    {:ok, device} = StringIO.open("")

    defaults = [
      device: device,
      width: @width,
      rows: @rows,
      footer_rows: @footer_rows,
      mode: :inline_log
    ]

    model = Surface.new(session, Keyword.merge(defaults, opts))
    {model, device}
  end

  defp drive_to_completion(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive_to_completion(model)
    end
  end

  defp run_to_completion(session, opts \\ []) do
    {model, device} = new_model(session, opts)
    {drive_to_completion(model), device}
  end

  # Plain-text projection of a captured byte stream: every `{:text, _}`
  # token, concatenated -- the mechanical way to compare CONTENT while
  # ignoring styling/positioning (mirrors the degradation ladder's own
  # `flat_is_pure_text?/1` convention, reusing the project's real ANSI
  # tokenizer per CLAUDE.md rather than a bespoke regex).
  defp strip_ansi(raw) when is_binary(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("", fn {:text, text} -> text end)
  end

  defp collect_checkpoints(model, device, acc) do
    case Surface.advance(model) do
      {_model, :done} -> Enum.reverse([raw(device) | acc])
      {model, :ok} -> collect_checkpoints(model, device, [raw(device) | acc])
    end
  end

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  # Same idea as `row_text/1`, but drops double-width continuation
  # cells (`wide_placeholder: true`) instead of rendering each one as a
  # literal space -- `row_text/1`'s "blank cell -> space" convention
  # (needed to preserve genuine inter-word gaps for ASCII content) would
  # otherwise inject a spurious space after every CJK/fullwidth/emoji
  # character (each occupies TWO cells: the glyph, then a placeholder),
  # splitting e.g. "你好世界" into "你 好 世 界" -- a rendering DETAIL of
  # the two-cells-per-glyph model, not a corruption of the sealed content.
  defp row_chars(row_cells) do
    row_cells
    |> Enum.reject(& &1.wide_placeholder)
    |> Enum.map_join("", &(&1.char || " "))
    |> String.trim_trailing()
  end

  defp history_at(raw) do
    history_at(raw, width: @width, height: @rows, region_top: @region_top)
  end

  # Geometry-aware variant for cross-resize comparisons: both sides of
  # an `immutable_prefix?/2` check must replay through emulators of the
  # SAME width (else "history" rows-of-`Cell` have mismatched lengths and
  # every comparison spuriously diverges on trailing/absent columns) --
  # only `region_top` may legitimately differ between a pre-resize and a
  # post-resize snapshot of the SAME final byte stream.
  defp history_at(raw, opts) do
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    region_top = Keyword.fetch!(opts, :region_top)

    emulator = SealOracle.replay(raw, width: width, height: height)
    SealOracle.history(emulator, region_top)
  end

  # The plain-text content of every FOOTER row emitted anywhere in
  # `raw` (`repaint/2` diffs AND `keyframe/2` full redraws alike), one
  # entry per footer paint of that row -- for the caller-side width-
  # truncation guarantee `InlineAuthority`'s own moduledoc documents as
  # NOT enforced by that module ("Caller contract: footer line width").
  # A row "starts" at any CUP whose row number is > `region_top` (i.e. a
  # footer-range address, never a history-range one); everything else
  # (history-range CUPs, SGR, EL, save/restore) just terminates whatever
  # footer row text was accumulating, without being mistaken for content.
  defp footer_row_texts(raw, region_top) do
    {rows, current} =
      raw
      |> SequenceScanner.scan()
      |> Enum.reduce({[], nil}, fn
        {:csi, params, "H"}, {rows, current} ->
          rows = if current, do: [current | rows], else: rows

          if cup_row(params) > region_top do
            {rows, ""}
          else
            {rows, nil}
          end

        {:text, _text}, {rows, nil} ->
          {rows, nil}

        {:text, text}, {rows, current} ->
          {rows, current <> text}

        _token, acc ->
          acc
      end)

    rows = if current, do: [current | rows], else: rows
    Enum.reverse(rows)
  end

  defp cup_row(params) do
    case params |> String.split(";") |> List.first() |> Integer.parse() do
      {n, _rest} -> n
      :error -> 0
    end
  end

  # ---------------------------------------------------------------------
  # 1. Full chrome
  # ---------------------------------------------------------------------

  describe "1. full chrome" do
    test "fixture session renders blocks, status strip, and composer prompt" do
      session = load_fixture!("simple-chat")
      {_model, device} = run_to_completion(session)
      plain = strip_ansi(raw(device))

      # a sealed block (the completed assistant message)
      assert plain =~ "Hello!"
      # status strip labels
      assert plain =~ "Stage:"
      assert plain =~ "Input:"
      # composer's first-focus hint (empty buffer, no history, focused)
      assert plain =~ "continue"
      assert plain =~ "submit"
    end

    test "multi-tool-turn fixture renders every block kind (reasoning, 2x tool_call, message)" do
      session = load_fixture!("multi-tool-turn")
      {model, device} = run_to_completion(session)

      assert length(model.projection.blocks) == 4

      assert Enum.map(model.projection.blocks, & &1.kind) == [
               :reasoning,
               :tool_call,
               :tool_call,
               :message
             ]

      plain = strip_ansi(raw(device))
      assert plain =~ "list_dir"
      assert plain =~ "read_file"
    end
  end

  # ---------------------------------------------------------------------
  # 2. Native scrollback
  # ---------------------------------------------------------------------

  describe "2. native scrollback" do
    test "sealed blocks replay into the emulator's real scrollback/history, in order" do
      session = load_fixture!("multi-tool-turn")
      {_model, device} = run_to_completion(session)

      history_text = Enum.map(history_at(raw(device)), &row_text/1)
      joined = Enum.join(history_text, "\n")

      # in-order: reasoning before both tool calls before the final message
      reasoning_idx = index_of_substring(joined, "list the directory first")
      tool_idx = index_of_substring(joined, "list_dir")
      message_idx = index_of_substring(joined, "Root has mix.exs")

      assert reasoning_idx < tool_idx
      assert tool_idx < message_idx
    end

    defp index_of_substring(text, substr) do
      case :binary.match(text, substr) do
        {pos, _len} ->
          pos

        :nomatch ->
          flunk(
            "expected #{inspect(substr)} to appear in history text: #{inspect(text)}"
          )
      end
    end
  end

  # ---------------------------------------------------------------------
  # 3. End-to-end invariants
  # ---------------------------------------------------------------------

  describe "3. end-to-end invariants" do
    test "immutable-prefix holds across every seal checkpoint of the whole assembled run" do
      session = load_fixture!("multi-tool-turn")
      {model, device} = new_model(session, [])

      checkpoints = collect_checkpoints(model, device, [])
      final_raw = List.last(checkpoints)
      history_final = history_at(final_raw)

      for checkpoint_raw <- checkpoints do
        history_k = history_at(checkpoint_raw)

        assert :ok == SealOracle.immutable_prefix?(history_k, history_final),
               "checkpoint history must be an immutable prefix of the final history"
      end

      refute SealOracle.emits_full_clear?(final_raw),
             "assembled run must never emit \\e[2J / \\e[3J anywhere"
    end

    test "footer repaints never touch history: every post-seal footer frame leaves prior sealed content unchanged" do
      session = load_fixture!("simple-chat")
      {model, device} = new_model(session, [])

      {model, :ok} = Surface.advance(model)
      {model, :ok} = Surface.advance(model)
      {model, :ok} = Surface.advance(model)
      {model, :ok} = Surface.advance(model)
      {model, :ok} = Surface.advance(model)

      # the message block is now sealed (item_completed just landed and,
      # per this unit's own pending/painted design, gets flushed on the
      # NEXT advance -- drive one more step to force the paint).
      {model, _status} = Surface.advance(model)
      history_after_seal = history_at(raw(device))

      # Now drive several MORE footer-only repaints (fold/jump input,
      # which only ever calls paint_footer/1) with no new fixture events.
      _model =
        model
        |> Surface.handle_input(Event.key("j"))
        |> Surface.handle_input(Event.key("k"))
        |> Surface.handle_input(Event.key(:tab))

      history_after_footer_churn = history_at(raw(device))

      assert history_after_seal == history_after_footer_churn,
             "footer-only repaints must never change sealed history"
    end

    test "resize mid-fixture to a REAL new geometry composes resize |> keyframe, never rewrites already-sealed history, and confines the new footer to the new geometry" do
      session = load_fixture!("multi-tool-turn")
      {model, device} = new_model(session, [])

      # advance partway through the fixture (past the first tool_call's seal)
      model =
        Enum.reduce(1..7, model, fn _n, m -> elem(Surface.advance(m), 0) end)

      raw_before_resize = raw(device)

      # A REAL geometry change (both wider AND taller), not the prior
      # same-size no-op: 60x20 -> 80x24. `new_region_top` is what
      # `ScrollRegionManager.region_top/2` (`max(rows - footer_rows, 1)`)
      # computes for the new geometry -- 24 - 6 = 18, vs. the old 14.
      new_width = 80
      new_rows = 24
      new_region_top = new_rows - @footer_rows

      # Replay the PRE-resize bytes at the FINAL geometry's width/height
      # too (not the old 60x20) -- `Emulator.get_screen_buffer/1`'s `.cells`
      # rows are exactly `width` cells wide, so comparing a 60-wide row
      # list against an 80-wide one would spuriously "diverge" on nothing
      # but trailing, never-written columns. Content sealed before the
      # resize only ever addressed columns 0..59 either way, so replaying
      # those same bytes into the wider emulator just adds blank columns
      # 60..79 -- identical to how `history_final` (below) sees those same
      # frozen rows. Only `region_top` legitimately differs between the
      # two snapshots (what was actually history vs. footer AT THE TIME).
      history_before_resize =
        history_at(raw_before_resize,
          width: new_width,
          height: new_rows,
          region_top: @region_top
        )

      model = Surface.resize(model, new_width, new_rows)

      # Isolate JUST the resize call's own bytes (the composed
      # `resize/3 |> keyframe/2`, precondition #5) so the footer-
      # confinement check below is scoped to this call, not every seal
      # that follows it.
      raw_after_resize_call = raw(device)

      resize_bytes =
        binary_part(
          raw_after_resize_call,
          byte_size(raw_before_resize),
          byte_size(raw_after_resize_call) - byte_size(raw_before_resize)
        )

      refute new_region_top in SealOracle.cup_rows(resize_bytes),
             "the post-resize keyframe must never address the NEW geometry's last history row"

      assert (new_region_top + 1) in SealOracle.cup_rows(resize_bytes),
             "the post-resize keyframe must repaint the footer starting at the NEW geometry's first footer row"

      model = drive_to_completion(model)
      raw_final = raw(device)

      history_final =
        history_at(raw_final,
          width: new_width,
          height: new_rows,
          region_top: new_region_top
        )

      # prior history is an immutable prefix of the final history -- no
      # rewrite across the resize (both replayed at the SAME, final-
      # geometry emulator width so row-of-`Cell` lengths line up; only
      # `region_top` differs between the two snapshots, matching what was
      # actually sealed/footer-owned at each point in time).
      assert :ok ==
               SealOracle.immutable_prefix?(
                 history_before_resize,
                 history_final
               )

      refute SealOracle.emits_full_clear?(raw_final)

      # subsequent seals land correctly at the new geometry: the fixture
      # finishes with every block painted, none lost or stuck pending.
      assert Surface.done?(model)
      assert model.painted_count == length(model.projection.blocks)
      assert length(model.projection.blocks) == 4
    end
  end

  # ---------------------------------------------------------------------
  # 4. Fold and jump
  # ---------------------------------------------------------------------

  describe "4. fold and jump" do
    test "jump moves focus off the composer; fold flips PRE-paint, freezes post-paint" do
      session = load_fixture!("simple-chat")
      {model, device} = new_model(session, [])

      # Precondition #2 sanity: keymap-first -- ESC is intercepted even
      # though the composer starts focused.
      assert model.composing?
      model = Surface.handle_input(model, Event.key(:escape))
      assert strip_ansi(raw(device)) =~ "interrupt requested (stub"

      # reveal turn_started, item_started, both deltas, item_completed --
      # the message block now exists but is the PENDING (not-yet-painted)
      # trailing block (only block, fixture not yet finished).
      model =
        Enum.reduce(1..5, model, fn _n, m -> elem(Surface.advance(m), 0) end)

      assert length(model.projection.blocks) == 1
      assert model.painted_count == 0

      # Keymap's `z`/`j`/`k` binds are guarded `:not_composing` -- there is
      # no dedicated keybind in `Keymap.binds/0` that leaves the composer,
      # so this assembler exposes that transition as explicit API
      # (`focus_transcript/1`, precondition #3). Once there, jump_next
      # focuses block 0.
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("j"))
      refute model.composing?
      assert model.focused_index == 0

      # default fold for :message is :expanded -- BlockBody mounts the
      # real MessageBlock component for an expanded body (no fold glyph;
      # that's Block.render/2's own affordance, used only for the folded
      # summary). PRE-paint fold_toggle must flip it to folded, which
      # routes back through Block.render/2's glyph-bearing header --
      # visible in the footer's pending preview.
      refute strip_ansi(raw(device)) =~ "▸"
      model = Surface.handle_input(model, Event.key("z"))
      assert Map.get(model.fold_overrides, 0) == :folded
      assert strip_ansi(raw(device)) =~ "▸"

      history_before_flush = history_at(raw(device))

      # finish the fixture: turn_completed reveals no new item, so the
      # fixture ends and the pending block is flushed (painted) carrying
      # the folded override baked in.
      {model, :done} = Surface.advance(model)
      history_after_flush = history_at(raw(device))
      # the flush is a NEW append, not a rewrite of the prior (empty at
      # this point) history -- the real assertion is the NEXT step.
      assert :ok ==
               SealOracle.immutable_prefix?(
                 history_before_flush,
                 history_after_flush
               )

      # the block is now PAINTED. A further fold_toggle on the same
      # index must be a documented no-op: fold_overrides is unchanged,
      # and sealed history is byte-for-byte unchanged (seal-time-only).
      model = Surface.handle_input(model, Event.key("z"))
      assert Map.get(model.fold_overrides, 0) == :folded
      history_after_second_toggle = history_at(raw(device))

      assert history_after_flush == history_after_second_toggle,
             "sealed blocks must NEVER repaint on fold (seal-time-only)"

      # The no-op must not be operator-opaque -- pressing `z` on an
      # already-sealed block surfaces the SAME one-frame notice mechanism
      # the `:interrupt`/`:steer` stubs use, in the FOOTER only. History
      # stays byte-identical (re-asserted here, over the SAME toggle that
      # produced `history_after_second_toggle` above).
      assert strip_ansi(raw(device)) =~ "block 0 sealed"
      assert strip_ansi(raw(device)) =~ "fold unavailable"

      history_after_notice = history_at(raw(device))

      assert history_after_flush == history_after_notice,
             "the sealed-fold notice must live in the footer only -- history must stay byte-identical"
    end
  end

  # ---------------------------------------------------------------------
  # 5. Flat-mode parity
  # ---------------------------------------------------------------------

  describe "5. flat-mode parity" do
    test "same fixture through the flat path: zero escapes, same block line content" do
      session = load_fixture!("simple-chat")

      {_inline_model, inline_device} =
        run_to_completion(session, mode: :inline_log)

      {_flat_model, flat_device} = run_to_completion(session, mode: :flat)

      inline_plain = strip_ansi(raw(inline_device))
      flat_raw = raw(flat_device)

      # THE mechanical flat assert (the degradation ladder's own
      # convention): every scanned token is `{:text, _}` -- zero
      # escape-sequence tokens anywhere.
      assert Enum.all?(SequenceScanner.scan(flat_raw), &match?({:text, _}, &1)),
             "flat output must contain zero escape-sequence tokens"

      # same block line content: every non-blank flat line also appears
      # in the inline path's plain-text projection (both derive from the
      # identical BlockBody.render/ViewText.lines pipeline over the same
      # projection.blocks; only styling/positioning differ).
      flat_lines = flat_raw |> String.split("\n", trim: true)
      assert flat_lines != []

      for line <- flat_lines do
        assert String.contains?(inline_plain, line),
               "flat line #{inspect(line)} must also appear in the inline transcript"
      end

      assert String.contains?(flat_raw, "Hello!")
    end
  end

  # ---------------------------------------------------------------------
  # 6. Mechanical-assert regressions
  # ---------------------------------------------------------------------

  describe "6. mechanical-assert regressions" do
    alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

    test "a broken painted-high-water-mark reseals already-painted blocks (duplicate history); the real Surface seals each block exactly once" do
      # Simulate the exact regression this unit's `painted_count`
      # bookkeeping (`paint_pending_blocks/1`) exists to prevent: on every
      # step, reseal EVERY known-complete block from scratch (as if the
      # high-water mark never advanced past 0).
      {:ok, bad_device} = StringIO.open("")

      bad_authority =
        InlineAuthority.new(bad_device, @width, @rows, @footer_rows)

      blocks_snapshots = [
        ["assistant: Hello!\r\n"],
        ["assistant: Hello!\r\n"],
        ["assistant: Hello!\r\n"]
      ]

      _final_bad =
        Enum.reduce(blocks_snapshots, bad_authority, fn known_blocks, auth ->
          Enum.reduce(known_blocks, auth, fn line, a ->
            InlineAuthority.seal(a, line)
          end)
        end)

      bad_history_text =
        bad_device |> raw() |> history_at() |> Enum.map_join("\n", &row_text/1)

      occurrences =
        bad_history_text |> String.split("Hello!") |> length() |> Kernel.-(1)

      assert occurrences > 1,
             "re-sealing the same completed block on every step must duplicate it in scrollback history (occurrences=#{occurrences})"

      # The real Surface, driven over the real fixture, never
      # does this: `paint_pending_blocks/1`'s high-water mark seals each
      # completed block exactly once. Checked against the terminal's
      # actual HISTORY (not the raw cumulative capture stream, which
      # legitimately shows "Hello!" a second time in the footer's live-
      # tail preview while the item is still streaming -- that is
      # transient chrome, never history).
      session = load_fixture!("simple-chat")
      {_model, good_device} = run_to_completion(session)

      good_history_text =
        good_device |> raw() |> history_at() |> Enum.map_join("\n", &row_text/1)

      good_occurrences =
        good_history_text |> String.split("Hello!") |> length() |> Kernel.-(1)

      assert good_occurrences == 1,
             "the real Surface must seal the completed message block exactly once in history"
    end
  end

  # ---------------------------------------------------------------------
  # 7. Unicode end-to-end (the golden unicode-heavy fixture was
  #    shipped but never actually driven through the assembled Surface;
  #    this closes that gap)
  # ---------------------------------------------------------------------

  describe "7. unicode end-to-end" do
    test "unicode-heavy fixture: invariants hold, footer never overflows by display width, sealed CJK/emoji/RTL content survives into history" do
      session = load_fixture!("unicode-heavy")
      {model, device} = new_model(session, [])

      # (a) every named invariant holds across the whole run -- same
      # checkpoint approach as describe "3. end-to-end invariants"'s
      # first test, just driven over unicode-heavy content instead.
      checkpoints = collect_checkpoints(model, device, [])
      final_raw = List.last(checkpoints)
      history_final = history_at(final_raw)

      for checkpoint_raw <- checkpoints do
        history_k = history_at(checkpoint_raw)

        assert :ok == SealOracle.immutable_prefix?(history_k, history_final),
               "checkpoint history must be an immutable prefix of the final history (unicode-heavy)"
      end

      refute SealOracle.emits_full_clear?(final_raw),
             "unicode-heavy run must never emit \\e[2J / \\e[3J"

      # (b) footer lines never exceed the display-width budget -- the
      # real risk this test guards against is `Raxol.UI.TextMeasure`
      # mis-measuring CJK double-width runs, ZWJ emoji sequences,
      # combining marks, or RTL script, which would let `ViewText`'s
      # truncation step under/over-shoot and hand the paint authority a
      # line that overflows `width` (which the authority itself does NOT
      # defend against -- see `InlineAuthority`'s "Caller contract").
      for line <- footer_row_texts(final_raw, @region_top) do
        assert TextMeasure.display_width(line) <= @width,
               "footer line #{inspect(line)} exceeds the #{@width}-column display-width budget " <>
                 "(display_width=#{TextMeasure.display_width(line)})"
      end

      # (c) sealed CJK/emoji/combining/RTL content survives emulator
      # replay into HISTORY intact -- not mangled into replacement
      # chars, not split mid-grapheme, not dropped.
      #
      # NFC-normalized for comparison only: the fixture's message content
      # is authored with "école" as a DECOMPOSED grapheme cluster ("e" +
      # U+0301 COMBINING ACUTE ACCENT), by design -- that decomposed form
      # IS the "combining marks" case this golden fixture exists to
      # exercise (its own header note: "combining marks... exercises...
      # grapheme-boundary safety"). Normalizing both sides before matching
      # tests the thing that actually matters here -- did the GRAPHEME
      # survive, not which of two equally-valid Unicode encodings of it
      # the source JSON happened to use -- without hiding real corruption
      # (mangled/dropped/reordered bytes stay mangled/dropped/reordered
      # after normalization too).
      history_text =
        history_final
        |> Enum.map_join("\n", &row_chars/1)
        |> String.normalize(:nfc)

      # the message block's content (item_completed payload):
      # "你好世界 👨‍👩‍👧‍👦 école مرحبا שלום 🎉 done!"
      assert history_text =~ "你好世界", "CJK greeting must survive intact"

      assert history_text =~ "école",
             "Latin combining-mark text must survive intact"

      assert history_text =~ "مرحبا", "Arabic (RTL) text must survive intact"
      assert history_text =~ "שלום", "Hebrew (RTL) text must survive intact"
      assert history_text =~ "🎉", "emoji must survive intact"

      assert history_text =~ "done!",
             "trailing ASCII after the unicode run must survive intact"

      # the tool_call block's tainted result:
      # "日本語.txt\n📁 emoji-folder\nRésumé.pdf"
      assert history_text =~ "日本語.txt", "CJK filename must survive intact"

      assert history_text =~ "emoji-folder",
             "emoji-prefixed filename must survive intact"

      assert history_text =~ "Résumé.pdf",
             "accented Latin filename must survive intact"
    end
  end

  # ---------------------------------------------------------------------
  # 8. Memory residency (research feedback: the block builder's block
  #    list and this module's own `events`/`projection` fields grow forever -- seal-once
  #    killed re-render COST, not RESIDENCY. `Raxol.UI.Layout.ScrollWindow`
  #    (exists on a branch, not merged here) is the planned virtualization
  #    substrate for the block list; this test pins the BUDGET it must
  #    eventually meet, so that future integration has a concrete
  #    regression target rather than a vague "make it use less memory".
  # ---------------------------------------------------------------------

  describe "8. memory residency" do
    # A single turn with `count` completed :message items -- the fixture
    # wire shape `Raxol.Harness.Projection.project/2` accepts directly
    # (plain event-shaped maps, string-keyed payloads, atom top-level
    # fields -- see that module's moduledoc), built programmatically so
    # this file never carries a 5000-line fixture.
    defp bulk_events(count) do
      turn_started = %{
        id: 1,
        turn_id: "bulk",
        ts: 1000,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "bulk"}
      }

      items =
        for i <- 1..count do
          base_id = 2 + (i - 1) * 2
          item_id = "i#{i}"
          content = "message #{i} " <> String.duplicate("x", 40)

          [
            %{
              id: base_id,
              turn_id: "bulk",
              ts: 1000 + base_id,
              family: :loop,
              type: :item_started,
              tier: :durable,
              payload: %{"item_id" => item_id, "item_type" => "message"}
            },
            %{
              id: base_id + 1,
              turn_id: "bulk",
              ts: 1000 + base_id + 1,
              family: :loop,
              type: :item_completed,
              tier: :durable,
              payload: %{
                "item_id" => item_id,
                "item_type" => "message",
                "content" => content
              }
            }
          ]
        end

      turn_completed = %{
        id: 2 + count * 2,
        turn_id: "bulk",
        ts: 999_999,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{
          "iteration" => 1,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
          "cost" => 0.0,
          "final" => true
        }
      }

      # `List.flatten/1` both concatenates and flattens the nested
      # per-item lists in one pass -- avoids the `list ++ [single_item]`
      # append-inefficiency Credo flags (turn_started/turn_completed are
      # maps, not lists, so they pass through untouched, in place).
      List.flatten([turn_started, items, turn_completed])
    end

    defp erts_bytes(term), do: :erts_debug.size(term) * @word_size

    # Real numbers this budget is derived from (measured on this branch,
    # `MIX_ENV=test`, driving the REAL `Surface.advance/2` loop to
    # completion over synthetic single-turn/many-message events, bytes):
    #
    #   count=500:  events=189_024   blocks=144_120   model=315_248   (ratio 1.668)
    #   count=1000: events=377_024   blocks=288_120   model=627_248   (ratio 1.664)
    #   count=5000: events=1_881_024 blocks=1_440_120 model=3_123_248 (ratio 1.660)
    #
    # The model/events ratio is FLAT (in fact very slightly falling)
    # across a 10x scale increase (500 -> 5000) -- direct evidence this is
    # LINEAR growth (content strings are SHARED references between
    # `model.events` and `model.projection.blocks`, never duplicated),
    # not the quadratic/unbounded blowup this test exists to catch. 2.0 is
    # a ~20% margin over the measured ~1.66x ceiling: enough to absorb
    # incidental struct-field growth, tight enough that a real regression
    # (e.g. someone accidentally deep-copying every event into every
    # block) would trip it immediately.
    @model_to_events_ratio_ceiling 2.0

    # The paint authority's own retained state (`InlineAuthority.footer_lines`,
    # at most `footer_rows` binaries) must stay small and CONSTANT
    # regardless of how much history has been sealed -- proving the
    # substrate itself never grows an emitted-bytes accumulator inside the
    # MODEL (a StringIO test device legitimately grows forever; the model
    # must not -- that growth belongs to the test harness, not this
    # struct). Measured: 520 bytes at count=100/500/1000 alike (unchanged
    # across scale) -- 4096 is a generous ceiling, not a tight one, since
    # this assertion's whole point is "constant", not "small".
    @authority_byte_budget 4096

    defp assert_memory_residency_budget(final_model, count) do
      assert length(final_model.projection.blocks) == count
      assert final_model.painted_count == count

      events_bytes = erts_bytes(final_model.events)
      model_bytes = erts_bytes(final_model)
      authority_bytes = erts_bytes(final_model.authority)

      assert model_bytes <= @model_to_events_ratio_ceiling * events_bytes,
             "model size (#{model_bytes} bytes) exceeds #{@model_to_events_ratio_ceiling}x " <>
               "the raw revealed-event size (#{events_bytes} bytes) at count=#{count} -- " <>
               "growth must stay linear (shared content references), never superlinear"

      assert authority_bytes <= @authority_byte_budget,
             "paint-authority state (#{authority_bytes} bytes) exceeds the " <>
               "#{@authority_byte_budget}-byte constant-size budget at count=#{count} -- " <>
               "the MODEL must never retain a growing emitted-bytes accumulator " <>
               "(a StringIO test device legitimately does; the model must not)"
    end

    test "500-block smoke: model size stays within the measured ratio budget of raw event bytes" do
      events = bulk_events(500)
      {model, _device} = new_model(events, [])
      final_model = drive_to_completion(model)

      assert_memory_residency_budget(final_model, 500)
    end

    @tag :slow
    @tag timeout: 180_000
    test "5000-block: the same ratio budget holds at 10x scale -- the budget ScrollWindow virtualization must meet" do
      events = bulk_events(5000)
      {model, _device} = new_model(events, [])
      final_model = drive_to_completion(model)

      assert_memory_residency_budget(final_model, 5000)
    end
  end

  # ---------------------------------------------------------------------
  # 9. Composer-echo bounds (research feedback: the Ink-lesson keystroke
  #    path -- a normalized input event -> Keymap `:passthrough` ->
  #    Composer insert -> footer repaint (a footer diff). Ink's own
  #    documented failure mode is erase-redraw-the-world per keystroke;
  #    no suite bounded the assembled Surface's equivalent path before
  #    this. These tests prove it costs O(one footer row), never
  #    O(session size).
  # ---------------------------------------------------------------------

  describe "9. composer-echo bounds" do
    defp echo_model, do: new_model([], [])

    defp delta_since(device, prior_size) do
      all = raw(device)
      binary_part(all, prior_size, byte_size(all) - prior_size)
    end

    # Every footer emit is bracketed in `Dialect.cursor_save() <> ... <>
    # Dialect.cursor_restore()` (`with_cursor/3`'s protocol). A FRESH,
    # per-keystroke-isolated delta has no memory of the row the save
    # actually captured (that context lives in the FULL stream since
    # construction) -- feeding the bracket itself to `cup_rows/1` makes
    # the DECRC restore report a fabricated row-1 "movement" that never
    # happened. Same fix `renderer_footer_property_test.exs` already
    # uses for exactly this reason: strip the bracket before the ROW
    # check (the byte-BUDGET check below still measures the full,
    # un-stripped delta -- the bracket is real emitted-byte cost).
    #
    # Since the cursor-park protocol, the delta's tail is no longer the
    # DECRC itself: a park CUP to the composer's edit point (and, on a
    # multi-row burst, a DECTCEM hide/show wrap) follows it -- all
    # footer-confined bytes the row check SHOULD see. So the restore is
    # removed wherever it sits (first occurrence -- there is exactly one
    # bracket per keystroke echo) instead of only as a suffix.
    defp strip_cursor_bracket(bytes) do
      save = Raxol.UI.Rendering.PaintAuthority.Dialect.cursor_save()
      restore = Raxol.UI.Rendering.PaintAuthority.Dialect.cursor_restore()

      bytes
      |> strip_prefix(Raxol.UI.Rendering.PaintAuthority.Dialect.cursor_hide())
      |> strip_prefix(save)
      |> String.replace(restore, "", global: false)
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

    test "a single keystroke's echo touches only footer rows and is byte-bounded" do
      {model, device} = echo_model()
      prior_size = device |> raw() |> byte_size()

      _model = Surface.handle_input(model, Event.key("h"))

      delta = delta_since(device, prior_size)
      rows = delta |> strip_cursor_bracket() |> SealOracle.cup_rows()

      assert rows != [], "a real keystroke must actually repaint something"

      assert Enum.all?(rows, &(&1 > @region_top)),
             "keystroke echo addressed a row outside the footer range: #{inspect(rows)}"

      assert byte_size(delta) <= @echo_byte_budget,
             "single-keystroke echo cost #{byte_size(delta)} bytes exceeds the " <>
               "#{@echo_byte_budget}-byte budget for one changed footer row -- " <>
               "the Ink lesson: one keystroke must never repaint the world"
    end

    test "N sequential keystrokes: every echo stays footer-confined and byte-bounded, none touches history" do
      {model, device} = echo_model()
      chars = String.graphemes("the quick brown fox jumps")

      Enum.reduce(chars, {model, byte_size(raw(device))}, fn ch,
                                                             {m, prior_size} ->
        m2 = Surface.handle_input(m, Event.key(ch))
        delta = delta_since(device, prior_size)
        rows = delta |> strip_cursor_bracket() |> SealOracle.cup_rows()

        assert Enum.all?(rows, &(&1 > @region_top)),
               "keystroke #{inspect(ch)} addressed a non-footer row: #{inspect(rows)}"

        assert byte_size(delta) <= @echo_byte_budget,
               "keystroke #{inspect(ch)} cost #{byte_size(delta)} bytes, over the " <>
                 "#{@echo_byte_budget}-byte budget"

        {m2, byte_size(raw(device))}
      end)

      refute SealOracle.emits_full_clear?(raw(device))
    end

    property "random typing bursts: total echoed bytes stay linear in keystroke count (no quadratic blowup)" do
      check all(
              chars <-
                list_of(string(:alphanumeric, length: 1),
                  min_length: 1,
                  max_length: 30
                ),
              max_runs: 30
            ) do
        {model, device} = echo_model()
        baseline = device |> raw() |> byte_size()

        Enum.reduce(chars, model, fn ch, m ->
          Surface.handle_input(m, Event.key(ch))
        end)

        total_bytes = device |> raw() |> byte_size() |> Kernel.-(baseline)
        n = length(chars)
        ceiling = n * @echo_byte_budget

        assert total_bytes <= ceiling,
               "total echo bytes #{total_bytes} for #{n} keystrokes exceeds the " <>
                 "linear ceiling #{ceiling} (per-keystroke budget #{@echo_byte_budget}) -- " <>
                 "growth must be linear in keystrokes, never quadratic"
      end
    end

    # The live-demo defect (real terminal, harness live/fixture demos):
    # control keys arriving over the REAL raw-ANSI wire -- not the
    # `Event.key/1` test-API shape every test above uses -- were dead in
    # the composer, because `MultiLineInput.EventHandler` only matched the
    # test-API `%{key: _, modifiers: _}` data shape. Printable chars
    # worked (the Composer intercepts those itself); backspace/arrows
    # delegated onward and no-opped. This drives the REAL
    # `InputParser.parse/1` emitter through the REAL
    # `Surface.handle_input/2` route (normalize -> Keymap :passthrough ->
    # Composer -> MultiLineInput delegation).
    test "a real ANSI backspace through Surface.handle_input edits the composer draft" do
      alias Raxol.Terminal.ANSI.InputParser
      {model, _device} = echo_model()

      model =
        Enum.reduce(
          InputParser.parse("hi"),
          model,
          &Surface.handle_input(&2, &1)
        )

      [backspace_event] = InputParser.parse(<<127>>)
      model = Surface.handle_input(model, backspace_event)

      assert Raxol.UI.Components.Harness.Composer.value(model.composer) == "h"
    end

    test "real ANSI arrow keys through Surface.handle_input move the composer cursor" do
      alias Raxol.Terminal.ANSI.InputParser
      {model, _device} = echo_model()

      model =
        InputParser.parse("ab" <> "\e[D" <> "X")
        |> Enum.reduce(model, &Surface.handle_input(&2, &1))

      assert Raxol.UI.Components.Harness.Composer.value(model.composer) ==
               "aXb"
    end
  end

  # ---------------------------------------------------------------------
  # 10. Binary detachment at seal (research feedback: the sub-binary
  #     pinning footgun -- see `Raxol.Harness.Surface`'s own moduledoc,
  #     "The sub-binary pinning footgun -- :binary.copy/1 at seal").
  #     Proves the fix actually detaches: the MODEL's own retained block
  #     content, after seal, is independent memory -- not a slice still
  #     referencing a much larger originating buffer.
  # ---------------------------------------------------------------------

  describe "10. binary detachment at seal" do
    test "sealed block content is detached from a large sub-binary source: referenced_byte_size matches its own size, not the 100KB buffer it sliced from" do
      big = :binary.copy(<<?a>>, 100_000)
      # A genuine SUB-BINARY of `big` (byte_size > 64, past the BEAM's
      # auto-copy-small-slices threshold -- this really is a
      # reference-counted slice, not an implicit copy already; the
      # assertion right below proves that).
      chunk = binary_part(big, 1000, 5000)
      assert :binary.referenced_byte_size(chunk) == byte_size(big)

      events = [
        %{
          id: 1,
          turn_id: "t1",
          ts: 1,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{"prompt" => "x"}
        },
        %{
          id: 2,
          turn_id: "t1",
          ts: 2,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i1", "item_type" => "message"}
        },
        %{
          id: 3,
          turn_id: "t1",
          ts: 3,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i1",
            "item_type" => "message",
            "content" => chunk
          }
        },
        %{
          id: 4,
          turn_id: "t1",
          ts: 4,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{
            "iteration" => 1,
            "usage" => %{},
            "cost" => 0.0,
            "final" => true
          }
        }
      ]

      {model, _device} = new_model(events, [])
      model = drive_to_completion(model)

      assert model.painted_count == 1
      [block] = model.projection.blocks
      assert block.content.text == chunk

      assert :binary.referenced_byte_size(block.content.text) ==
               byte_size(chunk),
             "sealed block content must be detached from the originating " <>
               "100KB chunk (referenced_byte_size must equal the content's " <>
               "own byte_size, not the big underlying buffer's) -- see " <>
               "Raxol.Harness.Surface.detach_content/1 (private, exercised " <>
               "here only through the public advance/2 path)"
    end

    test "detachment survives FURTHER advance/2 calls made after the block already sealed" do
      # `model.projection` is fully rebuilt from `source_events` on EVERY
      # `advance/2` call (see `Raxol.Harness.Projection.project/2`) -- a
      # detach that only touched the block newly sealing THIS step would
      # be silently overwritten by the next call's fresh rebuild for
      # every EARLIER-sealed block. This fixture forces exactly that: a
      # SECOND message seals on a LATER `advance/2` call than the first,
      # so the first block's content must still be detached after that
      # later call runs.
      big = :binary.copy(<<?a>>, 100_000)
      chunk = binary_part(big, 1000, 5000)

      events = [
        %{
          id: 1,
          turn_id: "t1",
          ts: 1,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{"prompt" => "x"}
        },
        %{
          id: 2,
          turn_id: "t1",
          ts: 2,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i1", "item_type" => "message"}
        },
        %{
          id: 3,
          turn_id: "t1",
          ts: 3,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i1",
            "item_type" => "message",
            "content" => chunk
          }
        },
        %{
          id: 4,
          turn_id: "t1",
          ts: 4,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i2", "item_type" => "message"}
        },
        %{
          id: 5,
          turn_id: "t1",
          ts: 5,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i2",
            "item_type" => "message",
            "content" => "second, ordinary message"
          }
        },
        %{
          id: 6,
          turn_id: "t1",
          ts: 6,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{
            "iteration" => 1,
            "usage" => %{},
            "cost" => 0.0,
            "final" => true
          }
        }
      ]

      {model, _device} = new_model(events, [])
      model = drive_to_completion(model)

      assert model.painted_count == 2
      [first_block, second_block] = model.projection.blocks
      assert first_block.content.text == chunk
      assert second_block.content.text == "second, ordinary message"

      assert :binary.referenced_byte_size(first_block.content.text) ==
               byte_size(chunk),
             "the FIRST block's detachment must still hold after the " <>
               "SECOND block's later seal -- a fix that only re-detaches " <>
               "the newly-sealing block each call would let this one " <>
               "silently revert via Projection's full per-call rebuild"
    end
  end

  describe "9. injection: ViewText.lines strips control/ESC from leaf content" do
    alias Raxol.Harness.Surface.ViewText

    test "a :text node whose content embeds \\e[2J and a newline yields plain lines with zero ESC/control bytes" do
      view = %{
        type: :column,
        children: [
          %{type: :text, content: "before\e[2Jafter\e[1;1Hhome"},
          %{type: :text, content: "second\nline injected"}
        ]
      }

      lines = ViewText.lines(view, 100, :plain)

      for line <- lines do
        refute String.contains?(line, "\e"),
               "ViewText line #{inspect(line)} must contain no ESC byte"

        for <<b <- line>> do
          assert b > 0x1F and b != 0x7F,
                 "ViewText line #{inspect(line)} must contain no C0/DEL control byte (found #{b})"
        end
      end

      # The now-printable residue survives, proving only control/ESC bytes
      # were stripped, not the payload.
      joined = Enum.join(lines, "|")
      assert joined =~ "before"
      assert joined =~ "after"
      assert joined =~ "home"
      assert joined =~ "injected"
    end
  end
end
