defmodule Raxol.MCP.ToolProvider do
  @moduledoc """
  Behaviour for widgets that expose MCP tools.

  Each interactive widget can implement this behaviour to declare what
  semantic actions (tools) are available given its current state. The
  `TreeWalker` traverses the view tree, calls `mcp_tools/1` on each
  widget that implements this behaviour, and registers the resulting
  tools with the MCP Registry.

  ## Tool Specs

  `mcp_tools/1` returns a list of tool spec maps:

      %{
        name: "click",
        description: "Click the button",
        inputSchema: %{type: "object", properties: %{}},
        annotations: %{sensitive: true}
      }

  The `name` is the action name (e.g., "click", "type_into"). The
  TreeWalker namespaces it with the session and widget IDs:
  `"demo.submit_btn.click"`.

  The `description` is static per (provider, action): it never carries app
  text (labels, titles, tab names) or the widget ID. Descriptions reach the
  client's tool list, which a model reads as instructions, so app text belongs
  in tool results only. `TreeWalker` also strips control characters from
  every description.

  `annotations` is optional and copied onto the derived tool. Give an action
  that changes app state `sensitive: true`, so `Raxol.MCP.Server` refuses it
  when no authorizer is configured.

  ## Handle Tool Call

  `handle_tool_call/3` executes the action. It receives the action name,
  arguments map, and a context map with `:widget_id`, `:widget_state`,
  and `:dispatcher_pid`.

  Return values:
  - `{:ok, result}` -- pure read, no state change
  - `{:ok, result, [message]}` -- result + TEA messages to dispatch
  - `{:error, reason}` -- failure

  ## Messages reach `update/2`

  `TreeWalker` hands each message, as returned, to the app's `update/2`
  through the session's Dispatcher, and the tool answers only once
  `update/2` has folded it. Messages are app terms, not `%Event{}`s: an app
  whose view renders a provider's node adds `update/2` clauses for the
  messages it acts on. `id` is the node's binary id.

  | Provider | Action: message |
  |---|---|
  | `Table` | `select_row`: `{:select_row, id, index}`; `sort`: `{:sort, id, column, direction}`, the column string as sent (unvalidated), direction `"asc"` or `"desc"` |
  | `SelectList` | `select`: `{:select_option, id, index}` |
  | `Tabs` | `select_tab`: `{:tab_change, id, index}`, index range-checked against the node's `:tabs` |
  | `Modal` | `dismiss`: `{:modal_dismiss, id}`; `confirm`: `{:modal_confirm, id}` |
  | `TextInput` | `type_into`: `{:text_input_change, id, text}`; `clear`: `{:text_input_change, id, ""}` |
  | `TextArea` | `type_into`: `{:text_area_change, id, text}`; `clear`: `{:text_area_change, id, ""}` |
  | `PasswordField` | `type_into`: `{:password_field_change, id, text}`; `clear`: `{:password_field_change, id, ""}` |
  | `Button` | `click`: the node's `:on_click` message (top level on View DSL nodes, under `:attrs` on Component trees); nothing without one |
  | `Checkbox` | `toggle`: `{:checkbox_toggle, id, new_checked}` |
  | `Menu` | `select`: `{:menu_select, id, item_id}` |
  | `Scrubber` | `seek`: `{:scrubber_seek, id, position}`; `play`: `{:scrubber_play, id}`; `pause`: `{:scrubber_pause, id}` |
  | `Tree` | `expand`: `{:tree_expand, id, node_id}`; `collapse`: `{:tree_collapse, id, node_id}`; `select_node`: `{:tree_select, id, node_id}` |
  | `Viewport` | `scroll_to`: `{:scroll_to, id, row}` |
  | `BarChart`, `LineChart`, `ScatterChart` | read-only |

  Every other action is a read (`{:ok, result}`) and sends nothing.

  ## Example

      defmodule MyApp.Button do
        @behaviour Raxol.MCP.ToolProvider

        @impl Raxol.MCP.ToolProvider
        def mcp_tools(%{attrs: %{disabled: true}}), do: []
        def mcp_tools(state) do
          [%{
            name: "click",
            description: "Click the button",
            inputSchema: %{type: "object", properties: %{}},
            annotations: %{sensitive: true}
          }]
        end

        @impl Raxol.MCP.ToolProvider
        def handle_tool_call("click", _args, context) do
          {:ok, "Clicked", [context.widget_state[:attrs][:on_click]]}
        end
      end
  """

  @type tool_spec :: %{
          optional(:annotations) => map(),
          name: String.t(),
          description: String.t(),
          inputSchema: map()
        }

  @type context :: %{
          widget_id: String.t(),
          widget_state: map(),
          dispatcher_pid: pid() | nil
        }

  @type result ::
          {:ok, term()}
          | {:ok, term(), [term()]}
          | {:error, term()}

  @doc """
  Returns the list of MCP tool specs for the widget's current state.

  Called by `TreeWalker` during view tree traversal. The widget state
  is the raw map from the view tree (the output of `view/1`), not the
  internal component struct.
  """
  @callback mcp_tools(widget_state :: map()) :: [tool_spec()]

  @doc """
  Handles an MCP tool call for this widget.

  `name` is the action name (e.g., "click", "type_into") without the
  widget ID namespace prefix.

  `args` is the arguments map from the MCP client.

  `context` contains `:widget_id`, `:widget_state`, and `:dispatcher_pid`.
  """
  @callback handle_tool_call(
              name :: String.t(),
              args :: map(),
              context :: context()
            ) :: result()

  @doc """
  Returns true if the given module implements the ToolProvider behaviour.
  """
  @spec tool_provider?(module()) :: boolean()
  def tool_provider?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :mcp_tools, 1) and
      function_exported?(module, :handle_tool_call, 3)
  end
end
