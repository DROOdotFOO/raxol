defmodule Raxol.MCP.TreeWalkerChildrenTest do
  @moduledoc """
  Pins the `:children` duality: the View DSL produces both list children
  and single-map children (a box whose do-block is one element). The
  Bubbler's path-finding has always handled both; TreeWalker derivation
  and StructuredScreenshot summaries must too, or subtrees silently
  disappear from tool derivation and widget summaries (the F0-mcp break
  that hid a demo's stats box).
  """
  use ExUnit.Case, async: true

  alias Raxol.MCP.{StructuredScreenshot, TreeWalker}

  defmodule ClickProvider do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(_state) do
      [
        %{
          name: "click",
          description: "Click",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("click", _args, ctx), do: {:ok, "ok", [{:click, ctx.widget_id}]}
    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  # A box whose :children is a single map (not a list), wrapping a column
  # that holds the interactive widget -- the shape `box do ... end` emits.
  defp tree_with_map_children do
    %{
      type: :box,
      children: %{
        type: :column,
        children: [
          %{type: :button, id: "nested_btn", children: []},
          %{type: :text, id: "nested_text", content: "hello", children: []}
        ]
      }
    }
  end

  test "TreeWalker derives tools through single-map :children" do
    context = %{dispatcher_pid: nil, type_map: %{button: ClickProvider}}

    names =
      tree_with_map_children()
      |> TreeWalker.derive_tools(context)
      |> Enum.map(& &1.name)

    assert "nested_btn.click" in names
  end

  test "StructuredScreenshot summarizes through single-map :children" do
    [box_summary] = StructuredScreenshot.from_view_tree(tree_with_map_children())

    [column_summary] = box_summary[:children]
    child_ids = Enum.map(column_summary[:children], & &1[:id])

    assert "nested_btn" in child_ids
    assert "nested_text" in child_ids

    text_summary = Enum.find(column_summary[:children], &(&1[:id] == "nested_text"))
    assert text_summary[:content] == "hello"
  end
end
