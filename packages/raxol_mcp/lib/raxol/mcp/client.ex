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
  `:serialized`; every policy has a finite in-flight cap, and a `:serialized`
  origin has a cap of one. Excess work waits in a bounded queue that answers
  `{:error, :busy}` on overflow rather than admitting work it cannot start.

  Every admitted request carries a timer. On expiry the client replies
  `{:error, :timeout}` itself and drops the entry, which is what stops
  `pending` from growing without bound: before this, an entry was removed only
  by a reply, a JSON-RPC error or a subprocess exit status, and a caller whose
  `GenServer.call` timed out left its entry behind forever. An HTTP transport
  has no exit status at all.

  ## Recovery

  A connect that fails, and a handshake that fails, both land the client in
  `:closed` carrying the reason and schedule a retry whose delay starts at
  `:reconnect_ms` (1 s) and doubles to one minute. Nothing here stops the
  process: `start_link/1` links the CALLER, so a `{:stop, _}` would take the
  agent down over one bad spec. A session the origin rejects mid-flight fails
  that one request and is re-established in place, on the same handle.

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
    waiters: [],
    queue: nil,
    queued: 0,
    next_id: 1,
    status: :starting,
    concurrency: :stateless,
    in_flight_cap: 8,
    queue_limit: 8,
    declared_concurrency: nil,
    call_timeout: 30_000,
    init_timeout: 60_000,
    reconnect_ms: 1_000,
    backoff_ms: nil
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
          pending: %{
            pos_integer() => %{
              from: GenServer.from() | :init | :notify,
              method: String.t(),
              timer: reference() | nil
            }
          },
          waiters: [{GenServer.from(), reference()}],
          queue: :queue.queue() | nil,
          queued: non_neg_integer(),
          next_id: pos_integer(),
          status: :starting | :initializing | :ready | :closed,
          concurrency: Transport.concurrency(),
          in_flight_cap: pos_integer(),
          queue_limit: non_neg_integer(),
          declared_concurrency: Transport.concurrency() | nil,
          call_timeout: pos_integer(),
          init_timeout: pos_integer(),
          reconnect_ms: pos_integer(),
          backoff_ms: pos_integer() | nil
        }

  @default_call_timeout 30_000
  @default_init_timeout 60_000
  @default_reconnect_ms 1_000
  @max_reconnect_ms 60_000
  @default_queue_limit 8
  @default_pool_size 8

  # `await_ready/2` answers its own timeout, so the surrounding
  # `GenServer.call` must outlive it: the reply is the answer, not an exit.
  @await_slack_ms 1_000

  # Bounds on what a remote `tools/list` may put into this process's state.
  # Far above any real server's catalog; they exist to stop a hostile one.
  @max_tools 256
  @max_name_bytes 128
  @max_description_bytes 8_192

  # What a tool name may contain. The namespaced form the agent renders is
  # `mcp__<server>__<tool>`, and a provider's own function-name rule is
  # narrower than this, so anything outside it could not be offered anyway.
  @tool_name_re ~r/\A[A-Za-z0-9_.\-]{1,#{@max_name_bytes}}\z/

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

  @doc """
  Block until the session is usable, or `timeout` passes.

  `{:ok, status}` once the handshake has round-tripped (immediately, for an
  era that has none), or `{:error, {:not_ready, status}}` when the budget
  passes first. A client that is retrying a failed connect keeps the caller
  waiting rather than answering for the state it is passing through, which
  is the whole point: readiness is an event, and polling `status/1` in a
  sleep loop is a race dressed up as a test helper.
  """
  @spec await_ready(GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def await_ready(server, timeout \\ @default_init_timeout) do
    GenServer.call(server, {:await_ready, timeout}, timeout + @await_slack_ms)
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
      call_timeout: Map.get(config, :call_timeout, @default_call_timeout),
      init_timeout: Map.get(config, :init_timeout, @default_init_timeout),
      reconnect_ms: reconnect_ms(config)
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
  #
  # `:closed` is not final, and that half was missing. Nothing retried, and a
  # live process is one a supervisor will not restart, so a DNS blip or a
  # breaker that happened to be open at boot removed that upstream until the VM
  # was restarted. The client retries itself instead.
  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

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
    {:reply, status_info(state), state}
  end

  def handle_manager_call({:await_ready, _timeout}, _from, %{status: :ready} = state) do
    {:reply, {:ok, status_info(state)}, state}
  end

  def handle_manager_call({:await_ready, timeout}, from, state) do
    timer = Process.send_after(self(), {:await_timeout, from}, timeout)
    {:noreply, %{state | waiters: [{from, timer} | state.waiters]}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:request_timeout, id}, state) do
    {:noreply, expire(state, id)}
  end

  def handle_manager_info({:await_timeout, from}, state) do
    {:noreply, expire_waiter(state, from)}
  end

  # Scheduled only by `schedule_reconnect/2`, so only from `:closed`.
  def handle_manager_info(:reconnect, state), do: {:noreply, connect(state)}

  # Nothing to decode with. A client whose connect failed still receives
  # whatever its own connect attempt left in the mailbox, and handing `nil` to
  # a transport would crash a process that is already reporting its failure
  # correctly.
  def handle_manager_info(_message, %{handle: nil} = state), do: {:noreply, state}

  def handle_manager_info(message, state) do
    {:noreply, apply_decoded(state, state.transport.decode_info(state.handle, message))}
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
  # `:config` is RETAINED, because a retry has to have something to dial. It
  # carries resolved credentials and a GenServer crash report prints state, so
  # the `Inspect` implementation at the bottom of this file redacts it.
  defp start_session(state, handle) do
    {kind, session} = state.transport.session(handle)
    concurrency = state.declared_concurrency || session.concurrency
    cap = in_flight_cap(concurrency, state.config)

    state = %{
      state
      | handle: handle,
        version: session.version,
        concurrency: concurrency,
        in_flight_cap: cap
    }

    case kind do
      :handshake -> send_initialize(state)
      :ready -> become_ready(state)
    end
  end

  # Readiness is the event `await_ready/2` parks on. Everything that makes a
  # session usable goes through here so a waiter cannot be left behind by one
  # of the two paths that reach `:ready`.
  defp become_ready(state) do
    info = status_info(%{state | status: :ready})

    Enum.each(state.waiters, fn {from, timer} ->
      cancel(timer)
      reply(from, {:ok, info})
    end)

    %{state | status: :ready, waiters: []}
  end

  defp expire_waiter(state, from) do
    case Enum.split_with(state.waiters, fn {waiter, _timer} -> waiter == from end) do
      {[{^from, _timer}], rest} ->
        reply(from, {:error, {:not_ready, state.status}})
        %{state | waiters: rest}

      {[], _rest} ->
        state
    end
  end

  defp status_info(state) do
    %{
      name: state.name,
      status: state.status,
      version: state.version,
      concurrency: state.concurrency,
      tools: if(state.tools, do: length(state.tools), else: nil),
      pending: map_size(state.pending),
      queued: state.queued
    }
  end

  defp connect(state) do
    case state.transport.connect(state.config) do
      {:ok, handle} ->
        start_session(%{state | error: nil, backoff_ms: nil}, handle)

      {:error, reason} ->
        Logger.warning("[MCP.Client] Server #{state.name} could not connect: #{inspect(reason)}")

        schedule_reconnect(state, reason)
    end
  end

  # The delay doubles to a cap, so a permanently-down origin costs one connect
  # a minute rather than a hot loop. Until one succeeds the client answers
  # every call `{:connect_failed, reason}`, which is what it answered before.
  defp schedule_reconnect(state, reason) do
    delay = next_backoff(state)

    Logger.debug(fn -> "[MCP.Client] Server #{state.name} retrying connect in #{delay} ms" end)

    Process.send_after(self(), :reconnect, delay)
    %{state | status: :closed, handle: nil, error: reason, backoff_ms: delay}
  end

  defp next_backoff(%{backoff_ms: nil} = state), do: state.reconnect_ms
  defp next_backoff(%{backoff_ms: delay}), do: min(delay * 2, @max_reconnect_ms)

  # A zero or negative delay would turn the retry into a hot loop, which is
  # the failure the backoff exists to prevent, so it is not a configuration.
  defp reconnect_ms(config) do
    case Map.get(config, :reconnect_ms, @default_reconnect_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _invalid -> @default_reconnect_ms
    end
  end

  defp send_initialize(state), do: issue_initialize(%{state | status: :initializing})

  # A RE-handshake keeps the session `:ready`. The initialize occupies an
  # in-flight slot, and a legacy origin's cap is one, so a request arriving
  # during it queues and then dispatches on the new session -- where
  # `:initializing` would refuse it outright as `{:not_ready, :initializing}`.
  defp rehandshake(%{handle: nil} = state), do: state

  defp rehandshake(state) do
    # `Transport.Http.session/1` answers `{:handshake, _}` from the era
    # alone, so it cannot say that an initialize is already in flight. An
    # origin restart that 404s N `:pooled` calls at once (cap 8) issued N
    # initializes and minted N sessions, N-1 of them orphaned on the origin.
    # One handshake repairs the session for all of them.
    if handshaking?(state) do
      state
    else
      case state.transport.session(state.handle) do
        {:handshake, _profile} -> issue_initialize(state)
        {:ready, _profile} -> state
      end
    end
  end

  defp handshaking?(state) do
    Enum.any?(state.pending, fn {_id, entry} -> entry.method == "initialize" end)
  end

  defp issue_initialize(state) do
    params = %{
      protocolVersion: state.version,
      capabilities: %{},
      clientInfo: %{name: "raxol", version: RaxolMcp.version()}
    }

    {state, call} = new_call(state, :init, "initialize", params, [])
    dispatch(state, call)
  end

  # A session the peer closed under us. Every waiting caller is answered,
  # and then the client RETRIES: a stdio server that died mid-session left a
  # live process no supervisor restarts, which is the hole the reconnect was
  # added to close and this path did not use.
  defp close_session(state, reason) do
    Logger.warning("[MCP.Client] Server #{state.name} closed: #{inspect(reason)}")

    state
    |> fail_pending(reason)
    |> flush_queue({:error, reason})
    |> schedule_reconnect(reason)
  end

  defp fail_pending(state, reason) do
    Enum.reduce(Map.keys(state.pending), state, fn id, acc ->
      {entry, acc} = pop_pending(acc, id)
      reply(entry.from, {:error, reason})
      acc
    end)
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

  # The id and timer are allocated at ADMISSION, not at dispatch, so a request
  # that waits in the queue and then dispatches is bounded by ONE `call_timeout`
  # in total rather than one per stage. Initialization has its own, longer
  # finite timeout: process startup must not inherit an aggressively short
  # caller-request timeout, but a peer that never completes the handshake still
  # cannot leave the client stuck forever.
  defp new_call(state, from, method, params, opts) do
    id = state.next_id

    call = %{
      id: id,
      from: from,
      method: method,
      params: params,
      opts: opts,
      timer: timer(state, method, id)
    }

    {%{state | next_id: id + 1}, call}
  end

  defp timer(state, "initialize", id) do
    Process.send_after(self(), {:request_timeout, id}, state.init_timeout)
  end

  defp timer(state, _method, id) do
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
            pending:
              Map.put(state.pending, call.id, %{
                from: call.from,
                method: call.method,
                timer: call.timer
              })
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

  # A notification carries no JSON-RPC id on the wire, but it IS a request in
  # flight: one POST on the session, which is why it holds a `pending` entry
  # and an in-flight slot. The transport is told both at once -- encode it
  # id-less, report its outcome under this id.
  defp send_id(%{from: :notify, id: id}), do: {:notify, id}
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

  defp capacity?(state), do: map_size(state.pending) < state.in_flight_cap

  defp in_flight_cap(:serialized, _config), do: 1
  defp in_flight_cap(:stateless, config), do: configured_cap(config)

  defp in_flight_cap(:pooled, config), do: configured_cap(config)

  defp configured_cap(config) do
    case Map.get(config || %{}, :pool_size, @default_pool_size) do
      cap when is_integer(cap) and cap > 0 -> cap
      _invalid -> @default_pool_size
    end
  end

  defp declared_concurrency(config) do
    case Map.get(config, :concurrency) do
      policy when policy in [:stateless, :pooled, :serialized] -> policy
      _absent -> nil
    end
  end

  # -- Private: message handling -----------------------------------------------

  # One arm of `Transport.decode_info/2`'s return per clause: the transport
  # says what it made of the message, and the state transition that arm names
  # is applied here rather than inside the clause that reads the mailbox.
  defp apply_decoded(state, {:messages, lines, handle}) do
    Enum.reduce(lines, %{state | handle: handle}, &handle_line/2)
  end

  defp apply_decoded(state, {:failed, id, reason, handle}) do
    fail_request(%{state | handle: handle}, id, reason)
  end

  # A request that completed with nothing to deliver: a notification's POST.
  # It holds an in-flight slot like any other request, so the slot is released
  # here rather than when its timer fires.
  defp apply_decoded(state, {:settled, id, handle}), do: settle(%{state | handle: handle}, id)

  defp apply_decoded(state, {:closed, reason, handle}) do
    close_session(%{state | handle: handle}, reason)
  end

  defp apply_decoded(state, :ignore), do: state

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
      handle_result(result, entry.method, entry.from, state)
    end)
  end

  defp handle_message(%{id: id, error: error}, state) do
    with_pending(state, id, fn entry, state ->
      handle_error(error, entry, state)
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

      {:ok, %{method: "initialize"}} ->
        {_entry, state} = pop_pending(state, id)
        fail_initialization(state, reason)

      {:ok, _entry} ->
        {entry, state} = pop_pending(state, id)
        reply(entry.from, {:error, reason})
        state |> recover(reason) |> drain()
    end
  end

  # A rejected session is the one failure the transport cannot repair alone: it
  # can forget the dead session id, but minting a new one is a handshake and
  # the handshake lives here. Before this the client failed the request like
  # any other and left the handle session-less, so every later request went out
  # with no `mcp-session-id`; the origin answered 404 to all of them, and a 404
  # is neither a failover reason nor a breaker failure. The client was wedged
  # for the lifetime of the node.
  defp recover(state, :session_rejected), do: rehandshake(state)
  defp recover(state, _reason), do: state

  # An expiry removes the entry, but the WORK does not stop by itself: an
  # HTTP transport still has a task holding a socket, and `capacity?/1` would
  # then admit the next queued request beside it -- two concurrent requests
  # on a `:serialized` session, the exact fan-out the cap exists to prevent.
  # Reachable with defaults, because one exchange's wall time (the dial, plus
  # the deadline, plus a chunk overshoot) can exceed `call_timeout`. So the
  # transport is told to drop the work with the entry.
  defp expire(state, id) do
    case Map.fetch(state.pending, id) do
      {:ok, %{method: "initialize"} = entry} ->
        state = %{state | pending: Map.delete(state.pending, id)}
        reply(entry.from, {:error, :timeout})
        state |> cancel_work(id) |> fail_initialization(:timeout)

      {:ok, entry} ->
        state = %{state | pending: Map.delete(state.pending, id)}
        reply(entry.from, {:error, :timeout})
        state |> cancel_work(id) |> drain()

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

  defp cancel_work(%{handle: nil} = state, _id), do: state

  defp cancel_work(state, id),
    do: %{state | handle: state.transport.cancel(state.handle, id)}

  # A request that finished with nothing to deliver: the `notifications/
  # initialized` POST. Its slot is released here, which is the point of
  # giving it an entry at all.
  defp settle(state, id) do
    case Map.fetch(state.pending, id) do
      {:ok, _entry} ->
        {_entry, state} = pop_pending(state, id)
        drain(state)

      :error ->
        state
    end
  end

  defp handle_result(result, "initialize", _from, state) when is_map(result) do
    server_info = Map.get(result, "serverInfo", %{})
    Logger.info("[MCP.Client] Server #{state.name} initialized: #{inspect(server_info)}")

    state = become_ready(%{state | version: negotiated(state, result)})
    send_notification(state, "notifications/initialized", %{})
  end

  defp handle_result(%{"tools" => tools}, "tools/list", from, state) when is_list(tools) do
    parsed_tools = parse_tools(tools, state)
    reply(from, {:ok, parsed_tools})
    %{state | tools: parsed_tools}
  end

  defp handle_result(result, "tools/call", from, state) when is_map(result) do
    call_result = %{
      content: Map.get(result, "content", []),
      is_error: Map.get(result, "isError", false)
    }

    reply(from, {:ok, call_result})
    state
  end

  defp handle_result(_result, method, from, state) do
    reply(from, {:error, {:invalid_response, method}})
    state
  end

  defp handle_error(error, %{method: "initialize"}, state) do
    fail_initialization(state, {:jsonrpc, error})
  end

  defp handle_error(error, entry, state) do
    reply(entry.from, {:error, error})
    state
  end

  defp fail_initialization(state, reason) do
    Logger.warning("[MCP.Client] Server #{state.name} initialization failed: #{inspect(reason)}")

    if state.handle, do: state.transport.close(state.handle)

    # Every waiting caller is answered, not only the queued ones. A
    # re-handshake at `:ready` runs beside live requests, and leaving their
    # entries behind held in-flight slots -- the whole window, on a
    # `:serialized` session -- across the reconnect, so each of those callers
    # waited out its full `call_timeout` for a session that no longer exists.
    #
    # Recovered the same way a failed connect is: a handshake that timed out is
    # transient as often as not, and staying closed forever was the same hole.
    state
    |> fail_pending({:initialization_failed, reason})
    |> flush_queue({:error, {:initialization_failed, reason}})
    |> schedule_reconnect({:initialization_failed, reason})
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

  # Notifications go through the same admission path as any other request.
  # One was issued as a bare transport write with no `pending` entry, so it
  # did not count against `in_flight_cap`: the bundle's `tools/list`
  # dispatched while the `notifications/initialized` POST was still in
  # flight, which is two concurrent requests on a `:serialized` session at
  # the exact moment the policy exists to prevent them. There is no reply to
  # correlate, so the transport settles the entry instead.
  defp send_notification(state, method, params) do
    {state, call} = new_call(state, :notify, method, params, [])
    dispatch(state, call)
  end

  defp reply(:init, _response), do: :ok

  # A notification has no caller. Its entry exists for the in-flight window,
  # and a failure is logged by whoever reports it.
  defp reply(:notify, _response), do: :ok
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

  # A `tools/list` answer is upstream data, and it was mapped straight into
  # this GenServer's state: a non-map entry raised `BadMapError` HERE, taking
  # the client and every linked caller with it, and neither the number of
  # tools nor the size of a name was bounded, so a 2 MiB list became prompt
  # context on every turn. The shape is therefore decided at the boundary it
  # arrives through.
  #
  # A bad entry is dropped rather than failing the list: one malformed tool
  # on an otherwise working server is not a reason to offer the agent none of
  # them. The count of dropped entries is logged; their content is not.
  defp parse_tools(tools, state) do
    {kept, over_cap} = Enum.split(tools, @max_tools)
    parsed = Enum.flat_map(kept, &parse_tool/1)
    dropped = length(kept) - length(parsed) + length(over_cap)

    if dropped > 0 do
      Logger.warning(
        "[MCP.Client] Server #{state.name} listed #{length(tools)} tools; dropped #{dropped} " <>
          "(unusable name, or past the #{@max_tools} cap)"
      )
    end

    parsed
  end

  defp parse_tool(tool_map) when is_map(tool_map) do
    case Map.get(tool_map, "name") do
      name when is_binary(name) ->
        if Regex.match?(@tool_name_re, name),
          do: [built_tool(name, tool_map)],
          else: []

      _unusable ->
        []
    end
  end

  defp parse_tool(_not_a_map), do: []

  defp built_tool(name, tool_map) do
    %{
      name: name,
      description: bounded(Map.get(tool_map, "description")),
      input_schema: schema(Map.get(tool_map, "inputSchema"))
    }
  end

  # A memory bound on the client's own state, not a context bound: the
  # model-facing cap (and the truncation marker that goes with it) is
  # `Raxol.Agent.Action.Dynamic`'s, at a quarter of this.
  defp bounded(description) when is_binary(description) do
    if byte_size(description) <= @max_description_bytes,
      do: description,
      else: valid_prefix(binary_part(description, 0, @max_description_bytes))
  end

  defp bounded(_not_text), do: ""

  # `binary_part/3` can halve a multi-byte codepoint, and an invalid UTF-8
  # string fails JSON encoding on the way to the provider.
  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp schema(schema) when is_map(schema), do: schema
  defp schema(_not_a_schema), do: %{}

  defp via(name, registry) do
    {:via, Registry, {registry, {:mcp_client, name}}}
  end
end

defimpl Inspect, for: Raxol.MCP.Client do
  import Inspect.Algebra

  # The spec is retained so a failed connect can be retried, and a GenServer
  # crash report prints its state. A spec carries resolved credentials -- a
  # bearer header, a subprocess environment -- so none of it renders.
  def inspect(client, opts) do
    redacted = %{
      name: client.name,
      status: client.status,
      version: client.version,
      error: client.error,
      pending: map_size(client.pending),
      queued: client.queued,
      config: if(client.config, do: "[redacted]")
    }

    concat(["#Raxol.MCP.Client<", to_doc(redacted, opts), ">"])
  end
end
