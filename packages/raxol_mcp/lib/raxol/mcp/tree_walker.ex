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
  A widget id becomes part of a tool name the client lists, so a provider
  whose id is not 1-32 characters of `[A-Za-z0-9_-]` derives no tools.

  Descriptions reach the client's tool list as well: control, format
  (bidi, zero-width, BOM, tag) and line/paragraph separator characters are
  stripped from a tool's `description` and from every `description` inside
  its `inputSchema`.

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

  alias Raxol.MCP.ToolProvider

  require Logger

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
              Raxol.UI.Components.Input.Scrubber
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
    scrubber: Raxol.UI.Components.Input.Scrubber
  }

  @type context :: %{
          dispatcher_pid: pid() | nil,
          type_map: %{atom() => module()}
        }

  @doc """
  The built-in declaration-type -> Component-module map used when `context`
  carries no `:type_map`.

  Exposed so the main app can assert it against `Raxol.UI.Registry`; this
  package cannot derive the map from that registry (main raxol is not a
  dependency), so conformance is a test, not a compile-time guarantee.
  """
  @spec default_type_map() :: %{atom() => module()}
  def default_type_map, do: @default_type_map

  @doc """
  Derives MCP tool definitions from a view element tree.

  Returns a list of `Registry.tool_def()` maps with namespaced names and
  wrapped callbacks that dispatch TEA messages. Logs a warning, once per id
  per call, for each provider widget refused for its id (see `derive/2`).

  ## Options in context

    * `:dispatcher_pid` - pid of the session's Dispatcher (for message dispatch)
    * `:type_map` - optional override for widget type -> module mapping
  """
  @spec derive_tools(map() | [map()], context()) :: [
          Raxol.MCP.Registry.tool_def()
        ]
  def derive_tools(tree, context) do
    {tools, refused_ids} = derive(tree, context)
    Enum.each(refused_ids, &warn_refused_id/1)
    tools
  end

  @doc """
  `derive_tools/2` without logging: returns the tools and the set of ids of
  provider widgets that derived none because their id is not 1-32
  characters of `[A-Za-z0-9_-]`. A caller that derives on every render
  (`Raxol.MCP.ToolSynchronizer`) warns once per id with `warn_refused_id/1`.
  """
  @spec derive(map() | [map()], context()) ::
          {[Raxol.MCP.Registry.tool_def()], MapSet.t(String.t())}
  def derive(tree, context) do
    type_map = Map.get(context, :type_map, @default_type_map)
    do_walk(tree, context, type_map, {[], MapSet.new()})
  end

  @doc "Logs that the provider widget `id` derived no tools because of its id."
  @spec warn_refused_id(String.t()) :: :ok
  def warn_refused_id(id) do
    Logger.warning(
      "[MCP.TreeWalker] widget id #{inspect(id)} derives no tools: an id must be " <>
        "1-32 characters of [A-Za-z0-9_-]"
    )
  end

  @widget_id ~r/\A[A-Za-z0-9_-]{1,32}\z/

  defp do_walk(nodes, context, type_map, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &do_walk(&1, context, type_map, &2))
  end

  defp do_walk(%{type: type, id: id} = node, context, type_map, acc)
       when is_atom(type) and is_binary(id) and id != "" do
    acc = do_walk(child_nodes(node), context, type_map, acc)
    add_widget_tools(widget_specs(node, type, type_map), node, id, context, acc)
  end

  defp do_walk(%{children: _} = node, context, type_map, acc) do
    do_walk(child_nodes(node), context, type_map, acc)
  end

  # An `:absolute_layer` (Raxol.UI.Components.AbsoluteLayer) parents its
  # subtree through `:flow_child` + `:overlays[].element`, not `:children`,
  # and carries no `:id` of its own -- so without these clauses the walker
  # would stop at it and every overlay Component hosted over the transcript
  # (pickers, panels, dialogs) would derive zero tools. Walk into both so an
  # overlay Component's stamped root is reached exactly as a flow child's is.
  defp do_walk(%{flow_child: _} = node, context, type_map, acc) do
    do_walk(child_nodes(node), context, type_map, acc)
  end

  defp do_walk(%{overlays: _} = node, context, type_map, acc) do
    do_walk(child_nodes(node), context, type_map, acc)
  end

  defp do_walk(_node, _context, _type_map, acc), do: acc

  defp add_widget_tools(nil, _node, _id, _context, acc), do: acc

  defp add_widget_tools({module, specs}, node, id, context, {tools, refused_ids}) do
    if Regex.match?(@widget_id, id) do
      {Enum.map(specs, &build_tool_def(&1, id, module, node, context)) ++ tools, refused_ids}
    else
      {tools, MapSet.put(refused_ids, id)}
    end
  end

  # The View DSL allows :children to be a list or a single element map
  # (e.g. a box whose do-block is one column). Mirror the Bubbler's
  # path-finding, which treats both shapes as first-class. An
  # `:absolute_layer` also contributes its flow child + overlay elements
  # (see the flow_child/overlays clauses above).
  defp child_nodes(node) do
    direct =
      case Map.get(node, :children) do
        kids when is_list(kids) -> kids
        kid when is_map(kid) -> [kid]
        _ -> []
      end

    direct ++ absolute_layer_children(node)
  end

  # The `:absolute_layer` overlay wiring: the flow child plus each
  # overlay's `:element`. Absent on ordinary nodes (both default to []), so
  # this is a no-op everywhere except an absolute layer.
  defp absolute_layer_children(node) do
    flow =
      case Map.get(node, :flow_child) do
        child when is_map(child) -> [child]
        _ -> []
      end

    overlay_elements =
      node
      |> Map.get(:overlays, [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{element: element} when is_map(element) -> [element]
        _ -> []
      end)

    flow ++ overlay_elements
  end

  # The provider module and its specs, or nil for a node that derives nothing
  # (excluded, no provider, or no specs).
  defp widget_specs(node, type, type_map) do
    module = resolve_module(node, type, type_map)

    if not mcp_excluded?(node) and module != nil and ToolProvider.tool_provider?(module) do
      case module.mcp_tools(node) do
        [_ | _] = specs -> {module, specs}
        _none -> nil
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

  # A description reaches the client's tool list verbatim, which a model reads
  # as instructions: a forged line break, a bidi override or invisible tag
  # characters there are a prompt-injection channel. The built-in providers
  # keep descriptions static per action; this holds for any other provider as
  # well. Control (C0, C1, DEL), format (bidi, zero-width, BOM, tag) and
  # line/paragraph separator characters.
  @unsafe_chars ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  defp build_tool_def(spec, widget_id, module, node, context) do
    action_name = spec.name

    %{
      name: "#{widget_id}.#{action_name}",
      description: sanitize_description(spec.description),
      inputSchema: sanitize_schema(spec.inputSchema),
      callback: fn args ->
        tool_context = %{
          widget_id: widget_id,
          widget_state: node,
          dispatcher_pid: context[:dispatcher_pid]
        }

        case module.handle_tool_call(action_name, args, tool_context) do
          {:ok, result, messages} ->
            with :ok <- dispatch_messages(messages, context[:dispatcher_pid]) do
              {:ok, format_result(result)}
            end

          {:ok, result} ->
            {:ok, format_result(result)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    }
    |> put_annotations(Map.get(spec, :annotations))
  end

  defp put_annotations(tool, nil), do: tool
  defp put_annotations(tool, annotations), do: Map.put(tool, :annotations, annotations)

  # A non-binary description (nil, say) passes through as before; invalid
  # UTF-8 is replaced first, since the `u` regex refuses it.
  defp sanitize_description(text) when is_binary(text) do
    text |> String.replace_invalid() |> String.replace(@unsafe_chars, "")
  end

  defp sanitize_description(other), do: other

  # Every `description` in the schema, at any depth (property descriptions,
  # nested objects, array `items`).
  defp sanitize_schema(%{} = map) when not is_struct(map) do
    Map.new(map, fn
      {key, text} when key in [:description, "description"] and is_binary(text) ->
        {key, sanitize_description(text)}

      {key, value} ->
        {key, sanitize_schema(value)}
    end)
  end

  defp sanitize_schema(list) when is_list(list), do: Enum.map(list, &sanitize_schema/1)
  defp sanitize_schema(other), do: other

  # A call, not a cast: each message has been through the app's update/2 by
  # the time the tool answers. An update/2 that failed answers
  # `{:error, :update_failed}`, which stops the remaining messages and becomes
  # the tool's error result. A dispatcher that is gone or does not answer
  # exits here, and `Raxol.MCP.Registry` turns that exit into an error result.
  defp dispatch_messages(messages, dispatcher_pid)
       when is_pid(dispatcher_pid) do
    messages
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn msg, :ok ->
      case GenServer.call(dispatcher_pid, {:dispatch_tool_message, msg}) do
        :ok -> {:cont, :ok}
        {:error, :update_failed} = error -> {:halt, error}
      end
    end)
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
