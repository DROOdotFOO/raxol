defmodule Raxol.Agent.Action.Dynamic do
  @moduledoc """
  A runtime-discovered tool that is NOT an Action module.

  The ReAct tool loop dispatches to Action *modules* (compile-time
  `use Raxol.Agent.Action`). External tools discovered at runtime -- primarily
  the tools of an external MCP server reached through `Raxol.MCP.Client` -- have
  no module. A `Dynamic` wraps such a tool as a value the loop can offer and
  call alongside module Actions: it carries the LLM-facing `name`, a
  `description`, the JSON-Schema `input_schema`, a `sensitive` flag, and an
  `invoke` function `(params, context -> {:ok, map()} | {:error, term()})`.

  `Raxol.Agent.Action.ToolConverter` accepts a `Dynamic` anywhere an Action
  module is accepted, so a dynamic tool runs through the SAME authorizer and
  tool-call hook chain as a module Action -- it is not a bypass. Put dynamic
  tools in the `:actions` list handed to `Raxol.Agent.Stream.react/2`.

  A discovered tool is `sensitive: true` by default: an external MCP server's
  capabilities (filesystem writes, network fetch, git, ...) are unknown, so the
  safe posture is that the default authorizer (`ToolPolicy.deny_sensitive`) gates
  them until an operator opts in (a `:tool_authorizer` in context, or a spec that
  marks the server non-sensitive). A caller that knows a tool is read-only can
  pass `sensitive: false` to `from_mcp/4`.

  Dynamic tools are a framework-react concern: a native (vendor-owns-loop)
  backend reaches its MCP servers directly, so it does not consume these.
  """

  @enforce_keys [:name, :invoke]
  defstruct [:name, :invoke, description: "", input_schema: %{}, sensitive: false]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          sensitive: boolean(),
          invoke: (map(), map() -> {:ok, map()} | {:error, term()})
        }

  @doc """
  The LLM tool definition, in the same outer shape an Action module's
  `to_tool_definition/0` produces (see `Raxol.Agent.Action.Schema.to_json_schema/3`).
  """
  @spec to_tool_definition(t()) :: map()
  def to_tool_definition(%__MODULE__{} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => parameters(tool.input_schema)
      }
    }
  end

  # MCP servers give a JSON-Schema object directly; pass it through, or default
  # to an empty object schema when a tool declares no inputs.
  defp parameters(schema) when is_map(schema) and map_size(schema) > 0, do: schema
  defp parameters(_), do: %{"type" => "object", "properties" => %{}}

  @doc """
  Build `Dynamic` tools from an external MCP server's discovered tool list.

  `server` is the `Raxol.MCP.Client` GenServer ref, `server_name` the atom used
  to namespace the LLM-facing name (`mcp__<server_name>__<tool>`). Each tool's
  `invoke` calls `Raxol.MCP.Client.call_tool/3` with the ORIGINAL (un-namespaced)
  tool name and string-keyed arguments. `tools` is the raw list from
  `Raxol.MCP.Client.list_tools/1` (string- or atom-keyed maps).

  `:sensitive` (default `true`) sets every wrapped tool's sensitivity; pass
  `false` only for a server known to be read-only/harmless.
  """
  @spec from_mcp(GenServer.server(), atom(), [map()], keyword()) :: [t()]
  def from_mcp(server, server_name, tools, opts \\ []) when is_list(tools) do
    sensitive = Keyword.get(opts, :sensitive, true)

    Enum.map(tools, fn tool ->
      raw = to_string(get(tool, :name) || "")

      %__MODULE__{
        name: Raxol.MCP.Client.tool_name(server_name, raw),
        description: to_string(get(tool, :description) || ""),
        input_schema: input_schema(tool),
        sensitive: sensitive,
        invoke: fn params, _context ->
          Raxol.MCP.Client.call_tool(server, raw, stringify(params))
        end
      }
    end)
  end

  @doc """
  List an MCP server's tools and wrap them as `Dynamic` tools.

  `{:ok, [t()]}`, or the `{:error, reason}` from `Raxol.MCP.Client.list_tools/1`.
  """
  @spec from_client(GenServer.server(), atom(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def from_client(server, server_name, opts \\ []) do
    case Raxol.MCP.Client.list_tools(server) do
      {:ok, tools} -> {:ok, from_mcp(server, server_name, tools, opts)}
      {:error, _} = err -> err
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp input_schema(tool),
    do:
      Map.get(tool, :input_schema) || Map.get(tool, "inputSchema") || Map.get(tool, :inputSchema) ||
        %{}

  # ToolConverter atomizes arg keys before dispatch; MCP wants the original
  # string names, so convert back at the boundary (top level is enough -- the
  # client JSON-encodes nested values).
  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: other
end
