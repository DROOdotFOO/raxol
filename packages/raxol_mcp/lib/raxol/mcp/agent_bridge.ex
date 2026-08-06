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

  The bridge also provides meta-tools for agent management:
  `agent.list`, `agent.send`, `agent.get_model`.
  """

  @compile {:no_warn_undefined, [Raxol.Agent.Registry, Raxol.Headless]}

  @doc """
  Convert a list of Action modules to MCP tool definitions.

  Each Action module must implement `__action_meta__/0` and `call/2`.
  Tools are namespaced with `agent.` prefix.
  """
  @spec actions_to_mcp_tools([module()], map()) :: [
          Raxol.MCP.Registry.tool_def()
        ]
  def actions_to_mcp_tools(action_modules, context \\ %{}) do
    Enum.map(action_modules, fn module ->
      meta = module.__action_meta__()
      input_schema = build_input_schema(meta.input_schema)

      %{
        name: "agent.#{meta.name}",
        description: meta.description,
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
    end)
  end

  @doc """
  Returns meta-tools for agent management: list, send, get_model.
  """
  @spec meta_tools() :: [Raxol.MCP.Registry.tool_def()]
  def meta_tools do
    [
      %{
        name: "agent.list",
        description:
          "List all active agent sessions with their IDs and status.",
        inputSchema: %{type: "object", properties: %{}},
        callback: &list_agents/1
      },
      %{
        name: "agent.send",
        description: "Send a message to a running agent session.",
        inputSchema: %{
          type: "object",
          required: ["id", "message"],
          properties: %{
            id: %{type: "string", description: "Agent session ID"},
            message: %{
              type: "string",
              description: "Message to send to the agent"
            }
          }
        },
        callback: &send_to_agent/1
      },
      %{
        name: "agent.get_model",
        description: "Get the current TEA model state of an agent session.",
        inputSchema: %{
          type: "object",
          required: ["id"],
          properties: %{
            id: %{type: "string", description: "Agent session ID"}
          }
        },
        callback: &get_agent_model/1
      }
    ]
  end

  # -- Callbacks ---------------------------------------------------------------

  defp list_agents(_args) do
    sessions =
      if Code.ensure_loaded?(Raxol.Headless) and
           function_exported?(Raxol.Headless, :list, 0) do
        # Headless.list/0 returns a bare list (and [] on exit).
        case Raxol.Headless.list() do
          list when is_list(list) -> list
          {:ok, list} when is_list(list) -> list
          _ -> []
        end
      else
        []
      end

    text =
      if sessions == [] do
        "No active agent sessions."
      else
        sessions
        |> Enum.map(fn s -> "- #{inspect(s)}" end)
        |> Enum.join("\n")
      end

    {:ok, [%{type: "text", text: text}]}
  end

  defp send_to_agent(%{"id" => id, "message" => message}) do
    send_to_agent(%{id: id, message: message})
  end

  defp send_to_agent(%{id: id, message: message}) do
    if Code.ensure_loaded?(Raxol.Headless) and
         function_exported?(Raxol.Headless, :send_key, 3) do
      case existing_session_atom(id) do
        {:ok, session} ->
          # Send the message as individual keystrokes, and report honestly:
          # a failed keystroke must not be summarized as success.
          results =
            for char <- String.graphemes(message) do
              Raxol.Headless.send_key(session, char, [])
            end

          case Enum.reject(results, &(&1 == :ok)) do
            [] ->
              {:ok,
               [
                 %{
                   type: "text",
                   text:
                     "Enqueued #{String.length(message)} keystrokes for agent #{id}"
                 }
               ]}

            failures ->
              {:error,
               "#{length(failures)}/#{length(results)} keystrokes failed for " <>
                 "agent #{id}: #{inspect(List.first(failures))}"}
          end

        {:error, :unknown_session} ->
          {:error, "Unknown agent session: #{id}"}
      end
    else
      {:error, "Headless module not available"}
    end
  end

  defp send_to_agent(_), do: {:error, "Missing required arguments: id, message"}

  defp get_agent_model(%{"id" => id}), do: get_agent_model(%{id: id})

  defp get_agent_model(%{id: id}) do
    if Code.ensure_loaded?(Raxol.Headless) and
         function_exported?(Raxol.Headless, :get_model, 1) do
      with {:ok, session} <- existing_session_atom(id),
           {:ok, model} <- Raxol.Headless.get_model(session) do
        {:ok,
         [%{type: "text", text: inspect(model, pretty: true, limit: :infinity)}]}
      else
        {:error, :unknown_session} -> {:error, "Unknown agent session: #{id}"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Headless module not available"}
    end
  end

  defp get_agent_model(_), do: {:error, "Missing required argument: id"}

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

  # Session ids arrive as caller-supplied strings on an externally callable
  # surface. A live headless session's id atom already exists in this VM, so
  # to_existing_atom succeeds exactly when the session could exist; minting a
  # new atom here (String.to_atom) would let callers grow the atom table.
  defp existing_session_atom(id) when is_binary(id) do
    {:ok, String.to_existing_atom(id)}
  rescue
    ArgumentError -> {:error, :unknown_session}
  end

  defp existing_session_atom(id) when is_atom(id), do: {:ok, id}

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
