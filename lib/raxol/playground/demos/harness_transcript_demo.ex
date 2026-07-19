defmodule Raxol.Playground.Demos.HarnessTranscriptDemo do
  @moduledoc """
  Playground demo: an agent-harness transcript message rendered from a real
  protocol event payload -- a completed assistant message with Markdown
  inline structure.

  Exercises `Raxol.UI.Components.Harness.MessageBlock` directly: `init/1`
  with a role + content + width, then `render/2` -- the same controlled
  mount the live transcript's `BodyProvider` seam performs for `:message`
  blocks.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.MessageBlock

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_content_width 46
  @border_and_padding_overhead 4

  @impl true
  def init(_context), do: %{}

  @impl true
  def update(_message, model), do: {model, []}

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

    column style: %{gap: 1} do
      [
        text("Harness Transcript Demo", style: [:bold]),
        divider(),
        box style: %{border: :single, padding: 1, width: box_width} do
          column style: %{gap: 1} do
            [MessageBlock.render(message_state, %{})]
          end
        end,
        text("a completed assistant message, bare prose (no tagline)",
          style: [:dim]
        )
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
end
