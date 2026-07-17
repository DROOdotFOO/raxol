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

    test "picking 'toggle fold' with no focused block refuses with an honest notice, never a silent no-op" do
      # Adversarial review (LOW): the :always palette chord makes the
      # :not_composing binds reachable mid-compose, where focused_index
      # is nil -- a silent no-op pick is dishonest UI. Same notice
      # mechanism as the sealed-block fold refusal.
      {model, device} = new_model([])
      assert model.composing?

      model = Surface.handle_input(model, ctrl_p())
      model = type_chars(model, "fold")
      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay == nil
      assert model.fold_overrides == %{}
      assert strip_ansi(raw(device)) =~ "no block focused"
    end

    test "pressing z in transcript-browse with no focused block surfaces the same honest notice" do
      {model, device} = new_model([])
      model = Surface.focus_transcript(model)
      assert model.focused_index == nil

      model = Surface.handle_input(model, Event.key("z"))

      assert model.fold_overrides == %{}
      assert strip_ansi(raw(device)) =~ "no block focused"
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

    test "an oversized sessions directory is capped honestly: 100 entries listed, the title names the total" do
      # Adversarial review (MEDIUM): sessions_dir is a public option and
      # File.ls + per-keystroke fuzzy ranking run synchronously on the
      # input path -- an unbounded listing must not be scored wholesale.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "raxol_session_cap_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      on_exit(fn -> File.rm_rf!(tmp) end)

      for i <- 1..120 do
        File.write!(
          Path.join(tmp, "session-#{String.pad_leading("#{i}", 3, "0")}.jsonl"),
          ""
        )
      end

      {model, _device} = new_model([], sessions_dir: tmp)
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("s"))

      assert model.overlay != nil
      picker = model.overlay.picker

      assert length(picker.items) == 100,
             "the listing must be capped, not scored wholesale"

      # sorted order: the cap keeps the FIRST 100 names
      assert List.first(picker.items) == "session-001"
      assert List.last(picker.items) == "session-100"

      # the truncation is named, never silent
      assert picker.title =~ "100"
      assert picker.title =~ "120"
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

  # ---------------------------------------------------------------------
  # 6. Search picker ('/'): body-search proof, not just label matching
  # ---------------------------------------------------------------------

  # A variant of bulk_events/1: `count` message blocks, all one-line
  # except block `needle_index` (1-based), whose SECOND line is
  # `needle` -- a token that appears in NO summary and NO other block,
  # proving the search picker's fuzzy filter reaches into block BODIES
  # (via `Block.search_text/1`), not just the summary-derived label
  # every other picker uses.
  defp bulk_events_with_needle(count, needle_index, needle) do
    turn_started = %{
      id: 1,
      turn_id: "bulk-needle",
      ts: 1000,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{"prompt" => "bulk-needle"}
    }

    items =
      for i <- 1..count do
        base_id = 2 + (i - 1) * 2
        item_id = "i#{i}"

        content =
          if i == needle_index do
            "history message #{i}\n#{needle}"
          else
            "history message #{i}"
          end

        [
          %{
            id: base_id,
            turn_id: "bulk-needle",
            ts: 1000 + base_id,
            family: :loop,
            type: :item_started,
            tier: :durable,
            payload: %{"item_id" => item_id, "item_type" => "message"}
          },
          %{
            id: base_id + 1,
            turn_id: "bulk-needle",
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
      turn_id: "bulk-needle",
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

  # A single-block session whose body carries hostile bytes, for the
  # sanitization test below -- built by hand (not bulk_events/1) so the
  # hostile string lands verbatim in exactly one block's content.
  defp hostile_events(content) do
    [
      %{
        id: 1,
        turn_id: "hostile",
        ts: 1000,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "hostile"}
      },
      %{
        id: 2,
        turn_id: "hostile",
        ts: 1001,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{"item_id" => "i1", "item_type" => "message"}
      },
      %{
        id: 3,
        turn_id: "hostile",
        ts: 1002,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{
          "item_id" => "i1",
          "item_type" => "message",
          "content" => content
        }
      },
      %{
        id: 4,
        turn_id: "hostile",
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
    ]
  end

  describe "6. search picker" do
    test "'/' opens the search picker; one entry per block, each labeled 'message · ...'" do
      {model, _device} =
        new_model(bulk_events_with_needle(4, 4, "zebra-needle appears here"))

      model = drive_to_completion(model)
      model = Surface.focus_transcript(model)

      model = Surface.handle_input(model, Event.key("/"))
      assert model.overlay != nil, "'/' must open the search picker"

      labels = overlay_labels(model)
      assert length(labels) == 4
      assert Enum.all?(labels, &String.starts_with?(&1, "message · "))
    end

    test "typing a token that only exists in one block's SECOND body line filters to it; picking jumps focus" do
      {model, _device} =
        new_model(bulk_events_with_needle(4, 4, "zebra-needle appears here"))

      model = drive_to_completion(model)
      model = Surface.focus_transcript(model)

      model = Surface.handle_input(model, Event.key("/"))
      model = type_chars(model, "zebra-needle")
      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay == nil
      assert model.focused_index == 3
    end

    test "'/' while composing stays typed text (never opens the picker)" do
      {model, _device} = new_model([])
      assert model.composing?

      model = Surface.handle_input(model, Event.key("/"))
      assert model.overlay == nil

      assert Raxol.UI.Components.Harness.Composer.value(model.composer) =~
               "/"
    end

    test "'/' with the palette already open becomes filter text, not a second picker" do
      {model, _device} = new_model([])

      model = Surface.handle_input(model, ctrl_p())
      assert model.overlay != nil
      assert model.overlay.picker.title == "commands"

      model = Surface.handle_input(model, Event.key("/"))

      assert model.overlay != nil
      assert model.overlay.picker.title == "commands"
      assert model.overlay.picker.query =~ "/"
    end

    test "'/' with an empty projection is an honest no-op notice, never an empty overlay" do
      {model, device} = new_model([])
      model = Surface.focus_transcript(model)

      model = Surface.handle_input(model, Event.key("/"))

      assert model.overlay == nil
      assert strip_ansi(raw(device)) =~ "no blocks to search"
    end

    test "picking 'search transcript' from the palette opens the search picker (palette parity)" do
      {model, _device} = new_model(bulk_events_with_needle(2, 2, "needle"))
      model = drive_to_completion(model)

      model = Surface.handle_input(model, ctrl_p())
      model = type_chars(model, "search transcript")
      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay != nil
      assert model.overlay.picker.title == "search"
    end

    test "hostile body content never leaks control bytes (C0, ESC, DEL, C1) into the footer once the picker is open" do
      # C0 (0x01), ESC/SGR, DEL (0x7F), AND the C1 range (0x80-0x9F):
      # raw CSI (0x9B) and IND (0x84) are lone high bytes a Latin-1 /
      # raw-agent stream can carry. #632 made `ViewText.sanitize/1`
      # code-point-aware so it strips 0x80-0x9F; this feature routes
      # full block BODIES through that boundary, so the guard must cover
      # the C1 class the sole sanitizer is now responsible for, not just
      # C0/ESC (the review's "false assurance" gap).
      hostile =
        "visible words \e[31mred\e[0m trailer\x01tail\x7f" <>
          <<0x9B>> <> "csi" <> <<0x84>> <> "ind"

      {model, device} = new_model(hostile_events(hostile))
      model = drive_to_completion(model)
      model = Surface.focus_transcript(model)

      prior = byte_size(raw(device))
      model = Surface.handle_input(model, Event.key("/"))
      assert model.overlay != nil

      delta = delta_since(device, prior)

      # Positive check on the stripped view (the row rendered).
      assert strip_ansi(delta) =~ "visible words"

      # Control-byte refutes run against the RAW delta, NOT the
      # strip_ansi'd view: `strip_ansi`'s SequenceScanner would itself
      # eat a lone C1 introducer (0x9B = CSI), so asserting on the
      # stripped text would pass for the wrong reason (the oracle masking
      # the byte under test). The renderer only ever emits 7-bit `ESC[`
      # sequences, never a bare 0x01/0x7F/0x84/0x9B, so their absence in
      # the raw bytes proves the sanitizer stripped the hostile input.
      refute delta =~ <<0x01>>, "C0 (0x01) must not reach the device"
      refute delta =~ <<0x7F>>, "DEL (0x7F) must not reach the device"
      refute delta =~ <<0x9B>>, "raw CSI (C1) must not reach the device"
      refute delta =~ <<0x84>>, "IND (C1) must not reach the device"
    end

    test "a long CJK body opens cleanly: the label is clamped and the claimed overlay height stays sane" do
      cjk = String.duplicate("漢", 500)
      {model, _device} = new_model(hostile_events("short line\n#{cjk}"))
      model = drive_to_completion(model)
      model = Surface.focus_transcript(model)

      model = Surface.handle_input(model, Event.key("/"))
      assert model.overlay != nil

      [label] = overlay_labels(model)
      assert String.length(label) < 450

      assert OverlayPicker.height(model.overlay.picker) == 2
    end

    test "a needle past the label cap is not searchable -- the named, honest clamp consequence" do
      # A block whose body is padded past @search_label_cap (400
      # graphemes) before the needle appears: the clamp means the
      # needle never reaches the picker's label, so filtering on it
      # yields no matches.
      padding = String.duplicate("x", 500)
      {model, _device} = new_model(hostile_events("#{padding}\nfar-needle"))
      model = drive_to_completion(model)
      model = Surface.focus_transcript(model)

      model = Surface.handle_input(model, Event.key("/"))
      assert model.overlay != nil

      model = type_chars(model, "far-needle")
      assert OverlayPicker.matches(model.overlay.picker) == []
    end
  end
end
