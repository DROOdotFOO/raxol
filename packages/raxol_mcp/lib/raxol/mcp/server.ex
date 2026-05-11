defmodule Raxol.MCP.Server do
  @moduledoc """
  Transport-agnostic MCP server.

  Receives decoded JSON-RPC messages, dispatches to the Registry for tool/resource
  operations, and returns response maps. Transports (stdio, SSE) call
  `handle_message/2` and write the response back over their I/O channel.

  ## Supported Methods

  - `initialize` -- MCP handshake, returns server capabilities
  - `notifications/initialized` -- client acknowledgement (no reply)
  - `ping` -- health check
  - `tools/list` -- list registered tools
  - `tools/call` -- invoke a tool
  - `resources/list` -- list registered resources
  - `resources/read` -- read a resource
  - `prompts/list` -- list registered prompts
  - `prompts/get` -- render a prompt with arguments
  - `logging/setLevel` -- set server log level
  - `completion/complete` -- auto-complete tool arguments

  ## Notifications

  The server can push notifications to connected transports. Transports
  subscribe via `subscribe/2` and receive `{:mcp_notification, map()}` messages.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @compile {:no_warn_undefined, Raxol.Headless}

  alias Raxol.MCP.Protocol
  alias Raxol.MCP.Registry
  alias Raxol.MCP.ResourceRouter

  defstruct [
    :registry,
    initialized: false,
    log_level: :info,
    subscribers: [],
    resource_subscriptions: %{}
  ]

  @type t :: %__MODULE__{
          registry: GenServer.server(),
          initialized: boolean(),
          log_level:
            :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency,
          subscribers: [pid()],
          resource_subscriptions: %{String.t() => boolean()}
        }

  @log_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @level_map Map.new(@log_levels, fn l -> {Atom.to_string(l), l} end)

  # -- Client API ---------------------------------------------------------------

  @doc "Start the server, linked to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Handle a decoded JSON-RPC message.

  Returns `{:reply, response_map}` for requests or `{:reply, nil}` for
  notifications (no response needed).
  """
  @spec handle_message(GenServer.server(), map()) :: {:reply, map() | nil}
  def handle_message(server \\ __MODULE__, message) do
    GenServer.call(server, {:handle_message, message})
  end

  @doc """
  Subscribe a transport process to server notifications.

  The subscriber receives `{:mcp_notification, notification_map}` messages.
  Automatically unsubscribes when the subscriber process exits.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid) do
    GenServer.cast(server, {:subscribe, pid})
  end

  @doc "Send a notification to all subscribed transports."
  @spec notify(GenServer.server(), String.t(), map()) :: :ok
  def notify(server \\ __MODULE__, method, params \\ %{}) do
    GenServer.cast(server, {:notify, method, params})
  end

  # -- GenServer Callbacks -------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    registry = Keyword.get(opts, :registry, Registry)
    {:ok, %__MODULE__{registry: registry}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:handle_message, message}, _from, state) do
    {response, state} = dispatch(message, state)
    {:reply, {:reply, response}, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:subscribe, pid}, state) do
    if pid in state.subscribers do
      {:noreply, state}
    else
      Process.monitor(pid)
      {:noreply, %{state | subscribers: [pid | state.subscribers]}}
    end
  end

  def handle_manager_cast({:notify, method, params}, state) do
    notification = Protocol.notification(method, params)
    broadcast(state.subscribers, notification)
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Dispatch -----------------------------------------------------------------

  defp dispatch(%{method: "initialize", id: id}, state) do
    result = %{
      protocolVersion: Protocol.mcp_protocol_version(),
      capabilities: capabilities(),
      serverInfo: server_info()
    }

    {Protocol.response(id, result), %{state | initialized: true}}
  end

  defp dispatch(%{method: "notifications/initialized"}, state) do
    {nil, state}
  end

  defp dispatch(%{method: "ping", id: id}, state) do
    {Protocol.response(id, %{}), state}
  end

  # -- Tools ---

  defp dispatch(%{method: "tools/list", id: id}, state) do
    tools = Registry.list_tools(state.registry)
    {Protocol.response(id, %{tools: tools}), state}
  end

  defp dispatch(%{method: "tools/call", id: id, params: params}, state) do
    name = Map.get(params, "name") || Map.get(params, :name, "")
    arguments = Map.get(params, "arguments") || Map.get(params, :arguments, %{})

    case Registry.call_tool(state.registry, name, arguments) do
      {:ok, result} ->
        content = normalize_content(result)
        {Protocol.response(id, %{content: content}), state}

      {:error, :tool_not_found} ->
        error =
          Protocol.error_response(id, Protocol.method_not_found(), "Tool not found: #{name}")

        {error, state}

      {:error, :circuit_open} ->
        content = [
          %{
            type: "text",
            text: "Tool temporarily unavailable (circuit open after repeated failures)"
          }
        ]

        {Protocol.response(id, %{content: content, isError: true}), state}

      {:error, reason} ->
        content = [%{type: "text", text: "Error: #{inspect(reason)}"}]
        {Protocol.response(id, %{content: content, isError: true}), state}
    end
  end

  # -- Resources ---

  defp dispatch(%{method: "resources/list", id: id}, state) do
    resources = Registry.list_resources(state.registry)
    {Protocol.response(id, %{resources: resources}), state}
  end

  defp dispatch(%{method: "resources/subscribe", id: id, params: params}, state) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")
    # Track that this URI has active subscribers. Notifications for
    # subscribed URIs go to all transport-level subscribers.
    new_subs = Map.put_new(state.resource_subscriptions, uri, true)
    {Protocol.response(id, %{}), %{state | resource_subscriptions: new_subs}}
  end

  defp dispatch(%{method: "resources/unsubscribe", id: id, params: params}, state) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")
    new_subs = Map.delete(state.resource_subscriptions, uri)
    {Protocol.response(id, %{}), %{state | resource_subscriptions: new_subs}}
  end

  defp dispatch(%{method: "resources/read", id: id, params: params}, state) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")

    case ResourceRouter.resolve(state.registry, uri) do
      {:ok, content} ->
        {text, mime} = format_resource_content(content)

        result = %{
          contents: [%{uri: uri, text: text, mimeType: mime}]
        }

        {Protocol.response(id, result), state}

      {:error, :resource_not_found} ->
        error =
          Protocol.error_response(id, Protocol.invalid_params(), "Resource not found: #{uri}")

        {error, state}

      {:error, :circuit_open} ->
        error =
          Protocol.error_response(
            id,
            Protocol.internal_error(),
            "Resource temporarily unavailable (circuit open)"
          )

        {error, state}

      {:error, reason} ->
        error = Protocol.error_response(id, Protocol.internal_error(), inspect(reason))
        {error, state}
    end
  end

  # -- Prompts ---

  defp dispatch(%{method: "prompts/list", id: id}, state) do
    prompts = Registry.list_prompts(state.registry)
    {Protocol.response(id, %{prompts: prompts}), state}
  end

  defp dispatch(%{method: "prompts/get", id: id, params: params}, state) do
    name = Map.get(params, "name") || Map.get(params, :name, "")
    arguments = Map.get(params, "arguments") || Map.get(params, :arguments, %{})

    case Registry.get_prompt(state.registry, name, arguments) do
      {:ok, messages} ->
        {Protocol.response(id, %{messages: messages}), state}

      {:error, :prompt_not_found} ->
        error =
          Protocol.error_response(
            id,
            Protocol.method_not_found(),
            "Prompt not found: #{name}"
          )

        {error, state}

      {:error, reason} ->
        error = Protocol.error_response(id, Protocol.internal_error(), inspect(reason))
        {error, state}
    end
  end

  # -- Logging ---

  defp dispatch(%{method: "logging/setLevel", id: id, params: params}, state) do
    level_str = Map.get(params, "level") || Map.get(params, :level, "info")

    case Map.fetch(@level_map, level_str) do
      {:ok, level} ->
        Logger.info("[MCP.Server] Log level set to #{level}")
        {Protocol.response(id, %{}), %{state | log_level: level}}

      :error ->
        error =
          Protocol.error_response(
            id,
            Protocol.invalid_params(),
            "Invalid log level: #{level_str}. Valid: #{inspect(@log_levels)}"
          )

        {error, state}
    end
  end

  # -- Completion ---

  defp dispatch(%{method: "completion/complete", id: id, params: params}, state) do
    ref = Map.get(params, "ref") || Map.get(params, :ref, %{})
    argument = Map.get(params, "argument") || Map.get(params, :argument, %{})

    completions = compute_completions(ref, argument, state)

    {Protocol.response(id, %{completion: %{values: completions}}), state}
  end

  # -- Catch-all ---

  # Notifications we don't handle -- no response
  defp dispatch(%{method: _method} = msg, state) when not is_map_key(msg, :id) do
    {nil, state}
  end

  # Unknown method with an id -- error response
  defp dispatch(%{method: method, id: id}, state) do
    error = Protocol.error_response(id, Protocol.method_not_found(), "Unknown method: #{method}")
    {error, state}
  end

  # Malformed message
  defp dispatch(%{id: id}, state) do
    error = Protocol.error_response(id, Protocol.invalid_request(), "Missing method")
    {error, state}
  end

  defp dispatch(_msg, state) do
    {nil, state}
  end

  # -- Helpers ------------------------------------------------------------------

  defp capabilities do
    %{
      tools: %{listChanged: true},
      resources: %{subscribe: true, listChanged: true},
      prompts: %{listChanged: false},
      logging: %{}
    }
  end

  defp server_info do
    %{name: "raxol", version: RaxolMcp.version()}
  end

  defp format_resource_content(text) when is_binary(text), do: {text, "text/plain"}

  defp format_resource_content(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> {json, "application/json"}
      {:error, _} -> {inspect(data, pretty: true), "text/plain"}
    end
  end

  defp normalize_content(result) when is_list(result), do: result
  defp normalize_content(text) when is_binary(text), do: [%{type: "text", text: text}]
  defp normalize_content(other), do: [%{type: "text", text: inspect(other, pretty: true)}]

  defp broadcast(subscribers, notification) do
    for pid <- subscribers, Process.alive?(pid) do
      send(pid, {:mcp_notification, notification})
    end
  end

  defp compute_completions(ref, argument, state) do
    ref_type = Map.get(ref, "type") || Map.get(ref, :type, "")
    arg_name = Map.get(argument, "name") || Map.get(argument, :name, "")
    arg_value = Map.get(argument, "value") || Map.get(argument, :value, "")

    case {ref_type, arg_name} do
      {"ref/tool", "id"} ->
        # Complete session IDs from headless tools
        complete_session_ids(arg_value)

      {"ref/tool", "name"} ->
        # Complete tool names
        tools = Registry.list_tools(state.registry)

        tools
        |> Enum.map(& &1.name)
        |> Enum.filter(&String.starts_with?(&1, arg_value))
        |> Enum.take(20)

      {"ref/prompt", _} ->
        prompts = Registry.list_prompts(state.registry)

        prompts
        |> Enum.map(& &1.name)
        |> Enum.filter(&String.starts_with?(&1, arg_value))
        |> Enum.take(20)

      {"ref/resource", _} ->
        resources = Registry.list_resources(state.registry)

        resources
        |> Enum.map(& &1.uri)
        |> Enum.filter(&String.starts_with?(&1, arg_value))
        |> Enum.take(20)

      _ ->
        []
    end
  end

  defp complete_session_ids(prefix) do
    if Code.ensure_loaded?(Raxol.Headless) and
         function_exported?(Raxol.Headless, :list, 0) do
      case Raxol.Headless.list() do
        {:ok, sessions} ->
          sessions
          |> Enum.map(fn s -> Map.get(s, :id, "") |> to_string() end)
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.take(20)

        _ ->
          []
      end
    else
      []
    end
  end
end
