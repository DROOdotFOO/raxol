defmodule Raxol.UI.Components.Harness.ToolResultBlock do
  @moduledoc """
  Renders one tool result from the harness protocol stream.

  Render-dual of `item_completed{item_type: :tool_result, content}`, folded
  with the owning event envelope's `provenance.trust`
  (`docs/proposals/in-flight/harness-spec-protocol.md` sec 3). Long output
  collapses behind a one-line summary; Enter/Space toggles it. Composes
  `Raxol.UI.Components.Harness.TaintBadge` for the `provenance.trust:
  :tainted` case -- the lethal-trifecta visibility marker described in
  `harness-spec-frontend.md` sec 6.

  The output body reuses `Raxol.UI.Components.CodeBlock`'s bordered/padded
  box convention (`box style: %{border: :single, padding: 1}`), but not its
  Makeup syntax highlighting: `CodeBlock` has no plaintext lexer and falls
  back to the Elixir lexer for any language it doesn't recognise, which
  would mis-highlight arbitrary tool output (JSON, logs, shell text) as
  pseudo-Elixir. Plain text keeps this honest for content of unknown shape.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.Components.Harness.{TaintBadge, ToolCallBlock}
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type status :: ToolCallBlock.status()

  @type t :: %{
          id: String.t() | atom(),
          output: String.t(),
          status: status(),
          taint: boolean(),
          collapsed: boolean(),
          collapse_lines: pos_integer(),
          style: map(),
          theme: map()
        }

  @default_collapse_lines 6

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "tool-result"),
      output: Keyword.get(props, :output, ""),
      status: Keyword.get(props, :status, :done),
      taint: Keyword.get(props, :taint, false),
      collapsed: Keyword.get(props, :collapsed, true),
      collapse_lines:
        Keyword.get(props, :collapse_lines, @default_collapse_lines),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(%Event{type: :key, data: %{key: :enter}}, state, _context) do
    {toggle_collapsed(state), []}
  end

  def handle_event(%Event{type: :key, data: %{key: :space}}, state, _context) do
    {toggle_collapsed(state), []}
  end

  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :tool_result_block)

    column_style = Map.put_new(base_style, :gap, 1)

    lines = output_lines(state.output)
    long? = length(lines) > state.collapse_lines

    children = [
      header_row(state, context, long?),
      body_box(state, lines, long?)
    ]

    %{type: :column, style: column_style, gap: 0, children: children}
  end

  defp toggle_collapsed(state), do: %{state | collapsed: not state.collapsed}

  defp header_row(state, context, long?) do
    {glyph, color} = ToolCallBlock.status_glyph(state.status, 0)

    children =
      [
        Raxol.View.Components.text(
          id: "#{state.id}-glyph",
          content: glyph,
          style: %{fg: color}
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-label",
          content: "Tool Result",
          style: %{bold: true}
        ),
        taint_badge_view(state, context)
      ] ++ collapse_hint(state, long?)

    %{type: :row, style: %{gap: 1}, children: children}
  end

  defp taint_badge_view(state, context) do
    {:ok, badge_state} =
      TaintBadge.init(taint: state.taint, id: "#{state.id}-taint")

    TaintBadge.render(badge_state, context)
  end

  defp collapse_hint(_state, false), do: []

  defp collapse_hint(%{collapsed: true} = state, true) do
    hidden = length(output_lines(state.output)) - state.collapse_lines

    [
      Raxol.View.Components.text(
        id: "#{state.id}-hint",
        content: "[+#{hidden} more lines, enter to expand]",
        style: %{dim: true}
      )
    ]
  end

  defp collapse_hint(state, true) do
    [
      Raxol.View.Components.text(
        id: "#{state.id}-hint",
        content: "[enter to collapse]",
        style: %{dim: true}
      )
    ]
  end

  defp body_box(state, lines, long?) do
    content = lines |> visible_lines(state, long?) |> Enum.join("\n")

    %{
      type: :box,
      style: %{border: :single, padding: 1},
      children: [
        Raxol.View.Components.text(id: "#{state.id}-body", content: content)
      ]
    }
  end

  defp visible_lines(lines, %{collapsed: true, collapse_lines: n}, true),
    do: Enum.take(lines, n)

  defp visible_lines(lines, _state, _long?), do: lines

  defp output_lines(output) do
    output
    |> String.trim_trailing("\n")
    |> String.split("\n")
  end
end
