defmodule Raxol.Playground.Demos.ScrollAnchorDemo do
  @moduledoc """
  Playground demo: `Viewport`'s `overflow_anchor` follow-tail scrolling.

  A simulated log stream grows on a timer. `overflow_anchor: :auto` pins
  the viewport to the newest line whenever you're already at the bottom
  (a `tail -f`), and releases the pin the instant you scroll up to read
  history -- new lines no longer yank the view. `:none` freezes scroll
  position outright, regardless of how much new content arrives.
  """
  use Raxol.Core.Runtime.Application
  alias Raxol.UI.Components.Display.Viewport
  alias Raxol.View.Components

  @visible_height 12
  @seed_count 20
  @tick_interval_ms 400
  @sources ["api", "worker", "db", "cache", "auth"]
  @levels ["INFO", "WARN", "ERROR", "DEBUG"]

  @impl true
  def init(_context) do
    seed = Enum.map(1..@seed_count, &log_line/1)

    {:ok, vp} =
      Viewport.init(
        id: :scroll_anchor_log,
        children: seed,
        scroll_top: max(0, @seed_count - @visible_height),
        visible_height: @visible_height,
        show_scrollbar: true,
        overflow_anchor: :auto
      )

    %{viewport: vp, seq: @seed_count, paused: false}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("a") ->
        {toggle_anchor(model), []}

      key_match("p") ->
        {%{model | paused: not model.paused}, []}

      :tick ->
        {maybe_append(model), []}

      %Raxol.Core.Events.Event{type: :key} = event ->
        {new_vp, _cmds} = Viewport.handle_event(event, model.viewport, %{})
        {%{model | viewport: new_vp}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    vp = model.viewport

    pos =
      if vp.content_height > 0 do
        "#{vp.scroll_top + 1}-#{min(vp.scroll_top + vp.visible_height, vp.content_height)}/#{vp.content_height}"
      else
        "0/0"
      end

    pinned? = vp.scroll_top >= max(0, vp.content_height - vp.visible_height)

    pin_label =
      if pinned?, do: "pinned to tail", else: "released -- reading history"

    pin_color = if pinned?, do: :green, else: :yellow
    stream_label = if model.paused, do: "stream paused", else: "stream running"

    column style: %{gap: 1} do
      [
        text("Scroll Anchor Demo", style: [:bold]),
        divider(),
        box style: %{border: :single, width: 52} do
          Viewport.render(vp, %{})
        end,
        row style: %{gap: 2} do
          [
            text("Lines: #{vp.content_height}"),
            text("Visible: #{pos}"),
            text("anchor: #{vp.overflow_anchor}"),
            text(pin_label, fg: pin_color)
          ]
        end,
        text(stream_label, style: [:dim]),
        text(
          "[Up/Down/PgUp/PgDn/Home/End] scroll  [a] toggle anchor  [p] pause",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end

  defp toggle_anchor(model) do
    new_anchor =
      if model.viewport.overflow_anchor == :auto, do: :none, else: :auto

    %{model | viewport: %{model.viewport | overflow_anchor: new_anchor}}
  end

  defp maybe_append(%{paused: true} = model), do: model

  defp maybe_append(model) do
    seq = model.seq + 1
    children = model.viewport.children ++ [log_line(seq)]
    {new_vp, _cmds} = Viewport.update({:set_children, children}, model.viewport)
    %{model | viewport: new_vp, seq: seq}
  end

  defp log_line(seq) do
    level = Enum.at(@levels, rem(seq, length(@levels)))
    source = Enum.at(@sources, rem(seq * 7, length(@sources)))

    Components.text(
      content:
        "[#{format_seq(seq)}] #{level} #{source}: event ##{seq} processed",
      fg: level_color(level)
    )
  end

  defp format_seq(seq), do: String.pad_leading(Integer.to_string(seq), 4, "0")

  defp level_color("ERROR"), do: :red
  defp level_color("WARN"), do: :yellow
  defp level_color("DEBUG"), do: :magenta
  defp level_color(_), do: :white
end
