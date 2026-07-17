defmodule Raxol.Harness.OverlayPickerSurfaceTest do
  @moduledoc """
  Footer-composition + keymap-priority suite for the overlay picker
  hosted inside the assembled harness surface (`Raxol.Harness.Surface`),
  byte-checked through the same StringIO + `SealOracle` harness the
  assembled-surface acceptance suite uses.

  The substrate rule under test: the harness renders inline -- history
  above the footer is terminal-owned scrollback that must NOT be painted
  over. The overlay therefore lives INSIDE the footer region: opening it
  GROWS the DECSTBM footer (more rows claimed from the bottom, any
  occupied claimed rows first scrolled up into native scrollback --
  preserved, never overwritten), shows the filterable list anchored above
  the prompt, and SHRINKS back on dismiss (vacated rows cleared while
  still footer-owned). Never a centered modal over history; never
  alt-screen; never `\\e[2J`/`\\e[3J`.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Harness.OverlayPicker
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 40
  @rows 12
  @footer_rows 4
  @region_top @rows - @footer_rows

  @items ["alpha", "beta", "gamma"]
  # overlay height for 3 items: 1 query row + 3 item rows
  @overlay_h 4
  @grown_footer_rows @footer_rows + @overlay_h
  @grown_region_top @rows - @grown_footer_rows

  # -- shared helpers (t13a conventions) ---------------------------------

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

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  defp history_at(bytes, region_top) do
    emulator = SealOracle.replay(bytes, width: @width, height: @rows)
    SealOracle.history(emulator, region_top)
  end

  # Rows addressed by an EXPLICIT CUP (`CSI row;col H`) -- the rows a
  # delta actually positions at to WRITE. `SealOracle.cup_rows/1`
  # (row_walk) additionally reports two implicit movements that write
  # nothing: DECSTBM's row-1 homing side effect (xterm semantics -- the
  # mandatory re-pin itself would flag as a "history row") and the
  # cursor bracket's DECRC restore. Those are real cursor states but not
  # paint targets, so footer-confinement is asserted over explicit CUPs
  # only. Two nets keep this honest: `full_walk!/1` retains row_walk's
  # fail-closed vocabulary sweep (raises on any unmodeled control
  # token), and the immutable-prefix replays (describes 3 and 6) catch
  # any write that actually lands in history, whatever positioned it.
  defp explicit_cup_rows(bytes) do
    bytes
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:csi, _params, "H"}, &1))
    |> Enum.map(fn {:csi, params, "H"} ->
      case params |> String.split(";") |> List.first() |> Integer.parse() do
        {n, _rest} -> n
        :error -> 1
      end
    end)
  end

  # Fail-closed sweep: `SealOracle.cup_rows/1` raises UnverifiableError
  # on any control token the row walk does not model (IL/DL/ED/etc.), so
  # a future implementation drifting into unvetted vocabulary reddens
  # these tests even though the confinement assertion itself only reads
  # explicit CUPs.
  defp full_walk!(bytes) do
    _rows = SealOracle.cup_rows(bytes)
    :ok
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
  # 1. Open: grow the pin, overlay rows land inside the grown footer
  # ---------------------------------------------------------------------

  describe "1. open grows the footer pin" do
    test "open re-pins DECSTBM to the grown split and paints overlay rows only inside the grown footer range" do
      {model, device} = new_model([])
      prior = byte_size(raw(device))

      assert {:ok, model} = Surface.open_overlay(model, @items)
      delta = delta_since(device, prior)

      # exactly one DECSTBM re-set, to the grown split
      assert SealOracle.region_sets(delta) == [{1, @grown_region_top}]

      # every addressed row is inside the grown footer range -- the
      # overlay never paints over (or into) the history region
      assert :ok == full_walk!(delta)
      rows = explicit_cup_rows(delta)
      assert rows != [], "opening must actually paint the overlay"

      assert Enum.all?(rows, &(&1 > @grown_region_top)),
             "overlay paint addressed a history row: #{inspect(rows)}"

      # the grown footer is what the authority now reports
      assert InlineAuthority.footer_row_count(model.authority) ==
               @grown_footer_rows

      # the overlay content is visible: query prompt + every item label
      plain = strip_ansi(delta)
      assert plain =~ "›"
      for item <- @items, do: assert(plain =~ item)

      refute SealOracle.emits_full_clear?(raw(device))
    end

    test "opening twice refuses" do
      {model, _device} = new_model([])
      assert {:ok, model} = Surface.open_overlay(model, @items)

      assert {:error, :overlay_already_open} =
               Surface.open_overlay(model, @items)
    end

    test "a taller item list is clamped to the available footer capacity, not refused" do
      {model, _device} = new_model([])
      many = Enum.map(1..10, &"item #{&1}")

      # capacity: history keeps >= 2 rows, so at most
      # rows - 2 - footer_rows = 6 overlay rows can be claimed
      assert {:ok, model} = Surface.open_overlay(model, many)

      assert OverlayPicker.height(model.overlay.picker) ==
               @rows - 2 - @footer_rows

      assert InlineAuthority.footer_row_count(model.authority) ==
               @footer_rows + (@rows - 2 - @footer_rows)

      refute Surface.degenerate?(model)
    end
  end

  # ---------------------------------------------------------------------
  # 2. Dismiss: shrink back, clear vacated rows, ESC hierarchy
  # ---------------------------------------------------------------------

  describe "2. ESC dismisses and shrinks the pin back" do
    test "ESC with the overlay open closes it (never interrupt); the NEXT ESC interrupts" do
      {model, device} = new_model([])
      assert {:ok, model} = Surface.open_overlay(model, @items)
      prior = byte_size(raw(device))

      model = Surface.handle_input(model, Event.key(:escape))
      assert model.overlay == nil

      delta = delta_since(device, prior)

      # dismissing must NOT fire the global ESC-interrupt
      refute strip_ansi(delta) =~ "interrupt requested"

      # the pin is back at the base split
      assert SealOracle.region_sets(delta) == [{1, @region_top}]
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows

      # the vacated rows (grown-footer top rows handed back toward
      # history) are cleared while still footer-owned -- their CUPs are
      # part of the shrink, and nothing ever addresses the base history
      # rows that held content (none here -- fresh model)
      assert :ok == full_walk!(delta)
      rows = explicit_cup_rows(delta)

      for r <- (@grown_region_top + 1)..@region_top do
        assert r in rows,
               "vacated row #{r} must be cleared on dismiss (rows addressed: #{inspect(rows)})"
      end

      assert Enum.all?(rows, &(&1 > @grown_region_top)),
             "dismiss addressed a row above the grown footer: #{inspect(rows)}"

      # ESC again, overlay closed: the normal interrupt stub fires
      _model = Surface.handle_input(model, Event.key(:escape))
      assert strip_ansi(raw(device)) =~ "interrupt requested"
    end
  end

  # ---------------------------------------------------------------------
  # 3. History preservation across grow/shrink (the substrate's spine)
  # ---------------------------------------------------------------------

  describe "3. sealed history survives open + dismiss" do
    test "growing over OCCUPIED history rows scrolls them into scrollback (immutable prefix), never paints over them" do
      {model, device} = new_model(bulk_events(4))
      model = drive_to_completion(model)

      # precondition: sealed content actually occupies rows the grow
      # will claim (the fill cursor is past the grown split)
      assert model.authority.next_row > @grown_region_top

      history_before = history_at(raw(device), @region_top)
      assert history_before != []

      assert {:ok, model} = Surface.open_overlay(model, @items)
      history_during = history_at(raw(device), @grown_region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_during),
             "growing the footer must scroll occupied rows up, never overwrite them"

      model = Surface.handle_input(model, Event.key(:escape))
      assert model.overlay == nil
      history_after = history_at(raw(device), @region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_after),
             "history must survive the full open + dismiss round trip"

      refute SealOracle.emits_full_clear?(raw(device))
    end

    test "open immediately after a shrink-resize (next_row clamped onto a full region) still scrolls, never overwrites -- immutable prefix from the post-resize baseline" do
      # Adversarial review, LOW (plausible): resize/3 clamps next_row
      # DOWN on a rows-shrink without moving on-screen content, so a
      # grow right after could under-report occupancy. The clamp lands
      # next_row exactly AT the new bottom, which is grow_reclaim_count's
      # conservative full-delta branch -- this pins that.
      {model, device} = new_model(bulk_events(4))
      model = drive_to_completion(model)
      assert model.authority.next_row == @region_top

      # shrink 12 -> 10 rows: history bottom 8 -> 6, next_row clamps 8 -> 6
      shrunk_rows = 10
      shrunk_region_top = shrunk_rows - @footer_rows
      model = Surface.resize(model, @width, shrunk_rows)
      assert model.authority.next_row == shrunk_region_top

      history_after_resize =
        raw(device)
        |> SealOracle.replay(width: @width, height: shrunk_rows)
        |> SealOracle.history(shrunk_region_top)

      assert {:ok, model} = Surface.open_overlay(model, @items)

      overlay_region_top = shrunk_region_top - @overlay_h

      history_during =
        raw(device)
        |> SealOracle.replay(width: @width, height: shrunk_rows)
        |> SealOracle.history(overlay_region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(
                 history_after_resize,
                 history_during
               ),
             "a grow right after a shrink-resize must scroll the still-occupied rows, never overwrite them"

      model = Surface.handle_input(model, Event.key(:escape))
      assert model.overlay == nil
      refute SealOracle.emits_full_clear?(raw(device))
    end
  end

  # ---------------------------------------------------------------------
  # 4. Typing filters, Enter commits (passthrough routing to the overlay)
  # ---------------------------------------------------------------------

  describe "4. filter + commit" do
    test "printable keys filter the overlay (not the composer); Enter commits via on_pick and restores the footer" do
      {model, device} = new_model([])

      on_pick = fn m, item -> %{m | stub_notice: "» picked #{item}"} end

      assert {:ok, model} =
               Surface.open_overlay(model, @items, on_pick: on_pick)

      composer_before =
        Raxol.UI.Components.Harness.Composer.value(model.composer)

      model = Surface.handle_input(model, Event.key("b"))

      # the keystroke filtered the overlay...
      assert OverlayPicker.matches(model.overlay.picker) == ["beta"]
      # ...and did NOT land in the composer buffer
      assert Raxol.UI.Components.Harness.Composer.value(model.composer) ==
               composer_before

      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay == nil
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows
      assert strip_ansi(raw(device)) =~ "picked beta"
    end

    test "arrow keys move the overlay selection; Enter picks the selected item" do
      {model, device} = new_model([])
      assert {:ok, model} = Surface.open_overlay(model, @items)

      model = Surface.handle_input(model, Event.key(:down))
      model = Surface.handle_input(model, Event.key(:enter))

      assert model.overlay == nil
      # default on_pick: an honest one-frame footer notice
      assert strip_ansi(raw(device)) =~ "beta"
    end

    test "opened from transcript-browse mode (composing?: false -- the natural jump/search path), z/j/k are filter text and never mutate fold/jump state behind the overlay" do
      # The adversarial review's CRITICAL: z/j/k are :not_composing
      # keymap binds. A guard consulting only composing? fires them as
      # commands past the open overlay -- dropped from the filter query
      # AND silently toggling folds / moving the jump cursor behind it.
      {model, _device} = new_model(bulk_events(2))
      model = drive_to_completion(model)

      model = Surface.focus_transcript(model)
      refute model.composing?
      model = Surface.handle_input(model, Event.key("j"))
      assert model.focused_index == 0

      assert {:ok, model} = Surface.open_overlay(model, ["jazz", "kilo"])

      model =
        Enum.reduce(["j", "k", "z"], model, fn ch, m ->
          Surface.handle_input(m, Event.key(ch))
        end)

      assert model.overlay != nil, "the overlay must survive plain typing"

      assert model.overlay.picker.query == "jkz",
             "every typed letter must reach the overlay filter"

      assert model.focused_index == 0,
             "the transcript jump cursor must not move behind the open overlay"

      assert model.fold_overrides == %{},
             "no fold may toggle behind the open overlay"
    end

    test "keystroke echo while the overlay is open stays inside the grown footer" do
      {model, device} = new_model([])
      assert {:ok, model} = Surface.open_overlay(model, @items)
      prior = byte_size(raw(device))

      _model = Surface.handle_input(model, Event.key("a"))
      delta = delta_since(device, prior)
      assert :ok == full_walk!(delta)
      rows = explicit_cup_rows(delta)

      assert rows != []

      assert Enum.all?(rows, &(&1 > @grown_region_top)),
             "overlay keystroke echo addressed a history row: #{inspect(rows)}"
    end
  end

  # ---------------------------------------------------------------------
  # 5. Degenerate geometry: the overlay refuses to open
  # ---------------------------------------------------------------------

  describe "5. degenerate geometry refusal" do
    test "too-short terminal: refuses with zero bytes and an unchanged model" do
      # rows 7 / footer 4: history keeps 3 rows; claiming even the
      # 2-row minimum overlay (query + one item) would leave < 2
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
               Surface.open_overlay(model, @items)

      assert byte_size(raw(device)) == prior,
             "a refused open must write zero bytes"
    end

    test "flat mode has no footer to grow: refuses" do
      {model, _device} = new_model([], mode: :flat)
      assert {:error, :no_footer} = Surface.open_overlay(model, @items)
    end

    test "resizing below capacity while open force-closes the overlay and restores the base pin" do
      {model, _device} = new_model([])
      assert {:ok, model} = Surface.open_overlay(model, @items)

      model = Surface.resize(model, @width, 8)

      assert model.overlay == nil

      assert InlineAuthority.footer_row_count(model.authority) ==
               @footer_rows
    end
  end

  # ---------------------------------------------------------------------
  # 6. Authority-level grow/shrink (InlineAuthority.set_footer_rows/2)
  # ---------------------------------------------------------------------

  describe "6. InlineAuthority.set_footer_rows/2" do
    defp new_authority do
      {:ok, device} = StringIO.open("")
      {InlineAuthority.new(device, @width, @rows, @footer_rows), device}
    end

    test "same footer_rows: {:ok, t} and zero bytes" do
      {auth, device} = new_authority()
      prior = byte_size(raw(device))

      assert {:ok, ^auth} = InlineAuthority.set_footer_rows(auth, @footer_rows)
      assert byte_size(raw(device)) == prior
    end

    test "a degenerate target: {:error, :degenerate} and zero bytes -- never unpins a live footer" do
      {auth, device} = new_authority()
      prior = byte_size(raw(device))

      assert {:error, :degenerate} =
               InlineAuthority.set_footer_rows(auth, @rows - 1)

      assert byte_size(raw(device)) == prior
    end

    test "grow over EMPTY claimed rows emits only the DECSTBM re-set (no scroll)" do
      {auth, device} = new_authority()
      prior = byte_size(raw(device))

      assert {:ok, auth} =
               InlineAuthority.set_footer_rows(auth, @grown_footer_rows)

      delta = delta_since(device, prior)
      assert SealOracle.region_sets(delta) == [{1, @grown_region_top}]

      refute String.contains?(delta, "\n"),
             "no content occupied the claimed rows -- nothing to scroll"

      assert InlineAuthority.footer_row_count(auth) == @grown_footer_rows
    end

    test "grow over OCCUPIED claimed rows scrolls them up first; a later seal never rewrites them" do
      {auth, device} = new_authority()

      auth =
        Enum.reduce(1..@region_top, auth, fn i, a ->
          InlineAuthority.seal(a, "sealed line #{i}\r\n")
        end)

      history_before = history_at(raw(device), @region_top)

      assert {:ok, auth} =
               InlineAuthority.set_footer_rows(auth, @grown_footer_rows)

      assert {:ok, auth} =
               InlineAuthority.set_footer_rows(auth, @footer_rows)

      auth = InlineAuthority.seal(auth, "sealed after round trip\r\n")
      _ = auth

      history_after = history_at(raw(device), @region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_after)

      assert history_after
             |> Enum.map(&row_text/1)
             |> Enum.join("\n") =~ "sealed after round trip"

      refute SealOracle.emits_full_clear?(raw(device))
    end

    test "grow over a PARTIALLY-filled history keeps the boundary row blank: the next seal appends, never overwrites" do
      # Regression: `grow_reclaim_count/3`'s pre-fix formula
      # (`max(next_row - 1 - new_bottom, 0)`) under-scrolled by exactly
      # one row whenever content reached the new boundary without filling
      # the OLD region -- leaving real content ON row `new_bottom` while
      # `next_row` claimed it blank, so the very next `seal/2` silently
      # overwrote it. `append_sealed/2`'s loop invariant (row `next_row`
      # is ALWAYS blank) must survive a grow.
      {auth, device} = new_authority()

      auth =
        Enum.reduce(1..6, auth, fn i, a ->
          InlineAuthority.seal(a, "sealed line #{i}\r\n")
        end)

      # partial fill: content stops short of the old history bottom
      assert auth.next_row == 7
      assert auth.next_row < @region_top

      history_before = history_at(raw(device), @region_top)

      assert {:ok, auth} =
               InlineAuthority.set_footer_rows(auth, @grown_footer_rows)

      _auth = InlineAuthority.seal(auth, "sealed after grow\r\n")

      history_after = history_at(raw(device), @grown_region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_after),
             "a seal right after a partial-fill grow must scroll, never overwrite the boundary row"

      text = history_after |> Enum.map(&row_text/1) |> Enum.join("\n")
      assert text =~ "sealed line 6"
      assert text =~ "sealed after grow"
      refute SealOracle.emits_full_clear?(raw(device))
    end

    test "shrink clears the vacated rows and re-pins; the next repaint self-promotes to a keyframe" do
      {auth, device} = new_authority()

      assert {:ok, auth} =
               InlineAuthority.set_footer_rows(auth, @grown_footer_rows)

      prior = byte_size(raw(device))
      assert {:ok, auth} = InlineAuthority.set_footer_rows(auth, @footer_rows)
      delta = delta_since(device, prior)

      assert SealOracle.region_sets(delta) == [{1, @region_top}]

      assert :ok == full_walk!(delta)
      rows = explicit_cup_rows(delta)

      for r <- (@grown_region_top + 1)..@region_top do
        assert r in rows, "vacated row #{r} must be cleared"
      end

      assert auth.needs_keyframe,
             "a footer-rows change must latch needs_keyframe (same latch resize/3 uses)"
    end
  end
end
