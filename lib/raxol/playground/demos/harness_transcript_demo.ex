defmodule Raxol.Playground.Demos.HarnessTranscriptDemo do
  @moduledoc """
  Playground demo: an agent-harness transcript rendered from real protocol
  event payloads -- a completed message, collapsible reasoning, and a fault.

  Exercises `Raxol.UI.Components.Harness.{MessageBlock, ReasoningBlock,
  ErrorBlock}` directly. Only `ReasoningBlock` carries interactive state (its
  own `expanded` flag), toggled through its real `handle_event/3` -- mirrors
  how `ScrollAnchorDemo` forwards raw key events into `Viewport`.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.{ErrorBlock, MessageBlock, ReasoningBlock}

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_content_width 46
  @border_and_padding_overhead 4

  @impl true
  def init(_context) do
    {:ok, reasoning} =
      ReasoningBlock.init(id: :demo_reasoning, content: reasoning_sample())

    %{reasoning: reasoning}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key} = event ->
        {new_reasoning, _cmds} =
          ReasoningBlock.handle_event(event, model.reasoning, %{})

        {%{model | reasoning: new_reasoning}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    box_width = effective_width(model, @default_content_width)
    content_width = max(box_width - @border_and_padding_overhead, 1)

    {:ok, message_state} =
      MessageBlock.init(
        id: :demo_message,
        role: :assistant,
        content: message_sample(),
        width: content_width
      )

    {:ok, error_state} =
      ErrorBlock.init(
        id: :demo_error,
        where: "tool_call:fetch_page",
        reason: "connection refused (ECONNREFUSED)"
      )

    reasoning_for_render = %{model.reasoning | width: content_width}

    column style: %{gap: 1} do
      [
        text("Harness Transcript Demo", style: [:bold]),
        divider(),
        # snippet:start
        box style: %{border: :single, padding: 1, width: box_width} do
          column style: %{gap: 1} do
            [
              MessageBlock.render(message_state, %{}),
              ReasoningBlock.render(reasoning_for_render, %{}),
              ErrorBlock.render(error_state, %{})
            ]
          end
        end,
        # snippet:end
        text("[Enter] or [Space] toggles the reasoning block", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp message_sample do
    "Here's the plan:\n\n" <>
      "- Check the **config** file\n" <>
      "- Run `mix test`\n" <>
      "- Report back\n\n" <>
      "Should be quick."
  end

  defp reasoning_sample do
    "The user wants a summary of the failing tests.\n" <>
      "First, check which files changed since the last green run.\n" <>
      "Then re-run just those to confirm they're still red.\n" <>
      "Finally, group failures by root cause before reporting back."
  end
end
