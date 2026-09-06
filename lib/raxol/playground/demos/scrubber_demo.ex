defmodule Raxol.Playground.Demos.ScrubberDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.Scrubber` seeking a recorded
  timeline.

  The pane under the transport is addressed by the playhead, so a seek is
  visible rather than merely reported: scrubbing moves the wave, and the
  frame counter and clock agree with it.

  Keys route through `Scrubber.handle_event/3`, so the widget owns its
  bindings. The demo also handles the `{:scrubber_seek | :scrubber_play |
  :scrubber_pause, id, ...}` messages the MCP tools dispatch, which is what
  makes `replay.seek` from an agent move this playhead.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Input.Scrubber

  @frames 48
  @tick_ms 120
  # Marks stand in for an asciicast's `:input` events -- the moments a human
  # typed, which are the ones worth jumping between.
  @marks [0, 11, 27, 40]
  @track_width 40
  @pane_rows 3
  @ramp [" ", "░", "▒", "▓", "█"]

  @impl true
  def init(_context) do
    # snippet:start
    {:ok, scrubber} =
      Scrubber.init(
        id: "replay",
        min: 0,
        max: @frames - 1,
        position: 0,
        marks: @marks,
        width: @track_width,
        playing?: true,
        speed: 1.0,
        elapsed_ms: 0,
        duration_ms: @frames * @tick_ms
      )

    # snippet:end

    %{scrubber: scrubber}
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        {advance(model), []}

      %Raxol.Core.Events.Event{type: :key} = event ->
        {scrubber, _commands} =
          Scrubber.handle_event(event, model.scrubber, %{})

        {%{model | scrubber: sync_clock(scrubber)}, []}

      {:scrubber_seek, _id, position} ->
        {put_scrubber(model, Scrubber.seek(model.scrubber, position)), []}

      {:scrubber_play, _id} ->
        {put_scrubber(model, %{model.scrubber | playing?: true}), []}

      {:scrubber_pause, _id} ->
        {put_scrubber(model, %{model.scrubber | playing?: false}), []}

      _other ->
        {model, []}
    end
  end

  # Playback wraps rather than stopping at the end: a looping preview shows
  # the whole timeline, and a transport parked on the last frame reads as a
  # hung demo.
  defp advance(%{scrubber: %{playing?: false}} = model), do: model

  defp advance(%{scrubber: scrubber} = model) do
    next =
      case scrubber.position + 1 do
        past when past > scrubber.max -> scrubber.min
        position -> position
      end

    put_scrubber(model, Scrubber.seek(scrubber, next))
  end

  defp put_scrubber(model, scrubber),
    do: %{model | scrubber: sync_clock(scrubber)}

  # This timeline IS uniform-tick, so the clock is derivable from the index.
  # `Scrubber` does not derive it for you, because an asciicast's index-to-time
  # map is not linear.
  defp sync_clock(scrubber),
    do: %{scrubber | elapsed_ms: (scrubber.position - scrubber.min) * @tick_ms}

  @impl true
  def view(model) do
    s = model.scrubber

    column style: %{gap: 0} do
      [
        text("Scrubber: Raxol.UI.Components.Input.Scrubber", style: [:bold]),
        text(" one transport for recordings, snapshots, and web frames",
          style: [:dim]
        ),
        text(""),
        Scrubber.to_node(s),
        text(""),
        column style: %{gap: 0} do
          pane_rows(s.position)
        end,
        text(""),
        row style: %{gap: 2} do
          [
            text("Frame: #{s.position}/#{s.max}"),
            text("Marks: #{Enum.join(s.marks, " ")}"),
            text("Speed: #{s.speed}x")
          ]
        end,
        text(" [space] play  [<>] step  [0-9] seek  [[ ]] mark  [+-] speed",
          style: [:dim]
        )
      ]
    end
  end

  # A standing wave whose phase is the playhead. Pure in `position`, so the
  # frame generator's folded ticks produce the same pixels every run.
  defp pane_rows(position) do
    Enum.map(0..(@pane_rows - 1), fn row ->
      line =
        Enum.map_join(0..(@track_width - 1), fn col ->
          phase = (col + position * 2) / 5.0 + row * 0.9
          level = round((:math.sin(phase) + 1) / 2 * (length(@ramp) - 1))
          Enum.at(@ramp, level)
        end)

      text(" " <> line)
    end)
  end

  @impl true
  def subscribe(%{scrubber: %{playing?: true}}),
    do: [subscribe_interval(@tick_ms, :tick)]

  def subscribe(_model), do: []
end
