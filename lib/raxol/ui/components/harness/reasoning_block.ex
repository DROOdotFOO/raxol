defmodule Raxol.UI.Components.Harness.ReasoningBlock do
  @moduledoc """
  Renders reasoning/thinking content: `item_completed{item_type: :reasoning, content}`.

  Collapsed by default, showing a one-line summary plus a "N lines"
  affordance. `handle_event/3` toggles expand/collapse on Enter, Space,
  or `z` (today's transcript fold key, Keymap `char: "z" ->
  :fold_toggle`); a modified chord (ctrl/alt) never toggles. Styled dim
  throughout -- reasoning is secondary to the message and error blocks
  around it in the transcript. Note the sealed transcript's own register
  for a reasoning block is `Block.render/2`'s compact `∴ reasoning · N
  lines` line in BOTH fold states (see `BlockBody`); this component is
  the peekable body form that `BodyProvider` maps for the kind.

  ## Controlled hosting (harness TEA migration U1-a)

  The component stays CONTROLLED (migration doc §2 doctrine): `expanded`
  comes in as a prop and the hosting model is the authority. The local
  flip `handle_event/3` performs is a convenience for direct hosts (the
  playground-demo pattern of keeping the returned state); on the Bubbler
  path returned state is discarded by design, so the wired `:on_toggle`
  prop -- emitted as an outgoing message on every toggle key -- is the
  channel a TEA host folds.

  ## TreeWalker stamping + MCP toggle (F0-mcp seam)

  The rendered root carries `id`, `attrs` (`kind`, `expanded`, `lines`,
  and the `component_module` marker `Raxol.MCP.TreeWalker` resolves
  providers through), and `on_click: on_toggle`. The ToolProvider
  callbacks derive one `toggle` semantic action -- only when `on_toggle`
  is wired -- and execute it exactly like `Button`: a widget-targeted
  `%Event{type: :click}` bubbled at this node, so the MCP toggle and a
  physical click dispatch the same `:on_click` message.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @behaviour Raxol.MCP.ToolProvider

  @type t :: %{
          id: String.t() | atom(),
          content: String.t(),
          expanded: boolean(),
          width: pos_integer(),
          on_toggle: term() | nil,
          style: map(),
          theme: map()
        }

  @collapsed_icon "▸"
  @expanded_icon "▾"

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "harness-reasoning-block-#{:erlang.unique_integer([:positive])}"
        ),
      content: Keyword.get(props, :content, ""),
      expanded: Keyword.get(props, :expanded, false),
      width: Keyword.get(props, :width, Raxol.Core.Defaults.terminal_width()),
      on_toggle: Keyword.get(props, :on_toggle),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # Enter/Space -- toggle expand/collapse (mirrors Tree's activation
  # keys); z -- today's transcript fold key. Each flips the local state
  # for direct hosts AND emits the wired :on_toggle message for TEA hosts.
  @impl true
  def handle_event(%Event{type: :key, data: %{key: :enter}}, state, _context) do
    {toggle(state), toggle_commands(state)}
  end

  def handle_event(%Event{type: :key, data: %{key: :space}}, state, _context) do
    {toggle(state), toggle_commands(state)}
  end

  def handle_event(
        %Event{type: :key, data: %{key: :char, char: "z"} = data},
        state,
        _context
      ) do
    if modified?(data) do
      {state, []}
    else
      {toggle(state), toggle_commands(state)}
    end
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

    lines = content_lines(state.content)

    %{
      type: :column,
      id: state.id,
      attrs: %{
        kind: :reasoning,
        expanded: state.expanded,
        lines: length(lines),
        component_module: __MODULE__
      },
      on_click: state.on_toggle,
      style: base_style,
      gap: 0,
      children: body_children(state, lines)
    }
  end

  defp toggle(state), do: %{state | expanded: not state.expanded}

  defp modified?(data) do
    Map.get(data, :ctrl, false) == true or Map.get(data, :alt, false) == true
  end

  defp toggle_commands(%{on_toggle: nil}), do: []
  defp toggle_commands(%{on_toggle: message}), do: [message]

  defp content_lines(""), do: []
  defp content_lines(content), do: String.split(content, "\n")

  defp body_children(%{expanded: false} = state, lines) do
    [collapsed_summary(state, lines)]
  end

  defp body_children(%{expanded: true} = state, lines) do
    [expanded_header(state, lines) | expanded_lines(state, lines)]
  end

  defp collapsed_summary(%{id: id, width: width}, lines) do
    prefix = "#{@collapsed_icon} #{line_label(length(lines))} — "
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

  # -- ToolProvider callbacks (mirrors Button's) ---------------------------

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(%{on_click: handler}) when not is_nil(handler) do
    [
      %{
        name: "toggle",
        description: "Expand or collapse the reasoning block",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  def mcp_tools(_node), do: []

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("toggle", _args, context) do
    # Resolved by the Dispatcher through the Bubbler at this widget, so
    # the node's :on_click message dispatches exactly as for a real click.
    {:ok, "Toggled '#{context.widget_id}'",
     [%Event{type: :click, data: %{widget_id: context.widget_id}}]}
  end

  def handle_tool_call(action, _args, _context),
    do: {:error, "Unknown action: #{action}"}
end
