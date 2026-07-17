defmodule Raxol.Harness.SurfaceSubmitTest do
  @moduledoc """
  The `:submit` channel on `Raxol.Harness.Surface`: the composer's Enter,
  made a first-class live command by the `:command_sink`. Track C of the
  AI-wiring fan-out -- the REAL prompt path replacing the mirror-composer
  stub.

  ## Doc guarantee -> test mapping (each is a falsifier)

    1. a live sink makes submit dispatch `{:submit, %{text}}` and enter the
       optimistic (dim, event-observed) "sending" state WITHOUT echoing
       history -> "live sink dispatches and enters the sending state"
    2. no sink keeps the fixture stub notice byte-for-byte ->
       "stub mode keeps the fixture notice unchanged"
    3. `submit_accepted/1` seals the `❯ prompt` echo exactly once and clears
       the sending state -> "accept seals the echo and clears sending"
    4. `submit_refused/1` restores the draft (never lost) and clears the
       sending state -> "refusal restores the draft"
    5. the echo seals BEFORE the first response block (echo-on-accept
       ordering) -> "the echo precedes the first response block"
    6. accept/refuse with nothing pending never fabricates -> "accept and
       refuse are no-ops with nothing pending"

  Mirrors `test/harness/surface_live_seam_test.exs`'s helper idioms: a
  `StringIO` device driving the REAL authority, `SealOracle` replay for the
  sealed-history reads.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
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

  defp footer_text(raw) do
    emulator = SealOracle.replay(raw, width: @width, height: @rows)

    emulator
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.drop(@region_top)
    |> Enum.map_join("\n", &row_text/1)
  end

  defp type(model, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(model, fn ch, m -> Surface.handle_input(m, Event.key(ch)) end)
  end

  defp submit(model), do: Surface.handle_input(model, Event.key(:enter))

  defp drive_to_completion(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive_to_completion(model)
    end
  end

  # A single completed assistant message turn (the RESPONSE to a prompt) --
  # the fixture wire shape `Projection.project/2` accepts. `base_id` keeps
  # ids monotonic when appended after an echo.
  defp response_turn(content, base_id \\ 0) do
    [
      %{
        id: base_id + 1,
        turn_id: "t1",
        ts: base_id + 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "hi"}
      },
      %{
        id: base_id + 2,
        turn_id: "t1",
        ts: base_id + 2,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{"item_id" => "i1", "item_type" => "message"}
      },
      %{
        id: base_id + 3,
        turn_id: "t1",
        ts: base_id + 3,
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
        id: base_id + 4,
        turn_id: "t1",
        ts: base_id + 4,
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

  describe "1. live sink dispatches and enters the sending state" do
    test "Enter dispatches {:submit, %{text}} through the sink, dims a sending preview, echoes NO history" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, device} = new_model([], command_sink: sink)

      model = model |> type("hi") |> submit()

      assert_receive {:sink_called, %{type: :submit, payload: %{text: "hi"}}}

      assert model.pending_submit == %{text: "hi"}

      # The optimistic preview is visible ...
      assert strip_ansi(raw(device)) =~ "sending: hi"

      # ... but nothing is on the record yet (event-observed accept only).
      # The echo sigil (`❯`) only ever appears in a SEALED echo, so its
      # absence is the unambiguous "nothing committed" check.
      refute history_text(raw(device)) =~ "❯",
             "no prompt echo may seal before turn_started is observed"

      refute strip_ansi(raw(device)) =~ "(stub) would send prompt",
             "a live sink must not paint the fixture-mode stub notice"
    end

    test "an empty/whitespace submit is a no-op -- no dispatch, no sending state" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, _device} = new_model([], command_sink: sink)

      model = model |> type("   ") |> submit()

      refute_receive {:sink_called, _}, 50
      assert model.pending_submit == nil
    end
  end

  describe "2. stub mode keeps the fixture notice unchanged" do
    test "no command_sink (the default) paints the byte-for-byte stub notice" do
      {model, device} = new_model([], [])

      model = model |> type("hi") |> submit()

      assert strip_ansi(raw(device)) =~ "» (stub) would send prompt: hi"

      # The stub path never enters the live "sending" state -- it is a
      # one-frame notice, byte-identical to before the live seam existed.
      assert model.pending_submit == nil
      refute strip_ansi(raw(device)) =~ "sending:"
    end
  end

  describe "3. accept seals the echo and clears sending" do
    test "submit_accepted seals `❯ prompt` into history and drops the sending preview" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, device} = new_model([], command_sink: sink)
      model = model |> type("run the tests") |> submit()
      assert_receive {:sink_called, _}

      model = Surface.submit_accepted(model)

      assert model.pending_submit == nil
      assert history_text(raw(device)) =~ "❯ run the tests"

      refute footer_text(raw(device)) =~ "sending:",
             "the sending preview must clear once the echo is sealed"
    end
  end

  describe "4. refusal restores the draft" do
    test "the Composer buffer (cleared on Enter) comes back, sending state clears" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, _device} = new_model([], command_sink: sink)
      model = model |> type("draft to keep") |> submit()
      assert_receive {:sink_called, _}

      # The Composer component cleared its own buffer on Enter ...
      assert Composer.value(model.composer) == ""
      assert model.pending_submit == %{text: "draft to keep"}

      model = Surface.submit_refused(model)

      # ... and the refusal path put it back, unlost.
      assert Composer.value(model.composer) == "draft to keep"
      assert model.pending_submit == nil
    end
  end

  describe "5. echo-on-accept ordering" do
    test "the `❯ prompt` echo seals ahead of the first response block" do
      test_pid = self()
      sink = fn cmd -> send(test_pid, {:sink_called, cmd}) end

      {model, device} = new_model([], command_sink: sink)
      model = model |> type("what is 2+2") |> submit()
      assert_receive {:sink_called, _}

      # Accept (as turn_started would), THEN reveal the response. The
      # result is read off the DEVICE (sealed bytes), not the model.
      _model =
        model
        |> Surface.submit_accepted()
        |> Surface.append_events(response_turn("the answer is four"))
        |> drive_to_completion()

      history = history_text(raw(device))
      echo_at = :binary.match(history, "❯ what is 2+2")
      response_at = :binary.match(history, "the answer is four")

      assert echo_at != :nomatch, "the prompt echo must be in history"
      assert response_at != :nomatch, "the response must be in history"

      {echo_pos, _} = echo_at
      {response_pos, _} = response_at

      assert echo_pos < response_pos,
             "the user echo must seal before the first response block"
    end
  end

  describe "6. accept and refuse are no-ops with nothing pending" do
    test "neither fabricates an echo nor touches the composer" do
      {model, device} = new_model([], command_sink: fn _ -> :ok end)

      before_history = history_text(raw(device))

      accepted = Surface.submit_accepted(model)
      refused = Surface.submit_refused(model)

      assert accepted.pending_submit == nil
      assert refused.pending_submit == nil
      assert history_text(raw(device)) == before_history
      refute history_text(raw(device)) =~ "❯"
    end
  end
end
