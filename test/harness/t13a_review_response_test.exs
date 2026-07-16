defmodule Raxol.Harness.T13aReviewResponseTest do
  @moduledoc """
  Regression suite for two Surface fixes:

    1. **`ViewText` trust-boundary sanitize** -- `Raxol.Harness.Surface.ViewText`
       now splits embedded `\\n` into multiple collected lines (row-
       accounting correctness) and strips ESC/C0 bytes (except `\\t`) from
       every `:text` node's content, BEFORE that content ever reaches
       `InlineAuthority`/`FlatAuthority`. Every test in `describe "1. ..."`
       drives REAL Surface call sites (`seal_block`, `pending_preview_lines`,
       `notice_line`) with hostile content -- never calling `ViewText`
       directly -- so a regression that reintroduces an unsanitized detour
       around the bridge (a new call site that skips `ViewText.lines/3`)
       would still be caught.
    2. **Startup mode-clamp notice** -- `Surface.new/2` now uses
       `ModeSelect.select_with_reason/3` and surfaces a one-line notice
       when the reason is `:degenerate_clamp` or `:override_unrecognized`.
       `describe "2. ..."` covers both.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Components.Harness.Composer

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp new_model(events, opts \\ []) do
    {:ok, device} = StringIO.open("")

    defaults = [
      device: device,
      width: @width,
      rows: @rows,
      footer_rows: @footer_rows,
      mode: :inline_log
    ]

    model = Surface.new(events, Keyword.merge(defaults, opts))
    {model, device}
  end

  defp drive_to_completion(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive_to_completion(model)
    end
  end

  # -- synthetic single-turn event builders --------------------------------

  defp turn_started do
    %{
      id: 1,
      turn_id: "t",
      ts: 1000,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{"prompt" => "hi"}
    }
  end

  defp turn_completed(id) do
    %{
      id: id,
      turn_id: "t",
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
  end

  defp item_started(id, item_id, item_type) do
    %{
      id: id,
      turn_id: "t",
      ts: 1000 + id,
      family: :loop,
      type: :item_started,
      tier: :durable,
      payload: %{"item_id" => item_id, "item_type" => item_type}
    }
  end

  defp item_completed(id, item_id, item_type, content) do
    %{
      id: id,
      turn_id: "t",
      ts: 1000 + id,
      family: :loop,
      type: :item_completed,
      tier: :durable,
      payload: %{
        "item_id" => item_id,
        "item_type" => item_type,
        "content" => content
      }
    }
  end

  defp item_delta(id, item_id, chunk) do
    %{
      id: id,
      turn_id: "t",
      ts: 1000 + id,
      family: :loop,
      type: :item_delta,
      tier: :durable,
      payload: %{"item_id" => item_id, "chunk" => chunk}
    }
  end

  # Every CUP-addressed footer row's accumulated plain-text content, in
  # emission order -- mirrors `t13a_surface_test.exs`'s own
  # `footer_row_texts/2` convention (a row "starts" at any footer-range CUP,
  # terminates on any other CUP/SGR/EL/save-restore token).
  defp footer_row_texts(raw_bytes) do
    {rows, current} =
      raw_bytes
      |> SequenceScanner.scan()
      |> Enum.reduce({[], nil}, fn
        {:csi, params, "H"}, {rows, current} ->
          rows = if current, do: [current | rows], else: rows

          if cup_row(params) > @region_top do
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
  # 1. ViewText trust-boundary sanitize, driven through real Surface paths
  # ---------------------------------------------------------------------

  describe "1. ViewText sanitize at seal_block/pending_preview_lines/notice_line" do
    test "seal_block: a folded block's header carries an embedded ESC that never reaches the device raw" do
      events = [
        turn_started(),
        item_started(2, "m1", "message"),
        item_completed(3, "m1", "message", "safe\e[2Jmalicious"),
        turn_completed(4)
      ]

      {model, device} =
        new_model(events, fold_defaults: %{message: :folded})

      model = drive_to_completion(model)
      assert length(model.projection.blocks) == 1

      bytes = raw(device)

      refute bytes =~ "\e[2J",
             "the injected CSI must never survive as a real, interpretable escape sequence"

      assert bytes =~ "safe[2Jmalicious",
             "content on both sides of the stripped ESC byte must survive intact " <>
               "(the honest, visible-fragment failure mode ViewText/FlatAuthority both document)"
    end

    test "pending_preview_lines: a live-tail chunk with an embedded newline paints as two distinct footer rows, not one" do
      chunk_events = [
        turn_started(),
        item_started(2, "m1", "message"),
        item_delta(3, "m1", "line1\nline2\e[2J")
        # deliberately no item_completed/turn_completed yet -- `advance/2`
        # below reveals only these three events, so nothing is "done" and
        # the tail preview renders from `chunks`.
      ]

      {model, device} = new_model(chunk_events)

      # reveal turn_started, item_started, item_delta -- three `advance/2`
      # calls, one per event -- leaving the fixture NOT finished (no
      # turn_completed revealed), so `pending_preview_lines/1` falls
      # through to `live_tail_preview_lines/1` (see `Surface`'s moduledoc,
      # "The live tail (delta streaming) has no history-region home").
      model =
        Enum.reduce(1..3, model, fn _n, m -> elem(Surface.advance(m), 0) end)

      assert model.projection.blocks == []
      assert map_size(model.projection.tail) == 1

      row_texts = footer_row_texts(raw(device))

      matching =
        Enum.filter(row_texts, &(&1 =~ "line1" or &1 =~ "line2"))

      assert length(matching) == 2,
             "embedded newline in one live-tail chunk must paint as TWO separate " <>
               "footer rows (one binary per row, per InlineAuthority's own " <>
               "row-accounting contract) -- got: #{inspect(row_texts)}"

      assert Enum.any?(matching, &(&1 =~ "line1")),
             "first split line's content must survive"

      assert Enum.any?(matching, &(&1 =~ "line2")),
             "second split line's content must survive"

      full_text = Enum.join(row_texts, "")

      refute full_text =~ "\e[2J",
             "the injected CSI riding the same chunk must never survive as a real escape sequence"

      assert full_text =~ "[2J",
             "the stripped-ESC fragment must still be visibly present (honest failure mode)"
    end

    test "notice_line: composer text set via the real Composer.set_value/2 seam (bypassing paste's own scrub) submits as a sanitized stub notice" do
      {model, device} = new_model([])

      hostile = "safe\e[31mtext"

      model = %{model | composer: Composer.set_value(model.composer, hostile)}
      assert Composer.value(model.composer) == hostile

      before_size = device |> raw() |> byte_size()

      model = Surface.handle_input(model, Event.key(:enter))

      # the submit must have fired (composer cleared, stub_notice queued)
      assert Composer.value(model.composer) == ""

      delta =
        device
        |> raw()
        |> binary_part(before_size, byte_size(raw(device)) - before_size)

      refute delta =~ "\e[31m",
             "an ESC riding composer text into the stub-notice path must never reach " <>
               "the device as a real SGR-injecting escape sequence"

      assert delta =~ "safe[31mtext",
             "the notice's surrounding content (with only the ESC byte stripped) must survive"
    end
  end

  # ---------------------------------------------------------------------
  # 2. Startup mode-clamp notice (ModeSelect.select_with_reason/3 seam)
  # ---------------------------------------------------------------------

  describe "2. startup mode notice" do
    test "degenerate geometry: mode clamps to :flat and the notice is sealed as the first history line" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: 40,
          # rows: 4, footer_rows: 3 -> region_top = 1, degenerate (< 2)
          rows: 4,
          footer_rows: 3,
          env: %{},
          tty?: true
        )

      assert model.mode == :flat

      assert raw(device) =~ "too small for a footer",
             "a degenerate-geometry clamp must surface a visible startup notice"
    end

    test "unrecognized override: mode auto-detects and the notice reaches the footer's one-shot slot exactly once" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: 100,
          rows: @rows,
          footer_rows: @footer_rows,
          env: %{"RAXOL_HARNESS_MODE" => "bogus"},
          tty?: true
        )

      assert model.mode == :inline_log

      assert raw(device) =~ "RAXOL_HARNESS_MODE=bogus not recognized",
             "an unrecognized override must surface a visible startup notice explaining the fallback"

      before_size = device |> raw() |> byte_size()
      _model = Surface.tick(model, 1)

      delta =
        device
        |> raw()
        |> binary_part(before_size, byte_size(raw(device)) - before_size)

      refute delta =~ "RAXOL_HARNESS_MODE",
             "the startup notice is one-shot -- it must not repeat on a later repaint"
    end

    test "an explicit :mode option bypasses the notice entirely (test seam, unchanged behavior)" do
      {:ok, device} = StringIO.open("")

      _model =
        Surface.new([],
          device: device,
          width: 40,
          rows: 4,
          footer_rows: 3,
          mode: :flat
        )

      refute raw(device) =~ "too small for a footer",
             "an explicit :mode override has no reason() to explain, so no notice is synthesized"
    end
  end
end
