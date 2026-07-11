defmodule Raxol.UI.Components.Display.Viewport do
  @moduledoc """
  A scrollable container that displays a windowed view of content
  that may exceed its visible bounds.

  Supports vertical and horizontal scrolling via keyboard (arrow keys,
  Page Up/Down, Home/End) and programmatic scroll control.

  Content is provided as a list of child elements. The viewport renders
  only the visible slice based on `scroll_top` and `visible_height`.
  """

  @behaviour Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider

  alias Raxol.View.Components

  @type t :: %{
          id: any(),
          children: list(map()),
          content_source: struct() | nil,
          scroll_top: non_neg_integer(),
          scroll_left: non_neg_integer(),
          visible_height: pos_integer(),
          visible_width: pos_integer() | nil,
          content_height: non_neg_integer(),
          style: map(),
          theme: map(),
          show_scrollbar: boolean(),
          focused: boolean()
        }

  @impl true
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = if Keyword.keyword?(props), do: Map.new(props), else: props
    children = Map.get(props, :children, [])
    content_source = Map.get(props, :content_source)

    content_height =
      if content_source do
        content_source.__struct__.total_count(content_source)
      else
        length(children)
      end

    state = %{
      id:
        Map.get(props, :id, "viewport-#{:erlang.unique_integer([:positive])}"),
      children: children,
      content_source: content_source,
      scroll_top: Map.get(props, :scroll_top, 0),
      scroll_left: Map.get(props, :scroll_left, 0),
      visible_height: Map.get(props, :visible_height, 10),
      visible_width: Map.get(props, :visible_width, nil),
      content_height: content_height,
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{}),
      show_scrollbar: Map.get(props, :show_scrollbar, true),
      focused: Map.get(props, :focused, false),
      # CSS overflow-anchor, terminal-log flavor (proposal Phase F2):
      # :auto -> when scrolled to the bottom, new content keeps the view
      # pinned to the bottom (follow mode); scrolling up releases it.
      # :none -> scroll_top never moves on content changes.
      overflow_anchor: Map.get(props, :overflow_anchor, :auto)
    }

    {:ok, state}
  end

  # At-bottom check BEFORE a content change; drives :auto anchoring.
  defp at_bottom?(state) do
    state.scroll_top >= max(0, state.content_height - state.visible_height)
  end

  @impl true
  def mount(state), do: {state, []}

  @impl true
  def unmount(state), do: state

  @impl true
  def update({:set_children, children}, state) do
    new_height = length(children)

    scroll_top =
      case state.overflow_anchor do
        :auto ->
          if at_bottom?(state) do
            # follow mode: stay pinned to the new bottom
            max(0, new_height - state.visible_height)
          else
            clamp_scroll(state.scroll_top, new_height, state.visible_height)
          end

        :none ->
          state.scroll_top
      end

    {%{
       state
       | children: children,
         content_height: new_height,
         scroll_top: scroll_top
     }, []}
  end

  def update({:scroll_to, row}, state) do
    scroll_top = clamp_scroll(row, state.content_height, state.visible_height)
    {%{state | scroll_top: scroll_top}, []}
  end

  def update({:scroll_by, delta}, state) do
    scroll_top =
      clamp_scroll(
        state.scroll_top + delta,
        state.content_height,
        state.visible_height
      )

    {%{state | scroll_top: scroll_top}, []}
  end

  def update({:set_visible_height, height}, state) do
    scroll_top = clamp_scroll(state.scroll_top, state.content_height, height)
    {%{state | visible_height: height, scroll_top: scroll_top}, []}
  end

  def update({:update_props, props}, state) do
    new_state =
      state
      |> maybe_update(:children, props)
      |> maybe_update(:visible_height, props)
      |> maybe_update(:visible_width, props)
      |> maybe_update(:show_scrollbar, props)
      |> maybe_update(:style, props)
      |> maybe_update(:theme, props)

    content_height =
      if new_state.content_source do
        new_state.content_source.__struct__.total_count(
          new_state.content_source
        )
      else
        length(new_state.children)
      end

    new_state = %{new_state | content_height: content_height}

    scroll_top =
      clamp_scroll(
        new_state.scroll_top,
        new_state.content_height,
        new_state.visible_height
      )

    {%{new_state | scroll_top: scroll_top}, []}
  end

  def update(_msg, state), do: {state, []}

  @impl true
  def handle_event(%{type: :key, data: %{key: key}}, state, _context) do
    handle_key(key, state)
  end

  def handle_event(%{type: :focus}, state, _context) do
    {%{state | focused: true}, []}
  end

  def handle_event(%{type: :blur}, state, _context) do
    {%{state | focused: false}, []}
  end

  def handle_event(_event, state, _context), do: {state, []}

  defp handle_key(k, state) when k in [:up, "Up"], do: scroll(state, -1)
  defp handle_key(k, state) when k in [:down, "Down"], do: scroll(state, 1)

  defp handle_key(k, state) when k in [:page_up, :pageup, "PageUp"],
    do: scroll(state, -state.visible_height)

  defp handle_key(k, state) when k in [:page_down, :pagedown, "PageDown"],
    do: scroll(state, state.visible_height)

  defp handle_key(k, state) when k in [:home, "Home"],
    do: {%{state | scroll_top: 0}, []}

  defp handle_key(k, state) when k in [:end, "End"] do
    scroll_top = max_scroll(state.content_height, state.visible_height)
    {%{state | scroll_top: scroll_top}, []}
  end

  defp handle_key(_key, state), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    state = %{
      state
      | focused:
          Raxol.UI.FocusHelper.focused?(state.id, context) or state.focused
    }

    visible_children =
      if state.content_source do
        state.content_source.__struct__.slice(
          state.content_source,
          state.scroll_top,
          state.visible_height
        )
      else
        Enum.slice(state.children, state.scroll_top, state.visible_height)
      end

    content_column = %{
      type: :column,
      style: %{},
      children: visible_children
    }

    children =
      if state.show_scrollbar and state.content_height > state.visible_height do
        scrollbar = render_scrollbar(state)
        [content_column, scrollbar]
      else
        [content_column]
      end

    %{
      type: :row,
      id: state.id,
      style: state.style,
      children: children
    }
  end

  defp render_scrollbar(state) do
    total = state.content_height
    visible = state.visible_height

    thumb_size = max(1, div(visible * visible, max(total, 1)))
    scrollable = max_scroll(total, visible)

    thumb_pos =
      if scrollable > 0,
        do: div(state.scroll_top * (visible - thumb_size), scrollable),
        else: 0

    track =
      Enum.map(0..(visible - 1), fn i ->
        char =
          if i >= thumb_pos and i < thumb_pos + thumb_size, do: "█", else: "░"

        Components.text(content: char, style: %{fg: :white})
      end)

    %{type: :column, style: %{}, children: track}
  end

  defp scroll(state, delta) do
    scroll_top =
      clamp_scroll(
        state.scroll_top + delta,
        state.content_height,
        state.visible_height
      )

    {%{state | scroll_top: scroll_top}, []}
  end

  defp clamp_scroll(pos, content_height, visible_height) do
    Raxol.Core.Utils.Math.clamp(
      pos,
      0,
      max_scroll(content_height, visible_height)
    )
  end

  defp max_scroll(content_height, visible_height) do
    max(0, content_height - visible_height)
  end

  defp maybe_update(state, key, props) do
    case Map.fetch(props, key) do
      {:ok, value} -> Map.put(state, key, value)
      :error -> state
    end
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(_state) do
    [
      %{
        name: "scroll_to",
        description: "Scroll to a specific row",
        inputSchema: %{
          type: "object",
          properties: %{
            row: %{type: "integer", description: "Row to scroll to (0-based)"}
          },
          required: ["row"]
        }
      },
      %{
        name: "get_visible_range",
        description: "Get the currently visible row range",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("scroll_to", %{"row" => row}, context) do
    {:ok, "Scrolled to row #{row}", [{:scroll_to, context.widget_id, row}]}
  end

  def handle_tool_call("get_visible_range", _args, context) do
    state = context.widget_state
    scroll_top = state[:scroll_top] || 0
    visible_height = state[:visible_height] || 10
    {:ok, %{top: scroll_top, bottom: scroll_top + visible_height - 1}}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}
end
