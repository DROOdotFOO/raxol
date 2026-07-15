defmodule Raxol.UI.Components.Harness.MessageBlock do
  @moduledoc """
  Renders a completed transcript message: `item_completed{item_type: :message, content}`.

  `content` is a Markdown string. Rendering the Markdown itself is delegated
  entirely to `Raxol.UI.Components.MarkdownRenderer` -- this module only adds
  a dim, accent-colored role prefix (`role: :user | :assistant`) above it so
  turns are visually distinguishable without shouting.
  """

  alias Raxol.UI.Components.MarkdownRenderer
  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type role :: :user | :assistant

  @type t :: %{
          id: String.t() | atom(),
          role: role(),
          content: String.t(),
          width: pos_integer(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "harness-message-block-#{:erlang.unique_integer([:positive])}"
        ),
      role: Keyword.get(props, :role, :assistant),
      content: Keyword.get(props, :content, ""),
      width: Keyword.get(props, :width, Raxol.Core.Defaults.terminal_width()),
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
      StyleHelper.merge_component_styles(state, context, :harness_message_block)

    {:ok, md_state} =
      MarkdownRenderer.init(%{markdown_text: state.content, width: state.width})

    %{
      type: :column,
      style: base_style,
      gap: 0,
      children: [role_header(state), MarkdownRenderer.render(md_state, context)]
    }
  end

  defp role_header(%{id: id, role: role}) do
    Components.text(
      id: "#{id}-role",
      content: "[#{role}]",
      style: %{dim: true, fg: role_accent(role)}
    )
  end

  defp role_accent(:user), do: :green
  defp role_accent(:assistant), do: :cyan
  defp role_accent(_), do: :white
end
