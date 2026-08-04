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

  ## Elicitation

  When `Raxol.MCP.Authorizer` returns `{:ask, prompt}`, what happens depends on
  whether the client can be asked. A client that advertised the `elicitation`
  capability at `initialize` (and has a subscribed transport) is sent a real
  `elicitation/create` request; anything else gets the machine-readable
  `authorization_required` deny.

  The shape matters, because the transport seam is synchronous. `tools/call`
  returns `nil` **immediately** and the call is parked:

      client                     server                    transport
      tools/call  ------------->  ASK -> park, return nil ->  (unblocked)
                 <-------------  elicitation/create (push)
      response   ------------->  resume, return nil
                 <-------------  tools/call response (push)

  Returning `nil` is what keeps this from deadlocking: the transport's
  `handle_message` does not block, so it stays free to READ the client's
  answer. Both the prompt and the eventual response ride the subscriber
  channel, so no transport change was needed.

  A parked call is always closed, exactly once, by one of four paths: an
  approval (runs the tool), a decline/cancel/unapproved accept, an error
  response, or a timeout (`:elicitation_timeout_ms`, default 60s). Every path
  but approval resolves to the same deny -- silence is not consent.

  ## Sensitive tools

  A tool annotated `destructiveHint: true` or `sensitive: true` (see
  `Raxol.MCP.ToolDef.sensitive?/1`) must not be served without an authorizer.
  The server REFUSES TO BOOT when one is already registered, and denies at
  `tools/call` for one registered afterwards -- the boot check alone would be
  bypassable by registering late.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @compile {:no_warn_undefined, Raxol.Headless}

  alias Raxol.MCP.Authorizer
  alias Raxol.MCP.Protocol
  alias Raxol.MCP.Registry
  alias Raxol.MCP.ResourceRouter
  alias Raxol.MCP.ToolDef

  # A client that advertises elicitation but never answers must not park a
  # `tools/call` forever: on expiry the call is answered with the same
  # machine-readable deny it would have received without elicitation.
  @default_elicitation_timeout_ms 60_000

  defstruct [
    :registry,
    :authorizer,
    initialized: false,
    log_level: :info,
    subscribers: [],
    resource_subscriptions: %{},
    client_capabilities: %{},
    pending_elicitations: %{},
    elicitation_seq: 0,
    elicitation_timeout_ms: @default_elicitation_timeout_ms
  ]

  @type t :: %__MODULE__{
          registry: GenServer.server(),
          authorizer: Authorizer.t() | nil,
          initialized: boolean(),
          log_level:
            :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency,
          subscribers: [pid()],
          resource_subscriptions: %{String.t() => boolean()},
          client_capabilities: map(),
          pending_elicitations: %{String.t() => pending_elicitation()},
          elicitation_seq: non_neg_integer(),
          elicitation_timeout_ms: pos_integer()
        }

  @typedoc """
  A `tools/call` parked awaiting the client's elicitation answer. `request_id`
  is the ORIGINAL call's id -- the one the client is still waiting on.
  """
  @type pending_elicitation :: %{
          request_id: term(),
          tool: String.t(),
          arguments: map(),
          timer: reference()
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

  @doc """
  Whether an authorizer is configured on this server. Network transport boot
  guards use this to fail closed (see `Raxol.MCP.Deployment`). Returns `false` if
  the server is unreachable.
  """
  @spec authorization_configured?(GenServer.server()) :: boolean()
  def authorization_configured?(server \\ __MODULE__) do
    GenServer.call(server, :authorization_configured?)
  catch
    :exit, _ -> false
  end

  # -- GenServer Callbacks -------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    registry = Keyword.get(opts, :registry, Registry)
    authorizer = Keyword.get(opts, :authorizer)

    refuse_unguarded_sensitive_tools!(registry, authorizer)

    {:ok,
     %__MODULE__{
       registry: registry,
       authorizer: authorizer,
       elicitation_timeout_ms:
         Keyword.get(opts, :elicitation_timeout_ms, @default_elicitation_timeout_ms)
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:handle_message, message}, _from, state) do
    {response, state} = dispatch(message, state)
    {:reply, {:reply, response}, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:authorization_configured?, _from, state) do
    {:reply, state.authorizer != nil, state}
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

  # The client advertised elicitation, was asked, and never answered. Close the
  # parked call with the same deny it would have got had it never advertised --
  # an unanswered prompt is not an approval.
  def handle_manager_info({:elicitation_timeout, id}, state) do
    case Map.fetch(state.pending_elicitations, id) do
      {:ok, pending} ->
        {_pending, state} = take_pending(state, id)

        broadcast(
          state.subscribers,
          authorization_required(pending.request_id, pending.tool, :ask, "elicitation timed out")
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Dispatch -----------------------------------------------------------------

  defp dispatch(%{method: "initialize", id: id} = msg, state) do
    result = %{
      protocolVersion: Protocol.mcp_protocol_version(),
      capabilities: capabilities(),
      serverInfo: server_info()
    }

    # Remember what the CLIENT can do. `elicitation` is the one that changes
    # behaviour: it is the difference between denying an ASK and asking.
    client_capabilities =
      msg
      |> Map.get(:params, %{})
      |> fetch_field("capabilities", %{})

    state = %{state | initialized: true, client_capabilities: client_capabilities}
    {Protocol.response(id, result), state}
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

    # A sensitive tool with no authorizer never runs, whatever the transport.
    # The boot check catches this for tools present at start; this catches one
    # registered afterwards, which would otherwise slip past it.
    if state.authorizer == nil and sensitive_tool?(state.registry, name) do
      {authorization_required(id, name, :deny, :sensitive_tool_unguarded), state}
    else
      authorize_and_call(id, name, arguments, state)
    end
  end

  # The client's answer to an `elicitation/create` we sent. It arrives as an
  # ordinary inbound message, so it is dispatched like one -- but it is a
  # RESPONSE (id + result, no method), and it resumes a `tools/call` that is
  # still parked. Placed above the catch-all; an id we did not mint falls
  # through to it and is ignored.
  defp dispatch(%{id: id, result: result}, state)
       when is_map_key(state.pending_elicitations, id) do
    {pending, state} = take_pending(state, id)
    Process.cancel_timer(pending.timer)
    {nil, answer_parked(state, resume(pending, result, state))}
  end

  # An error response to our elicitation is a refusal, not a crash.
  defp dispatch(%{id: id, error: _}, state) when is_map_key(state.pending_elicitations, id) do
    {pending, state} = take_pending(state, id)
    Process.cancel_timer(pending.timer)

    {nil,
     answer_parked(
       state,
       authorization_required(pending.request_id, pending.tool, :ask, "elicitation failed")
     )}
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

  # An inbound RESPONSE (id + result/error, no method) whose id we did not mint:
  # a late answer to an elicitation that already timed out, or a stray. JSON-RPC
  # says ignore it. Answering "Missing method" would bounce an error response AT
  # a response, which a strict peer can answer in turn -- a loop. Must sit above
  # the malformed-message clause, which would otherwise claim it.
  defp dispatch(msg, state) when is_map_key(msg, :result) or is_map_key(msg, :error) do
    {nil, state}
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

  defp call_tool_response(id, name, result) do
    case result do
      {:ok, result} ->
        Protocol.response(id, %{content: normalize_content(result)})

      {:error, :tool_not_found} ->
        Protocol.error_response(id, Protocol.method_not_found(), "Tool not found: #{name}")

      {:error, :circuit_open} ->
        content = [
          %{
            type: "text",
            text: "Tool temporarily unavailable (circuit open after repeated failures)"
          }
        ]

        Protocol.response(id, %{content: content, isError: true})

      {:error, reason} ->
        content = [%{type: "text", text: "Error: #{inspect(reason)}"}]
        Protocol.response(id, %{content: content, isError: true})
    end
  end

  # A denied tool call returns a machine-readable error result the agent can act
  # on (learn the tool is gated) instead of a silent failure or a retry loop.
  defp authorization_required(id, tool, decision, detail) do
    payload = %{
      "error" => "authorization_required",
      "tool" => tool,
      "decision" => Atom.to_string(decision),
      "detail" => authz_detail(detail)
    }

    content = [%{type: "text", text: Jason.encode!(payload)}]
    Protocol.response(id, %{content: content, isError: true})
  end

  defp authz_detail(detail) when is_binary(detail), do: detail
  defp authz_detail(detail), do: inspect(detail)

  defp normalize_content(result) when is_list(result), do: result
  defp normalize_content(text) when is_binary(text), do: [%{type: "text", text: text}]
  defp normalize_content(other), do: [%{type: "text", text: inspect(other, pretty: true)}]

  # -- Sensitive-tool guard -----------------------------------------------------

  defp authorize_and_call(id, name, arguments, state) do
    # Authorize before the tool runs. A nil authorizer allows (stdio inherits
    # the OS boundary).
    case Authorizer.decide(state.authorizer, name, arguments, %{}) do
      :allow ->
        {call_tool_response(id, name, Registry.call_tool(state.registry, name, arguments)), state}

      {:ask, prompt} ->
        ask(id, name, arguments, prompt, state)

      {:deny, reason} ->
        {authorization_required(id, name, :deny, reason), state}
    end
  end

  # Registering a tool that declares itself destructive/sensitive while no
  # authorizer is configured is a REFUSAL, not a warning: the whole point of the
  # annotation is that this tool must not run unattended, and booting anyway
  # would serve it wide open. The fix is one line at the call site -- pass an
  # authorizer (`Raxol.MCP.Authorizer.allow_all/0` if that is genuinely what you
  # want, which is at least then visible in the code).
  defp refuse_unguarded_sensitive_tools!(_registry, authorizer) when authorizer != nil, do: :ok

  defp refuse_unguarded_sensitive_tools!(registry, _authorizer) do
    case sensitive_tool_names(registry) do
      [] ->
        :ok

      names ->
        raise ArgumentError,
              "Raxol.MCP.Server refuses to boot: #{length(names)} tool(s) are annotated " <>
                "sensitive/destructive but no :authorizer is configured -- " <>
                "#{Enum.join(names, ", ")}. Pass an authorizer to start_link/1 " <>
                "(Raxol.MCP.Authorizer.allow_all/0 opts out, explicitly)."
    end
  end

  defp sensitive_tool_names(registry) do
    registry
    |> Registry.list_tools()
    |> Enum.filter(&ToolDef.sensitive?/1)
    |> Enum.map(&(Map.get(&1, :name) || Map.get(&1, "name")))
  catch
    # A registry that is not up yet cannot be scanned. Absence of evidence is
    # not evidence of absence, but refusing to boot on it would make the server
    # un-startable in every registry-after-server tree -- the runtime backstop
    # in tools/call is what actually holds the line there.
    :exit, _ -> []
  end

  defp sensitive_tool?(registry, name) do
    registry
    |> Registry.list_tools()
    |> Enum.any?(fn tool ->
      (Map.get(tool, :name) || Map.get(tool, "name")) == name and ToolDef.sensitive?(tool)
    end)
  catch
    :exit, _ -> false
  end

  # -- Elicitation --------------------------------------------------------------

  # An ASK with no way to ask is a deny. Elicitation needs BOTH a client that
  # advertised the capability AND a transport subscribed to carry the request --
  # without a subscriber the prompt would go nowhere and the call would park
  # until it timed out, which is strictly worse than answering now.
  defp ask(id, tool, arguments, prompt, state) do
    if elicitation_capable?(state) do
      start_elicitation(id, tool, arguments, prompt, state)
    else
      {authorization_required(id, tool, :ask, prompt), state}
    end
  end

  defp elicitation_capable?(state) do
    state.subscribers != [] and
      fetch_field(state.client_capabilities, "elicitation", nil) != nil
  end

  # Park the call and ask. Returning `nil` is what makes this safe on a
  # synchronous transport: the transport's `handle_message` returns immediately
  # instead of blocking, so it stays free to READ the client's answer. Both the
  # prompt and the eventual response go out over the subscriber channel.
  defp start_elicitation(request_id, tool, arguments, prompt, state) do
    seq = state.elicitation_seq + 1
    elicit_id = "raxol-elicit-#{seq}"

    timer =
      Process.send_after(self(), {:elicitation_timeout, elicit_id}, state.elicitation_timeout_ms)

    pending = %{request_id: request_id, tool: tool, arguments: arguments, timer: timer}

    state = %{
      state
      | elicitation_seq: seq,
        pending_elicitations: Map.put(state.pending_elicitations, elicit_id, pending)
    }

    broadcast(state.subscribers, elicitation_request(elicit_id, tool, prompt))
    {nil, state}
  end

  # A server-initiated id lives in the SERVER's id space; a string prefix keeps
  # it from ever colliding with a client's integer request ids.
  defp elicitation_request(elicit_id, tool, prompt) do
    Protocol.request(elicit_id, "elicitation/create", %{
      message: prompt,
      requestedSchema: %{
        type: "object",
        properties: %{
          approve: %{
            type: "boolean",
            description: "Approve running the #{tool} tool"
          }
        },
        required: ["approve"]
      }
    })
  end

  # The parked call is answered by PUSH, never as the reply to the message that
  # unparked it: what arrived was a JSON-RPC *response*, and a response never
  # gets a reply. This also makes all three resolutions -- answered, errored,
  # timed out -- take one identical path out.
  defp answer_parked(state, response) do
    broadcast(state.subscribers, response)
    state
  end

  defp take_pending(state, id) do
    {pending, rest} = Map.pop(state.pending_elicitations, id)
    {pending, %{state | pending_elicitations: rest}}
  end

  # Only an explicit accept-with-approval runs the tool. Decline, cancel, a
  # missing action, and accept-without-approval all fail closed -- the same
  # direction absence takes everywhere else in this seam.
  defp resume(pending, result, state) do
    action = fetch_field(result, "action", nil)
    content = fetch_field(result, "content", %{})

    if action == "accept" and fetch_field(content, "approve", false) == true do
      call_tool_response(
        pending.request_id,
        pending.tool,
        Registry.call_tool(state.registry, pending.tool, pending.arguments)
      )
    else
      authorization_required(
        pending.request_id,
        pending.tool,
        :ask,
        "user #{action || "declined"}"
      )
    end
  end

  # Decoded wire maps carry atom keys; hand-built ones may carry strings.
  defp fetch_field(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key), default)
    end
  rescue
    ArgumentError -> default
  end

  defp fetch_field(_map, _key, default), do: default

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
