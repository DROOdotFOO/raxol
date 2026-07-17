defmodule Raxol.Harness.SurfaceLiveSeamTest do
  @moduledoc """
  The live-session seam additions to `Raxol.Harness.Surface`: a
  `:command_sink` that makes `:interrupt`/`:steer` LIVE instead of the
  fixture-mode stubs, `append_events/2` (the same reveal path as fixture
  events), `put_lane_notice/2` (a persistent footer line), `seal_marker/2`
  (an honest loss-notice sealed into history), and `put_stall_verdict/2`
  (the status strip's `:stall_verdict` seam).

  Mirrors `test/harness/t13a_surface_test.exs`'s own helper idioms: a
  `StringIO` device driving the REAL `InlineAuthority`, and the
  `Raxol.Harness.Test.SealOracle` byte-replay oracles for the
  seal-once/immutable-prefix invariants.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.Test.CrossTerminal.SequenceScanner

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp new_model(events, opts) do
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

  defp strip_ansi(raw) when is_binary(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("", fn {:text, text} -> text end)
  end

  defp history_at(raw) do
    emulator = SealOracle.replay(raw, width: @width, height: @rows)
    SealOracle.history(emulator, @region_top)
  end

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  defp history_text(raw),
    do: raw |> history_at() |> Enum.map_join("\n", &row_text/1)

  # The CURRENT (not cumulative) footer state: replays the whole byte
  # stream through the real emulator and reads its live screen buffer's
  # footer rows. Needed for "present, then cleared" assertions within one
  # test -- `strip_ansi/1` over the raw stream is cumulative (every byte
  # ever written, including a row's PRIOR content before it was
  # overwritten), so it can only prove presence, never absence.
  defp footer_text(raw) do
    emulator = SealOracle.replay(raw, width: @width, height: @rows)

    emulator
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.drop(@region_top)
    |> Enum.map_join("\n", &row_text/1)
  end

  # A single-turn, single-message event list -- the fixture wire shape
  # (atom top-level fields, string-keyed payload) `Projection.project/2`
  # accepts directly, matching `t13a_surface_test.exs`'s own `bulk_events/1`
  # convention.
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
  # command_sink: interrupt
  # ---------------------------------------------------------------------

  describe "command_sink makes :interrupt live" do
    test "ESC dispatches to the sink instead of the fixture-mode stub, and paints no stub notice" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, device} = new_model([], command_sink: sink)

      _model = Surface.handle_input(model, Event.key(:escape))

      assert_receive {:sink_called, %{type: :interrupt, payload: %{}}}

      refute strip_ansi(raw(device)) =~ "interrupt requested (stub",
             "a live command_sink must not paint the fixture-mode stub notice"
    end

    test "nil command_sink (the default) keeps the fixture-mode stub untouched" do
      {model, device} = new_model([], [])

      _model = Surface.handle_input(model, Event.key(:escape))

      assert strip_ansi(raw(device)) =~ "interrupt requested (stub"
    end
  end

  # ---------------------------------------------------------------------
  # command_sink: steer
  # ---------------------------------------------------------------------

  describe "command_sink makes :steer live" do
    test "Tab queues the real banner AND dispatches to the sink with the composer's text" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, device} = new_model([], command_sink: sink)

      model =
        Enum.reduce(["h", "i"], model, fn ch, m ->
          Surface.handle_input(m, Event.key(ch))
        end)

      _model = Surface.handle_input(model, Event.key(:tab))

      assert_receive {:sink_called, %{type: :steer, payload: %{text: "hi"}}}

      assert strip_ansi(raw(device)) =~ "steer queued for next boundary",
             "a live command_sink must still queue the real composer banner"
    end

    test "an open overlay freezes steer -- the sink is never called" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, _device} = new_model([], command_sink: sink)
      {:ok, model} = Surface.open_overlay(model, ["a", "b"])

      _model = Surface.handle_input(model, Event.key(:tab))

      refute_receive {:sink_called, _}, 50
    end
  end

  # ---------------------------------------------------------------------
  # append_events/2
  # ---------------------------------------------------------------------

  describe "append_events/2" do
    test "appending events then advancing seals the same bytes as constructing with them up front" do
      events = single_message_events("hello from append")

      {model_a, device_a} = new_model(events, [])
      model_a = drive_to_completion(model_a)

      {model_b, device_b} = new_model([], [])
      model_b = Surface.append_events(model_b, events)
      model_b = drive_to_completion(model_b)

      assert model_a.painted_count == model_b.painted_count
      assert raw(device_a) == raw(device_b)
    end

    test "a non-map element raises ArgumentError" do
      {model, _device} = new_model([], [])

      assert_raise ArgumentError, fn ->
        Surface.append_events(model, ["not a map"])
      end
    end
  end

  # ---------------------------------------------------------------------
  # put_lane_notice/2
  # ---------------------------------------------------------------------

  describe "put_lane_notice/2" do
    test "persists across further paint-causing calls and clears on nil" do
      {model, device} = new_model([], [])

      model = Surface.put_lane_notice(model, "» reconnecting to live session")
      assert strip_ansi(raw(device)) =~ "reconnecting to live session"

      # A further, unrelated paint-causing call (a keystroke) must NOT
      # consume the lane notice the way `stub_notice` is consumed.
      model = Surface.handle_input(model, Event.key("x"))
      assert strip_ansi(raw(device)) =~ "reconnecting to live session"

      model = Surface.tick(model, 42)
      assert strip_ansi(raw(device)) =~ "reconnecting to live session"

      _model = Surface.put_lane_notice(model, nil)

      refute footer_text(raw(device)) =~ "reconnecting to live session",
             "the CURRENT footer frame must no longer show the cleared notice"
    end

    test "accepts a list of lines, each rendered" do
      {model, device} = new_model([], [])

      _model = Surface.put_lane_notice(model, ["» line one", "» line two"])

      plain = strip_ansi(raw(device))
      assert plain =~ "line one"
      assert plain =~ "line two"
    end
  end

  # ---------------------------------------------------------------------
  # seal_marker/2
  # ---------------------------------------------------------------------

  describe "seal_marker/2" do
    test "seals a marker line into history exactly once; later seals never touch it" do
      events = single_message_events("second block content")
      {model, device} = new_model(events, [])

      model = Surface.seal_marker(model, "note: 3 deltas shed")
      raw_after_marker = raw(device)
      history_after_marker = history_at(raw_after_marker)

      assert history_text(raw_after_marker) =~ "note: 3 deltas shed"

      assert model.painted_count == 0,
             "a marker is not a block -- painted_count must not advance"

      model = drive_to_completion(model)
      raw_final = raw(device)

      assert :ok ==
               SealOracle.immutable_prefix?(
                 history_after_marker,
                 history_at(raw_final)
               ),
             "sealing further blocks must never rewrite the earlier marker line"

      assert history_text(raw_final) =~ "note: 3 deltas shed"
      assert history_text(raw_final) =~ "second block content"

      # Further footer-only churn must not touch the marker either.
      _model = Surface.handle_input(model, Event.key("j"))

      assert :ok ==
               SealOracle.immutable_prefix?(
                 history_at(raw_final),
                 history_at(raw(device))
               )
    end
  end

  # ---------------------------------------------------------------------
  # put_stall_verdict/2
  # ---------------------------------------------------------------------

  describe "put_stall_verdict/2" do
    test "renders the status strip's ALERT segment; clears on nil" do
      {model, device} = new_model([], [])

      verdict = %{class: :stalled, evidence: %{summary: "tool loop detected"}}
      model = Surface.put_stall_verdict(model, verdict)

      assert strip_ansi(raw(device)) =~ "ALERT: tool loop detected"

      _model = Surface.put_stall_verdict(model, nil)

      refute footer_text(raw(device)) =~ "ALERT:",
             "the CURRENT footer frame must no longer show the cleared alert"
    end
  end
end
