defmodule Raxol.Harness.UnreadDividerSurfaceTest do
  @moduledoc """
  Integration suite for the unread divider on the assembled harness
  (`Raxol.Harness.Surface` + `Raxol.Harness.UnreadDivider`), driving the
  REAL `InlineAuthority` through a `StringIO` device and reading the
  resulting footer grid back through the `SealOracle` replay harness --
  the same byte-level discipline as `t13a_surface_test.exs`.

  ## What this suite pins (each claim = a named test)

    * **The ratified acceptance**: blur -> N blocks arrive -> focus renders
      exactly one "N new since you looked" rule in the LIVE region
      (the footer viewport), positioned between the status strip and the
      pending/live preview.
    * **The mode-1004 seam**: `Surface.blur/1` / `Surface.focus/1` are the
      explicit attention API a later focus-event unit wires; keystrokes
      through `Surface.handle_input/2` are the fallback return signal.
    * **Clears on scroll-past**: jump navigation (`j`) reaching the
      boundary block retires the divider; the divider itself is NOT a
      block (no fold identity, no focus slot) -- jumps skip it by
      construction because `focused_index` ranges over
      `projection.blocks` only.
    * **The goldens decision**: the divider is live-region-only. Sealed
      history bytes are IDENTICAL with and without divider activity, so
      the seal-once property suite and the `.blocks.json` projection
      snapshots need no new fixtures and no off-by-default switch --
      enforced here byte-for-byte, not asserted in prose.
    * **Hostile adjacency**: divider-adjacent untrusted content (the
      adversarial fixture) still crosses the ViewText sanitize seam; the
      divider row itself is module-built inert text (rule glyphs, digits,
      the fixed label), and the whole run still never emits a full clear.
    * **Width discipline**: the rule is sized to the CURRENT width via
      TextMeasure -- exact at narrow widths too.
    * **Flat-mode honesty**: no footer, no live region, no divider; the
      attention API is a safe no-op there.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.TextMeasure

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows
  @fixtures_dir Path.join(["test", "fixtures", "harness", "sessions"])

  @label "new since you looked"

  # -- shared harness helpers (t13a conventions) -------------------------

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp load_fixture!(name) do
    path = Path.join(@fixtures_dir, "#{name}.jsonl")
    {:ok, session} = Fixture.load(path)
    session
  end

  defp new_model(session, opts \\ []) do
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

  defp advance_times(model, 0), do: model

  defp advance_times(model, n) do
    {model, _status} = Surface.advance(model)
    advance_times(model, n - 1)
  end

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  # The CURRENT footer grid rows (as trimmed text), read back by replaying
  # the full byte capture through the real emulator -- final screen state,
  # not per-repaint diffs, so "the divider is (not) on screen right now"
  # is asserted against what an operator actually sees.
  defp footer_texts(device, opts \\ []) do
    width = Keyword.get(opts, :width, @width)
    rows = Keyword.get(opts, :rows, @rows)
    region_top = Keyword.get(opts, :region_top, @region_top)

    device
    |> raw()
    |> SealOracle.replay(width: width, height: rows)
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.drop(region_top)
    |> Enum.map(&row_text/1)
  end

  defp divider_rows(footer_texts),
    do: Enum.filter(footer_texts, &String.contains?(&1, @label))

  defp history_texts(device) do
    device
    |> raw()
    |> SealOracle.replay(width: @width, height: @rows)
    |> SealOracle.history(@region_top)
    |> Enum.map(&row_text/1)
  end

  # Drives simple-chat to the standard scenario: reveal a prefix, blur,
  # reveal the rest, focus. Returns {model, device, expected_count}.
  defp blur_focus_run(prefix_advances \\ 3) do
    {model, device} = new_model(load_fixture!("simple-chat"))

    model = advance_times(model, prefix_advances)
    seen = length(model.projection.blocks)

    model = Surface.blur(model)
    model = drive_to_completion(model)
    total = length(model.projection.blocks)

    assert total > seen,
           "test precondition: blocks must arrive while blurred " <>
             "(seen #{seen}, total #{total})"

    model = Surface.focus(model)
    {model, device, total - seen}
  end

  # -- 1. the ratified acceptance -----------------------------------------

  describe "1. blur -> events -> focus renders the divider (ratified acceptance)" do
    test "exactly one divider row, carrying the unattended count" do
      {_model, device, count} = blur_focus_run()

      rows = divider_rows(footer_texts(device))

      assert length(rows) == 1,
             "expected exactly one divider row, got #{inspect(rows)}"

      assert hd(rows) =~ "#{count} #{@label}"
    end

    test "the divider sits between the status strip and the preview/composer rows" do
      {_model, device, _count} = blur_focus_run()

      footer = footer_texts(device)

      divider_index = Enum.find_index(footer, &String.contains?(&1, @label))

      # The status strip yields to silence once the turn has completed
      # (the strip-visibility gate), so on this idle post-run frame the
      # divider is the FIRST footer row, directly above the preview/
      # composer rows it separates the unread span from.
      assert divider_index == 0,
             "the divider must be the first footer row on an idle frame " <>
               "(the strip yields after turn completion), got index " <>
               "#{inspect(divider_index)} in " <> inspect(footer)
    end

    test "no blur, no divider: an attended run never renders the rule" do
      {model, device} = new_model(load_fixture!("simple-chat"))
      model = drive_to_completion(model)
      _model = Surface.focus(model)

      assert divider_rows(footer_texts(device)) == []
    end

    test "blur with nothing arriving renders no divider on focus" do
      {model, device} = new_model(load_fixture!("simple-chat"))
      model = drive_to_completion(model)
      model = Surface.blur(model)
      _model = Surface.focus(model)

      assert divider_rows(footer_texts(device)) == []
    end
  end

  # -- 2. one divider, frozen count ----------------------------------------

  describe "2. one divider per span, count frozen at return" do
    test "footer-only churn after focus keeps exactly one divider with the same count" do
      {model, device, count} = blur_focus_run()

      model = Surface.tick(model, 1_000)
      model = Surface.handle_input(model, Event.key("x"))
      _model = Surface.tick(model, 2_000)

      rows = divider_rows(footer_texts(device))
      assert length(rows) == 1
      assert hd(rows) =~ "#{count} #{@label}"
    end
  end

  # -- 3. clears on scroll-past --------------------------------------------

  describe "3. scroll-past retires the divider; jumps skip it gracefully" do
    test "jumping to the boundary block clears the divider from the footer" do
      {model, device, _count} = blur_focus_run()

      model = Surface.focus_transcript(model)

      # Jump forward until every block has been visited -- the boundary
      # block is necessarily among them (jump navigation ranges over
      # projection.blocks only; the divider itself has no focus slot, so
      # this loop also proves jumps never land ON the divider).
      total = length(model.projection.blocks)

      _model =
        Enum.reduce(1..total, model, fn _i, acc ->
          Surface.handle_input(acc, Event.key("j"))
        end)

      assert divider_rows(footer_texts(device)) == [],
             "the divider must retire once navigation reaches the boundary"
    end

    test "jumping strictly before the boundary keeps the divider" do
      # multi-tool-turn is the multi-block fixture: 2 completed blocks
      # after 5 reveals (simple-chat folds into a single block, which can
      # never place a jump strictly before the boundary).
      {model, device} = new_model(load_fixture!("multi-tool-turn"))

      # Reveal enough that at least 2 blocks exist BEFORE the blur, so a
      # first jump (index 0) stays strictly before the boundary.
      model = advance_times(model, 5)
      seen = length(model.projection.blocks)

      assert seen >= 2,
             "test precondition: need >= 2 pre-blur blocks, got #{seen}"

      model = Surface.blur(model)
      model = drive_to_completion(model)
      model = Surface.focus(model)

      model = Surface.focus_transcript(model)
      _model = Surface.handle_input(model, Event.key("j"))

      assert length(divider_rows(footer_texts(device))) == 1,
             "a jump landing before the boundary must not clear the divider"
    end
  end

  # -- 3b. reconciliation: a stale span never renders past reality ----------

  describe "3b. a block-count shrink after focus cannot leave a stuck divider" do
    test "the footer stops rendering a span whose boundary exceeds the extant blocks" do
      {model, device, _count} = blur_focus_run()

      # Simulate the shrink the reviewer reproduced (replay/reattach/
      # truncation rebuilding a smaller projection): the model is a plain
      # map, so the projection can be hand-shrunk below the frozen
      # span's boundary. The very next footer paint must drop the stale
      # divider -- viewed/2's navigation gate is unreachable in this
      # state, so rendering it would be a permanent false claim.
      span = Raxol.Harness.UnreadDivider.divider(model.unread)
      assert span != nil, "test precondition: an active span"

      shrunk = Enum.take(model.projection.blocks, max(span.from - 1, 0))

      model = %{
        model
        | projection: %{model.projection | blocks: shrunk},
          painted_count: min(model.painted_count, length(shrunk))
      }

      _model = Surface.tick(model, 9_000)

      assert divider_rows(footer_texts(device)) == [],
             "a divider whose boundary no longer exists must not render"
    end
  end

  # -- 4. the keystroke fallback -------------------------------------------

  describe "4. keystroke return (the fallback attention signal)" do
    test "blur -> events -> a plain keystroke renders the divider without any focus call" do
      {model, device} = new_model(load_fixture!("simple-chat"))

      model = advance_times(model, 3)
      seen = length(model.projection.blocks)

      model = Surface.blur(model)
      model = drive_to_completion(model)
      count = length(model.projection.blocks) - seen

      _model = Surface.handle_input(model, Event.key("h"))

      rows = divider_rows(footer_texts(device))
      assert length(rows) == 1
      assert hd(rows) =~ "#{count} #{@label}"
    end
  end

  # -- 5. overlay suppression ----------------------------------------------

  describe "5. the overlay picker suppresses the divider while open" do
    test "open hides it, close restores it" do
      {model, device, count} = blur_focus_run()

      {:ok, model} = Surface.open_overlay(model, ["alpha", "beta"])

      assert divider_rows(footer_texts(device)) == [],
             "the overlay claims the footer space; the divider must yield"

      _model = Surface.close_overlay(model)

      rows = divider_rows(footer_texts(device))
      assert length(rows) == 1
      assert hd(rows) =~ "#{count} #{@label}"
    end
  end

  # -- 6. the goldens decision: sealed history is untouched -----------------

  describe "6. live-region only: sealed bytes identical with and without divider activity" do
    test "history rows are byte-identical across an attended and an unattended run" do
      {plain_model, plain_device} = new_model(load_fixture!("simple-chat"))
      _plain_model = drive_to_completion(plain_model)

      {model, device} = new_model(load_fixture!("simple-chat"))
      model = advance_times(model, 3)
      model = Surface.blur(model)
      model = drive_to_completion(model)
      model = Surface.focus(model)
      model = Surface.tick(model, 5_000)
      _model = Surface.handle_input(model, Event.key("y"))

      assert history_texts(device) == history_texts(plain_device),
             "divider activity must never change sealed history -- the " <>
               "goldens (projection snapshots + seal-once property suite) " <>
               "stay valid without new fixtures"
    end

    test "the divider text never appears in the history region" do
      {_model, device, _count} = blur_focus_run()

      refute Enum.any?(history_texts(device), &String.contains?(&1, @label)),
             "the v1 divider is live-region only; an in-history divider " <>
               "is the deferred reflow-capable upgrade"
    end
  end

  # -- 7. hostile adjacency --------------------------------------------------

  describe "7. hostile divider-adjacent content cannot smuggle bytes" do
    test "adversarial fixture with divider active: no full clear, divider row is inert text" do
      {model, device} = new_model(load_fixture!("adversarial"))

      model = advance_times(model, 2)
      model = Surface.blur(model)
      model = drive_to_completion(model)
      _model = Surface.focus(model)

      refute SealOracle.emits_full_clear?(raw(device)),
             "adversarial content adjacent to the divider must never " <>
               "smuggle \\e[2J/\\e[3J through"

      case divider_rows(footer_texts(device)) do
        [row] ->
          # One leading space: the doctrine margin -- still nothing but
          # margin + rule glyphs + the module-built label.
          assert row =~ ~r/^ ─+ \d+ new since you looked ─+$/u,
                 "the divider row must be exactly the margin + rule " <>
                   "glyphs + the module-built label, got #{inspect(row)}"

        other ->
          flunk("expected exactly one divider row, got #{inspect(other)}")
      end
    end
  end

  # -- 8. width discipline ----------------------------------------------------

  describe "8. the rule is sized to the CURRENT width" do
    test "narrow terminal: the painted divider row spans exactly the width" do
      {model, device} = new_model(load_fixture!("simple-chat"), width: 31)

      model = advance_times(model, 3)
      model = Surface.blur(model)
      model = drive_to_completion(model)
      _model = Surface.focus(model)

      [row] = divider_rows(footer_texts(device, width: 31))

      # The doctrine margin: footer content renders at width - 2 inside
      # a 1-column margin each side; the painted row is the left margin
      # plus the rule (the right margin is the absent 31st column).
      assert TextMeasure.display_width(row) == 31 - 1,
             "divider must fill the margined content width exactly, got " <>
               "#{TextMeasure.display_width(row)} for #{inspect(row)}"

      assert String.starts_with?(row, " "),
             "divider row must carry the 1-column left margin"
    end
  end

  # -- 9. flat-mode honesty ----------------------------------------------------

  describe "9. flat mode has no live region, so no divider -- and no crash" do
    test "blur/focus are safe no-ops and the label never reaches the byte stream" do
      {model, device} = new_model(load_fixture!("simple-chat"), mode: :flat)

      model = advance_times(model, 3)
      model = Surface.blur(model)
      model = drive_to_completion(model)
      _model = Surface.focus(model)

      refute raw(device) =~ @label
    end
  end
end
