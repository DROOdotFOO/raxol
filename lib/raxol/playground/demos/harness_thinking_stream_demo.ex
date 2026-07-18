defmodule Raxol.Playground.Demos.HarnessThinkingStreamDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Harness.ShadowStream` — the live
  "thinking" render, in ALL its states (the point of the harness-chat-widgets
  split: track a widget *while* it works, not only when sealed).

  The reasoning streams in on a timer, so you see the shadow window shift
  live — the dominating primitive ("thinking") holding the faintest row
  while newer lines fade up toward it. `z` / `Enter` / `Space` (or a click)
  cycle the three states:

    * `:fully_collapsed` — `▸ thinking` only;
    * `:peek` — the shadow window (default, animated);
    * `:expanded` — `▾ thinking` + the full `∵ … ∴` bracket.

  The primitive is a parameter — swap "thinking" for "searching" / a
  translated word and the whole thing follows.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ShadowStream

  @tick_ms 220
  @width 60
  @newline_every 6

  @script ~w(User told me to refactor the failing suite so I should first
             locate the flaky test then isolate the shared state it leaks
             then add a regression that pins the row before I touch the fix
             carefully because the seam is subtle and the blast radius reaches
             three callers across the render path)

  @impl true
  def init(_context), do: %{buffer: "", idx: 0, count: 0, state: :peek}

  @impl true
  def update(:tick, model), do: {stream(model), []}

  def update(:cycle, model), do: {%{model | state: next_state(model.state)}, []}

  def update(%Event{type: :key, data: %{key: key}}, model)
      when key in [:enter, :space],
      do: {%{model | state: next_state(model.state)}, []}

  def update(%Event{type: :key, data: %{key: :char, char: "z"}}, model),
    do: {%{model | state: next_state(model.state)}, []}

  def update(_message, model), do: {model, []}

  # Reveal one script word per tick; break a line every @newline_every words;
  # restart the stream once exhausted so the demo loops live.
  defp stream(%{idx: idx} = model) when idx >= length(@script),
    do: %{model | buffer: "", idx: 0, count: 0}

  defp stream(model) do
    word = Enum.at(@script, model.idx)
    sep = separator(model.buffer, model.count)

    %{
      model
      | buffer: model.buffer <> sep <> word,
        idx: model.idx + 1,
        count: model.count + 1
    }
  end

  defp separator("", _count), do: ""
  defp separator(_buffer, count) when rem(count, @newline_every) == 0, do: "\n"
  defp separator(_buffer, _count), do: " "

  defp next_state(:fully_collapsed), do: :peek
  defp next_state(:peek), do: :expanded
  defp next_state(:expanded), do: :fully_collapsed

  @impl true
  def view(model) do
    column style: %{gap: 1} do
      [
        text("Harness Thinking Stream — live shadow-cast reasoning",
          style: [:bold]
        ),
        divider(),
        ShadowStream.render(%{
          primitive: "thinking",
          lines: model.buffer,
          state: model.state,
          width: @width,
          id: "thinking",
          on_click: :cycle
        }),
        divider(),
        text(
          "state: #{model.state}   ·   [z] / [enter] / [space] / click → " <>
            "cycle  (fully_collapsed → peek → expanded)",
          id: "state_hint",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_ms, :tick)]
end
