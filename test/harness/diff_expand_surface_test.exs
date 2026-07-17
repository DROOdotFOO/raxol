defmodule Raxol.Harness.DiffExpandSurfaceTest do
  @moduledoc """
  Full-screen diff expansion hosted inside the assembled harness surface
  (`Raxol.Harness.Surface`), byte-checked through the same StringIO +
  `SealOracle` harness the overlay-picker suite uses.

  The substrate ruling under test (footer-region maximization, mechanism
  B): expanding a focused diff block GROWS the DECSTBM footer to the
  largest non-degenerate claim (history keeps its 2-row minimum) and
  renders a scrollable diff viewport inside it -- never the alternate
  screen (`\\e[?1049h` -- the inline profile's LC-P-NOALT invariant holds
  across the whole feature), never a paint over history, never
  `\\e[2J`/`\\e[3J`. Dismiss shrinks back to the base footer split and the
  latched keyframe restores the footer byte-identically.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Components.Harness.{Block, Composer}
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 40
  @rows 12
  @footer_rows 4
  @region_top @rows - @footer_rows

  # Maximization: the largest non-degenerate claim leaves history its
  # 2-row minimum -- footer grows to rows - 2.
  @expanded_footer_rows @rows - 2
  @expanded_region_top @rows - @expanded_footer_rows

  @old_text Enum.map_join(1..20, "\n", &"alpha line #{&1}")
  @new_text String.replace(
              @old_text,
              "alpha line 10",
              "EXPANDED_MARKER line ten"
            )

  # -- shared helpers (overlay-suite conventions) -------------------------

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

  defp history_at(bytes, region_top) do
    emulator = SealOracle.replay(bytes, width: @width, height: @rows)
    SealOracle.history(emulator, region_top)
  end

  # The footer's on-screen rows (full Cell rows, styles included) -- the
  # byte-identical-restore comparison surface.
  defp footer_cells_at(bytes, region_top) do
    bytes
    |> SealOracle.replay(width: @width, height: @rows)
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.drop(region_top)
  end

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

  defp full_walk!(bytes) do
    _rows = SealOracle.cup_rows(bytes)
    :ok
  end

  defp diff_block(old, new) do
    %Block{
      kind: :diff,
      raw_kind: "diff",
      event_refs: [],
      fold: :expanded,
      seal: :sealed,
      outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
      content: %{path: "lib/sample.ex", old: old, new: new, language: nil}
    }
  end

  # Injects a diff block into the projection (no producer resolves the
  # :diff kind yet -- the path is wired but dormant, so tests construct
  # it directly), focuses it, and enters transcript-browse mode.
  defp with_focused_diff(model, old \\ @old_text, new \\ @new_text) do
    blocks = model.projection.blocks ++ [diff_block(old, new)]

    model = %{model | projection: %{model.projection | blocks: blocks}}
    model = %{model | focused_index: length(blocks) - 1}
    Surface.focus_transcript(model)
  end

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
  # 1. The keybind guard matrix ('e' = expand focused diff)
  # ---------------------------------------------------------------------

  describe "1. keybind guard matrix" do
    test "while composing, 'e' is typed text -- never an expansion" do
      {model, _device} = new_model([])
      model = with_focused_diff(model)
      model = Surface.focus_composer(model)
      assert model.composing?

      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion == nil
      assert Composer.value(model.composer) == "e"
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows
    end

    test "transcript-browse + focused diff: 'e' expands to the maximized footer" do
      {model, device} = new_model([])
      model = with_focused_diff(model)
      prior = byte_size(raw(device))

      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion != nil

      assert InlineAuthority.footer_row_count(model.authority) ==
               @expanded_footer_rows

      delta = delta_since(device, prior)
      assert SealOracle.region_sets(delta) == [{1, @expanded_region_top}]

      assert :ok == full_walk!(delta)
      rows = explicit_cup_rows(delta)
      assert rows != [], "expanding must actually paint the diff view"

      assert Enum.all?(rows, &(&1 > @expanded_region_top)),
             "expansion paint addressed a history row: #{inspect(rows)}"

      # One rendered line per visual diff row (the pure suite pins the
      # exact math): the first unscrolled frame shows the header (path +
      # position) and the top of the diff; the changed row mid-file is
      # reached by scrolling.
      plain = strip_ansi(delta)
      assert plain =~ "lib/sample.ex"
      assert plain =~ "alpha line 1"

      model =
        Enum.reduce(1..20, model, fn _i, m ->
          Surface.handle_input(m, Event.key("j"))
        end)

      _model = model

      assert strip_ansi(raw(device)) =~ "EXPANDED_MARKER",
             "the changed row must be reachable by scrolling"

      refute SealOracle.emits_full_clear?(raw(device))
    end

    test "focused block is not a diff: honest notice, zero grow" do
      {model, device} = new_model(bulk_events(2))
      model = drive_to_completion(model)
      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("j"))
      assert model.focused_index == 0

      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion == nil
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows
      assert strip_ansi(raw(device)) =~ "not a diff"
    end

    test "no block focused: honest notice, zero grow" do
      {model, device} = new_model([])
      model = Surface.focus_transcript(model)
      assert model.focused_index == nil

      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion == nil
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows
      assert strip_ansi(raw(device)) =~ "no block focused"
    end

    test "with an overlay open, 'e' is filter text -- never an expansion" do
      {model, _device} = new_model([])
      model = with_focused_diff(model)

      assert {:ok, model} = Surface.open_overlay(model, ["echo", "foxtrot"])
      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion == nil
      assert model.overlay.picker.query == "e"
    end
  end

  # ---------------------------------------------------------------------
  # 2. Scrolling inside the expanded view
  # ---------------------------------------------------------------------

  describe "2. scrolling" do
    setup do
      {model, device} = new_model([])
      model = with_focused_diff(model)
      model = Surface.handle_input(model, Event.key("e"))
      assert model.expansion != nil
      {:ok, model: model, device: device}
    end

    test "j/down scroll down; k/up scroll up; both clamped", %{model: model} do
      assert model.expansion.offset == 0

      model = Surface.handle_input(model, Event.key("k"))
      assert model.expansion.offset == 0, "scroll up from the top clamps"

      model = Surface.handle_input(model, Event.key("j"))
      assert model.expansion.offset == 1

      model = Surface.handle_input(model, Event.key(:down))
      assert model.expansion.offset == 2

      model = Surface.handle_input(model, Event.key(:up))
      assert model.expansion.offset == 1

      model =
        Enum.reduce(1..500, model, fn _i, m ->
          Surface.handle_input(m, Event.key("j"))
        end)

      max_offset = model.expansion.total - model.expansion.view_rows
      assert model.expansion.offset == max_offset, "scroll down clamps at end"
    end

    test "scroll repaints stay inside the expanded footer", %{
      model: model,
      device: device
    } do
      prior = byte_size(raw(device))
      _model = Surface.handle_input(model, Event.key("j"))
      delta = delta_since(device, prior)

      assert :ok == full_walk!(delta)
      rows = explicit_cup_rows(delta)
      assert rows != []

      assert Enum.all?(rows, &(&1 > @expanded_region_top)),
             "scroll repaint addressed a history row: #{inspect(rows)}"
    end

    test "'q' dismisses, same as ESC", %{model: model} do
      model = Surface.handle_input(model, Event.key("q"))
      assert model.expansion == nil
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows
    end
  end

  # ---------------------------------------------------------------------
  # 3. The dismiss bracket: exact restoration
  # ---------------------------------------------------------------------

  describe "3. dismiss restores the prior harness state exactly" do
    test "ESC closes the expansion (never interrupt); footer restored byte-identically; focus preserved" do
      {model, device} = new_model([])
      model = with_focused_diff(model)
      focused_before = model.focused_index

      # settle one repaint post-focus so the baseline footer is current
      model = Surface.handle_input(model, Event.key(:up))
      footer_before = footer_cells_at(raw(device), @region_top)

      model = Surface.handle_input(model, Event.key("e"))
      assert model.expansion != nil
      model = Surface.handle_input(model, Event.key("j"))

      prior = byte_size(raw(device))
      model = Surface.handle_input(model, Event.key(:escape))

      assert model.expansion == nil
      delta = delta_since(device, prior)

      refute strip_ansi(delta) =~ "interrupt requested",
             "ESC on an open expansion must dismiss, never interrupt"

      assert SealOracle.region_sets(delta) == [{1, @region_top}]
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows

      # byte-identical footer: full Cell rows, styles included
      footer_after = footer_cells_at(raw(device), @region_top)
      assert footer_after == footer_before

      # focus position preserved, still transcript-browse
      assert model.focused_index == focused_before
      refute model.composing?

      # ESC again, expansion closed: the normal interrupt stub fires
      _model = Surface.handle_input(model, Event.key(:escape))
      assert strip_ansi(raw(device)) =~ "interrupt requested"
    end

    test "sealed history survives the full expand + scroll + dismiss bracket (immutable prefix)" do
      {model, device} = new_model(bulk_events(4))
      model = drive_to_completion(model)
      model = with_focused_diff(model)

      # precondition: sealed content occupies rows the grow will claim
      assert model.authority.next_row > @expanded_region_top

      history_before = history_at(raw(device), @region_top)
      assert history_before != []

      model = Surface.handle_input(model, Event.key("e"))
      assert model.expansion != nil

      history_during = history_at(raw(device), @expanded_region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_during),
             "growing the footer must scroll occupied rows up, never overwrite them"

      model = Surface.handle_input(model, Event.key("j"))
      model = Surface.handle_input(model, Event.key(:escape))
      assert model.expansion == nil

      history_after = history_at(raw(device), @region_top)

      assert :ok ==
               SealOracle.immutable_prefix?(history_before, history_after),
             "history must survive the full expand + dismiss round trip"

      refute SealOracle.emits_full_clear?(raw(device))
    end

    test "the whole feature never touches the alternate screen (LC-P-NOALT)" do
      {model, device} = new_model([])
      model = with_focused_diff(model)

      model = Surface.handle_input(model, Event.key("e"))
      model = Surface.handle_input(model, Event.key("j"))
      _model = Surface.handle_input(model, Event.key(:escape))

      bytes = raw(device)
      refute bytes =~ "\e[?1049", "alt-screen byte on the inline path"
      refute bytes =~ "\e[?47", "legacy alt-screen byte on the inline path"
      refute SealOracle.emits_full_clear?(bytes)
    end
  end

  # ---------------------------------------------------------------------
  # 4. Hostile diff content at the surface level
  # ---------------------------------------------------------------------

  describe "4. hostile diff content" do
    test "escape sequences in agent-produced diff text never reach the wire" do
      hostile_new =
        Enum.join(
          [
            "\e[2Jwipe attempt",
            "\e[?1049halt attempt",
            "\e]0;osc injection\adone",
            "plain line"
          ],
          "\n"
        )

      {model, device} = new_model([])
      model = with_focused_diff(model, "", hostile_new)
      prior = byte_size(raw(device))

      model = Surface.handle_input(model, Event.key("e"))
      assert model.expansion != nil

      delta = delta_since(device, prior)
      refute delta =~ "\e[2J"
      refute delta =~ "\e[?1049"
      refute delta =~ "\e]0;"

      # the walk's fail-closed vocabulary sweep still passes: hostile
      # content introduced no unmodeled control tokens
      assert :ok == full_walk!(delta)
    end
  end

  # ---------------------------------------------------------------------
  # 5. Degenerate geometry + flat mode: honest refusal
  # ---------------------------------------------------------------------

  describe "5. refusal" do
    test "too-short terminal: direct call refuses with zero bytes and an unchanged model" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: @width,
          rows: 7,
          footer_rows: 4,
          mode: :inline_log
        )

      model = with_focused_diff(model)
      prior = byte_size(raw(device))

      assert {:error, :insufficient_footer_capacity} =
               Surface.expand_focused_diff(model)

      assert byte_size(raw(device)) == prior,
             "a refused expansion must write zero bytes"
    end

    test "too-short terminal: the keybind surfaces an honest notice instead" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: @width,
          rows: 7,
          footer_rows: 4,
          mode: :inline_log
        )

      model = with_focused_diff(model)
      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion == nil
      assert strip_ansi(raw(device)) =~ "too small"
    end

    test "flat mode has no footer to grow: refuses" do
      {model, _device} = new_model([], mode: :flat)
      model = with_focused_diff(model)
      assert {:error, :no_footer} = Surface.expand_focused_diff(model)
    end

    test "expanding twice refuses; expanding with an overlay open refuses" do
      {model, _device} = new_model([])
      model = with_focused_diff(model)

      assert {:ok, model} = Surface.expand_focused_diff(model)

      assert {:error, :expansion_already_open} =
               Surface.expand_focused_diff(model)

      model = Surface.close_expansion(model)
      assert {:ok, model} = Surface.open_overlay(model, ["a", "b"])
      assert {:error, :overlay_open} = Surface.expand_focused_diff(model)
    end

    test "opening an overlay while expanded refuses" do
      {model, _device} = new_model([])
      model = with_focused_diff(model)
      assert {:ok, model} = Surface.expand_focused_diff(model)

      assert {:error, :expansion_open} = Surface.open_overlay(model, ["a"])
    end
  end

  # ---------------------------------------------------------------------
  # 7. The honest-notice law under footer overflow (integration finding)
  # ---------------------------------------------------------------------
  #
  # `InlineAuthority.repaint/2` pads/TRUNCATES the line list to the footer
  # row count position-blind (`Enum.take/2` -- the tail is the casualty).
  # With the notice as the LAST footer group, any composed footer that
  # overflows the row budget silently eats the honest refusal/degradation
  # notice first: an honest-notice-law violation that only manifests when
  # sibling footer content (evidence rows, previews, extra slots) pushes
  # the list past the budget. The fix is a priority-ordered fit inside
  # `footer_lines/1` itself: discretionary rows (preview, divider,
  # composer tail) yield; a notice is NEVER the line that silently drops.

  describe "7. honest-notice law under footer overflow" do
    test "a refusal notice survives a footer too small to hold everything (composer yields, never the notice)" do
      {:ok, device} = StringIO.open("")

      # footer_rows 2: status + composer already exceed the budget, so a
      # tail-truncating repaint would eat the notice appended after them.
      model =
        Surface.new([],
          device: device,
          width: @width,
          rows: 7,
          footer_rows: 2,
          mode: :inline_log
        )

      model = Surface.focus_transcript(model)
      assert model.focused_index == nil

      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion == nil

      assert strip_ansi(raw(device)) =~ "no block focused",
             "the honest refusal notice must never be the row an " <>
               "overflowing footer silently drops"
    end

    test "the notice outranks even the status line at a 1-row budget" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: @width,
          rows: 7,
          footer_rows: 1,
          mode: :inline_log
        )

      model = Surface.focus_transcript(model)
      model = Surface.handle_input(model, Event.key("e"))

      assert strip_ansi(raw(device)) =~ "no block focused",
             "at the degenerate 1-row budget the notice is the one row " <>
               "that must win"
    end

    test "a notice survives when a pending preview competes for the same rows (the preview yields)" do
      {:ok, device} = StringIO.open("")

      # footer_rows 4 with a pending-block preview present: status +
      # preview (2) + composer already meet/exceed the budget before the
      # notice is appended.
      model =
        Surface.new(bulk_events(2),
          device: device,
          width: @width,
          rows: 10,
          footer_rows: 4,
          mode: :inline_log
        )

      # advance far enough that a completed block sits in the pending
      # (not-yet-painted) preview slot, but not to completion
      {model, :ok} = Surface.advance(model)
      {model, :ok} = Surface.advance(model)
      {model, :ok} = Surface.advance(model)

      model = Surface.focus_transcript(model)
      prior = byte_size(raw(device))
      model = Surface.handle_input(model, Event.key("e"))

      assert model.expansion == nil

      assert strip_ansi(delta_since(device, prior)) =~ "no block focused",
             "a discretionary preview row must yield before an honest " <>
               "notice is ever dropped"
    end

    test "footer_lines never hands repaint more rows than the budget (the clamp is priority-aware, not repaint's position-blind tail-drop)" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: @width,
          rows: 7,
          footer_rows: 2,
          mode: :inline_log
        )

      model = Surface.focus_transcript(model)
      prior = byte_size(raw(device))
      _model = Surface.handle_input(model, Event.key("e"))

      delta = delta_since(device, prior)
      assert :ok == full_walk!(delta)
      rows = explicit_cup_rows(delta)
      assert rows != []

      assert Enum.all?(rows, &(&1 > 7 - 2)),
             "an overflowing footer must never paint outside its region: #{inspect(rows)}"
    end
  end

  # ---------------------------------------------------------------------
  # 6. Interactions with the rest of the surface
  # ---------------------------------------------------------------------

  describe "6. interactions" do
    test "Ctrl+E (editor handoff) is a no-op while expanded -- the footer is expansion-shaped" do
      test_pid = self()

      session = fn _draft, _opts ->
        send(test_pid, :editor_called)
        {:error, :should_never_run}
      end

      {model, _device} = new_model([], editor_session: session)
      model = with_focused_diff(model)
      assert {:ok, model} = Surface.expand_focused_diff(model)

      model =
        Surface.handle_input(model, Event.key_event("e", :pressed, [:ctrl]))

      refute_received :editor_called
      assert model.expansion != nil
    end

    test "Tab (:steer) is a no-op while expanded -- the composer is hidden state" do
      {model, _device} = new_model([])
      model = with_focused_diff(model)
      assert {:ok, model} = Surface.expand_focused_diff(model)
      composer_before = model.composer

      model = Surface.handle_input(model, Event.key(:tab))

      assert model.composer == composer_before
      assert model.expansion != nil
    end

    test "j/k scroll the expansion -- transcript focus never moves behind it" do
      {model, _device} = new_model(bulk_events(2))
      model = drive_to_completion(model)
      model = with_focused_diff(model)
      focused_before = model.focused_index

      assert {:ok, model} = Surface.expand_focused_diff(model)
      model = Surface.handle_input(model, Event.key("j"))
      model = Surface.handle_input(model, Event.key("j"))

      assert model.focused_index == focused_before,
             "the transcript jump cursor must not move behind the expansion"

      assert model.expansion.offset == 2
    end

    test "resize that still fits re-derives the claim and keeps the expansion open" do
      {model, _device} = new_model([])
      model = with_focused_diff(model)
      assert {:ok, model} = Surface.expand_focused_diff(model)

      # rows 14: max claim leaves the 2-row history minimum
      model = Surface.resize(model, @width, 14)

      assert model.expansion != nil
      assert InlineAuthority.footer_row_count(model.authority) == 14 - 2

      max_offset =
        max(model.expansion.total - model.expansion.view_rows, 0)

      assert model.expansion.offset <= max_offset
    end

    test "resize below capacity force-closes the expansion and restores the base pin" do
      {model, _device} = new_model([])
      model = with_focused_diff(model)
      assert {:ok, model} = Surface.expand_focused_diff(model)

      model = Surface.resize(model, @width, 7)

      assert model.expansion == nil
      assert InlineAuthority.footer_row_count(model.authority) == @footer_rows
    end
  end
end
