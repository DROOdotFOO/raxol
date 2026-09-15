defmodule Raxol.MCP.Client do
  @moduledoc """
  MCP (Model Context Protocol) client for consuming external tool servers.

  One JSON-RPC session machine over a pluggable transport: it performs the
  `initialize` handshake where the peer's era requires one, discovers available
  tools via `tools/list`, and executes tool calls via `tools/call`. The wire is
  `Raxol.MCP.Client.Transport` (ADR-0037 decision 1): a local subprocess
  (`Transport.Stdio`) or a hosted HTTPS endpoint (`Transport.Http`).

  ## Usage

      {:ok, client} = Client.start_link(
        name: :my_server,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      {:ok, remote} = Client.start_link(
        name: :intel,
        url: "https://mcp.example.com/mcp",
        headers: [{"authorization", "Bearer ..."}]
      )

      {:ok, tools} = Client.list_tools(client)
      {:ok, result} = Client.call_tool(client, "read_file", %{path: "/tmp/hello.txt"})
      Client.stop(client)

  The spec discriminator is `:command` XOR `:url`. A spec carrying both, or
  neither, is `{:error, {:invalid_spec, spec}}` with its header values
  redacted; a `:url` spec in a build without `mint` is
  `{:error, :no_http_client}`.

  Header values reaching this module are ALREADY RESOLVED LITERALS. Nothing
  here reads `${env:VAR}` or `op://...`: resolution and the provenance rule
  that gates it live in `raxol_agent`, where `.mcp.json` is parsed.

  ## Concurrency and the in-flight window

  A `GenServer` serializes calls on entry, which is not the same as bounding
  the requests in flight: two callers used to get two concurrent requests on
  one session, and a TronScan-shaped upstream answers 500 to both
  (`docs/proposals/web3-upstream-survey.md:72-78`). So the window is explicit
  (ADR-0037 decision 6). `:concurrency` is `:stateless`, `:pooled` or
  `:serialized`; a `:serialized` origin has an in-flight cap of one and holds
  the excess in a bounded queue that answers `{:error, :busy}` on overflow,
  rather than admitting work it cannot start.

  Every admitted request carries a timer. On expiry the client replies
  `{:error, :timeout}` itself and drops the entry, which is what stops
  `pending` from growing without bound: before this, an entry was removed only
  by a reply, a JSON-RPC error or a subprocess exit status, and a caller whose
  `GenServer.call` timed out left its entry behind forever. An HTTP transport
  has no exit status at all.

  ## Tool Namespacing

  Tools are namespaced with the server name prefix: `mcp__<server>__<tool>`.
  Use `tool_name/2` to build namespaced names, and `parse_tool_name/1` to
  decompose them.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.MCP.Client.Transport
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
    :config,
    :transport,
    :handle,
    :tools,
    :registry,
    :version,
    :error,
    pending: %{},
    queue: nil,
    queued: 0,
    next_id: 1,
    status: :starting,
    concurrency: :stateless,
    in_flight_cap: :infinity,
    queue_limit: 8,
    declared_concurrency: nil,
    call_timeout: 30_000
  ]

  @type t :: %__MODULE__{
          name: atom(),
          config: map() | nil,
          transport: module(),
          handle: Transport.handle() | nil,
          tools: [tool()] | nil,
          registry: atom() | nil,
          version: String.t() | nil,
          error: term() | nil,
          pending: %{pos_integer() => %{from: GenServer.from() | :init, timer: reference()}},
          queue: :queue.queue() | nil,
          queued: non_neg_integer(),
          next_id: pos_integer(),
          status: :starting | :initializing | :ready | :closed,
          concurrency: Transport.concurrency(),
          in_flight_cap: pos_integer() | :infinity,
          queue_limit: non_neg_integer(),
          declared_concurrency: Transport.concurrency() | nil,
          call_timeout: pos_integer()
        }

  @default_call_timeout 30_000
  @default_queue_limit 8
  @default_pool_size 8

  # -- Client API ---------------------------------------------------------------

  @doc """
  Start an MCP client linked to the calling process.

  The spec is a keyword list or a map. `:name` is required; `:command` XOR
  `:url` selects the transport. Refused specs never start a process, so an
  invalid spec costs no supervision noise.
  """
  @spec start_link(keyword() | map()) :: GenServer.on_start() | {:error, term()}
  def start_link(opts) do
    with {:ok, transport, config} <- Transport.select(opts),
         {:ok, name} <- fetch_name(config) do
      registry = Map.get(config, :registry)
      gen_opts = if registry, do: [name: via(name, registry)], else: []
      GenServer.start_link(__MODULE__, Map.put(config, :transport, transport), gen_opts)
    end
  end

  @doc "List tools available on the MCP server."
  @spec list_tools(GenServer.server(), keyword()) :: {:ok, [tool()]} | {:error, term()}
  def list_tools(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout)
    GenServer.call(server, :list_tools, timeout)
  end

  @doc """
  Call a tool on the MCP server.

  Options:

    * `:timeout` - caller-side timeout, default 30 s.
    * `:reservation` - the spend-gate handle for a priced tool. A tool the spec
      declares as priced, called with no handle, is `{:error, :unmetered_call}`
      and no request is issued (ADR-0037 decision 7). The value is opaque
      here; it is minted at the `Raxol.Agent.ToolCall.Hook` seam.

  """
  @spec call_tool(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, call_result()} | {:error, term()}
  def call_tool(server, tool_name, arguments \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout)
    call_opts = Keyword.take(opts, [:reservation])
    GenServer.call(server, {:call_tool, tool_name, arguments, call_opts}, timeout)
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
  def init_manager(config) do
    state = %__MODULE__{
      name: Map.fetch!(config, :name),
      transport: Map.fetch!(config, :transport),
      config: config,
      registry: Map.get(config, :registry),
      queue: :queue.new(),
      status: :starting,
      declared_concurrency: declared_concurrency(config),
      queue_limit: Map.get(config, :queue_limit, @default_queue_limit),
      call_timeout: Map.get(config, :call_timeout, @default_call_timeout)
    }

    {:ok, state, {:continue, :connect}}
  end

  # A failed connect does NOT stop the process, and both halves of that are
  # deliberate. `GenServer.start_link/3` returns as soon as `init/1` does, so a
  # connect in `init/1` would serialize every client's cold start behind the
  # one before it, which is exactly what `Raxol.Agent.McpBundle.load/2` starts
  # them concurrently to avoid (`mcp_bundle.ex:102-106`). And a `{:stop, _}`
  # from either place takes the LINKED caller down with it, so a bad remote
  # spec would kill the agent rather than being skipped.
  #
  # So the client lands in `:closed` carrying the reason, and every call
  # answers `{:connect_failed, reason}`. That is a non-`:not_ready` error, which
  # `poll_tools/5` fails open on immediately instead of burning its whole
  # readiness budget (`mcp_bundle.ex:213-227`).
  @impl GenServer
  def handle_continue(:connect, state) do
    case state.transport.connect(state.config) do
      {:ok, handle} ->
        {:noreply, start_session(state, handle)}

      {:error, reason} ->
        Logger.warning("[MCP.Client] Server #{state.name} could not connect: #{inspect(reason)}")
        {:noreply, %{state | status: :closed, config: nil, error: reason}}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:list_tools, _from, %{status: :ready, tools: tools} = state)
      when is_list(tools) do
    {:reply, {:ok, tools}, state}
  end

  def handle_manager_call(:list_tools, from, %{status: :ready} = state) do
    admit(state, from, "tools/list", %{}, [])
  end

  def handle_manager_call(:list_tools, _from, state) do
    {:reply, {:error, unavailable(state)}, state}
  end

  def handle_manager_call(
        {:call_tool, tool_name, arguments, opts},
        from,
        %{status: :ready} = state
      ) do
    admit(state, from, "tools/call", %{name: tool_name, arguments: arguments}, opts)
  end

  def handle_manager_call({:call_tool, _tool, _args, _opts}, _from, state) do
    {:reply, {:error, unavailable(state)}, state}
  end

  def handle_manager_call(:status, _from, state) do
    info = %{
      name: state.name,
      status: state.status,
      version: state.version,
      concurrency: state.concurrency,
      tools: if(state.tools, do: length(state.tools), else: nil),
      pending: map_size(state.pending),
      queued: state.queued
    }

    {:reply, info, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:request_timeout, id}, state) do
    {:noreply, expire(state, id)}
  end

  # Nothing to decode with. A client whose connect failed still receives
  # whatever its own connect attempt left in the mailbox, and handing `nil` to
  # a transport would crash a process that is already reporting its failure
  # correctly.
  def handle_manager_info(_message, %{handle: nil} = state), do: {:noreply, state}

  def handle_manager_info(message, state) do
    case state.transport.decode_info(state.handle, message) do
      {:messages, lines, handle} ->
        {:noreply, Enum.reduce(lines, %{state | handle: handle}, &handle_line/2)}

      {:failed, id, reason, handle} ->
        {:noreply, fail_request(%{state | handle: handle}, id, reason)}

      {:closed, reason, handle} ->
        {:noreply, close_session(%{state | handle: handle}, reason)}

      :ignore ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{transport: transport, handle: handle}) when not is_nil(handle) do
    transport.close(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Private: session lifecycle ----------------------------------------------

  # The negotiated session profile decides whether a handshake happens at all.
  # A modern-era origin is specified not to answer `initialize`, so offering one
  # would leave this client in `:initializing` forever.
  #
  # `:config` is dropped once the transport holds what it needs, because it
  # carries resolved credentials and a GenServer crash report prints state.
  defp start_session(state, handle) do
    {kind, session} = state.transport.session(handle)
    concurrency = state.declared_concurrency || session.concurrency
    cap = in_flight_cap(concurrency, state.config)

    state = %{
      state
      | handle: handle,
        config: nil,
        version: session.version,
        concurrency: concurrency,
        in_flight_cap: cap
    }

    case kind do
      :handshake -> send_initialize(state)
      :ready -> %{state | status: :ready}
    end
  end

  defp send_initialize(state) do
    params = %{
      protocolVersion: state.version,
      capabilities: %{},
      clientInfo: %{name: "raxol", version: RaxolMcp.version()}
    }

    {state, call} = new_call(%{state | status: :initializing}, :init, "initialize", params, [])
    dispatch(state, call)
  end

  defp close_session(state, reason) do
    Logger.warning("[MCP.Client] Server #{state.name} closed: #{inspect(reason)}")

    state =
      Enum.reduce(Map.keys(state.pending), state, fn id, acc ->
        {entry, acc} = pop_pending(acc, id)
        reply(entry.from, {:error, reason})
        acc
      end)

    state = flush_queue(state, {:error, reason})
    %{state | status: :closed}
  end

  # -- Private: admission, dispatch and the bounded queue ----------------------

  defp admit(state, from, method, params, opts) do
    {state, call} = new_call(state, from, method, params, opts)

    cond do
      capacity?(state) ->
        {:noreply, dispatch(state, call)}

      state.queued < state.queue_limit ->
        {:noreply, enqueue(state, call)}

      true ->
        # Refused rather than admitted-and-never-started: a queued request that
        # cannot dispatch would expire in the caller, which is the failure mode
        # ADR-0037 decision 6 exists to remove.
        cancel(call.timer)
        {:reply, {:error, :busy}, state}
    end
  end

  # The id and the timer are allocated at ADMISSION, not at dispatch, so a
  # request that waits in the queue and then dispatches is bounded by ONE
  # `call_timeout` in total rather than one per stage.
  #
  # The handshake is the one entry with no timer, and that is not an oversight.
  # The leak decision 6 closes is `pending` GROWING: one entry per caller whose
  # `GenServer.call` gave up. There is exactly one handshake per client, so it
  # cannot grow, nobody is waiting on it (its `from` is `:init`), and the bound
  # that matters is the caller's readiness deadline, which
  # `Raxol.Agent.McpBundle` already owns (`mcp_bundle.ex:206-227`). Timing it
  # out here would also make a client's readiness depend on how fast its server
  # starts, which for a subprocess is a whole VM boot.
  defp new_call(state, from, method, params, opts) do
    id = state.next_id

    call = %{
      id: id,
      from: from,
      method: method,
      params: params,
      opts: opts,
      timer: timer(state, from, id)
    }

    {%{state | next_id: id + 1}, call}
  end

  defp timer(_state, :init, _id), do: nil

  defp timer(state, _from, id) do
    Process.send_after(self(), {:request_timeout, id}, state.call_timeout)
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp enqueue(state, call) do
    %{state | queue: :queue.in(call, state.queue), queued: state.queued + 1}
  end

  defp dispatch(state, call) do
    request = request(call)

    case state.transport.send(state.handle, send_id(call), request) do
      {:ok, handle} ->
        %{
          state
          | handle: handle,
            pending: Map.put(state.pending, call.id, %{from: call.from, timer: call.timer})
        }

      {:error, reason} ->
        cancel(call.timer)
        reply(call.from, {:error, reason})
        state
    end
  end

  defp request(call) do
    case Keyword.get(call.opts, :reservation) do
      nil -> %{method: call.method, params: call.params}
      handle -> %{method: call.method, params: call.params, reservation: handle}
    end
  end

  defp send_id(%{id: id}), do: id

  defp drain(state) do
    if capacity?(state) and state.queued > 0 do
      {{:value, call}, queue} = :queue.out(state.queue)
      state = %{state | queue: queue, queued: state.queued - 1}
      drain(dispatch(state, call))
    else
      state
    end
  end

  defp flush_queue(state, response) do
    Enum.each(:queue.to_list(state.queue), fn call ->
      cancel(call.timer)
      reply(call.from, response)
    end)

    %{state | queue: :queue.new(), queued: 0}
  end

  defp capacity?(%{in_flight_cap: :infinity}), do: true
  defp capacity?(state), do: map_size(state.pending) < state.in_flight_cap

  defp in_flight_cap(:serialized, _config), do: 1
  defp in_flight_cap(:stateless, _config), do: :infinity

  defp in_flight_cap(:pooled, config) do
    Map.get(config || %{}, :pool_size, @default_pool_size)
  end

  defp declared_concurrency(config) do
    case Map.get(config, :concurrency) do
      policy when policy in [:stateless, :pooled, :serialized] -> policy
      _absent -> nil
    end
  end

  # -- Private: message handling -----------------------------------------------

  defp handle_line(line, state) do
    case Protocol.decode(line) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, _reason} ->
        Logger.debug("[MCP.Client] Ignoring non-JSON line: #{String.slice(line, 0, 100)}")
        state
    end
  end

  defp handle_message(%{id: id, result: result}, state) do
    with_pending(state, id, fn entry, state ->
      handle_result(result, entry.from, state)
    end)
  end

  defp handle_message(%{id: id, error: error}, state) do
    with_pending(state, id, fn entry, state ->
      reply(entry.from, {:error, error})
      state
    end)
  end

  defp handle_message(%{method: _}, state), do: state
  defp handle_message(_message, state), do: state

  defp with_pending(state, id, callback) do
    case Map.fetch(state.pending, id) do
      :error ->
        Logger.debug("[MCP.Client] Response for unknown id #{inspect(id)}")
        state

      {:ok, _entry} ->
        {entry, state} = pop_pending(state, id)
        drain(callback.(entry, state))
    end
  end

  defp pop_pending(state, id) do
    {entry, pending} = Map.pop(state.pending, id)
    cancel(entry.timer)
    {entry, %{state | pending: pending}}
  end

  defp fail_request(state, id, reason) do
    case Map.fetch(state.pending, id) do
      :error ->
        Logger.debug("[MCP.Client] Failure for unknown id #{inspect(id)}: #{inspect(reason)}")
        state

      {:ok, _entry} ->
        {entry, state} = pop_pending(state, id)
        reply(entry.from, {:error, reason})
        drain(state)
    end
  end

  defp expire(state, id) do
    case Map.fetch(state.pending, id) do
      {:ok, entry} ->
        state = %{state | pending: Map.delete(state.pending, id)}
        reply(entry.from, {:error, :timeout})
        drain(state)

      :error ->
        expire_queued(state, id)
    end
  end

  defp expire_queued(state, id) do
    case Enum.split_with(:queue.to_list(state.queue), &(&1.id == id)) do
      {[call], rest} ->
        reply(call.from, {:error, :timeout})
        %{state | queue: :queue.from_list(rest), queued: length(rest)}

      {[], _rest} ->
        state
    end
  end

  defp handle_result(result, _from, %{status: :initializing} = state) do
    server_info = Map.get(result, "serverInfo", %{})
    Logger.info("[MCP.Client] Server #{state.name} initialized: #{inspect(server_info)}")

    state = %{state | status: :ready, version: negotiated(state, result)}
    send_notification(state, "notifications/initialized", %{})
  end

  defp handle_result(%{"tools" => tools}, from, state) do
    parsed_tools = Enum.map(tools, &parse_tool/1)
    reply(from, {:ok, parsed_tools})
    %{state | tools: parsed_tools}
  end

  defp handle_result(result, from, state) do
    call_result = %{
      content: Map.get(result, "content", []),
      is_error: Map.get(result, "isError", false)
    }

    reply(from, {:ok, call_result})
    state
  end

  # The per-connection revision. A peer that answers with a revision this
  # client does not know keeps the one we offered rather than the connection
  # being dropped: an unrecognised revision string is not evidence that the
  # session is unusable, and every method this client sends predates all three.
  defp negotiated(state, result) do
    case Protocol.negotiate(Map.get(result, "protocolVersion")) do
      {:ok, version} ->
        version

      {:error, {:unsupported_version, offered}} ->
        Logger.warning(
          "[MCP.Client] Server #{state.name} answered unsupported protocol " <>
            "#{inspect(offered)}; continuing on #{inspect(state.version)}"
        )

        state.version
    end
  end

  defp send_notification(state, method, params) do
    case state.transport.send(state.handle, nil, %{method: method, params: params}) do
      {:ok, handle} ->
        %{state | handle: handle}

      {:error, reason} ->
        Logger.warning(
          "[MCP.Client] Server #{state.name} notification #{method} failed: #{inspect(reason)}"
        )

        state
    end
  end

  defp reply(:init, _response), do: :ok
  defp reply(from, response), do: GenServer.reply(from, response)

  # -- Private: Helpers ---------------------------------------------------------

  # A client that never connected reports WHY, rather than reporting the state
  # it is stuck in: the reason is what an operator needs, and a
  # non-`:not_ready` error is also what makes a bundle skip the server at once
  # instead of polling a dead client until its deadline.
  defp unavailable(%{error: reason}) when not is_nil(reason), do: {:connect_failed, reason}
  defp unavailable(state), do: {:not_ready, state.status}

  defp fetch_name(config) do
    case Map.get(config, :name) do
      name when is_atom(name) and not is_nil(name) -> {:ok, name}
      _missing -> {:error, {:invalid_spec, Transport.redact(config)}}
    end
  end

  defp parse_tool(tool_map) do
    %{
      name: Map.get(tool_map, "name", ""),
      description: Map.get(tool_map, "description", ""),
      input_schema: Map.get(tool_map, "inputSchema", %{})
    }
  end

  defp via(name, registry) do
    {:via, Registry, {registry, {:mcp_client, name}}}
  end
end
