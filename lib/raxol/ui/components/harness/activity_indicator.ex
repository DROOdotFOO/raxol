defmodule Raxol.UI.Components.Harness.ActivityIndicator do
  @moduledoc """
  Working / idle / hung indicator for one harness turn.

  `since_ms` is the elapsed time, in milliseconds, that the turn has spent in
  its *current* `state` -- not a wall-clock timestamp. That keeps `render/2` a
  pure function of props (no `System.monotonic_time/1` inside render, so the
  component stays trivially testable); the caller's own tick/subscription
  loop accumulates it, the same way `Raxol.Playground.Demos.StatusBarDemo`
  accumulates `model.tick`.

  When `state: :working` has run longer than `hung_threshold_ms`, the
  indicator flips itself to the hung display even though the caller still
  claims `:working` -- that override is the point: it catches the agent that
  died but still *looks* like it is working.
  """

  alias Raxol.UI.Components.Progress.Spinner
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type activity_state :: :working | :idle | :hung

  @type t :: %{
          id: String.t() | atom(),
          state: activity_state(),
          since_ms: number(),
          frame: non_neg_integer(),
          hung_threshold_ms: pos_integer(),
          style: map(),
          theme: map()
        }

  @default_hung_threshold_ms 10_000

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "activity-indicator-#{:erlang.unique_integer([:positive])}"
        ),
      state: Keyword.get(props, :state, :idle),
      since_ms: Keyword.get(props, :since_ms, 0),
      frame: Keyword.get(props, :frame, 0),
      hung_threshold_ms:
        Keyword.get(props, :hung_threshold_ms, @default_hung_threshold_ms),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :activity_indicator)

    spec = display_spec(effective_state(state), state)

    %{
      type: :row,
      style: base_style,
      children: [
        Raxol.View.Components.text(
          id: "#{state.id}-indicator",
          content: spec.content,
          fg: spec.fg,
          style: spec.style
        )
      ]
    }
  end

  defp effective_state(%{
         state: :working,
         since_ms: ms,
         hung_threshold_ms: threshold
       })
       when ms >= threshold,
       do: :hung

  defp effective_state(%{state: activity_state}), do: activity_state

  defp display_spec(:working, state) do
    %{
      content: Spinner.spinner("working", state.frame, type: :dots),
      fg: :cyan,
      style: %{}
    }
  end

  defp display_spec(:idle, _state) do
    %{content: "• idle", fg: nil, style: %{dim: true}}
  end

  defp display_spec(:hung, state) do
    %{
      content: "HUNG? (#{elapsed_seconds(state.since_ms)}s)",
      fg: :red,
      style: %{bold: true}
    }
  end

  defp elapsed_seconds(ms) when is_number(ms), do: trunc(ms / 1000)
end
