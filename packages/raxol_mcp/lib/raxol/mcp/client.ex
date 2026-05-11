defmodule Raxol.MCP.Client do
  @moduledoc """
  MCP (Model Context Protocol) client for consuming external tool servers.

  Manages a stdio-based MCP server process: spawns it, performs the
  `initialize` handshake, discovers available tools via `tools/list`,
  and executes tool calls via `tools/call`.

  ## Usage

      {:ok, client} = Client.start_link(
        name: :my_server,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      {:ok, tools} = Client.list_tools(client)
      {:ok, result} = Client.call_tool(client, "read_file", %{path: "/tmp/hello.txt"})
      Client.stop(client)

  ## Tool Namespacing

  Tools are namespaced with the server name prefix: `mcp__<server>__<tool>`.
  Use `tool_name/2` to build namespaced names, and `parse_tool_name/1` to
  decompose them.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.MCP.Protocol

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @type call_result :: %{
          content: [map()],
          is_error: boolean()
        }

  defstruct [
    :name,
    :command,
    :args,
    :env,
    :port,
    :buffer,
    :pending,
    :tools,
    :registry,
    next_id: 1,
    status: :starting,
    call_timeout: 30_000
  ]

  @type t :: %__MODULE__{
          name: atom(),
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          port: port() | nil,
          buffer: String.t(),
          pending: %{pos_integer() => GenServer.from() | :init},
          tools: [tool()] | nil,
          registry: atom() | nil,
          next_id: pos_integer(),
          status: :starting | :initializing | :ready | :closed,
          call_timeout: pos_integer()
        }

  @default_call_timeout 30_000

  # -- Client API ---------------------------------------------------------------

  @doc "Start an MCP client linked to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    registry = Keyword.get(opts, :registry)
    gen_opts = if registry, do: [name: via(name, registry)], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "List tools available on the MCP server."
  @spec list_tools(GenServer.server(), keyword()) :: {:ok, [tool()]} | {:error, term()}
  def list_tools(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout)
    GenServer.call(server, :list_tools, timeout)
  end

  @doc "Call a tool on the MCP server."
  @spec call_tool(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, call_result()} | {:error, term()}
  def call_tool(server, tool_name, arguments \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout)
    GenServer.call(server, {:call_tool, tool_name, arguments}, timeout)
  end

  @doc "Get the client's current status."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Stop the MCP server and client."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @doc "Build a namespaced tool name: `mcp__<server>__<tool>`."
  @spec tool_name(atom(), String.t()) :: String.t()
  def tool_name(server_name, tool) do
    normalized = server_name |> to_string() |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    "mcp__#{normalized}__#{tool}"
  end

  @doc "Parse a namespaced tool name into `{server, tool}` or `:error`."
  @spec parse_tool_name(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_tool_name("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] -> {:ok, {server, tool}}
      _ -> :error
    end
  end

  def parse_tool_name(_), do: :error

  # -- Server Callbacks ---------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    name = Keyword.fetch!(opts, :name)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])
    registry = Keyword.get(opts, :registry)

    call_timeout = Keyword.get(opts, :call_timeout, @default_call_timeout)

    state = %__MODULE__{
      name: name,
      command: command,
      args: args,
      env: env,
      buffer: "",
      pending: %{},
      status: :starting,
      registry: registry,
      call_timeout: call_timeout
    }

    {:ok, state, {:continue, :spawn_server}}
  end

  @impl GenServer
  def handle_continue(:spawn_server, state) do
    charlist_env =
      Enum.map(state.env, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    port_opts =
      [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        :use_stdio,
        :stderr_to_stdout,
        args: state.args
      ]
      |> maybe_add_opt(:env, if(charlist_env != [], do: charlist_env))

    port =
      Port.open(
        {:spawn_executable, find_executable(state.command)},
        port_opts
      )

    state = %{state | port: port, status: :initializing}
    send_initialize(state)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:list_tools, _from, %{status: :ready, tools: tools} = state)
      when is_list(tools) do
    {:reply, {:ok, tools}, state}
  end

  def handle_manager_call(:list_tools, from, %{status: :ready} = state) do
    {state, id} = next_id(state)
    state = register_pending(state, id, from)
    send_request(state, id, "tools/list", %{})
    {:noreply, state}
  end

  def handle_manager_call(:list_tools, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  def handle_manager_call({:call_tool, tool_name, arguments}, from, %{status: :ready} = state) do
    {state, id} = next_id(state)
    state = register_pending(state, id, from)
    send_request(state, id, "tools/call", %{name: tool_name, arguments: arguments})
    {:noreply, state}
  end

  def handle_manager_call({:call_tool, _tool, _args}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  def handle_manager_call(:status, _from, state) do
    info = %{
      name: state.name,
      status: state.status,
      tools: if(state.tools, do: length(state.tools), else: nil),
      pending: map_size(state.pending)
    }

    {:reply, info, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(line, state)
  end

  def handle_manager_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_manager_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[MCP.Client] Server #{state.name} exited with status #{code}")

    Enum.each(state.pending, fn {_id, from} ->
      reply(from, {:error, {:server_exited, code}})
    end)

    {:noreply, %{state | port: nil, status: :closed, pending: %{}}}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port} = _state) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Private: Message Handling ------------------------------------------------

  defp handle_line(line, state) do
    full_line = state.buffer <> line
    state = %{state | buffer: ""}

    case Protocol.decode(full_line) do
      {:ok, msg} ->
        handle_message(msg, state)

      {:error, _reason} ->
        Logger.debug("[MCP.Client] Ignoring non-JSON line: #{String.slice(full_line, 0, 100)}")

        {:noreply, state}
    end
  end

  defp handle_message(%{id: id, result: result}, state) do
    pop_pending(state, id, fn from, state ->
      handle_result(result, from, state)
    end)
  end

  defp handle_message(%{id: id, error: error}, state) do
    pop_pending(state, id, fn from, state ->
      reply(from, {:error, error})
      {:noreply, state}
    end)
  end

  defp handle_message(%{method: _}, state), do: {:noreply, state}
  defp handle_message(_msg, state), do: {:noreply, state}

  defp pop_pending(state, id, callback) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.debug("[MCP.Client] Response for unknown id #{id}")
        {:noreply, state}

      {from, pending} ->
        callback.(from, %{state | pending: pending})
    end
  end

  defp handle_result(result, _from, %{status: :initializing} = state) do
    server_info = Map.get(result, "serverInfo", %{})
    Logger.info("[MCP.Client] Server #{state.name} initialized: #{inspect(server_info)}")
    state = %{state | status: :ready}
    send_notification(state, "notifications/initialized", %{})
    {:noreply, state}
  end

  defp handle_result(%{"tools" => tools}, from, state) do
    parsed_tools = Enum.map(tools, &parse_tool/1)
    reply(from, {:ok, parsed_tools})
    {:noreply, %{state | tools: parsed_tools}}
  end

  defp handle_result(result, from, state) do
    call_result = %{
      content: Map.get(result, "content", []),
      is_error: Map.get(result, "isError", false)
    }

    reply(from, {:ok, call_result})
    {:noreply, state}
  end

  defp reply(:init, _response), do: :ok
  defp reply(from, response), do: GenServer.reply(from, response)

  # -- Private: Protocol -------------------------------------------------------

  defp send_initialize(state) do
    {state, id} = next_id(state)

    params = %{
      protocolVersion: Protocol.mcp_protocol_version(),
      capabilities: %{},
      clientInfo: %{name: "raxol", version: RaxolMcp.version()}
    }

    state = register_pending(state, id, :init)
    send_request(state, id, "initialize", params)
    {:noreply, state}
  end

  defp send_request(state, id, method, params) do
    msg = Protocol.request(id, method, params)
    send_to_port(state, msg)
  end

  defp send_notification(state, method, params) do
    msg = Protocol.notification(method, params)
    send_to_port(state, msg)
  end

  defp send_to_port(%{port: port}, msg) when is_port(port) do
    case Protocol.encode(msg) do
      {:ok, data} -> Port.command(port, data)
      {:error, reason} -> Logger.warning("[MCP.Client] Failed to encode: #{inspect(reason)}")
    end
  end

  defp send_to_port(_, _), do: :ok

  # -- Private: Helpers ---------------------------------------------------------

  defp next_id(state) do
    {%{state | next_id: state.next_id + 1}, state.next_id}
  end

  defp register_pending(state, id, from) do
    %{state | pending: Map.put(state.pending, id, from)}
  end

  defp parse_tool(tool_map) do
    %{
      name: Map.get(tool_map, "name", ""),
      description: Map.get(tool_map, "description", ""),
      input_schema: Map.get(tool_map, "inputSchema", %{})
    }
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> String.to_charlist(command)
      path -> String.to_charlist(path)
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: [{key, value} | opts]

  defp via(name, registry) do
    {:via, Registry, {registry, {:mcp_client, name}}}
  end
end
