defmodule Raxol.UI.Components.Harness.ReasoningBlock do
  @moduledoc """
  Renders reasoning/thinking content: `item_completed{item_type: :reasoning, content}`.

  Collapsed by default, showing a one-line summary plus a "N lines"
  affordance. `handle_event/3` toggles expand/collapse on Enter or Space.
  Styled dim throughout -- reasoning is secondary to the message and error
  blocks around it in the transcript.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          content: String.t(),
          expanded: boolean(),
          width: pos_integer(),
          style: map(),
          theme: map()
        }

  @collapsed_icon "▸"
  @expanded_icon "▾"

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "harness-reasoning-block"),
      content: Keyword.get(props, :content, ""),
      expanded: Keyword.get(props, :expanded, false),
      width: Keyword.get(props, :width, Raxol.Core.Defaults.terminal_width()),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # Enter/Space -- toggle expand/collapse (mirrors Tree's activation keys).
  @impl true
  def handle_event(%Event{type: :key, data: %{key: :enter}}, state, _context) do
    {toggle(state), []}
  end

  def handle_event(%Event{type: :key, data: %{key: :space}}, state, _context) do
    {toggle(state), []}
  end

  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(
        state,
        context,
        :harness_reasoning_block
      )

    %{
      type: :column,
      style: base_style,
      gap: 0,
      children: body_children(state, content_lines(state.content))
    }
  end

  defp toggle(state), do: %{state | expanded: not state.expanded}

  defp content_lines(""), do: []
  defp content_lines(content), do: String.split(content, "\n")

  defp body_children(%{expanded: false} = state, lines) do
    [collapsed_summary(state, lines)]
  end

  defp body_children(%{expanded: true} = state, lines) do
    [expanded_header(state, lines) | expanded_lines(state, lines)]
  end

  defp collapsed_summary(%{id: id, width: width}, lines) do
    prefix = "#{@collapsed_icon} #{line_label(length(lines))}: "
    budget = max(width - TextMeasure.display_width(prefix), 1)

    dim_text(id, "summary", prefix <> summary_text(lines, budget))
  end

  defp expanded_header(%{id: id}, lines) do
    dim_text(id, "summary", "#{@expanded_icon} #{line_label(length(lines))}")
  end

  defp expanded_lines(%{id: id}, lines) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} -> dim_text(id, "line-#{idx}", line) end)
  end

  defp summary_text([], _budget), do: "(empty)"

  defp summary_text(lines, budget) do
    lines
    |> Enum.find("", &(String.trim(&1) != ""))
    |> TextLayout.truncate(budget, :ellipsis)
  end

  defp line_label(1), do: "1 line"
  defp line_label(n), do: "#{n} lines"

  defp dim_text(id, suffix, content) do
    Components.text(
      id: "#{id}-#{suffix}",
      content: content,
      style: %{dim: true}
    )
  end
end
