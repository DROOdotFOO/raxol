defmodule Raxol.Harness.GreetingTest do
  @moduledoc """
  Byte-level pins for the boot greeting (V's ruling): the default boot
  frame carries one centered, dim `welcome back, operator` line in the
  unclaimed history span -- an ephemeral region element, NEVER sealed:

    * painted at the vertical center of the unclaimed span, horizontally
      centered, dim, through the normal role/SGR path;
    * erased with targeted EL on its rows BEFORE the first sealed
      content's bytes, in the same frame;
    * never present in sealed history (print-once untouched: no sealed
      byte is ever rewritten -- the greeting was never sealed at all);
    * absent in `:flat` mode (no positioning exists there);
    * OFF by default (`greeting: true` is the demos' opt-in), so every
      byte-golden embedder is untouched.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.TextMeasure

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  @text "welcome back, operator"

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

  defp screen_rows(device) do
    device
    |> raw()
    |> SealOracle.replay(width: @width, height: @rows)
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.map(fn row ->
      row |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
    end)
  end

  defp turn_events do
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
          "content" => "Hello!"
        }
      },
      %{
        id: 4,
        turn_id: "t1",
        ts: 4,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{"status" => "ok"}
      }
    ]
  end

  # Pinned boot at this geometry: unclaimed span is rows 1..@region_top
  # (next_row 1, history bottom 14). The intro line sits at the BOTTOM
  # of the span, one blank row above the footer (V mock: transcript
  # position, directly above the chevron) -- row 13 -- at column 2
  # (after the 1-column transcript margin, never centered).
  @greeting_row @region_top - 1
  @greeting_col 2

  describe "painted as an in-flow intro line above the chevron" do
    test "the greeting lands at the transcript position, dim, via one positioned write" do
      {_model, device} = new_model([], greeting: true)
      bytes = raw(device)

      assert bytes =~ "\e[#{@greeting_row};#{@greeting_col}H"
      assert bytes =~ @text
      # dim channel through the normal SGR path
      assert bytes =~ "\e[2m#{@text}\e[0m"

      # And on the replayed screen it sits exactly there -- margined
      # like transcript content, with a blank row between it and the
      # footer (the chevron row).
      rows = screen_rows(device)
      row_text = Enum.at(rows, @greeting_row - 1)
      assert row_text =~ @text

      col = :binary.match(row_text, @text) |> elem(0) |> Kernel.+(1)
      assert col == @greeting_col

      assert Enum.at(rows, @region_top - 1) == "",
             "one blank row must sit between the intro line and the footer"
    end

    test "the text itself is width-honest (22 single-width columns)" do
      assert TextMeasure.display_width(@text) == 22
    end

    test "OFF by default: no greeting bytes without the opt-in" do
      {_model, device} = new_model([])
      refute raw(device) =~ "welcome back"
    end

    test "flat mode never paints it (no positioning exists there)" do
      {_model, device} = new_model([], greeting: true, mode: :flat)
      refute raw(device) =~ "welcome back"
    end
  end

  describe "erased at the first seal, never sealed" do
    test "targeted EL on the greeting row precedes the first sealed row's bytes" do
      {model, device} = new_model(turn_events(), greeting: true)
      _model = drive_to_completion(model)

      bytes = raw(device)

      erase_at = :binary.match(bytes, "\e[#{@greeting_row};1H\e[K")

      # The first SEALED write is the authority's CUP to history row 1
      # (the footer PREVIEW legitimately shows block text earlier --
      # that is repaintable footer, not sealed content, and the
      # greeting may coexist with it).
      first_seal_at = :binary.match(bytes, "\e[1;1H")

      assert erase_at != :nomatch, "no targeted EL on the greeting row"
      assert first_seal_at != :nomatch

      assert elem(erase_at, 0) < elem(first_seal_at, 0),
             "the greeting erase must precede the first sealed content"
    end

    test "gone from the final screen and absent from sealed history + scrollback" do
      {model, device} = new_model(turn_events(), greeting: true)
      _model = drive_to_completion(model)

      refute Enum.any?(screen_rows(device), &String.contains?(&1, @text))

      emulator = SealOracle.replay(raw(device), width: @width, height: @rows)

      history_text =
        emulator
        |> SealOracle.history(@region_top)
        |> Enum.map_join("\n", fn row ->
          row |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
        end)

      refute history_text =~ @text
    end

    test "an embedder-sealed marker (the --debug POST path) erases it too" do
      {model, device} = new_model([], greeting: true)
      _model = Surface.seal_marker(model, "raxol harness self-check")

      bytes = raw(device)
      erase_at = :binary.match(bytes, "\e[#{@greeting_row};1H\e[K")
      marker_at = :binary.match(bytes, "self-check")

      assert erase_at != :nomatch
      assert elem(erase_at, 0) < elem(marker_at, 0)
      refute Enum.any?(screen_rows(device), &String.contains?(&1, @text))
    end
  end
end
