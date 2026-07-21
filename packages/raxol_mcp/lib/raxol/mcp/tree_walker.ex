defmodule Raxol.MCP.TreeWalker do
  @moduledoc """
  Traverses a view element tree and derives namespaced MCP tools from widgets.

  The view tree is the output of a TEA app's `view/1` function -- nested maps
  with `:type`, `:id`, `:attrs`, `:children` keys. TreeWalker walks this tree,
  finds widgets that implement `Raxol.MCP.ToolProvider`, calls `mcp_tools/1`
  to get tool specs, namespaces them by widget ID, and wraps callbacks that
  dispatch TEA messages through the session's Dispatcher.

  ## Usage

      context = %{dispatcher_pid: dispatcher_pid}
      tools = TreeWalker.derive_tools(view_tree, context)
      Raxol.MCP.Registry.register_tools(tools)

  Tool names are namespaced as `"widget_id.action"`, e.g., `"search_input.type_into"`.
  Nodes without an `:id` key are skipped (layout containers like `:column`, `:row`).

  ## Excluding Widgets

  Set `mcp_exclude: true` in a widget's attrs to suppress tool derivation:

      %{type: :text_input, id: "internal", attrs: %{mcp_exclude: true}}

  The widget and its children still render normally -- only MCP tool
  exposure is suppressed. Useful for decorative or internal widgets.

  ## Explicit provider marker (`attrs.component_module`)

  Components whose root emits a plain layout type (`:column`, `:row`) can
  declare their providing module explicitly instead of growing this
  package's type map (the harness block Components do this):

      %{type: :column, id: "blk", attrs: %{component_module: MyBlock}}

  An explicit marker wins over the built-in type map; the same
  `ToolProvider` guard applies, so a module that does not implement the
  behaviour still derives nothing, and a non-atom marker is ignored.
  """

  alias Raxol.MCP.NodeChildren
  alias Raxol.MCP.ToolProvider

  # Widget type atoms -> module names. These are in main raxol, so we use
  # @compile to suppress undefined warnings for cross-package references.
  @compile {:no_warn_undefined,
            [
              Raxol.UI.Components.Input.Button,
              Raxol.UI.Components.Input.TextInput,
              Raxol.UI.Components.Input.SelectList,
              Raxol.UI.Components.Input.Checkbox,
              Raxol.UI.Components.Input.Tabs,
              Raxol.UI.Components.Input.TextArea,
              Raxol.UI.Components.Input.Menu,
              Raxol.UI.Components.Input.PasswordField,
              Raxol.UI.Components.Display.Tree,
              Raxol.UI.Components.Display.Viewport,
              Raxol.UI.Components.Modal,
              Raxol.UI.Components.Table,
              Raxol.UI.Charts.BarChart,
              Raxol.UI.Charts.LineChart,
              Raxol.UI.Charts.ScatterChart,
              Raxol.UI.Components.Harness.ApprovalPrompt
            ]}

  @default_type_map %{
    button: Raxol.UI.Components.Input.Button,
    text_input: Raxol.UI.Components.Input.TextInput,
    select_list: Raxol.UI.Components.Input.SelectList,
    checkbox: Raxol.UI.Components.Input.Checkbox,
    tabs: Raxol.UI.Components.Input.Tabs,
    text_area: Raxol.UI.Components.Input.TextArea,
    menu: Raxol.UI.Components.Input.Menu,
    password_field: Raxol.UI.Components.Input.PasswordField,
    tree: Raxol.UI.Components.Display.Tree,
    viewport: Raxol.UI.Components.Display.Viewport,
    modal: Raxol.UI.Components.Modal,
    table: Raxol.UI.Components.Table,
    bar_chart: Raxol.UI.Charts.BarChart,
    line_chart: Raxol.UI.Charts.LineChart,
    scatter_chart: Raxol.UI.Charts.ScatterChart,
    approval_prompt: Raxol.UI.Components.Harness.ApprovalPrompt
  }

  @type context :: %{
          dispatcher_pid: pid() | nil,
          type_map: %{atom() => module()}
        }

  @doc """
  Derives MCP tool definitions from a view element tree.

  Returns a list of `Registry.tool_def()` maps with namespaced names and
  wrapped callbacks that dispatch TEA messages.

  ## Options in context

    * `:dispatcher_pid` - pid of the session's Dispatcher (for message dispatch)
    * `:type_map` - optional override for widget type -> module mapping
  """
  @spec derive_tools(map() | [map()], context()) :: [
          Raxol.MCP.Registry.tool_def()
        ]
  def derive_tools(tree, context) do
    type_map = Map.get(context, :type_map, @default_type_map)
    do_walk(tree, context, type_map, [])
  end

  defp do_walk(nodes, context, type_map, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &do_walk(&1, context, type_map, &2))
  end

  defp do_walk(%{type: type, id: id} = node, context, type_map, acc)
       when is_atom(type) and is_binary(id) and id != "" do
    widget_tools =
      if mcp_excluded?(node) do
        []
      else
        derive_widget_tools(node, type, id, context, type_map)
      end

    children_acc = do_walk(NodeChildren.child_nodes(node), context, type_map, acc)
    widget_tools ++ children_acc
  end

  defp do_walk(%{children: _} = node, context, type_map, acc) do
    do_walk(NodeChildren.child_nodes(node), context, type_map, acc)
  end

  # An `:absolute_layer` (Raxol.UI.Components.AbsoluteLayer) parents its
  # subtree through `:flow_child` + `:overlays[].element`, not `:children`,
  # and carries no `:id` of its own -- so without these clauses the walker
  # would stop at it and every overlay Component hosted over the transcript
  # (pickers, panels, dialogs) would derive zero tools. Walk into both so an
  # overlay Component's stamped root is reached exactly as a flow child's is.
  defp do_walk(%{flow_child: _} = node, context, type_map, acc) do
    do_walk(NodeChildren.child_nodes(node), context, type_map, acc)
  end

  defp do_walk(%{overlays: _} = node, context, type_map, acc) do
    do_walk(NodeChildren.child_nodes(node), context, type_map, acc)
  end

  defp do_walk(_node, _context, _type_map, acc), do: acc

  defp derive_widget_tools(node, type, id, context, type_map) do
    case resolve_module(node, type, type_map) do
      nil ->
        []

      module ->
        if ToolProvider.tool_provider?(module) do
          specs = module.mcp_tools(node)
          Enum.map(specs, &build_tool_def(&1, id, module, node, context))
        else
          []
        end
    end
  end

  # An explicit `attrs.component_module` declaration wins over the
  # built-in type map (the marker exists precisely for nodes whose :type
  # is a plain layout container). `ToolProvider.tool_provider?/1` guards
  # both paths, so an arbitrary/unloaded module still derives nothing.
  defp resolve_module(node, type, type_map) do
    case node do
      %{attrs: %{component_module: module}} when is_atom(module) and not is_nil(module) ->
        module

      _no_marker ->
        Map.get(type_map, type)
    end
  end

  defp build_tool_def(spec, widget_id, module, node, context) do
    action_name = spec.name

    %{
      name: "#{widget_id}.#{action_name}",
      description: spec.description,
      inputSchema: spec.inputSchema,
      callback: fn args ->
        tool_context = %{
          widget_id: widget_id,
          widget_state: node,
          dispatcher_pid: context[:dispatcher_pid]
        }

        case module.handle_tool_call(action_name, args, tool_context) do
          {:ok, result, messages} ->
            dispatch_messages(messages, context[:dispatcher_pid])
            {:ok, format_result(result)}

          {:ok, result} ->
            {:ok, format_result(result)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    }
  end

  defp dispatch_messages(messages, dispatcher_pid)
       when is_pid(dispatcher_pid) do
    for msg <- messages, msg != nil do
      GenServer.cast(dispatcher_pid, {:dispatch, msg})
    end
  end

  defp dispatch_messages(_messages, _pid), do: :ok

  defp format_result(result) when is_binary(result) do
    [%{type: "text", text: result}]
  end

  defp format_result(result) do
    [%{type: "text", text: inspect(result)}]
  end

  defp mcp_excluded?(%{attrs: %{mcp_exclude: true}}), do: true
  defp mcp_excluded?(_), do: false
end
