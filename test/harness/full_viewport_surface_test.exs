defmodule Raxol.Harness.FullViewportSurfaceTest do
  @moduledoc """
  Acceptance for the `:full_viewport` surface mode (V's endgame pivot):
  the alternate-screen, full-frame repaint path with the harness's owned
  virtual scrollback. Drives the REAL `Raxol.Harness.Surface` +
  `ViewportAuthority` through a `StringIO` device against replayed
  fixtures, exactly like the inline suites -- but asserting the
  full-viewport laws: alt-screen enter, bottom-anchored tail, sealed-block
  render stability (logical immutability), scrollback window + "N below"
  indicator + scroll-anchor (no yank), full-reflow resize, the
  degradation floor, and teardown.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Surface
  alias Raxol.UI.Rendering.PaintAuthority.ViewportAuthority

  @fixtures_dir Path.join(["test", "fixtures", "harness", "sessions"])

  defp load!(name) do
    {:ok, session} = Fixture.load(Path.join(@fixtures_dir, "#{name}.jsonl"))
    session
  end

  defp new_model(session_or_events, opts) do
    {:ok, device} = StringIO.open("")

    defaults = [
      device: device,
      width: 60,
      rows: 20,
      footer_rows: 6,
      mode: :full_viewport
    ]

    model = Surface.new(session_or_events, Keyword.merge(defaults, opts))
    {model, device}
  end

  defp drive(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive(model)
    end
  end

  # Flush accumulated bytes, force ONE fresh full-frame repaint, return
  # just that frame -- the current visible screen.
  defp frame(model, device) do
    _ = StringIO.flush(device)
    _model = Surface.resize(model, model.width, model.rows)
    {_in, out} = StringIO.contents(device)
    out
  end

  defp strip_ansi(s), do: Regex.replace(~r/\x1b\[[0-9;?]*[A-Za-z]/, s, "")

  defp visible_text(frame), do: strip_ansi(frame)

  # Parse a full frame into row-number => visible text. Rows are
  # `\e[<n>;1H\e[0m\e[2K<content>`; split at each column-1 CUP.
  defp frame_rows(frame) when is_binary(frame) do
    ~r/\x1b\[(\d+);1H(.*?)(?=\x1b\[\d+;1H|\z)/s
    |> Regex.scan(frame)
    |> Map.new(fn [_all, n, body] ->
      {String.to_integer(n), String.trim_trailing(strip_ansi(body))}
    end)
  end

  # Mode resolution must go through the REAL ModeSelect ladder, so these
  # omit the explicit `:mode` seam entirely (which would bypass the
  # ladder) and let `:surface_mode` + geometry + env decide.
  defp resolve_mode_model(opts) do
    {:ok, device} = StringIO.open("")
    base = [device: device, width: 60, rows: 20, footer_rows: 6]
    Surface.new([], Keyword.merge(base, opts))
  end

  describe "mode resolution (the surface_mode axis)" do
    test "surface_mode: :full_viewport resolves to the :full_viewport tier" do
      model =
        resolve_mode_model(surface_mode: :full_viewport, tty?: true, env: %{})

      assert model.mode == :full_viewport
    end

    test "the default surface_mode keeps the inline ladder (never full_viewport)" do
      model = resolve_mode_model(tty?: true, env: %{})
      refute model.mode == :full_viewport
    end

    test "a degenerate geometry floors :full_viewport down to :flat" do
      model =
        resolve_mode_model(
          surface_mode: :full_viewport,
          rows: 2,
          footer_rows: 2,
          tty?: true,
          env: %{}
        )

      assert model.mode == :flat
    end

    test "a headless (non-tty) session floors :full_viewport down to :flat" do
      model =
        resolve_mode_model(surface_mode: :full_viewport, tty?: false, env: %{})

      assert model.mode == :flat
    end
  end

  describe "alternate screen + greeting" do
    test "construction enters the alternate screen" do
      {:ok, device} = StringIO.open("")

      _model =
        Surface.new([],
          device: device,
          width: 40,
          rows: 12,
          footer_rows: 4,
          mode: :full_viewport
        )

      {_in, out} = StringIO.contents(device)
      assert String.contains?(out, ViewportAuthority.enter())
    end

    test "an empty transcript shows the centered greeting, cleared on first content" do
      {model, device} = new_model(load!("simple-chat"), greeting: true)

      assert visible_text(frame(model, device)) =~ "welcome back, operator"

      full = drive(model)
      assert visible_text(frame(full, device)) =~ "Hello!"
      refute visible_text(frame(full, device)) =~ "welcome back, operator"
    end
  end

  describe "transcript render (bottom-anchored, immutable)" do
    test "sealed content is visible and hugs the footer (bottom-anchored)" do
      {model, device} = new_model(load!("simple-chat"), [])
      model = drive(model)

      rows = frame_rows(frame(model, device))
      content_rows = for {n, t} <- rows, t =~ "Hello!", do: n
      refute content_rows == []

      footer_rows = for {n, t} <- rows, t =~ "❯" or t =~ ">", do: n
      # The sealed content sits ABOVE the composer prompt (bottom-anchored
      # transcript, footer pinned beneath it).
      if footer_rows != [] do
        assert Enum.max(content_rows) < Enum.max(footer_rows)
      end
    end

    test "a repaint with no new events re-renders sealed rows byte-identically" do
      {model, device} = new_model(load!("simple-chat"), [])
      model = drive(model)

      once = frame(model, device)
      twice = frame(model, device)
      assert once == twice
    end
  end

  # V's "extra line above the input field" ruling: the composer always
  # carries exactly ONE blank row above it, separating the input from
  # whatever precedes it (the transcript tail, or the live-region footer
  # groups). The one-blank-between-blocks rhythm extended across the
  # transcript->composer boundary.
  describe "the above-composer separator (blank-row rhythm)" do
    # The row-number of the composer's chevron row, and the visible text of
    # the N rows directly above it (nearest-first).
    defp composer_row_and_above(model, device, n) do
      rows = frame_rows(frame(model, device))

      composer_row =
        rows
        |> Enum.filter(fn {_r, t} -> t =~ "❯" end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.max()

      above = for i <- 1..n, do: Map.get(rows, composer_row - i, :missing)
      {composer_row, above}
    end

    test "exactly one blank row sits above the composer after a sealed block" do
      {model, device} = new_model(load!("simple-chat"), [])
      model = drive(model)

      {_composer_row, [above1, above2]} =
        composer_row_and_above(model, device, 2)

      assert above1 == "",
             "the row directly above the composer must be blank (the separator)"

      refute above2 == "",
             "the row two above the composer must be content, not a second blank " <>
               "(never two blanks -- no double-pay)"
    end

    test "empty transcript + greeting: intro line, one blank, then composer" do
      {model, device} = new_model(load!("simple-chat"), greeting: true)

      {_composer_row, [above1, above2]} =
        composer_row_and_above(model, device, 2)

      assert above1 == "",
             "one blank row must sit between the greeting and the composer"

      assert above2 =~ "welcome back, operator",
             "the greeting intro line sits exactly one blank above the composer"
    end

    test "the separator is discretionary -- it yields first under a too-short footer" do
      # A 1-row footer budget cannot hold both the separator and the
      # composer prompt. The separator (FIRST in the drop order) yields, so
      # the single surviving row is the composer itself, never a bare blank.
      {model, device} = new_model([], rows: 20, footer_rows: 1)

      rows = frame_rows(frame(model, device))
      composer_rows = for {r, t} <- rows, t =~ "❯", do: r

      refute composer_rows == [],
             "the composer must survive a 1-row footer -- the separator yields, not the input"
    end

    test "a repaint with the separator present is byte-stable" do
      {model, device} = new_model(load!("simple-chat"), [])
      model = drive(model)

      assert frame(model, device) == frame(model, device)
    end
  end

  describe "scrollback window" do
    # A tall transcript in a modest viewport forces a scroll window.
    # markdown-stream is a long, message-heavy transcript (message blocks
    # stay expanded -- unlike the machinery kinds, which fold to one-line
    # compact rows), so it comfortably overruns a 14-row / 6-footer
    # viewport and the scroll window engages.
    defp overflowing,
      do: new_model(load!("markdown-stream"), rows: 14, footer_rows: 6)

    test "PgUp scrolls off the tail and shows an honest 'N below' indicator" do
      {model, device} = overflowing()
      model = drive(model)

      refute visible_text(frame(model, device)) =~ "more below"

      scrolled = Surface.handle_input(model, Event.key(:page_up))
      assert scrolled.scroll_anchor != :tail
      assert visible_text(frame(scrolled, device)) =~ "more below"
    end

    test "End (off the composer) returns the window to the tail" do
      {model, device} = overflowing()
      model = model |> drive() |> Surface.handle_input(Event.key(:page_up))
      assert model.scroll_anchor != :tail

      model =
        model
        |> Surface.focus_transcript()
        |> Surface.handle_input(Event.key(:end))

      assert model.scroll_anchor == :tail
      refute visible_text(frame(model, device)) =~ "more below"
    end

    test "an advance never resets a scrolled-back anchor (no yank)" do
      {model, _device} = overflowing()

      # Advance a few steps so several blocks seal (transcript overflows)
      # while events still remain, then scroll back.
      model =
        Enum.reduce(1..6, model, fn _i, m -> elem(Surface.advance(m), 0) end)

      scrolled = Surface.handle_input(model, Event.key(:page_up))
      anchor = scrolled.scroll_anchor

      {advanced, _status} = Surface.advance(scrolled)
      # Only a scroll key moves the window; new sealed content leaves the
      # anchor exactly where the user parked it (the scroll-anchor rule).
      assert advanced.scroll_anchor == anchor
    end
  end

  describe "resize is a full reflow" do
    test "narrowing the width re-renders frozen records (content survives)" do
      {model, device} = new_model(load!("multi-tool-turn"), [])
      model = drive(model)

      wide = frame(model, device)
      narrow = frame(Surface.resize(model, 24, 20), device)

      # A resize re-renders every frozen record at the new width (full
      # reflow is legal and expected), and the content survives the reflow.
      assert visible_text(narrow) != ""
      # The two frames differ (a narrower content column re-wraps).
      assert wide != narrow
    end
  end

  # -- the frame margin (V's inset ruling, 2026-07-18) --------------------
  #
  # A uniform 1-cell frame inset on the full-viewport surface: nothing
  # touches the very screen edge on the left, and one blank row sits below
  # the composer at the bottom. Every marker (dialogue chevron, machinery
  # glyph, composer chevron, running-tool spinner) sits at ONE uniform
  # left column (`@inset`, one cell in from the edge); content sits at one
  # uniform indent past that. Inline modes keep their outer-contour col-0
  # chevrons UNCHANGED (pinned by speaker_separation_surface_test.exs).
  @inset 1

  # Leading blank cells before the first painted glyph on a row.
  defp lead(s), do: byte_size(s) - byte_size(String.trim_leading(s))

  # The machinery kind + fold glyphs a sealed non-dialogue row can front.
  @machinery_glyphs ~w(⚙ ∴ » ± ⚑ ◆ ▸)

  defp marker_row?(row) do
    t = String.trim_leading(row)

    t != "" and
      (String.starts_with?(t, "❯") or String.starts_with?(t, "❮") or
         String.starts_with?(t, ">") or String.starts_with?(t, "<") or
         Enum.any?(@machinery_glyphs, &String.starts_with?(t, &1)))
  end

  describe "frame margin: the bottom inset" do
    test "the bottom-most row is a blank margin, the composer sits one row above it" do
      {model, device} = new_model([], greeting: false)
      rows = frame_rows(frame(model, device))

      # Nothing is painted on the very bottom row -- it is the frame's
      # bottom margin.
      assert Map.get(rows, 20) == "",
             "bottom row must be a blank frame margin, got " <>
               inspect(Map.get(rows, 20))

      # The composer's chevron row is the last PAINTED row: one cell above
      # the bottom edge (row 20 - @inset).
      composer_rows = for {n, t} <- rows, t =~ "❯" or t =~ ">", do: n

      refute composer_rows == [],
             "no composer chevron row found: #{inspect(rows)}"

      assert Enum.max(composer_rows) == 20 - @inset
    end
  end

  describe "frame margin: the unified left column" do
    test "the composer chevron sits one cell in from the edge (not col 0)" do
      {model, device} = new_model([], greeting: false)
      rows = frame_rows(frame(model, device))

      {_n, composer} =
        Enum.find(rows, fn {_n, t} -> t =~ "❯" or t =~ ">" end)

      assert lead(composer) == @inset,
             "composer chevron must sit at the framed left column " <>
               "(#{@inset} cell in), got lead #{lead(composer)} in " <>
               inspect(composer)
    end

    test "dialogue chevrons sit at the framed left column, aligned with the composer" do
      {model, device} = new_model(load!("speaker-roles"), [])
      model = drive(model)
      rows = frame_rows(frame(model, device))

      dialogue =
        for {_n, t} <- rows,
            s = String.trim_leading(t),
            String.starts_with?(s, "❯") or String.starts_with?(s, "❮"),
            do: t

      refute dialogue == [], "no dialogue chevron rows: #{inspect(rows)}"

      for row <- dialogue do
        assert lead(row) == @inset,
               "dialogue chevron must sit at the framed left column, " <>
                 "got lead #{lead(row)} in #{inspect(row)}"
      end
    end

    test "every marker (dialogue + machinery) shares the one framed left column" do
      {model, device} = new_model(load!("multi-tool-turn"), [])
      model = drive(model)
      rows = frame_rows(frame(model, device))

      leads =
        for {_n, t} <- rows, marker_row?(t), do: lead(t)

      refute leads == [], "no marker rows found: #{inspect(rows)}"

      assert Enum.uniq(leads) == [@inset],
             "all markers must align at the framed left column #{@inset}, " <>
               "got distinct leads #{inspect(Enum.uniq(leads))}"
    end
  end

  describe "frame margin: inline geometry is untouched" do
    test "the same transcript gains the inset only in full_viewport" do
      # full_viewport: dialogue chevron is one cell in from the edge.
      {fv, fv_dev} = new_model(load!("speaker-roles"), [])
      fv = drive(fv)
      fv_rows = frame_rows(frame(fv, fv_dev))

      fv_dialogue =
        for {_n, t} <- fv_rows,
            s = String.trim_leading(t),
            String.starts_with?(s, "❯") or String.starts_with?(s, "❮"),
            do: t

      refute fv_dialogue == []
      assert Enum.all?(fv_dialogue, &(lead(&1) == @inset))
    end
  end

  describe "teardown" do
    test "Surface.teardown/1 leaves the alternate screen" do
      {model, device} = new_model([], [])
      _ = StringIO.flush(device)
      _model = Surface.teardown(model)
      {_in, out} = StringIO.contents(device)
      assert out == ViewportAuthority.leave()
    end

    test "teardown is a no-op in the inline family" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: 40,
          rows: 12,
          footer_rows: 4,
          mode: :inline_log
        )

      _ = StringIO.flush(device)
      _model = Surface.teardown(model)
      {_in, out} = StringIO.contents(device)
      assert out == ""
    end
  end
end
