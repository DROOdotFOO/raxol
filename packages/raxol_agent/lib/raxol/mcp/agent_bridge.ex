defmodule Raxol.MCP.AgentBridge do
  @moduledoc """
  Bridges Raxol Agent Actions to MCP tools.

  Converts Action modules (which implement the `Raxol.Agent.Action` behaviour)
  into MCP Registry tool definitions, allowing external MCP clients to invoke
  agent capabilities.

  ## Usage

      actions = [MyApp.Actions.ReadFile, MyApp.Actions.WriteFile]
      tools = AgentBridge.actions_to_mcp_tools(actions)
      Raxol.MCP.Registry.register_tools(registry, tools)
  """

  require Logger

  alias Raxol.MCP.TreeWalker

  @doc """
  Convert a list of Action modules to MCP tool definitions.

  Each Action module must implement `__action_meta__/0` and `call/2`.
  Tools are namespaced with `agent.` prefix. An Action whose meta says
  `sensitive: true` becomes a tool annotated `sensitive: true`, so
  `Raxol.MCP.Server` refuses it when no authorizer is configured.

  An Action's name, description and input schema reach the client's tool
  list as a widget provider's do, so they get the same treatment
  (`Raxol.MCP.TreeWalker.action_name?/1`, `Raxol.MCP.TreeWalker.clean_spec/2`):
  the description and every string and key of the schema are cleaned, and
  an Action whose name is not a lowercase letter followed by up to 31 of
  `[a-z0-9_]`, or whose spec is refused, becomes no tool and is logged as a
  warning.
  """
  @spec actions_to_mcp_tools([module()], map()) :: [
          Raxol.MCP.Registry.tool_def()
        ]
  def actions_to_mcp_tools(action_modules, context \\ %{}) do
    Enum.flat_map(action_modules, fn module ->
      meta = module.__action_meta__()

      with :ok <- check_action_name(meta.name),
           {:ok, description, input_schema} <-
             TreeWalker.clean_spec(meta.description, build_input_schema(meta.input_schema)) do
        [action_tool(module, meta, description, input_schema, context)]
      else
        {:error, fault} ->
          Logger.warning(
            "[MCP.AgentBridge] #{inspect(module)} action #{inspect(meta.name)} derives " <>
              "no tool: #{inspect(fault)}"
          )

          []
      end
    end)
  end

  defp check_action_name(name) do
    if TreeWalker.action_name?(name), do: :ok, else: {:error, :action_name}
  end

  defp action_tool(module, meta, description, input_schema, context) do
    %{
      name: "agent.#{meta.name}",
      description: description,
      inputSchema: input_schema,
      callback: fn args ->
        atomized = atomize_keys(args)

        case module.call(atomized, context) do
          {:ok, result} ->
            {:ok, [%{type: "text", text: inspect(result, pretty: true)}]}

          {:ok, result, _commands} ->
            {:ok, [%{type: "text", text: inspect(result, pretty: true)}]}

          {:error, reason} ->
            {:error, reason}
        end
      end
    }
    |> put_sensitive(Map.get(meta, :sensitive) == true)
  end

  defp put_sensitive(tool, true), do: Map.put(tool, :annotations, %{sensitive: true})
  defp put_sensitive(tool, false), do: tool

  # -- Private -----------------------------------------------------------------

  defp build_input_schema(schema) when is_list(schema) do
    {properties, required} =
      Enum.reduce(schema, {%{}, []}, fn {field, spec}, {props, req} ->
        type = Keyword.get(spec, :type, :string) |> to_string()
        desc = Keyword.get(spec, :description, "")

        prop = %{type: type}
        prop = if desc != "", do: Map.put(prop, :description, desc), else: prop

        props = Map.put(props, to_string(field), prop)

        req =
          if Keyword.get(spec, :required, false),
            do: [to_string(field) | req],
            else: req

        {props, req}
      end)

    schema = %{type: "object", properties: properties}

    if required != [],
      do: Map.put(schema, :required, Enum.reverse(required)),
      else: schema
  end

  defp build_input_schema(_), do: %{type: "object", properties: %{}}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> k
          end

        {atom, v}

      {k, v} ->
        {k, v}
    end)
  end
end
