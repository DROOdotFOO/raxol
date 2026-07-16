defmodule Raxol.Harness.CommandPaletteSurfaceTest do
  @moduledoc """
  End-to-end suite for the overlay picker's first three consumers hosted
  by the assembled harness surface (`Raxol.Harness.Surface`): the command
  palette (Ctrl+P), the jump picker (`g` in transcript-browse), and the
  session picker (`s` in transcript-browse). Byte-checked through the
  same StringIO + `SealOracle` harness the overlay-picker surface suite
  uses.

  The load-bearing contracts under test:

    * **Palette derives from the bind table** -- every labeled
      `Raxol.UI.Harness.Keymap` bind appears as a palette entry; a new
      labeled bind appears automatically (the assertions iterate
      `Keymap.palette_binds/0`, never a hand-maintained list).
    * **Picking executes through the same dispatch path** as the
      keybind -- observable as byte-identical stub notices / identical
      model deltas, never a parallel execution mechanism.
    * **Session switch honors print-once** -- the abandoned session's
      sealed history stays byte-identical in scrollback; the new session
      appends below.
    * **Degenerate geometry refusal is inherited** from
      `Surface.open_overlay/3`, surfaced as an honest notice.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Harness.{Keymap, OverlayPicker}

  @width 60
  @rows 16
  @footer_rows 4
  @region_top @rows - @footer_rows

  @sessions_dir Path.join(["test", "fixtures", "harness", "sessions"])

  # -- shared helpers (overlay_picker_surface_test conventions) -----------

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

  defp history_at(bytes, region_top, rows \\ @rows) do
    emulator = SealOracle.replay(bytes, width: @width, height: rows)
    SealOracle.history(emulator, region_top)
  end

  defp ctrl_p, do: Event.key_event("p", :pressed, [:ctrl])

  defp type_chars(model, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(model, fn ch, m ->
      Surface.handle_input(m, Event.key(ch))
    end)
  end

  defp overlay_labels(%{overlay: %{picker: picker}}),
    do: Enum.map(picker.items, picker.label_fn)

  defp history_text(history_rows) do
    Enum.map_join(history_rows, "\n", fn row ->
      row |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
    end)
  end

  # A single turn with `count` completed :message items -- the fixture
  # wire shape `Raxol.Harness.Projection.project/2` accepts directly.
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

  # ---------------------------------------------------------------------
  # 1. Command palette: derives from the bind table
  # ---------------------------------------------------------------------

  describe "1. command palette derivation" do
    test "Ctrl+P opens the palette; every labeled keymap bind appears as an entry (derived, never hand-maintained)" do
      {model, _device} = new_model([])

      model = Surface.handle_input(model, ctrl_p())
      assert model.overlay != nil, "Ctrl+P must open the command palette"

      labels = overlay_labels(model)

      palette_binds = Keymap.palette_binds()
      assert palette_binds != []

      for bind <- palette_binds do
        assert bind.label in labels,
               "labeled bind #{inspect(bind.command_type)} missing from the palette"
      end
    end

    test "the palette opens from composing mode too (a chord is never typed text)" do
      {model, _device} = new_model([])
      assert model.composing?

      model = type_chars(model, "draft")
      model = Surface.handle_input(model, ctrl_p())

      assert model.overlay != nil
    end

    test "opening the palette while a picker is already open is a no-op with an honest notice, never a crash" do
      {model, device} = new_model([])
      model = Surface.handle_input(model, ctrl_p())
      assert model.overlay != nil
      picker_before = model.overlay.picker

      model = Surface.handle_input(model, ctrl_p())

      assert model.overlay != nil
      assert model.overlay.picker.items == picker_before.items
      assert strip_ansi(raw(device)) =~ "already open"
    end
  end

  # ---------------------------------------------------------------------
  # 2. Picking executes through the same dispatch path
  # ---------------------------------------------------------------------

  describe "2. palette execution routes through dispatch" do
    test "picking 'interrupt turn' produces the exact interrupt stub the ESC keybind produces" do
      {model, device} = new_model([])

      model = Surface.handle_input(model, ctrl_p())
      model = type_chars(model, "interrupt")
      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay == nil

      assert strip_ansi(raw(device)) =~
               "interrupt requested (stub — no agent lane in fixture mode)"
    end

    test "picking 'toggle fold' mutates fold state exactly like pressing z (same dispatch, same model delta)" do
      events = bulk_events(2)

      # Partial reveal: 2 blocks exist, the newest is held un-painted
      # (the foldable window), focus it in transcript-browse mode.
      setup = fn ->
        {model, _device} = new_model(events)
        model = advance_times(model, 5)
        model = Surface.focus_transcript(model)

        model
        |> Surface.handle_input(Event.key("j"))
        |> Surface.handle_input(Event.key("j"))
      end

      via_key = Surface.handle_input(setup.(), Event.key("z"))

      # "fold" uniquely selects the "toggle fold" entry among all labels
      via_palette =
        setup.()
        |> Surface.handle_input(ctrl_p())
        |> type_chars("fold")
        |> Surface.handle_input(Event.key(:enter))

      assert via_key.fold_overrides != %{},
             "precondition: z must actually toggle a fold"

      assert via_palette.fold_overrides == via_key.fold_overrides
      assert via_palette.focused_index == via_key.focused_index
    end

    test "typing a subsequence filters palette entries through the fuzzy scorer (substring would drop it)" do
      {model, _device} = new_model([])

      model = Surface.handle_input(model, ctrl_p())
      # "nb" is a subsequence of "next block" but a substring of no label
      model = type_chars(model, "nb")

      picker = model.overlay.picker
      matches = OverlayPicker.matches(picker)

      assert Enum.map(matches, picker.label_fn) == ["next block"]
    end
  end

  # ---------------------------------------------------------------------
  # 3. Jump picker
  # ---------------------------------------------------------------------

  describe "3. jump picker" do
    test "'g' in transcript-browse opens the block list; picking a block sets focused_index" do
      {model, device} = new_model(bulk_events(4))
      model = drive_to_completion(model)
      model = Surface.focus_transcript(model)

      model = Surface.handle_input(model, Event.key("g"))
      assert model.overlay != nil, "'g' must open the jump picker"

      labels = overlay_labels(model)
      assert length(labels) == 4

      # label = kind + first-line summary
      assert Enum.all?(labels, &(&1 =~ "message"))
      plain = strip_ansi(raw(device))
      assert plain =~ "history message 1"

      # pick block 4 (0-based index 3) by filtering to its summary
      model = type_chars(model, "4")
      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay == nil
      assert model.focused_index == 3
    end

    test "'g' while composing stays typed text (never opens the picker)" do
      {model, _device} = new_model([])
      assert model.composing?

      model = Surface.handle_input(model, Event.key("g"))
      assert model.overlay == nil

      assert Raxol.UI.Components.Harness.Composer.value(model.composer) =~
               "g"
    end
  end

  # ---------------------------------------------------------------------
  # 4. Session picker
  # ---------------------------------------------------------------------

  describe "4. session picker" do
    test "'s' lists the fixture sessions dir (the same source the demo uses)" do
      {model, _device} = new_model([], sessions_dir: @sessions_dir)
      model = Surface.focus_transcript(model)

      model = Surface.handle_input(model, Event.key("s"))
      assert model.overlay != nil, "'s' must open the session picker"

      labels = overlay_labels(model)

      expected =
        @sessions_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&String.replace_suffix(&1, ".jsonl", ""))
        |> Enum.sort()

      assert labels == expected
      assert "simple-chat" in labels
    end

    test "picking a session switches: sealed history stays byte-identical (print-once), the new session appends below" do
      {model, device} = new_model(bulk_events(3), sessions_dir: @sessions_dir)
      model = drive_to_completion(model)

      history_before = history_at(raw(device), @region_top)
      assert history_before != []

      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("s"))
      model = type_chars(model, "simple-chat")
      model = Surface.handle_input(model, Event.key(:enter))

      # switched: replay state reset, events are the new session's
      assert model.overlay == nil
      assert model.revealed == 0
      assert model.painted_count == 0
      assert model.projection.blocks == []
      assert model.events != []
      refute Enum.any?(model.events, &(Map.get(&1, :turn_id) == "bulk"))

      # print-once: the old session's sealed history is untouched
      history_after_switch = history_at(raw(device), @region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(
                 history_before,
                 history_after_switch
               ),
             "switching sessions must never rewrite sealed history"

      # an honest notice names the switch
      assert strip_ansi(raw(device)) =~ "switched to session"

      # the new session seals below the old one
      model = drive_to_completion(model)
      assert model.painted_count > 0

      history_final = history_at(raw(device), @region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_final),
             "the new session must append below, never rewrite"

      refute SealOracle.emits_full_clear?(raw(device))
    end

    test "mid-reveal switch drops the abandoned session's un-painted blocks (never seals them late)" do
      {model, device} =
        new_model(bulk_events(2), sessions_dir: @sessions_dir)

      # partial reveal: newest block held un-painted in the fold window
      model = advance_times(model, 5)
      assert model.painted_count < length(model.projection.blocks)

      history_before = history_at(raw(device), @region_top)

      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("s"))
      model = type_chars(model, "simple-chat")
      _model = Surface.handle_input(model, Event.key(:enter))

      history_after = history_at(raw(device), @region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_after)

      refute history_text(history_after) =~ "history message 2",
             "the abandoned pending block must be dropped, never sealed late"
    end
  end

  # ---------------------------------------------------------------------
  # 5. Degenerate geometry / flat mode refusal (inherited)
  # ---------------------------------------------------------------------

  describe "5. refusal inheritance" do
    test "too-short terminal: Ctrl+P refuses with an honest notice, no overlay, no region change" do
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
      model = Surface.handle_input(model, ctrl_p())

      assert model.overlay == nil
      delta = delta_since(device, prior)
      assert SealOracle.region_sets(delta) == []
      assert strip_ansi(delta) =~ "picker needs more rows"
    end

    test "flat mode: Ctrl+P seals one honest history line (no footer to host a picker)" do
      {model, device} = new_model([], mode: :flat)

      model = Surface.handle_input(model, ctrl_p())

      assert model.overlay == nil
      assert strip_ansi(raw(device)) =~ "flat mode"
    end
  end
end
