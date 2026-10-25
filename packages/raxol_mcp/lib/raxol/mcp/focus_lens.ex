defmodule Raxol.MCP.FocusLens do
  @moduledoc """
  Attention-aware tool filtering for MCP surfaces.

  Complex UIs can expose 100+ tools, but LLM tool selection degrades
  past ~20. FocusLens filters the full tool set to a manageable subset
  based on which widget has focus.

  ## Modes

    * `:all` -- return all tools (default for headless sessions)
    * `:focused` -- return the session's tools for the focused widget + globals
    * `:hover` -- return the session's tools for the focused widget + the
      hovered widget + globals

  Derived tool names are `"session_id.widget_id.action"`. In `:focused` and
  `:hover` modes a tool belongs to the session when the first `.` segment of
  its name is exactly `:session_id`, and to a widget when the second is
  exactly the widget ID, so another session's tools for a widget with the
  same ID never leak in. A session or widget ID never holds a `.`
  (`Raxol.MCP.TreeWalker.id?/1`). A global tool is one with no `.` in its
  name (a server-level tool such as `raxol_list`), and the session's
  `"session_id.discover_tools"` meta-tool is always included so agents can
  search the session's full set by keyword.

  ## Usage

      all_tools = TreeWalker.derive_tools(view_tree, context)

      # Headless: show everything
      FocusLens.filter(all_tools, mode: :all)

      # Interactive: show focused + globals
      FocusLens.filter(all_tools,
        mode: :focused,
        session_id: "demo",
        focused_id: "search_input"
      )

      # Mouse tracking: anticipatory tool exposure
      FocusLens.filter(all_tools,
        mode: :hover,
        session_id: "demo",
        focused_id: "search_input",
        hover_id: "submit_btn"
      )
  """

  @default_max_tools 15

  @type tool_def :: Raxol.MCP.Registry.tool_def()

  @doc """
  Filters a list of tools based on focus state.

  ## Options

    * `:mode` - `:all` (default), `:focused`, or `:hover`
    * `:session_id` - the session whose tools `:focused` and `:hover` select
      (required in those modes)
    * `:focused_id` - widget ID that currently has focus
    * `:hover_id` - widget ID under the mouse cursor (for `:hover` mode)
    * `:max_tools` - maximum number of tools to return (default: 15)
    * `:registry` - Registry reference for `discover_tools` (optional)
  """
  @spec filter([tool_def()], keyword()) :: [tool_def()]
  def filter(tools, opts \\ []) do
    mode = Keyword.get(opts, :mode, :all)
    max_tools = Keyword.get(opts, :max_tools, @default_max_tools)

    case mode do
      :all ->
        Enum.take(tools, max_tools)

      :focused ->
        scope = scope(opts)
        focused_id = Keyword.get(opts, :focused_id)
        filter_focused(tools, focused_id, max_tools, scope)

      :hover ->
        scope = scope(opts)
        focused_id = Keyword.get(opts, :focused_id)
        hover_id = Keyword.get(opts, :hover_id)
        filter_hover(tools, focused_id, hover_id, max_tools, scope)
    end
  end

  defp scope(opts) do
    %{session_id: Keyword.fetch!(opts, :session_id), registry: Keyword.get(opts, :registry)}
  end

  @doc """
  Returns the session's `"session_id.discover_tools"` meta-tool spec.

  This tool lets agents search the session's full tool set by keyword when
  FocusLens is hiding tools. Pass a registry reference so the tool can query
  the registered tools; it matches only the tools named under `session_id`.
  """
  @spec discover_tools_spec(GenServer.server(), String.t()) :: tool_def()
  def discover_tools_spec(registry, session_id) do
    %{
      name: discover_tools_name(session_id),
      description:
        "Search all available tools in this session by keyword. " <>
          "Use this when the tool you need is not in the current focused set.",
      inputSchema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Search term to match against tool names and descriptions"
          }
        },
        required: ["query"]
      },
      callback: fn args ->
        query = String.downcase(args["query"] || "")

        matches =
          registry
          |> Raxol.MCP.Registry.list_tools()
          |> Enum.filter(fn tool ->
            name = tool[:name] || ""

            in_session?(name, session_id) and
              (String.downcase(name) =~ query or
                 String.downcase(tool[:description] || "") =~ query)
          end)
          |> Enum.map(fn tool ->
            %{name: tool[:name], description: tool[:description]}
          end)

        {:ok, [%{type: "text", text: inspect(matches)}]}
      end
    }
  end

  @doc "The name of the session's `discover_tools` meta-tool."
  @spec discover_tools_name(String.t()) :: String.t()
  def discover_tools_name(session_id), do: "#{session_id}.discover_tools"

  defp filter_focused(tools, nil, max_tools, scope) do
    (session_tools(tools, scope.session_id) ++ discover(scope) ++ global_tools(tools))
    |> Enum.uniq_by(& &1.name)
    |> Enum.take(max_tools)
  end

  defp filter_focused(tools, focused_id, max_tools, scope) do
    (widget_tools(tools, scope.session_id, focused_id) ++
       discover(scope) ++ global_tools(tools))
    |> Enum.uniq_by(& &1.name)
    |> Enum.take(max_tools)
  end

  defp filter_hover(tools, focused_id, nil, max_tools, scope) do
    filter_focused(tools, focused_id, max_tools, scope)
  end

  defp filter_hover(tools, focused_id, hover_id, max_tools, scope)
       when hover_id == focused_id do
    filter_focused(tools, focused_id, max_tools, scope)
  end

  defp filter_hover(tools, focused_id, hover_id, max_tools, scope) do
    focused_tools =
      if focused_id, do: widget_tools(tools, scope.session_id, focused_id), else: []

    hover_tools = widget_tools(tools, scope.session_id, hover_id)

    (focused_tools ++ hover_tools ++ discover(scope) ++ global_tools(tools))
    |> Enum.uniq_by(& &1.name)
    |> Enum.take(max_tools)
  end

  defp session_tools(tools, session_id) do
    Enum.filter(tools, &in_session?(&1.name, session_id))
  end

  defp widget_tools(tools, session_id, widget_id) do
    Enum.filter(
      tools,
      &match?([^session_id, ^widget_id, _], String.split(&1.name, ".", parts: 3))
    )
  end

  defp in_session?(name, session_id),
    do: match?([^session_id, _], String.split(name, ".", parts: 2))

  defp global_tools(tools) do
    Enum.reject(tools, &String.contains?(&1.name, "."))
  end

  defp discover(%{registry: nil}), do: []

  defp discover(%{registry: registry, session_id: session_id}),
    do: [discover_tools_spec(registry, session_id)]
end
