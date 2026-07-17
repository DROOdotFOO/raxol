defmodule Raxol.Harness.SurfaceDebugHighlightTest do
  @moduledoc """
  Byte-level pins for the DevTools hover-highlight seam
  (`Raxol.Harness.Surface.put_debug_highlight/2`): a display-only
  pale-blue BACKGROUND over exactly one footer group's rows.

  The laws pinned here:

    * the bg SGR lands on EXACTLY the highlighted group's rows and
      nowhere else (repaint-diff precision);
    * clearing restores a byte-identical footer (set -> clear -> set is
      byte-deterministic; the replayed footer screen state round-trips);
    * `nil` highlight is a zero-byte no-op -- goldens can never be
      perturbed by an idle highlight channel;
    * highlight bytes are CONFINED to the footer region -- sealed
      history is never touched (seal-once);
    * the cursor park still lands after a highlight repaint;
    * capability tiers pick the documented bg vocabulary (truecolor /
      256-cube / ANSI16 blue);
    * `close_stream/1` clears an active highlight (teardown honesty);
    * `:flat` mode is a byte-free no-op (no footer, nothing to paint).

  Mirrors `surface_live_seam_test.exs`'s helper idioms: a `StringIO`
  device driving the REAL `InlineAuthority`, `SealOracle` replay for
  screen-state assertions.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Surface.ViewText
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Capabilities
  alias Raxol.UI.Components.Harness.Composer

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  # The documented per-tier bg SGR prefixes (see Surface's
  # "DevTools debug highlight" section).
  @bg_256 "\e[48;5;24m"
  @bg_truecolor "\e[48;2;35;70;96m"
  @bg_ansi16 "\e[44m"

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  # Bytes emitted after `offset` (capture-the-increment idiom).
  defp bytes_since(device, offset) do
    all = raw(device)
    binary_part(all, offset, byte_size(all) - offset)
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

  # Splits a byte capture into per-CUP chunks: each chunk starts with the
  # `\e[row;colH` that positioned it. The pre-CUP head (cursor-hide,
  # sync-open decoration) is dropped -- it carries no row content.
  defp cup_chunks(bytes) do
    [_head | chunks] = Regex.split(~r/(?=\e\[\d+;\d+H)/, bytes)
    chunks
  end

  defp chunk_row(chunk) do
    [_, row] = Regex.run(~r/^\e\[(\d+);\d+H/, chunk)
    String.to_integer(row)
  end

  # Absolute terminal rows the bg prefix was painted on.
  defp rows_with_bg(bytes, bg) do
    bytes
    |> cup_chunks()
    |> Enum.filter(&String.contains?(&1, bg))
    |> Enum.map(&chunk_row/1)
  end

  # The CURRENT footer screen state: full-stream emulator replay, footer
  # rows as trimmed text (cumulative raw-byte greps can prove presence,
  # never absence -- this proves both).
  defp footer_text(device) do
    emulator = SealOracle.replay(raw(device), width: @width, height: @rows)

    emulator
    |> SealOracle.rows_above_footer(@rows + 1)
    |> Enum.drop(@region_top)
    |> Enum.map(fn row ->
      row |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
    end)
  end

  defp history_text(device) do
    emulator = SealOracle.replay(raw(device), width: @width, height: @rows)

    emulator
    |> SealOracle.history(@region_top)
    |> Enum.map_join("\n", fn row ->
      row |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
    end)
  end

  defp composer_row_count(model) do
    model.composer
    |> Composer.render(%{available_width: @width})
    |> ViewText.lines(@width, :styled)
    |> length()
  end

  defp single_message_events(text) do
    [
      %{
        id: 1,
        turn_id: "t1",
        ts: 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "hi"}
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
          "content" => text
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
  end

  # ---------------------------------------------------------------------
  # bg SGR precision: exactly the highlighted group's rows
  # ---------------------------------------------------------------------

  describe "highlight :composer" do
    test "bg SGR lands on exactly the composer rows and nowhere else" do
      {model, device} = new_model([])
      offset = byte_size(raw(device))

      model = Surface.put_debug_highlight(model, :composer)
      hl_bytes = bytes_since(device, offset)

      expected_rows = composer_row_count(model)
      assert expected_rows > 0

      bg_rows = rows_with_bg(hl_bytes, @bg_256)

      # Exactly the composer group repainted with bg: contiguous run,
      # one row per composer line, entirely inside the footer, below the
      # status row (footer's first row).
      assert length(bg_rows) == expected_rows
      assert bg_rows == Enum.to_list(hd(bg_rows)..List.last(bg_rows))
      assert Enum.all?(bg_rows, &(&1 > @region_top))
      refute (@region_top + 1) in bg_rows

      # Nowhere else: every repainted chunk that carries content carries
      # the bg (the diff repaint touched ONLY the composer rows) -- any
      # bg-free chunk must be pure cursor movement (the park), zero text.
      for chunk <- cup_chunks(hl_bytes), not String.contains?(chunk, @bg_256) do
        assert Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]|\e[78]/, chunk, "") == ""
      end
    end

    test "highlight repaint keeps the cursor park landing" do
      {model, device} = new_model([])
      base_park = SealOracle.last_cursor_row(raw(device))
      offset = byte_size(raw(device))

      _model = Surface.put_debug_highlight(model, :composer)
      hl_bytes = bytes_since(device, offset)

      # The park CUP still lands after the highlight repaint, at the
      # same composer edit row the un-highlighted frame parked at.
      assert SealOracle.last_cursor_row(hl_bytes) == base_park
    end

    test "clear restores a byte-identical footer (set/clear round-trips)" do
      {model, device} = new_model([])
      footer_before = footer_text(device)

      o1 = byte_size(raw(device))
      model = Surface.put_debug_highlight(model, :composer)
      h1 = bytes_since(device, o1)

      o2 = byte_size(raw(device))
      model = Surface.put_debug_highlight(model, nil)
      c1 = bytes_since(device, o2)

      refute String.contains?(c1, @bg_256)
      assert footer_text(device) == footer_before

      # Determinism: a second set/clear cycle emits byte-identical
      # repaints -- the highlight is a pure function of the frame.
      o3 = byte_size(raw(device))
      model = Surface.put_debug_highlight(model, :composer)
      h2 = bytes_since(device, o3)

      o4 = byte_size(raw(device))
      _model = Surface.put_debug_highlight(model, nil)
      c2 = bytes_since(device, o4)

      assert h1 == h2
      assert c1 == c2
    end
  end

  describe "highlight :status" do
    test "bg lands on exactly the status row (the footer's first row)" do
      {model, device} = new_model([])
      offset = byte_size(raw(device))

      _model = Surface.put_debug_highlight(model, :status)
      hl_bytes = bytes_since(device, offset)

      assert rows_with_bg(hl_bytes, @bg_256) == [@region_top + 1]
    end
  end

  # ---------------------------------------------------------------------
  # nil highlight can never perturb bytes (the goldens guarantee)
  # ---------------------------------------------------------------------

  describe "nil highlight" do
    test "put_debug_highlight(model, nil) on an un-highlighted model emits zero bytes" do
      {model, device} = new_model([])
      offset = byte_size(raw(device))

      _model = Surface.put_debug_highlight(model, nil)

      assert bytes_since(device, offset) == ""
    end

    test "an unknown group is treated as clear (fail-safe), never a stray paint" do
      {model, device} = new_model([])
      model = Surface.put_debug_highlight(model, :composer)

      offset = byte_size(raw(device))
      model = Surface.put_debug_highlight(model, :no_such_group)

      refute String.contains?(bytes_since(device, offset), @bg_256)
      assert model.debug_highlight == nil
    end
  end

  # ---------------------------------------------------------------------
  # sealed history is never touched
  # ---------------------------------------------------------------------

  describe "seal-once honesty" do
    test "highlight bytes are confined to footer rows; sealed history is byte-untouched" do
      {model, device} = new_model(single_message_events("hello world"))
      model = drive_to_completion(model)

      history_before = history_text(device)
      assert history_before =~ "hello world"

      offset = byte_size(raw(device))
      model = Surface.put_debug_highlight(model, :composer)
      _model = Surface.put_debug_highlight(model, nil)
      bytes = bytes_since(device, offset)

      # Every ABSOLUTE cursor address in the highlight/clear cycle is a
      # footer row. (`SealOracle.cup_rows/2` is the wrong oracle for a
      # mid-stream fragment: the cycle's `\e7`/`\e8` park bracket restores
      # to a position saved before the fragment began, which the walk
      # can only model as its assumed row 1 -- a fragment artifact, not a
      # history write. The direct CUP scan below has no such blind spot,
      # and the emulator replay equality underneath is the full-stream
      # ground truth.)
      for [_, row] <- Regex.scan(~r/\e\[(\d+);\d+H/, bytes) do
        assert String.to_integer(row) > @region_top,
               "highlight cycle addressed history row #{row}"
      end

      assert history_text(device) == history_before
    end
  end

  # ---------------------------------------------------------------------
  # capability tiers
  # ---------------------------------------------------------------------

  describe "capability-aware bg tier" do
    test "truecolor terminals get the 24-bit pale blue" do
      caps = %Capabilities{truecolor: true, tier: :modern}
      {model, device} = new_model([], capabilities: caps)
      offset = byte_size(raw(device))

      _model = Surface.put_debug_highlight(model, :composer)
      bytes = bytes_since(device, offset)

      assert String.contains?(bytes, @bg_truecolor)
      refute String.contains?(bytes, @bg_256)
    end

    test "a probed non-truecolor terminal gets the 256-cube entry" do
      caps = %Capabilities{truecolor: false, tier: :modern}
      {model, device} = new_model([], capabilities: caps)
      offset = byte_size(raw(device))

      _model = Surface.put_debug_highlight(model, :composer)

      assert String.contains?(bytes_since(device, offset), @bg_256)
    end

    test "core_minus (no probe response) downgrades to ANSI blue bg -- category-preserving" do
      caps = %Capabilities{truecolor: false, tier: :core_minus}
      {model, device} = new_model([], capabilities: caps)
      offset = byte_size(raw(device))

      _model = Surface.put_debug_highlight(model, :composer)
      bytes = bytes_since(device, offset)

      assert String.contains?(bytes, @bg_ansi16)
      refute String.contains?(bytes, @bg_256)
      refute String.contains?(bytes, @bg_truecolor)
    end

    test "capabilities nil (the demo default) gets the 256-cube entry" do
      {model, device} = new_model([])
      offset = byte_size(raw(device))

      _model = Surface.put_debug_highlight(model, :composer)

      assert String.contains?(bytes_since(device, offset), @bg_256)
    end
  end

  # ---------------------------------------------------------------------
  # lifecycle: close_stream clears; flat mode is byte-free
  # ---------------------------------------------------------------------

  describe "lifecycle" do
    test "close_stream/1 clears an active highlight" do
      {model, device} = new_model([], stream_open: true)
      footer_before = footer_text(device)

      model = Surface.put_debug_highlight(model, :composer)
      model = Surface.close_stream(model)

      assert model.debug_highlight == nil
      assert footer_text(device) == footer_before
    end

    test ":flat mode has no footer -- highlight is a zero-byte no-op" do
      {:ok, device} = StringIO.open("")

      model =
        Surface.new([],
          device: device,
          width: @width,
          rows: @rows,
          footer_rows: @footer_rows,
          mode: :flat
        )

      offset = byte_size(raw(device))
      model = Surface.put_debug_highlight(model, :composer)
      _model = Surface.put_debug_highlight(model, nil)

      assert bytes_since(device, offset) == ""
    end
  end

  # ---------------------------------------------------------------------
  # ViewText bg vocabulary (the minimal style extension)
  # ---------------------------------------------------------------------

  describe "ViewText :bg style vocabulary" do
    test "styled mode emits 48;2 for hex, 48;5 for xterm256, 44 for ansi16 blue" do
      node = fn bg -> %{type: :text, content: "x", style: %{bg: bg}} end

      assert ViewText.lines(node.("#234660"), 10, :styled) ==
               ["\e[48;2;35;70;96mx\e[0m"]

      assert ViewText.lines(node.({:xterm256, 24}), 10, :styled) ==
               ["\e[48;5;24mx\e[0m"]

      assert ViewText.lines(node.({:ansi16, 4}), 10, :styled) ==
               ["\e[44mx\e[0m"]
    end

    test "plain mode never emits bg bytes" do
      node = %{type: :text, content: "x", style: %{bg: {:xterm256, 24}}}
      assert ViewText.lines(node, 10, :plain) == ["x"]
    end

    test "highlight_bg/3 pads to width and re-asserts bg after inner resets" do
      assert ViewText.highlight_bg("hi", {:xterm256, 24}, 5) ==
               "\e[48;5;24mhi   \e[0m"

      # An inner reset (a styled run ending) must not drop the bg for
      # the rest of the row -- the bg is re-asserted after every reset.
      assert ViewText.highlight_bg("\e[2mhi\e[0m", {:xterm256, 24}, 5) ==
               "\e[48;5;24m\e[2mhi\e[0m\e[48;5;24m   \e[0m"
    end

    test "highlight_bg/3 with a nil spec is the identity" do
      assert ViewText.highlight_bg("hi", nil, 5) == "hi"
    end
  end
end
