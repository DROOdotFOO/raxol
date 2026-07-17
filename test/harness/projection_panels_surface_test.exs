defmodule Raxol.Harness.ProjectionPanelsSurfaceTest do
  @moduledoc """
  Footer-composition + keymap-priority suite for the read-only projection
  panels (worktracks/memory/plan) hosted inside the assembled harness
  surface (`Raxol.Harness.Surface`), byte-checked through the same
  StringIO + `SealOracle` harness `overlay_picker_surface_test.exs` and
  `command_palette_surface_test.exs` use.

  A projection panel rides the exact same hosted-overlay footer slot the
  filterable pickers do (grow the footer viewport, paint above the
  prompt, shrink back on dismiss), but is a `Raxol.UI.Harness.OverlayPanel`
  instance instead of an `OverlayPicker` -- read-only, no `{:picked, _}`
  outcome ever, content folded live by `Raxol.Harness.PanelProjection`
  from the projection's retained durable `extract` meta events.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Projection
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Components.Harness.Composer
  alias Raxol.UI.Harness.{OverlayPanel, OverlayPicker}
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 50
  @rows 20
  @footer_rows 4
  @region_top @rows - @footer_rows

  # panel height for the default max_visible (OverlayPanel.default_max_visible/0
  # == 8): 1 title row + 8 content rows.
  @panel_h 9
  @grown_footer_rows @footer_rows + @panel_h
  @grown_region_top @rows - @grown_footer_rows

  # -- shared helpers (overlay_picker_surface_test / command_palette_surface_test conventions) --

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

  defp advance_times(model, 0), do: model

  defp advance_times(model, n) do
    {model, _} = Surface.advance(model)
    advance_times(model, n - 1)
  end

  defp delta_since(device, prior_size) do
    all = raw(device)
    binary_part(all, prior_size, byte_size(all) - prior_size)
  end

  defp strip_ansi(bytes) when is_binary(bytes) do
    bytes
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("", fn {:text, text} -> text end)
  end

  defp history_at(bytes, region_top) do
    emulator = SealOracle.replay(bytes, width: @width, height: @rows)
    SealOracle.history(emulator, region_top)
  end

  defp ctrl_p, do: Event.key_event("p", :pressed, [:ctrl])

  defp type_chars(model, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(model, fn ch, m -> Surface.handle_input(m, Event.key(ch)) end)
  end

  # -- fixture event builders ---------------------------------------------

  defp extract_event(id, class, op, item) do
    %{
      id: id,
      turn_id: nil,
      ts: 1_000_000 + id,
      family: :meta,
      type: :extract,
      tier: :durable,
      scope: :session,
      payload: %{"class" => class, "op" => op, "item" => item, "refs" => []}
    }
  end

  # A minimal worktracks sequence: add (open) -> update (done) -> a
  # hostile add (raw ESC + embedded newline in the title). Three events,
  # revealed one at a time across the tests below.
  defp worktracks_events do
    [
      extract_event(1, "worktracks", "add", %{
        "id" => "wt-1",
        "lane" => "todo",
        "title" => "Design schema",
        "status" => "open"
      }),
      extract_event(2, "worktracks", "update", %{
        "id" => "wt-1",
        "status" => "done"
      }),
      extract_event(3, "worktracks", "add", %{
        "id" => "wt-hostile",
        "lane" => "security",
        "title" => "\e[2Jevil\ntitle",
        "status" => "flagged"
      })
    ]
  end

  defp memory_events(n) do
    for i <- 1..n do
      extract_event(i, "memory", "add", %{"key" => "k#{i}", "value" => "v#{i}"})
    end
  end

  # A single turn with `count` completed :message items -- the fixture
  # wire shape `Raxol.Harness.Projection.project/2` accepts directly (same
  # shape `overlay_picker_surface_test.exs`'s own `bulk_events/1` uses).
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
              "content" => "history message #{i}"
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

    List.flatten([turn_started, items, turn_completed])
  end

  # `worktracks_events/0` reindexed to start right after `loop_events`'s
  # own ids, appended -- used where sealed loop content must exist before
  # the panel opens.
  defp panel_events_after(loop_events) do
    base = length(loop_events)
    reindexed = Enum.map(worktracks_events(), &%{&1 | id: &1.id + base})
    loop_events ++ reindexed
  end

  # -----------------------------------------------------------------------
  # 1. Summon: opening grows the footer, shows the LIVE projection
  # -----------------------------------------------------------------------

  describe "1. summon" do
    test "'w' opens the worktracks panel: exactly one grow to the panel split, live content visible" do
      {model, device} = new_model(worktracks_events())
      model = advance_times(model, 1)
      model = Surface.focus_transcript(model)
      prior = byte_size(raw(device))

      model = Surface.handle_input(model, Event.key("w"))
      delta = delta_since(device, prior)

      assert model.overlay != nil
      assert model.overlay.mod == OverlayPanel
      assert model.overlay.picker.kind == :worktracks

      assert SealOracle.region_sets(delta) == [{1, @grown_region_top}]

      assert InlineAuthority.footer_row_count(model.authority) ==
               @grown_footer_rows

      plain = strip_ansi(delta)
      assert plain =~ "Design schema"
      assert plain =~ "open"
      refute plain =~ "done", "the update event has not been revealed yet"

      refute SealOracle.emits_full_clear?(raw(device))
    end
  end

  # -----------------------------------------------------------------------
  # 2. Live refresh: advancing past a later extract event updates content
  # -----------------------------------------------------------------------

  describe "2. live refresh" do
    test "advancing past the update event repaints the open panel with the new status" do
      {model, device} = new_model(worktracks_events())
      model = advance_times(model, 1)
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("w"))

      prior = byte_size(raw(device))
      {model, _status} = Surface.advance(model)
      delta = delta_since(device, prior)

      assert model.overlay != nil
      plain = strip_ansi(delta)
      assert plain =~ "Design schema"
      assert plain =~ "done"
    end
  end

  # -----------------------------------------------------------------------
  # 3. Dismissed is not dead
  # -----------------------------------------------------------------------

  describe "3. dismissed is not dead" do
    test "close then re-summon shows current state; open/close alone never perturbs the block projection" do
      {model, device} = new_model(worktracks_events())
      model = advance_times(model, 1)
      model = Surface.focus_transcript(model)

      identity_before_open = Projection.transcript_identity(model.projection)

      model = Surface.handle_input(model, Event.key("w"))
      prior = byte_size(raw(device))
      model = Surface.handle_input(model, Event.key(:escape))
      delta = delta_since(device, prior)

      assert model.overlay == nil
      assert SealOracle.region_sets(delta) == [{1, @region_top}]
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows

      identity_after_close = Projection.transcript_identity(model.projection)

      assert identity_before_open == identity_after_close,
             "opening and closing a panel with no advance in between must not touch the block projection"

      {model, _status} = Surface.advance(model)
      _model = Surface.handle_input(model, Event.key("w"))

      assert strip_ansi(raw(device)) =~ "done",
             "re-summoning must fold the CURRENT retained events, not a stale snapshot"
    end
  end

  # -----------------------------------------------------------------------
  # 4. Sealed history untouched
  # -----------------------------------------------------------------------

  describe "4. sealed history untouched" do
    test "a full open/scroll/refresh/close round trip preserves already-sealed history bytes" do
      {model, device} = new_model(panel_events_after(bulk_events(12)))
      model = drive_to_completion(model)

      history_before = history_at(raw(device), @region_top)
      assert history_before != []

      assert {:ok, model} = Surface.open_panel(model, :worktracks)
      model = Surface.handle_input(model, Event.key(:down))
      {model, _status} = Surface.advance(model)
      model = Surface.handle_input(model, Event.key(:escape))
      assert model.overlay == nil

      history_after = history_at(raw(device), @region_top)

      assert :ok == SealOracle.immutable_prefix?(history_before, history_after),
             "history sealed before the panel opened must survive open/scroll/refresh/close byte-identical"

      refute SealOracle.emits_full_clear?(raw(device))
    end
  end

  # -----------------------------------------------------------------------
  # 5. Hostile content
  # -----------------------------------------------------------------------

  describe "5. hostile content" do
    test "the repaint contains no live escape+bracket sequence and no raw newline from the hostile title" do
      {model, device} = new_model(worktracks_events())
      model = advance_times(model, 1)
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("w"))

      prior = byte_size(raw(device))
      # reveal the update, then the hostile add, while the panel is open
      {model, _status} = Surface.advance(model)
      {_model, _status} = Surface.advance(model)
      delta = delta_since(device, prior)

      # ViewText.sanitize strips the raw ESC byte before it ever reaches
      # the device -- so the literal escape+bracket sequence never
      # appears (a real ESC-prefixed "\e[2J" would be a live full-clear).
      refute delta =~ "\e[2J"

      plain = strip_ansi(delta)

      assert plain =~ "evil title",
             "the flattened, sanitized title must still be visible"

      refute plain =~ "evil\ntitle",
             "PanelProjection.flatten_newlines/1 must keep this one footer row"
    end
  end

  # -----------------------------------------------------------------------
  # 6. Refusals
  # -----------------------------------------------------------------------

  describe "6. refusals" do
    test "too-short geometry: zero bytes, model untouched" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: @width,
          rows: 7,
          footer_rows: 4,
          mode: :inline_log
        )

      prior = byte_size(raw(device))

      assert {:error, :insufficient_footer_capacity} =
               Surface.open_panel(model, :worktracks)

      assert byte_size(raw(device)) == prior
    end

    test "flat mode has no footer to grow: refuses" do
      {model, _device} = new_model([], mode: :flat)
      assert {:error, :no_footer} = Surface.open_panel(model, :worktracks)
    end

    test "a picker already open suppresses 'w' as filter text; a direct open_panel/2 call refuses" do
      {model, _device} = new_model([])
      model = Surface.handle_input(model, ctrl_p())
      assert model.overlay != nil
      assert model.overlay.mod == OverlayPicker

      model = Surface.handle_input(model, Event.key("w"))

      assert model.overlay.mod == OverlayPicker,
             "the open picker must not be replaced by a panel"

      assert model.overlay.picker.query == "w",
             "'w' must reach the picker as filter text, never open_panel"

      assert {:error, :overlay_already_open} =
               Surface.open_panel(model, :worktracks)
    end
  end

  # -----------------------------------------------------------------------
  # 7. Routing
  # -----------------------------------------------------------------------

  describe "7. routing" do
    test "'w' while composing stays typed text (never opens a panel)" do
      {model, _device} = new_model([])
      assert model.composing?

      model = Surface.handle_input(model, Event.key("w"))

      assert model.overlay == nil
      assert Composer.value(model.composer) =~ "w"
    end

    test "up/down scroll an open panel -- visible via the title's range indicator" do
      {model, device} = new_model(memory_events(12))
      model = advance_times(model, 12)
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("m"))

      assert model.overlay.mod == OverlayPanel
      assert model.overlay.picker.kind == :memory
      assert strip_ansi(raw(device)) =~ "(1-8/12)"

      prior = byte_size(raw(device))
      model = Surface.handle_input(model, Event.key(:down))
      delta = delta_since(device, prior)

      assert strip_ansi(delta) =~ "(2-9/12)"
      assert model.overlay.picker.offset == 1
    end

    test "Tab (:steer) while a panel is open is a documented no-op" do
      {model, _device} = new_model(memory_events(3))
      model = advance_times(model, 3)
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("m"))
      picker_before = model.overlay.picker

      model = Surface.handle_input(model, Event.key(:tab))

      assert model.overlay != nil
      assert model.overlay.picker == picker_before
    end

    test "Enter while a panel is open does nothing -- no {:picked, _} path, no notice" do
      {model, device} = new_model(memory_events(3))
      model = advance_times(model, 3)
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("m"))
      picker_before = model.overlay.picker

      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay != nil
      assert model.overlay.picker == picker_before
      refute strip_ansi(raw(device)) =~ "» picked"
    end
  end

  # -----------------------------------------------------------------------
  # 8. Resize force-close
  # -----------------------------------------------------------------------

  describe "8. resize force-close" do
    test "resizing below capacity while a panel is open force-closes it and restores the base pin" do
      {model, _device} = new_model([])
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("w"))
      assert model.overlay != nil

      model = Surface.resize(model, @width, 8)

      assert model.overlay == nil
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows
    end
  end

  # -----------------------------------------------------------------------
  # 9. Palette summon (dispatch parity)
  # -----------------------------------------------------------------------

  describe "9. palette summon" do
    test "picking 'worktracks panel' from the palette opens the panel through the same dispatch path" do
      {model, _device} = new_model([])

      model = Surface.handle_input(model, ctrl_p())
      model = type_chars(model, "worktracks panel")
      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay != nil
      assert model.overlay.mod == OverlayPanel
      assert model.overlay.picker.kind == :worktracks
    end
  end
end
