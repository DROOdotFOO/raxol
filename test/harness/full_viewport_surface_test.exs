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
