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
  - `tools/list` -- list the registered tools this caller may call
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

  A parked call never holds up its caller. A `handle_message/3` caller blocks
  until it gets a reply, so `tools/call` returns `nil` **immediately** and the
  call's eventual response is pushed on the subscriber channel:

      client                     server                    transport
      tools/call  ------------->  ASK -> park, return nil ->  (unblocked)
                 <-------------  elicitation/create (push)
      response   ------------->  resume, return nil
                 <-------------  tools/call response (push)

  Returning `nil` is what keeps such a transport (`Transport.SSE`) from
  deadlocking: it stays free to READ the client's answer. A `request/3` caller
  (`Transport.Stdio`) never blocks, so its call simply stays outstanding: the
  prompt is still pushed, but the call's response, or deny, is the REPLY to
  that request. Until then `cancel/2` with the call's `request_ref` reaches it,
  whether it is still waiting for the answer or, once approved, running.

  A parked call is always closed, exactly once, by one of five paths: an
  approval (runs the tool), a decline/cancel/unapproved accept, an error
  response, a timeout (`:elicitation_timeout_ms`, default 60s), or, on a full
  server, making room for another connection's call (see below). Every path
  but approval resolves to the same deny -- silence is not consent. Dropping
  it is the exception: `cancel/2`, its `request/3` caller exiting, or its
  connection going away ends it with no answer, and kills the tool if an
  approval already started it.

  Parked calls are capped twice. A connection may have at most
  `:max_parked_elicitations` (default 32) calls parked at once, and the server
  at most `:max_parked_elicitations_total` (default 256) across every
  connection. A parked call holds no callback worker, so without the first a
  client could park calls as fast as it sent them; without the second, every
  connection that can be asked (up to `:max_client_capabilities`) could park
  its full share. The total defaults to eight connections' full share: each
  parked call is a timer and a small entry in the server's state, so 256
  bounds that state while eight clients can each use their whole share at
  once. The per-connection cap may not exceed the total; the server refuses to
  start if it does.

  Past the per-connection cap an ASK gets the `authorization_required` deny
  with the detail `too many elicitations pending`. The total is shared by
  every client, so it is not first come, first served: when the server is
  full, an ASK from a connection holding fewer parked calls than the
  connection holding the most closes that connection's oldest parked call
  (with the deny and the detail `too many elicitations pending on this
  server`) and parks in its place. Any other ASK on a full server gets that
  deny itself. So a client that spreads its calls over several connections
  (a network transport mints one per stream) cannot hold every other
  client's approvals; it only crowds out its own. What remains: a client
  with more elicitation-capable connections than the total, each holding one
  call, can still keep a newcomer's call from lasting. Bounding that needs a
  per-peer identity no transport gives the server (`Transport.SSE` trusts
  the client's session id, and a remote address is shared behind a proxy).

  ## Sensitive tools

  A tool annotated `destructiveHint: true` or `sensitive: true` (see
  `Raxol.MCP.ToolDef.sensitive?/1`) must not be served without an authorizer.
  The server REFUSES TO BOOT when a static one is already registered, and
  denies at `tools/call` for one registered afterwards -- the boot check
  alone would be bypassable by registering late. Derived widget tools (the
  tool defs `Raxol.MCP.TreeWalker` derives, which `Raxol.MCP.ToolSynchronizer`
  registers with `derived: true`; see `Raxol.MCP.Registry.register_tools/3`
  and `Raxol.MCP.Registry.static_tools/1`) are left out of the boot check:
  they come and go with a session's view, so a restart of this server with
  live sessions would otherwise refuse to boot. A static tool with a dotted
  name (`agent.send`), or one whose tool map carries a `:derived` key, is
  still checked. The `tools/call` refusal covers both.

  ## Unknown tools

  A `tools/call` naming no registered tool answers JSON-RPC `-32601`, unless
  the `:unknown_tool_reply` option says otherwise. It is a 1-arity function
  given the tool name (a binary); a binary it returns is sent back as an
  `isError` tool result with that text, and `nil` keeps the `-32601`. An app
  whose tools come and go uses it to tell a client that cached a name what
  happened to it: `Raxol.Application` passes
  `Raxol.Headless.McpTools.unknown_tool_reply/1`, which names a stopped
  session. The server itself reads nothing into a tool name.

  ## Client capabilities

  What each connection advertised at `initialize` is kept until that
  connection's subscriber exits. A connection that never subscribes has no
  exit to wait for, so the map is also capped by `:max_client_capabilities`
  (default 1024). Past the cap the oldest entry without a live subscriber is
  evicted first, and a live one only when every entry has a subscriber. Each
  eviction emits `[:raxol, :mcp, :server, :client_capabilities_evicted]`.
  An evicted connection keeps working; it just cannot be asked, so an ASK
  becomes the deny, until it sends `initialize` again.

  ## Callback isolation

  Tool, resource, prompt, completion, and authorization callbacks run in
  linked, monitored workers rather than in the shared server process. The
  server remains responsive to other clients, notifications, subscriber exits,
  and elicitation timers while callback work is pending.

  `:max_in_flight` bounds concurrent callback workers across every connection
  (default 32); it does not count parked calls, which hold no worker.
  `:callback_timeout_ms` bounds each worker's lifetime (default 300,000 ms).
  Work above the concurrency bound receives a structured busy error. A finite
  timeout passed to `handle_message/4` also cancels that call's worker if the
  caller stops waiting. `request/3` callers cancel explicitly with `cancel/2`,
  and are monitored: when one exits, its outstanding requests are cancelled.

  `params` must be an object. `"params": null` is treated as absent; any other
  non-object `params` is answered `-32602` before the method is looked at.
  `method` must be a string: a request naming anything else is answered
  `-32600`, and such a notification is dropped. `logging/setLevel` answers an
  unknown `level` with `-32602`, and is otherwise gated by `:read_authorizer`
  like the other read surfaces.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @compile {:no_warn_undefined, Raxol.Headless}

  alias Raxol.MCP.Authorizer
  alias Raxol.MCP.Deployment
  alias Raxol.MCP.Protocol
  alias Raxol.MCP.Registry
  alias Raxol.MCP.ResourceRouter
  alias Raxol.MCP.ToolDef

  # A client that advertises elicitation but never answers must not park a
  # `tools/call` forever: on expiry the call is answered with the same
  # machine-readable deny it would have received without elicitation.
  @default_elicitation_timeout_ms 60_000

  # `initialize` is unauthenticated and a transport may take the connection id
  # from the client (`Transport.SSE` trusts `mcp-session-id`), so a client that
  # never subscribes can mint entries the `:DOWN` path will never reach.
  @default_max_client_capabilities 1024

  # Callback code is supplied by applications and may call agents, terminals,
  # or remote services. It runs outside this GenServer, with both concurrency
  # and lifetime bounded so one wedged callback cannot occupy the shared MCP
  # router forever.
  @default_max_in_flight 32

  # A parked call holds no worker, so `:max_in_flight` does not bound it. One
  # client is held to a share, and the server to a total: elicitation-capable
  # connections are limited only by `:max_client_capabilities`, and a network
  # transport can mint a new one per stream. The total is eight connections'
  # full share (8 x 32): a parked call costs a timer and one entry here, so 256
  # stays small while eight clients can each park their whole share at once.
  @default_max_parked_elicitations 32
  @default_max_parked_elicitations_total 256
  @default_callback_timeout_ms 300_000

  # The implicit single connection. stdio has exactly one peer and the OS
  # process boundary IS the principal, so it never names a connection and every
  # message it carries belongs to this one. A multi-client transport must mint
  # real ids instead; see `Raxol.MCP.Transport.SSE`.
  @default_conn :default

  defstruct [
    :registry,
    :authorizer,
    :read_authorizer,
    :unknown_tool_reply,
    authorizer_source: :default,
    transport: :unknown,
    initialized: false,
    log_level: :info,
    subscribers: %{},
    resource_subscriptions: %{},
    client_capabilities: %{},
    pending_elicitations: %{},
    parked_counts: %{},
    in_flight: %{},
    worker_refs: %{},
    caller_refs: %{},
    elicitation_timeout_ms: @default_elicitation_timeout_ms,
    max_client_capabilities: @default_max_client_capabilities,
    max_in_flight: @default_max_in_flight,
    max_parked_elicitations: @default_max_parked_elicitations,
    max_parked_elicitations_total: @default_max_parked_elicitations_total,
    callback_timeout_ms: @default_callback_timeout_ms
  ]

  @typedoc """
  Where this server's `:authorizer` came from.

  `:configured` -- a caller chose it. `:default` -- a framework fallback stood in
  because nobody chose one. The distinction exists for
  `authorization_configured?/1`; see that function for why the two cannot be told
  apart by the authorizer's value.
  """
  @type authorizer_source :: :configured | :default

  # Transports a caller can declare this server fronts. `:unknown` is the
  # default: the server is transport-agnostic and a transport attaches after it
  # boots, so absent a declaration nobody has said. Validated, not trusted --
  # see `transport!/1`.
  @transports [:stdio, :sse, :unknown]

  # Of those, the ones that carry clients over a network and so cannot lean on
  # the OS process boundary for anything.
  @network_transports [:sse]

  @typedoc """
  Which transport carries this server's clients, as DECLARED at start.

  Server-derived rather than client-asserted, which is what makes it usable in
  an authorization decision: a policy can tell a stdio caller (which inherits
  the OS process boundary) from a network one.
  """
  @type transport :: :stdio | :sse | :unknown

  @type t :: %__MODULE__{
          registry: GenServer.server(),
          authorizer: Authorizer.t() | nil,
          read_authorizer: Authorizer.t() | nil,
          unknown_tool_reply: (String.t() -> String.t() | nil) | nil,
          authorizer_source: authorizer_source(),
          transport: transport(),
          initialized: boolean(),
          log_level:
            :debug
            | :info
            | :notice
            | :warning
            | :error
            | :critical
            | :alert
            | :emergency,
          subscribers: %{conn_id() => pid()},
          resource_subscriptions: %{String.t() => boolean()},
          client_capabilities: %{conn_id() => {integer(), map()}},
          pending_elicitations: %{String.t() => pending_elicitation()},
          parked_counts: %{conn_id() => pos_integer()},
          in_flight: %{reference() => map()},
          worker_refs: %{reference() => reference()},
          caller_refs: %{reference() => reference()},
          elicitation_timeout_ms: pos_integer(),
          max_client_capabilities: pos_integer(),
          max_in_flight: pos_integer(),
          max_parked_elicitations: pos_integer(),
          max_parked_elicitations_total: pos_integer(),
          callback_timeout_ms: pos_integer()
        }

  @typedoc """
  Identifies one client connection. `:default` is the implicit single
  connection used by stdio and by direct callers; a network transport mints an
  opaque per-connection value.
  """
  @type conn_id :: term()

  @typedoc """
  A `tools/call` parked awaiting the client's elicitation answer. `request_id`
  is the ORIGINAL call's id -- the one the client is still waiting on, and
  `owner` is the connection that made it. Only `owner` may answer, and the
  answer goes only to `owner`: pushed to its subscriber, or, when the call came
  through `request/3`, sent as the reply to `caller` (the call's `from` and
  `request_ref`, plus the monitor on the calling process). `parked_at` orders
  parked calls, so a full server can tell its oldest.
  """
  @type pending_elicitation :: %{
          request_id: term(),
          tool: String.t(),
          arguments: map(),
          timer: reference(),
          owner: conn_id(),
          caller: caller() | nil,
          parked_at: integer()
        }

  @typedoc false
  @type caller :: %{from: GenServer.from(), request_ref: reference(), monitor: reference()}

  @log_levels [
    :debug,
    :info,
    :notice,
    :warning,
    :error,
    :critical,
    :alert,
    :emergency
  ]
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
  notifications (no response needed). The message is what
  `Raxol.MCP.Protocol.decode/1` returns: its top-level keys are atoms. A
  request with string top-level keys is answered `-32600`.
  """
  @spec handle_message(GenServer.server(), map()) :: {:reply, map() | nil}
  def handle_message(server \\ __MODULE__, message) do
    handle_message(server, message, @default_conn)
  end

  @doc """
  Handle a decoded JSON-RPC message attributed to a specific connection.

  `conn_id` is what binds an elicitation to the client that triggered it: only
  the connection that parked a `tools/call` may answer its prompt, and the
  prompt and result are delivered to that connection alone. A transport that
  cannot tell its clients apart must NOT invent ids -- passing an unidentified
  connection is safe (it can still make ordinary requests, and simply cannot
  elicit), whereas reusing one client's id for another hands over its approvals.
  """
  #
  # Callback work is isolated from the server process. A finite caller timeout
  # still applies to the `GenServer.call`; if it expires, the cancellation cast
  # below terminates that request's worker instead of merely abandoning it.
  @spec handle_message(GenServer.server(), map(), conn_id(), timeout()) ::
          {:reply, map() | nil}
  def handle_message(server, message, conn_id, timeout \\ :infinity) do
    request_ref = make_ref()

    try do
      GenServer.call(
        server,
        {:handle_message, message, conn_id, request_ref},
        timeout
      )
    catch
      :exit, {:timeout, _} = reason ->
        GenServer.cast(server, {:cancel_request, request_ref})
        exit(reason)
    end
  end

  @doc """
  Send a decoded JSON-RPC message without waiting for the reply.

  The non-blocking form of `handle_message/3`, for a transport that must keep
  reading while earlier requests run. Messages from one caller reach the
  server in send order, so methods handled inline keep their order.

  `message` must be what `Raxol.MCP.Protocol.decode/1` returns: top-level keys
  (`:jsonrpc`, `:id`, `:method`, `:params`, `:result`, `:error`) are atoms,
  anything below them keeps its string keys. A request decoded some other way,
  with string top-level keys, is answered `-32600`; such a notification or
  response gets `{:reply, nil}`.

  Returns the `:gen_server` request id and the `request_ref` that `cancel/2`
  takes. Collect the reply with `:gen_server.check_response/2,3`: it is
  `{:reply, map() | nil}`, as `handle_message/3` returns. Every request gets
  exactly one reply; a cancelled one gets `{:reply, nil}`. Unlike
  `handle_message/3`, a `tools/call` parked for elicitation is not answered
  `nil`: it stays outstanding, and its reply is the call's eventual response.

  The server monitors the calling process while it has requests outstanding,
  and cancels them if it exits.
  """
  @spec request(GenServer.server(), map(), conn_id()) ::
          {:gen_server.request_id(), reference()}
  def request(server, message, conn_id \\ @default_conn) do
    request_ref = make_ref()
    req_id = :gen_server.send_request(server, {:request, message, conn_id, request_ref})

    {req_id, request_ref}
  end

  @doc """
  Cancel a request sent with `request/3`.

  Kills the request's callback worker, if it still runs, or drops it while it
  is parked for an elicitation answer (a later answer is then ignored), and
  answers the request with `{:reply, nil}`. A `tools/call` approved through
  elicitation runs under its original `request_ref`, so this reaches it at
  every stage. A request that already completed is left alone.
  """
  @spec cancel(GenServer.server(), reference()) :: :ok
  def cancel(server, request_ref) do
    GenServer.cast(server, {:cancel_request, request_ref})
  end

  @doc """
  Subscribe a transport process to server notifications.

  The subscriber receives `{:mcp_notification, notification_map}` messages.
  Automatically unsubscribes when the subscriber process exits.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid) do
    subscribe(server, pid, @default_conn)
  end

  @doc """
  Subscribe a transport process as a named connection.

  The id is what later elicitation prompts and results are addressed to, so it
  must be the same value the transport passes to `handle_message/3` for that
  client's requests.
  """
  @spec subscribe(GenServer.server(), pid(), conn_id()) :: :ok
  def subscribe(server, pid, conn_id) do
    GenServer.cast(server, {:subscribe, pid, conn_id})
  end

  @doc "Send a notification to all subscribed transports."
  @spec notify(GenServer.server(), String.t(), map()) :: :ok
  def notify(server \\ __MODULE__, method, params \\ %{}) do
    GenServer.cast(server, {:notify, method, params})
  end

  @doc """
  Whether authorization on this server was CHOSEN by a caller. Network transport
  boot guards use this to fail closed (see `Raxol.MCP.Deployment`). Returns
  `false` if the server is unreachable.

  Deliberately not `authorizer != nil`. A framework may supply a restrictive
  fallback -- a deny-everything allowlist is a sensible default for an
  unconfigured production server -- and the value alone cannot be told apart from
  a policy an operator wrote. Treating the fallback as configured would satisfy
  this gate with a default, which removes exactly the forcing function the gate
  exists to be: nobody had to decide that a network transport should serve.

  So a server started with `authorizer_source: :default` answers `false` however
  strict its authorizer is. `:default` is also the DEFAULT source: for a
  predicate whose whole purpose is "nobody had to decide that a network
  transport should serve", an embedder who forgets the option must fail closed,
  not be taken at its word. `Raxol.Application` passes `:configured`
  explicitly when `mcp_authorizer_source/0` says an operator named a key.
  """
  @spec authorization_configured?(GenServer.server()) :: boolean()
  def authorization_configured?(server \\ __MODULE__) do
    GenServer.call(server, :authorization_configured?)
  catch
    :exit, _ -> false
  end

  @doc """
  Whether the READ seam has an authorizer. The network boot guards use this to
  refuse a server that would serve `resources/read` -- live model state -- to
  any client that connects. Returns `false` if the server is unreachable.

  Presence, not source: unlike `authorization_configured?/1` there is no
  framework fallback here worth telling apart. A read authorizer exists only
  because someone configured one, and `Raxol.MCP.Deployment`'s tool-seam gate
  is what carries the "nobody decided" argument.
  """
  @spec read_authorization_configured?(GenServer.server()) :: boolean()
  def read_authorization_configured?(server \\ __MODULE__) do
    GenServer.call(server, :read_authorization_configured?)
  catch
    :exit, _ -> false
  end

  # -- GenServer Callbacks -------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    Process.flag(:trap_exit, true)

    registry = Keyword.get(opts, :registry, Registry)
    authorizer = Keyword.get(opts, :authorizer)
    read_authorizer = Keyword.get(opts, :read_authorizer)
    transport = transport!(Keyword.get(opts, :transport, :unknown))

    authorizer_source =
      authorizer_source!(Keyword.get(opts, :authorizer_source, :default))

    refuse_unguarded_sensitive_tools!(registry, authorizer)
    refuse_unguarded_reads!(transport, read_authorizer)

    {max_parked, max_parked_total} = parked_caps!(opts)

    {:ok,
     %__MODULE__{
       registry: registry,
       authorizer_source: authorizer_source,
       authorizer: authorizer,
       read_authorizer: read_authorizer,
       unknown_tool_reply: unknown_tool_reply!(Keyword.get(opts, :unknown_tool_reply)),
       transport: transport,
       elicitation_timeout_ms:
         Keyword.get(
           opts,
           :elicitation_timeout_ms,
           @default_elicitation_timeout_ms
         ),
       max_client_capabilities:
         max_client_capabilities!(
           Keyword.get(opts, :max_client_capabilities, @default_max_client_capabilities)
         ),
       max_in_flight: positive_option!(opts, :max_in_flight, @default_max_in_flight),
       max_parked_elicitations: max_parked,
       max_parked_elicitations_total: max_parked_total,
       callback_timeout_ms:
         positive_option!(opts, :callback_timeout_ms, @default_callback_timeout_ms)
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:handle_message, message, conn_id, request_ref}, from, state),
    do: handle_request(message, conn_id, request_ref, {:reply, from}, state)

  # A `request/3` caller does not block on its reply, so the reply can wait for
  # whatever the call waits on, an elicitation answer included.
  def handle_manager_call({:request, message, conn_id, request_ref}, from, state),
    do: handle_request(message, conn_id, request_ref, {:request, from, request_ref}, state)

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:authorization_configured?, _from, state) do
    {:reply, state.authorizer != nil and state.authorizer_source == :configured, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:read_authorization_configured?, _from, state) do
    {:reply, state.read_authorizer != nil, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:subscribe, pid, conn_id}, state) do
    if Map.get(state.subscribers, conn_id) == pid do
      {:noreply, state}
    else
      # Taking an id AWAY from a live subscriber is a new connection on it, so
      # it starts clean. The `:DOWN` path already reasons that a stale id must
      # not hand its capabilities or its parked elicitation to whoever takes it
      # next; that is just as true when the id is rebound while the old
      # subscriber is still alive, which `Map.put` alone let through.
      #
      # Only on a REBIND. A first subscribe must not clear, or it would discard
      # the capabilities of a connection that sent `initialize` before it
      # subscribed -- which is the order a direct in-VM caller naturally uses.
      state =
        if Map.has_key?(state.subscribers, conn_id),
          do: drop_connection(conn_id, state),
          else: state

      # One monitor per PID, not per connection. `{:DOWN, ...}` already drops
      # every id that pid held, so a process subscribed under several ids
      # would otherwise accumulate monitors and deliver as many DOWNs, all but
      # the first finding nothing left to clean up.
      unless pid in Map.values(state.subscribers), do: Process.monitor(pid)

      {:noreply, %{state | subscribers: Map.put(state.subscribers, conn_id, pid)}}
    end
  end

  def handle_manager_cast({:cancel_request, request_ref}, state) do
    {:noreply, cancel_in_flight(state, request_ref)}
  end

  # Resource-updated notifications honor resources/subscribe: with no
  # subscription for the URI, the notification is not broadcast. This is
  # what makes the subscribe call (and its authorization gate) meaningful
  # rather than write-only state.
  def handle_manager_cast(
        {:notify, "notifications/resources/updated" = method, params},
        state
      ) do
    uri = Map.get(params, "uri") || Map.get(params, :uri)

    if uri != nil and Map.has_key?(state.resource_subscriptions, uri) do
      broadcast(state.subscribers, Protocol.notification(method, params))
    end

    {:noreply, state}
  end

  def handle_manager_cast({:notify, method, params}, state) do
    notification = Protocol.notification(method, params)
    broadcast(state.subscribers, notification)
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:mcp_request_result, request_ref, result}, state) do
    case pop_in_flight(state, request_ref) do
      {:ok, entry, state} ->
        {:noreply, complete_async(entry, result, state)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_manager_info({:mcp_request_timeout, request_ref}, state) do
    case pop_in_flight(state, request_ref) do
      {:ok, entry, state} ->
        stop_worker(entry)
        {:noreply, deliver_async(entry, callback_error(entry.work, :callback_timeout), state)}

      :error ->
        {:noreply, state}
    end
  end

  # A `request/3` caller that exits takes its outstanding request with it:
  # nobody is left to answer, so it is cancelled like any other.
  def handle_manager_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.caller_refs, ref),
      do: {:noreply, cancel_in_flight(state, Map.fetch!(state.caller_refs, ref))}

  # Worker monitors and subscriber monitors share this mailbox. Resolve worker
  # refs first; a callback crash fails only its own request. Every other DOWN is
  # the existing subscriber cleanup path.
  def handle_manager_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.worker_refs, ref) do
      {:ok, request_ref} ->
        case pop_in_flight(state, request_ref) do
          {:ok, entry, state} ->
            Logger.error("[MCP.Server] callback worker crashed: #{inspect(reason)}")
            response = callback_error(entry.work, :callback_crashed)
            {:noreply, deliver_async(entry, response, state)}

          :error ->
            {:noreply, state}
        end

      :error ->
        gone =
          state.subscribers
          |> Enum.filter(fn {_conn_id, subscriber} -> subscriber == pid end)
          |> Enum.map(fn {conn_id, _} -> conn_id end)

        {:noreply, Enum.reduce(gone, state, &drop_connection/2)}
    end
  end

  # The client advertised elicitation, was asked, and never answered. Close the
  # parked call with the same deny it would have got had it never advertised --
  # an unanswered prompt is not an approval.
  def handle_manager_info({:elicitation_timeout, id}, state) do
    case Map.fetch(state.pending_elicitations, id) do
      {:ok, pending} ->
        {_pending, state} = take_pending(state, id)

        {:noreply,
         answer_parked(
           state,
           pending,
           authorization_required(
             pending.request_id,
             pending.tool,
             :ask,
             "elicitation timed out"
           )
         )}

      :error ->
        {:noreply, state}
    end
  end

  # Linked callback workers are also monitored. EXIT is lifecycle coupling
  # only; result and failure attribution is driven by the monitor ref above.
  def handle_manager_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Isolated callback execution ---------------------------------------------

  defp handle_request(message, conn_id, request_ref, delivery, state) do
    message = drop_null_params(message)

    case async_action(message, state, conn_id) do
      {:call, work} ->
        start_async_call(work, request_ref, delivery, state)

      {:push, pending, work} ->
        {_pending, state} = take_pending(state, message.id)
        Process.cancel_timer(pending.timer)
        start_async_push(work, pending, state)

      {:reply, response} ->
        {:reply, {:reply, response}, state}

      :sync ->
        {response, state} = dispatch(message, state, conn_id)
        {:reply, {:reply, response}, state}
    end
  end

  # JSON-RPC lets a client send `"params": null` for a method that takes none;
  # it means the same as leaving `params` out.
  defp drop_null_params(%{params: nil} = message), do: Map.delete(message, :params)
  defp drop_null_params(message), do: message

  # `method` picks the handler, and the unknown-method reply prints it, so a
  # frame naming it with a number or an object is refused before either.
  defp async_action(%{method: method} = message, _state, _conn_id) when not is_binary(method) do
    case message do
      %{id: id} ->
        {:reply,
         Protocol.error_response(id, Protocol.invalid_request(), "method must be a string")}

      _notification ->
        {:reply, nil}
    end
  end

  # Every handler reads `params` as an object; JSON-RPC also allows an array,
  # which no MCP method takes. Refused here, before any handler, so a malformed
  # frame from one client cannot crash the server every connection shares.
  defp async_action(%{params: params} = message, _state, _conn_id) when not is_map(params) do
    case message do
      %{id: id, method: _method} ->
        {:reply,
         Protocol.error_response(id, Protocol.invalid_params(), "params must be an object")}

      _notification ->
        {:reply, nil}
    end
  end

  defp async_action(
         %{method: "tools/call", id: id, params: params},
         state,
         conn_id
       ) do
    name = Map.get(params, "name") || Map.get(params, :name, "")
    arguments = Map.get(params, "arguments") || Map.get(params, :arguments, %{})

    if state.authorizer == nil and sensitive_tool?(state.registry, name) do
      {:reply, authorization_required(id, name, :deny, :sensitive_tool_unguarded)}
    else
      {:call,
       {:authorize_tool, id, name, arguments, {state.registry, state.unknown_tool_reply},
        state.authorizer, authz_context(state, conn_id), conn_id}}
    end
  end

  defp async_action(%{method: "tools/list", id: id}, state, conn_id) do
    read_action(
      id,
      "tools/list",
      %{},
      {:tools_list, state.registry, state.authorizer},
      state,
      conn_id
    )
  end

  defp async_action(%{method: "resources/list", id: id}, state, conn_id) do
    read_action(
      id,
      "resources/list",
      %{},
      {:resources_list, state.registry},
      state,
      conn_id
    )
  end

  defp async_action(
         %{method: "resources/subscribe", id: id, params: params},
         state,
         conn_id
       ) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")
    read_action(id, "resources/subscribe", %{"uri" => uri}, {:subscribe, uri}, state, conn_id)
  end

  defp async_action(
         %{method: "resources/unsubscribe", id: id, params: params},
         state,
         conn_id
       ) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")

    read_action(
      id,
      "resources/unsubscribe",
      %{"uri" => uri},
      {:unsubscribe, uri},
      state,
      conn_id
    )
  end

  defp async_action(%{method: "resources/read", id: id, params: params}, state, conn_id) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")

    read_action(
      id,
      "resources/read",
      %{"uri" => uri},
      {:resource_read, state.registry, uri},
      state,
      conn_id
    )
  end

  defp async_action(%{method: "prompts/list", id: id}, state, conn_id) do
    read_action(
      id,
      "prompts/list",
      %{},
      {:prompts_list, state.registry},
      state,
      conn_id
    )
  end

  defp async_action(%{method: "prompts/get", id: id, params: params}, state, conn_id) do
    name = Map.get(params, "name") || Map.get(params, :name, "")
    arguments = Map.get(params, "arguments") || Map.get(params, :arguments, %{})

    read_action(
      id,
      "prompts/get",
      %{"name" => name, "arguments" => arguments},
      {:prompt_get, state.registry, name, arguments},
      state,
      conn_id
    )
  end

  defp async_action(
         %{method: "completion/complete", id: id, params: params},
         state,
         conn_id
       ) do
    ref = Map.get(params, "ref") || Map.get(params, :ref, %{})
    argument = Map.get(params, "argument") || Map.get(params, :argument, %{})

    read_action(
      id,
      "completion/complete",
      %{"ref" => ref},
      {:completion, state.registry, state.authorizer, ref, argument},
      state,
      conn_id
    )
  end

  # The level is checked before anyone is asked, so whatever the client sent
  # reaches the authorizer, and this process, only as a known level.
  defp async_action(
         %{method: "logging/setLevel", id: id, params: params},
         state,
         conn_id
       ) do
    level = Map.get(params, "level") || Map.get(params, :level, "info")

    case Map.fetch(@level_map, level) do
      {:ok, log_level} ->
        read_action(
          id,
          "logging/setLevel",
          %{"level" => level},
          {:set_log_level, log_level},
          state,
          conn_id
        )

      :error ->
        {:reply,
         Protocol.error_response(
           id,
           Protocol.invalid_params(),
           "Invalid log level: #{inspect(level)}. Valid: #{inspect(@log_levels)}"
         )}
    end
  end

  defp async_action(%{id: id, result: result}, state, conn_id) do
    case Map.fetch(state.pending_elicitations, id) do
      {:ok, %{owner: ^conn_id} = pending} ->
        if approved?(result) do
          {:push, pending,
           {:call_tool, pending.request_id, pending.tool, pending.arguments,
            {state.registry, state.unknown_tool_reply}}}
        else
          :sync
        end

      _other ->
        :sync
    end
  end

  defp async_action(_message, _state, _conn_id), do: :sync

  defp read_action(id, method, detail, operation, state, conn_id) do
    {:call,
     {:read_operation, id, method, detail, operation, state.read_authorizer,
      authz_context(state, conn_id)}}
  end

  defp approved?(result) do
    action = fetch_field(result, "action", nil)
    content = fetch_field(result, "content", %{})
    action == "accept" and fetch_field(content, "approve", false) == true
  end

  defp start_async_call(work, request_ref, delivery, state) do
    case start_worker(state, request_ref, work, delivery) do
      {:ok, state} ->
        {:noreply, state}

      :busy ->
        {:reply, {:reply, callback_error(work, :server_busy)}, state}
    end
  end

  defp start_async_push(work, pending, state) do
    {request_ref, delivery} = push_delivery(pending)

    case start_worker(state, request_ref, work, delivery) do
      {:ok, state} ->
        {:reply, {:reply, nil}, state}

      :busy ->
        state = answer_parked(state, pending, callback_error(work, :server_busy))
        {:reply, {:reply, nil}, state}
    end
  end

  # A call parked by a `request/3` caller is still outstanding, so the approved
  # tool runs under that request's ORIGINAL ref: cancelling the request, or its
  # caller exiting, reaches the tool. Any other caller was answered `nil` at the
  # park, so the result is pushed to the owning connection.
  defp push_delivery(%{caller: %{from: from, request_ref: request_ref}}),
    do: {request_ref, {:request, from, request_ref}}

  defp push_delivery(pending), do: {make_ref(), {:push, pending}}

  defp start_worker(state, request_ref, work, delivery) do
    if map_size(state.in_flight) >= state.max_in_flight do
      :busy
    else
      server = self()

      {pid, monitor_ref} =
        :erlang.spawn_opt(
          fn ->
            result = execute_async(work)
            send(server, {:mcp_request_result, request_ref, result})
          end,
          [:link, :monitor]
        )

      timer =
        Process.send_after(
          self(),
          {:mcp_request_timeout, request_ref},
          state.callback_timeout_ms
        )

      caller_monitor = monitor_caller(delivery)

      entry = %{
        pid: pid,
        monitor_ref: monitor_ref,
        timer: timer,
        delivery: delivery,
        work: work,
        caller_monitor: caller_monitor
      }

      {:ok,
       %{
         state
         | in_flight: Map.put(state.in_flight, request_ref, entry),
           worker_refs: Map.put(state.worker_refs, monitor_ref, request_ref),
           caller_refs: track_caller(state.caller_refs, caller_monitor, request_ref)
       }}
    end
  end

  defp execute_async({:authorize_tool, id, name, arguments, tools, authorizer, ctx, conn_id}) do
    case safe_decide(authorizer, name, arguments, ctx) do
      :allow ->
        {:response, call_tool_response(id, name, call_tool(tools, name, arguments))}

      {:ask, prompt} ->
        {:ask, id, name, arguments, prompt, conn_id}

      {:deny, reason} ->
        {:response, authorization_required(id, name, :deny, reason)}
    end
  end

  defp execute_async({:call_tool, id, name, arguments, tools}) do
    {:response, call_tool_response(id, name, call_tool(tools, name, arguments))}
  end

  defp execute_async({:read_operation, id, method, detail, operation, read_authorizer, ctx}) do
    case safe_decide(read_authorizer, method, detail, ctx) do
      :allow ->
        execute_read_operation(id, operation, ctx)

      {:ask, _prompt} ->
        {:response, authz_error_response(id, method, :interactive_approval_unsupported)}

      {:deny, reason} ->
        {:response, authz_error_response(id, method, reason)}
    end
  end

  defp execute_read_operation(id, {:tools_list, registry, nil}, _ctx) do
    {:response, Protocol.response(id, %{tools: Registry.list_tools(registry)})}
  end

  defp execute_read_operation(id, {:tools_list, registry, tool_authorizer}, ctx) do
    tools =
      registry
      |> Registry.list_tools()
      |> Enum.filter(fn tool ->
        name = Map.get(tool, :name) || Map.get(tool, "name")
        safe_decide(tool_authorizer, name, %{}, ctx) == :allow
      end)

    {:response, Protocol.response(id, %{tools: tools})}
  end

  defp execute_read_operation(id, {:resources_list, registry}, _ctx) do
    {:response, Protocol.response(id, %{resources: Registry.list_resources(registry)})}
  end

  defp execute_read_operation(id, {:resource_read, registry, uri}, _ctx) do
    {:response, do_read_resource(id, uri, %{registry: registry})}
  end

  defp execute_read_operation(id, {:prompts_list, registry}, _ctx) do
    {:response, Protocol.response(id, %{prompts: Registry.list_prompts(registry)})}
  end

  defp execute_read_operation(id, {:prompt_get, registry, name, arguments}, _ctx) do
    {:response, do_get_prompt(id, name, arguments, %{registry: registry})}
  end

  defp execute_read_operation(id, {:completion, registry, authorizer, ref, argument}, ctx) do
    completions =
      compute_completions(ref, argument, %{registry: registry, authorizer: authorizer}, ctx)

    {:response, Protocol.response(id, %{completion: %{values: completions}})}
  end

  defp execute_read_operation(id, {:subscribe, uri}, _ctx),
    do: {:read_mutation, id, :subscribe, uri}

  defp execute_read_operation(id, {:unsubscribe, uri}, _ctx),
    do: {:read_mutation, id, :unsubscribe, uri}

  defp execute_read_operation(id, {:set_log_level, level}, _ctx),
    do: {:read_mutation, id, :set_log_level, level}

  defp complete_async(entry, {:response, response}, state),
    do: deliver_async(entry, response, state)

  # A call that parks is answered now with `nil`, unless its caller came
  # through `request/3`: that request stays outstanding until whatever closes
  # the elicitation answers it.
  defp complete_async(
         %{delivery: delivery} = entry,
         {:ask, id, name, arguments, prompt, conn_id},
         state
       ) do
    caller = parked_caller(delivery)
    {response, state} = ask(id, name, arguments, prompt, state, conn_id, caller)

    if response == nil and caller != nil,
      do: state,
      else: deliver_async(entry, response, state)
  end

  defp complete_async(entry, {:read_mutation, id, :set_log_level, level}, state) do
    Logger.info("[MCP.Server] Log level set to #{level}")
    deliver_async(entry, Protocol.response(id, %{}), %{state | log_level: level})
  end

  defp complete_async(entry, {:read_mutation, id, action, uri}, state) do
    resource_subscriptions =
      case action do
        :subscribe -> Map.put_new(state.resource_subscriptions, uri, true)
        :unsubscribe -> Map.delete(state.resource_subscriptions, uri)
      end

    deliver_async(entry, Protocol.response(id, %{}), %{
      state
      | resource_subscriptions: resource_subscriptions
    })
  end

  defp complete_async(entry, _unexpected, state) do
    deliver_async(entry, callback_error(entry.work, :invalid_callback_result), state)
  end

  defp deliver_async(%{delivery: {:push, pending}}, response, state),
    do: answer_parked(state, pending, response)

  defp deliver_async(%{delivery: delivery}, response, state) do
    GenServer.reply(reply_to(delivery), {:reply, response})
    state
  end

  defp reply_to({:reply, from}), do: from
  defp reply_to({:request, from, _request_ref}), do: from

  defp parked_caller({:request, from, request_ref}), do: {from, request_ref}
  defp parked_caller(_delivery), do: nil

  defp monitor_caller({:request, {pid, _tag}, _request_ref}), do: Process.monitor(pid)
  defp monitor_caller(_delivery), do: nil

  defp track_caller(caller_refs, nil, _request_ref), do: caller_refs

  defp track_caller(caller_refs, monitor, request_ref),
    do: Map.put(caller_refs, monitor, request_ref)

  defp release_caller(caller_refs, nil), do: caller_refs

  defp release_caller(caller_refs, monitor) do
    Process.demonitor(monitor, [:flush])
    Map.delete(caller_refs, monitor)
  end

  defp callback_error(
         {:read_operation, id, method, _detail, _operation, _read_authorizer, _ctx},
         reason
       ) do
    Protocol.error_response(
      id,
      Protocol.internal_error(),
      "MCP callback failed",
      %{"error" => Atom.to_string(reason), "method" => method}
    )
  end

  defp callback_error(work, reason) do
    {id, name} = work_identity(work)
    call_tool_response(id, name, {:error, reason})
  end

  defp work_identity({:authorize_tool, id, name, _arguments, _tools, _authorizer, _ctx, _conn}),
    do: {id, name}

  defp work_identity({:call_tool, id, name, _arguments, _tools}), do: {id, name}

  defp cancel_in_flight(state, request_ref) do
    case pop_in_flight(state, request_ref) do
      {:ok, entry, state} ->
        stop_worker(entry)
        reply_cancelled(entry)
        state

      :error ->
        cancel_parked(state, request_ref)
    end
  end

  defp reply_cancelled(%{delivery: {:push, _pending}}), do: :ok

  defp reply_cancelled(%{delivery: delivery}),
    do: GenServer.reply(reply_to(delivery), {:reply, nil})

  # A `request/3` call parked for an elicitation answer is dropped, not denied:
  # its client cancelled it or its caller is gone, so it gets no response, and a
  # later answer to its prompt finds nothing to resume.
  defp cancel_parked(state, request_ref) do
    parked =
      Enum.find(state.pending_elicitations, fn {_id, pending} ->
        match?(%{caller: %{request_ref: ^request_ref}}, pending)
      end)

    case parked do
      {id, pending} ->
        {_pending, state} = take_pending(state, id)
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.caller.from, {:reply, nil})
        state

      nil ->
        state
    end
  end

  defp pop_in_flight(state, request_ref) do
    case Map.pop(state.in_flight, request_ref) do
      {nil, _in_flight} ->
        :error

      {entry, in_flight} ->
        Process.cancel_timer(entry.timer)
        Process.unlink(entry.pid)
        Process.demonitor(entry.monitor_ref, [:flush])

        {:ok, entry,
         %{
           state
           | in_flight: in_flight,
             worker_refs: Map.delete(state.worker_refs, entry.monitor_ref),
             caller_refs: release_caller(state.caller_refs, entry.caller_monitor)
         }}
    end
  end

  defp stop_worker(entry) do
    if Process.alive?(entry.pid), do: Process.exit(entry.pid, :kill)
    :ok
  end

  # -- Dispatch -----------------------------------------------------------------

  # Only four messages care WHICH connection sent them: `initialize` (whose
  # capabilities are that client's alone), `tools/call` (which may park an
  # elicitation owned by it), and the two response shapes that answer one. The
  # rest route by method alone and fall through to `dispatch_common/3` -- which
  # still receives the connection, flattened into the authorization context,
  # because every gated surface authorizes against WHO is asking.

  defp dispatch(%{method: "initialize", id: id} = msg, state, conn_id) do
    result = %{
      protocolVersion: Protocol.mcp_protocol_version(),
      capabilities: capabilities(),
      serverInfo: server_info()
    }

    # Remember what the CLIENT can do, PER CONNECTION. `elicitation` is the one
    # that changes behaviour: it is the difference between denying an ASK and
    # asking. Held globally, one client advertising it would turn prompting on
    # for every other client on the server.
    #
    # This map is keyed by connection and evicted on that connection's `:DOWN`.
    # A key nobody subscribes under never gets one, which is why the map is also
    # capped; see `put_client_capabilities/3`. A transport that mints a fresh
    # key per REQUEST for callers it cannot identify would still churn that cap
    # and push out other clients' entries; see `Transport.SSE`, which collapses
    # those onto one shared key for that reason.
    client_capabilities =
      msg
      |> Map.get(:params, %{})
      |> fetch_field("capabilities", %{})

    state = put_client_capabilities(%{state | initialized: true}, conn_id, client_capabilities)

    {Protocol.response(id, result), state}
  end

  # The client's answer to an `elicitation/create` we sent. It arrives as an
  # ordinary inbound message, so it is dispatched like one -- but it is a
  # RESPONSE (id + result, no method), and it resumes a `tools/call` that is
  # still parked.
  #
  # Knowing the id is NOT authority to answer: ids are server-minted and travel
  # to exactly one connection, so a request from anyone else carrying one is
  # either a forgery or a mix-up. `owned_pending/3` refuses both, and refuses
  # them the same way an unknown id is refused, so a prober cannot use the
  # difference to learn that an id exists.
  defp dispatch(%{id: id, result: result}, state, conn_id) do
    case owned_pending(state, id, conn_id) do
      {:ok, pending, state} ->
        {nil, answer_parked(state, pending, resume(pending, result))}

      :error ->
        dispatch_common(
          %{id: id, result: result},
          state,
          authz_context(state, conn_id)
        )
    end
  end

  # An error response to our elicitation is a refusal, not a crash.
  defp dispatch(%{id: id, error: error}, state, conn_id) do
    case owned_pending(state, id, conn_id) do
      {:ok, pending, state} ->
        {nil,
         answer_parked(
           state,
           pending,
           authorization_required(
             pending.request_id,
             pending.tool,
             :ask,
             "elicitation failed"
           )
         )}

      :error ->
        dispatch_common(
          %{id: id, error: error},
          state,
          authz_context(state, conn_id)
        )
    end
  end

  defp dispatch(msg, state, conn_id),
    do: dispatch_common(msg, state, authz_context(state, conn_id))

  defp dispatch_common(%{method: "notifications/initialized"}, state, _ctx) do
    {nil, state}
  end

  defp dispatch_common(%{method: "ping", id: id}, state, _ctx) do
    {Protocol.response(id, %{}), state}
  end

  # -- Tools ---

  # tools/list is a read/metadata surface too: names, descriptions, and
  # input schemas are the same enumeration class the other gates close. The
  # method-level gate answers "may this caller enumerate at all"; the listing
  # itself is then filtered per tool, because "yes" to enumerating is not yes
  # to the whole surface.
  defp dispatch_common(%{method: "tools/list", id: id}, state, ctx) do
    case authorize_read("tools/list", %{}, state, ctx) do
      :allow ->
        {Protocol.response(id, %{tools: visible_tools(state, ctx)}), state}

      {:deny, detail} ->
        {authz_error_response(id, "tools/list", detail), state}
    end
  end

  # The direct-caller entry to the conn-aware clause, guarded on the SAME keys
  # that clause matches. Without the guard the two layers bounce a `tools/call`
  # missing either key between them forever: the conn-aware clause declines it,
  # the generic clause forwards it to `dispatch_common/3`, and here forwards it
  # back. That runs inside a `GenServer.call(:infinity)`, so one malformed
  # frame -- which the SSE transport will happily decode, since
  # `normalize_body_params/1` only sets `:params` when the client sent one --
  # spins the server forever and it never serves another request, for any
  # client.
  defp dispatch_common(%{method: "tools/call"} = msg, state, _ctx)
       when is_map_key(msg, :id) and is_map_key(msg, :params) do
    dispatch(msg, state, @default_conn)
  end

  # A `tools/call` that names no tool. Answered as bad parameters rather than
  # left to the catch-all, which would report a method it plainly recognises as
  # unknown.
  defp dispatch_common(%{method: "tools/call", id: id}, state, _ctx) do
    {Protocol.error_response(
       id,
       Protocol.invalid_params(),
       "tools/call requires params"
     ), state}
  end

  # -- Resources ---

  defp dispatch_common(%{method: "resources/list", id: id}, state, ctx) do
    case authorize_read("resources/list", %{}, state, ctx) do
      :allow ->
        resources = Registry.list_resources(state.registry)
        {Protocol.response(id, %{resources: resources}), state}

      {:deny, detail} ->
        {authz_error_response(id, "resources/list", detail), state}
    end
  end

  defp dispatch_common(
         %{method: "resources/subscribe", id: id, params: params},
         state,
         ctx
       ) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")

    case authorize_read("resources/subscribe", %{"uri" => uri}, state, ctx) do
      :allow ->
        # Track that this URI has active subscribers. Notifications for
        # subscribed URIs go to all transport-level subscribers.
        new_subs = Map.put_new(state.resource_subscriptions, uri, true)

        {Protocol.response(id, %{}), %{state | resource_subscriptions: new_subs}}

      {:deny, detail} ->
        {authz_error_response(id, "resources/subscribe", detail), state}
    end
  end

  # Gated like subscribe: subscriptions are URI-global (one set for all
  # transport subscribers), so an ungated unsubscribe would let a
  # denied-everything client delete another client's subscription.
  defp dispatch_common(
         %{method: "resources/unsubscribe", id: id, params: params},
         state,
         ctx
       ) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")

    case authorize_read("resources/unsubscribe", %{"uri" => uri}, state, ctx) do
      :allow ->
        new_subs = Map.delete(state.resource_subscriptions, uri)

        {Protocol.response(id, %{}), %{state | resource_subscriptions: new_subs}}

      {:deny, detail} ->
        {authz_error_response(id, "resources/unsubscribe", detail), state}
    end
  end

  defp dispatch_common(
         %{method: "resources/read", id: id, params: params},
         state,
         ctx
       ) do
    uri = Map.get(params, "uri") || Map.get(params, :uri, "")

    case authorize_read("resources/read", %{"uri" => uri}, state, ctx) do
      :allow ->
        {do_read_resource(id, uri, state), state}

      {:deny, detail} ->
        {authz_error_response(id, "resources/read", detail), state}
    end
  end

  # -- Prompts ---

  defp dispatch_common(%{method: "prompts/list", id: id}, state, ctx) do
    case authorize_read("prompts/list", %{}, state, ctx) do
      :allow ->
        prompts = Registry.list_prompts(state.registry)
        {Protocol.response(id, %{prompts: prompts}), state}

      {:deny, detail} ->
        {authz_error_response(id, "prompts/list", detail), state}
    end
  end

  defp dispatch_common(
         %{method: "prompts/get", id: id, params: params},
         state,
         ctx
       ) do
    name = Map.get(params, "name") || Map.get(params, :name, "")
    arguments = Map.get(params, "arguments") || Map.get(params, :arguments, %{})

    case authorize_read(
           "prompts/get",
           %{"name" => name, "arguments" => arguments},
           state,
           ctx
         ) do
      :allow ->
        {do_get_prompt(id, name, arguments, state), state}

      {:deny, detail} ->
        {authz_error_response(id, "prompts/get", detail), state}
    end
  end

  # -- Completion ---

  # Gated as a read surface: completions enumerate tool names, resource
  # URIs, prompt names, and LIVE headless session ids.
  defp dispatch_common(
         %{method: "completion/complete", id: id, params: params},
         state,
         ctx
       ) do
    ref = Map.get(params, "ref") || Map.get(params, :ref, %{})
    argument = Map.get(params, "argument") || Map.get(params, :argument, %{})

    case authorize_read("completion/complete", %{"ref" => ref}, state, ctx) do
      :allow ->
        completions = compute_completions(ref, argument, state, ctx)
        {Protocol.response(id, %{completion: %{values: completions}}), state}

      {:deny, detail} ->
        {authz_error_response(id, "completion/complete", detail), state}
    end
  end

  # -- Catch-all ---

  # Notifications we don't handle -- no response
  defp dispatch_common(%{method: _method} = msg, state, _ctx)
       when not is_map_key(msg, :id) do
    {nil, state}
  end

  # Unknown method with an id -- error response
  defp dispatch_common(%{method: method, id: id}, state, _ctx) do
    error =
      Protocol.error_response(
        id,
        Protocol.method_not_found(),
        "Unknown method: #{inspect(method)}"
      )

    {error, state}
  end

  # An inbound RESPONSE (id + result/error, no method) whose id we did not mint:
  # a late answer to an elicitation that already timed out, or a stray. JSON-RPC
  # says ignore it. Answering "Missing method" would bounce an error response AT
  # a response, which a strict peer can answer in turn -- a loop. Must sit above
  # the malformed-message clause, which would otherwise claim it.
  defp dispatch_common(msg, state, _ctx)
       when is_map_key(msg, :result) or is_map_key(msg, :error) do
    {nil, state}
  end

  # Malformed message
  defp dispatch_common(%{id: id}, state, _ctx) do
    error =
      Protocol.error_response(id, Protocol.invalid_request(), "Missing method")

    {error, state}
  end

  # Top-level keys that are strings mean the message did not come through
  # `Protocol.decode/1`, so no clause above can read it. A request still names
  # an id to answer, so its caller learns why instead of getting silence.
  defp dispatch_common(%{"id" => id, "method" => _method}, state, _ctx) do
    error =
      Protocol.error_response(
        id,
        Protocol.invalid_request(),
        "top-level keys must be atoms, as Raxol.MCP.Protocol.decode/1 returns them"
      )

    {error, state}
  end

  defp dispatch_common(_msg, state, _ctx) do
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

  defp format_resource_content(text) when is_binary(text),
    do: {text, "text/plain"}

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
        Protocol.error_response(
          id,
          Protocol.method_not_found(),
          "Tool not found: #{inspect(name)}"
        )

      {:unknown_tool_reply, text} ->
        Protocol.response(id, %{content: [%{type: "text", text: text}], isError: true})

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

  # `tools` is the registry and the `:unknown_tool_reply` function (see
  # "Unknown tools" in the moduledoc).
  defp call_tool({registry, unknown_tool_reply}, name, arguments) do
    case Registry.call_tool(registry, name, arguments) do
      {:error, :tool_not_found} -> tool_not_found(unknown_tool_reply, name)
      result -> result
    end
  end

  defp tool_not_found(reply, name) when is_function(reply, 1) and is_binary(name) do
    case reply.(name) do
      text when is_binary(text) -> {:unknown_tool_reply, text}
      nil -> {:error, :tool_not_found}
    end
  end

  defp tool_not_found(_reply, _name), do: {:error, :tool_not_found}

  defp do_read_resource(id, uri, state) do
    case ResourceRouter.resolve(state.registry, uri) do
      {:ok, content} ->
        {text, mime} = format_resource_content(content)

        result = %{
          contents: [%{uri: uri, text: text, mimeType: mime}]
        }

        Protocol.response(id, result)

      {:error, :resource_not_found} ->
        Protocol.error_response(
          id,
          Protocol.invalid_params(),
          "Resource not found: #{inspect(uri)}"
        )

      {:error, :circuit_open} ->
        Protocol.error_response(
          id,
          Protocol.internal_error(),
          "Resource temporarily unavailable (circuit open)"
        )

      {:error, reason} ->
        Protocol.error_response(id, Protocol.internal_error(), inspect(reason))
    end
  end

  defp do_get_prompt(id, name, arguments, state) do
    case Registry.get_prompt(state.registry, name, arguments) do
      {:ok, messages} ->
        Protocol.response(id, %{messages: messages})

      {:error, :prompt_not_found} ->
        Protocol.error_response(
          id,
          Protocol.method_not_found(),
          "Prompt not found: #{inspect(name)}"
        )

      {:error, reason} ->
        Protocol.error_response(id, Protocol.internal_error(), inspect(reason))
    end
  end

  # What an authorizer at either seam is told about the CALLER, as opposed to
  # the call. Server-derived facts only: the connection the request arrived on
  # and the transport this server was told it fronts. Without it no policy can
  # tell a stdio caller from an unauthenticated network one, which is most of
  # what a policy would want to key on.
  #
  # NOTHING the client asserts belongs in here -- not the `clientInfo` name or
  # version from `initialize`, not a header it chose. A policy keyed on a
  # client-asserted value is bypassed by asserting a different one, so shipping
  # one in this map would be shipping the bypass alongside the gate. Anything
  # added here must be something only the server can know.
  defp authz_context(state, conn_id) do
    %{conn_id: conn_id, transport: state.transport}
  end

  # Read surfaces (resources/read, resources/subscribe, resources/list,
  # prompts/get, prompts/list, completion/complete, logging/setLevel) consult
  # the DEDICATED :read_authorizer, not the tools/call authorizer: an existing
  # tool allowlist knows nothing about method names like "resources/read" and
  # would deny every read if the seams were shared. A nil read_authorizer
  # allows, which is the pre-gate behavior (reads open; stdio inherits the
  # OS boundary). There is no elicitation path here: ASK resolves to deny,
  # because the elicitation flow is shaped around approving a tool RUN --
  # and the operator-facing prompt is NOT echoed to the denied client.
  defp authorize_read(_op, _detail, %{read_authorizer: nil}, _ctx), do: :allow

  defp authorize_read(op, detail, state, ctx) do
    case Authorizer.decide(state.read_authorizer, op, detail, ctx) do
      :allow -> :allow
      {:ask, _prompt} -> {:deny, :interactive_approval_unsupported}
      {:deny, reason} -> {:deny, reason}
    end
  end

  # The entries of a `tools/list` this caller may actually invoke.
  #
  # A listing is an advertisement, and it must not advertise what the caller
  # cannot call. Each entry carries the tool's name, description, input schema
  # and its sensitive/destructive annotations, so an unfiltered listing hands
  # any accepted client a map of the live capability surface with the
  # interesting entries marked. Every entry therefore goes through the SAME
  # authorizer `tools/call` will consult.
  #
  # ASK hides exactly like DENY. An entry that needs an approval the caller
  # has not got is not callable now, and for a client that cannot elicit an
  # ASK is a flat deny -- advertising it as callable would be a lie about this
  # caller's surface.
  #
  # Decided with no arguments, because there is no call yet: a policy that can
  # only answer with arguments in hand has not said yes to the tool. It runs
  # through `safe_decide/4`, so a policy that raises on the empty map hides the
  # tool rather than taking the listing (and the server) down with it.
  #
  # A nil authorizer lists everything: stdio inherits the OS process boundary,
  # and that is the behaviour every embedder without a policy already has.
  defp visible_tools(%{authorizer: nil} = state, _ctx),
    do: Registry.list_tools(state.registry)

  defp visible_tools(state, ctx) do
    state.registry
    |> Registry.list_tools()
    |> Enum.filter(fn tool ->
      name = Map.get(tool, :name) || Map.get(tool, "name")
      safe_decide(state.authorizer, name, %{}, ctx) == :allow
    end)
  end

  # JSON-RPC application-defined error code for an authorization denial on a
  # read surface. Distinct from internal_error (-32603) so a policy denial
  # is never mistaken for a transient server fault and retry-looped. NOT
  # -32000/-32001/-32002: the MCP SDKs already use those (ConnectionClosed,
  # RequestTimeout, resource-not-found), and a client keying off them would
  # classify the denial as a transient fault -- the exact retry loop this
  # code exists to prevent.
  @authz_denied_code -32090

  # Read-surface denials are JSON-RPC errors (there is no tool-result shape to
  # carry an isError payload on these methods); the machine-readable detail
  # rides in the error `data` field.
  defp authz_error_response(id, method, detail) do
    Protocol.error_response(
      id,
      @authz_denied_code,
      "authorization_required: #{method}",
      %{
        "error" => "authorization_required",
        "method" => method,
        "detail" => authz_detail(detail)
      }
    )
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

  defp normalize_content(text) when is_binary(text),
    do: [%{type: "text", text: text}]

  defp normalize_content(other),
    do: [%{type: "text", text: inspect(other, pretty: true)}]

  # An authorizer is operator-supplied code. It runs in the same isolated
  # worker as the callback it guards, and this helper contains contract
  # violations, raises, exits, and throws as a deny. The response stays coarse;
  # the operator log keeps the stacktrace.
  defp safe_decide(authorizer, name, arguments, ctx) do
    case Authorizer.decide(authorizer, name, arguments, ctx) do
      :allow ->
        :allow

      {:ask, prompt} ->
        {:ask, prompt}

      {:deny, reason} ->
        {:deny, reason}

      other ->
        Logger.error(
          "[MCP.Server] authorizer returned #{inspect(other)} for #{inspect(name)}; " <>
            "expected :allow | {:ask, prompt} | {:deny, reason}. Denying."
        )

        {:deny, :authorizer_contract_violation}
    end
  rescue
    exception ->
      Logger.error(
        "[MCP.Server] authorizer raised for #{inspect(name)}: " <>
          Exception.format(:error, exception, __STACKTRACE__) <> " Denying."
      )

      {:deny, :authorizer_failed}
  catch
    kind, reason ->
      Logger.error(
        "[MCP.Server] authorizer #{kind} for #{inspect(name)}: #{inspect(reason)}. Denying."
      )

      {:deny, :authorizer_failed}
  end

  # A typo here would silently answer `false` forever and keep a network
  # transport from ever booting, which reads as "the gate is broken" rather than
  # "the option is wrong". Refuse instead.
  defp authorizer_source!(source) when source in [:configured, :default], do: source

  defp authorizer_source!(other) do
    raise ArgumentError,
          "Raxol.MCP.Server :authorizer_source must be :configured or :default, got: #{inspect(other)}"
  end

  # A typo'd transport must not read as "some other transport". This value is
  # handed to authorizers as fact, so `:SSE` silently reading as neither stdio
  # nor SSE would quietly change what every policy keyed on it decides.
  defp transport!(transport) when transport in @transports, do: transport

  defp transport!(other) do
    raise ArgumentError,
          "Raxol.MCP.Server :transport must be one of #{inspect(@transports)}, " <>
            "got: #{inspect(other)}"
  end

  defp max_client_capabilities!(max) when is_integer(max) and max > 0, do: max

  defp max_client_capabilities!(other) do
    raise ArgumentError,
          "Raxol.MCP.Server :max_client_capabilities must be a positive integer, " <>
            "got: #{inspect(other)}"
  end

  defp unknown_tool_reply!(reply) when is_nil(reply) or is_function(reply, 1), do: reply

  defp unknown_tool_reply!(other) do
    raise ArgumentError,
          "Raxol.MCP.Server :unknown_tool_reply must be a 1-arity function or nil, " <>
            "got: #{inspect(other)}"
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "Raxol.MCP.Server #{inspect(key)} must be a positive integer, " <>
                "got: #{inspect(other)}"
    end
  end

  # A per-connection share larger than the total cannot be used, and
  # configuring one says the operator misread which cap is which.
  defp parked_caps!(opts) do
    max_parked =
      positive_option!(opts, :max_parked_elicitations, @default_max_parked_elicitations)

    max_parked_total =
      positive_option!(
        opts,
        :max_parked_elicitations_total,
        @default_max_parked_elicitations_total
      )

    if max_parked > max_parked_total do
      raise ArgumentError,
            "Raxol.MCP.Server :max_parked_elicitations (#{max_parked}) must not exceed " <>
              ":max_parked_elicitations_total (#{max_parked_total})"
    end

    {max_parked, max_parked_total}
  end

  # Registering a tool that declares itself destructive/sensitive while no
  # authorizer is configured is a REFUSAL, not a warning: the whole point of the
  # annotation is that this tool must not run unattended, and booting anyway
  # would serve it wide open. The fix is one line at the call site -- pass an
  # authorizer (`Raxol.MCP.Authorizer.allow_all/0` if that is genuinely what you
  # want, which is at least then visible in the code).
  defp refuse_unguarded_sensitive_tools!(_registry, authorizer)
       when authorizer != nil, do: :ok

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

  # The read seam's boot gate. `Deployment.enforce_authorization!/2` counts only
  # the TOOL authorizer, so an embedder could satisfy the network gate while
  # leaving `:read_authorizer` nil -- and `resources/read` serves live model
  # state, `completion/complete` enumerates live session ids. The network gate
  # was satisfied; the reads were wide open.
  #
  # The per-call default stays `:allow`: stdio embedders rely on it and the OS
  # process boundary is a real boundary. What changes is that a server DECLARED
  # to front a network transport refuses to boot with the read seam open,
  # loudly, rather than serving model state quietly. stdio (and an undeclared
  # transport) is untouched.
  defp refuse_unguarded_reads!(transport, read_authorizer)
       when transport in @network_transports do
    Deployment.enforce_read_authorization!(
      read_authorizer != nil,
      "Raxol.MCP.Server fronting the #{transport} transport"
    )
  end

  defp refuse_unguarded_reads!(_transport, _read_authorizer), do: :ok

  # Static tools only, by origin: `Raxol.MCP.ToolSynchronizer` registers a
  # derived widget tool with `derived: true`. A Server restarted under its
  # supervisor while sessions are live finds their derived sensitive tools
  # registered, and refusing to boot on them would exhaust the restart
  # intensity and take the whole MCP tree down. The `tools/call` refusal
  # (`sensitive_tool?/2`) still holds them.
  defp sensitive_tool_names(registry) do
    registry
    |> Registry.static_tools()
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
      (Map.get(tool, :name) || Map.get(tool, "name")) == name and
        ToolDef.sensitive?(tool)
    end)
  catch
    # Fail CLOSED. This is the runtime backstop that makes the documented
    # "enforced twice" guarantee true, and it is consulted only when
    # `state.authorizer == nil`. A registry that is restarting made every
    # sensitive tool read as non-sensitive, so the backstop fell straight
    # through -- the one condition under which it is the only thing left.
    # Refusing a call while the registry is unavailable is the safe answer;
    # the caller can retry.
    :exit, _ -> true
  end

  # -- Elicitation --------------------------------------------------------------

  # An ASK with no way to ask is a deny. Elicitation needs BOTH a client that
  # advertised the capability AND a transport subscribed to carry the request --
  # without a subscriber the prompt would go nowhere and the call would park
  # until it timed out, which is strictly worse than answering now.
  #
  # Both conditions are read for THIS connection. Read globally, a second client
  # merely holding a stream open satisfied the subscriber half for everyone, and
  # any client's `initialize` satisfied the capability half.
  #
  # A parked call holds no worker, so `:max_in_flight` never bounded how many
  # one client could park: only the elicitation timeout did. A connection may
  # have at most `:max_parked_elicitations` calls parked and the server at most
  # `:max_parked_elicitations_total`. Both counts are kept as they change, so an
  # ASK on a server below the total does not scan every parked call in this
  # process every connection shares; only an ASK on a full one looks for a call
  # to close.
  defp ask(id, tool, arguments, prompt, state, conn_id, caller) do
    parked = Map.get(state.parked_counts, conn_id, 0)

    cond do
      not elicitation_capable?(state, conn_id) ->
        {authorization_required(id, tool, :ask, prompt), state}

      parked >= state.max_parked_elicitations ->
        {authorization_required(id, tool, :ask, "too many elicitations pending"), state}

      map_size(state.pending_elicitations) < state.max_parked_elicitations_total ->
        start_elicitation(id, tool, arguments, prompt, state, conn_id, caller)

      true ->
        case crowding_call(state, parked) do
          {:ok, elicit_id} ->
            state = close_for_room(state, elicit_id)
            start_elicitation(id, tool, arguments, prompt, state, conn_id, caller)

          :none ->
            {authorization_required(
               id,
               tool,
               :ask,
               "too many elicitations pending on this server"
             ), state}
        end
    end
  end

  # The total is shared by every client, so a full server is not first come,
  # first served: a client parking through several connections would otherwise
  # deny every other client's approvals for as long as it kept re-parking. A
  # connection holding fewer parked calls than the largest holder takes the
  # place of that holder's oldest call. Among several largest holders the
  # oldest call goes, so a newcomer's call is the last of theirs to be closed.
  defp crowding_call(state, parked) do
    largest = state.parked_counts |> Map.values() |> Enum.max()

    if largest > parked do
      {elicit_id, _pending} =
        state.pending_elicitations
        |> Enum.filter(fn {_id, p} -> Map.fetch!(state.parked_counts, p.owner) == largest end)
        |> Enum.min_by(fn {_id, p} -> p.parked_at end)

      {:ok, elicit_id}
    else
      :none
    end
  end

  defp close_for_room(state, elicit_id) do
    {pending, state} = take_pending(state, elicit_id)
    Process.cancel_timer(pending.timer)

    answer_parked(
      state,
      pending,
      authorization_required(
        pending.request_id,
        pending.tool,
        :ask,
        "too many elicitations pending on this server"
      )
    )
  end

  defp elicitation_capable?(state, conn_id) do
    Map.has_key?(state.subscribers, conn_id) and
      case Map.fetch(state.client_capabilities, conn_id) do
        {:ok, {_seq, caps}} -> fetch_field(caps, "elicitation", nil) != nil
        :error -> false
      end
  end

  # Record what `conn_id` advertised, stamped so the cap can tell old from new.
  # A re-`initialize` restamps the entry: the connection just showed it is
  # still there.
  #
  # Only one entry is added per call, so at most one needs to go. Entries
  # without a live subscriber go first: nothing will ever remove them
  # otherwise, and none of them can elicit anyway. That includes the entry
  # just written -- an unsubscribed newcomer does not push out a live client.
  # Only when every entry has a subscriber does the oldest live one go, which
  # costs it nothing but the ability to be asked until it re-initializes.
  defp put_client_capabilities(state, conn_id, caps) do
    entry = {System.unique_integer([:monotonic]), caps}
    all = Map.put(state.client_capabilities, conn_id, entry)

    if map_size(all) > state.max_client_capabilities do
      {victim, live?} = eviction_victim(all, state.subscribers)
      remaining = Map.delete(all, victim)

      :telemetry.execute(
        [:raxol, :mcp, :server, :client_capabilities_evicted],
        %{count: 1, size: map_size(remaining)},
        %{
          server: self(),
          max_client_capabilities: state.max_client_capabilities,
          live_subscriber: live?
        }
      )

      %{state | client_capabilities: remaining}
    else
      %{state | client_capabilities: all}
    end
  end

  defp eviction_victim(entries, subscribers) do
    {unsubscribed, live} =
      Enum.split_with(entries, fn {conn_id, _} -> not Map.has_key?(subscribers, conn_id) end)

    case unsubscribed do
      [] -> {oldest(live), true}
      _ -> {oldest(unsubscribed), false}
    end
  end

  defp oldest(entries) do
    {conn_id, _} = Enum.min_by(entries, fn {_conn_id, {seq, _caps}} -> seq end)
    conn_id
  end

  # Park the call and ask. Returning `nil` is what makes this safe for a
  # transport blocked in `handle_message`: it gets its reply immediately, so it
  # stays free to READ the client's answer. A `request/3` caller (`caller`) is
  # not blocked, so it gets no reply until the call closes, and is monitored
  # meanwhile. Both the prompt and the eventual response go to the OWNING
  # connection only.
  defp start_elicitation(request_id, tool, arguments, prompt, state, conn_id, caller) do
    elicit_id = mint_elicit_id()

    timer =
      Process.send_after(
        self(),
        {:elicitation_timeout, elicit_id},
        state.elicitation_timeout_ms
      )

    {caller, caller_refs} = park_caller(caller, state.caller_refs)

    pending = %{
      request_id: request_id,
      tool: tool,
      arguments: arguments,
      timer: timer,
      owner: conn_id,
      caller: caller,
      parked_at: System.unique_integer([:monotonic])
    }

    state = %{
      state
      | pending_elicitations: Map.put(state.pending_elicitations, elicit_id, pending),
        parked_counts: Map.update(state.parked_counts, conn_id, 1, &(&1 + 1)),
        caller_refs: caller_refs
    }

    send_to(state, conn_id, elicitation_request(elicit_id, tool, prompt))
    {nil, state}
  end

  defp park_caller(nil, caller_refs), do: {nil, caller_refs}

  defp park_caller({{pid, _tag} = from, request_ref}, caller_refs) do
    monitor = Process.monitor(pid)

    {%{from: from, request_ref: request_ref, monitor: monitor},
     Map.put(caller_refs, monitor, request_ref)}
  end

  # Unguessable, not merely unique. Ownership is what actually decides who may
  # answer, so this is defence in depth -- but a counter published the next id
  # to anyone who saw one, and there is no reason to hand that out.
  defp mint_elicit_id do
    "raxol-elicit-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  # Take a pending elicitation only for the connection that owns it. A wrong
  # owner is treated exactly like an unknown id: no state change, and the caller
  # falls through to the ordinary unknown-message path.
  defp owned_pending(state, id, conn_id) do
    case Map.fetch(state.pending_elicitations, id) do
      {:ok, %{owner: ^conn_id} = pending} ->
        {_pending, state} = take_pending(state, id)
        Process.cancel_timer(pending.timer)
        {:ok, pending, state}

      _ ->
        :error
    end
  end

  # Forget everything scoped to a connection that has gone away, and stop what
  # it started. Its parked calls are dropped unanswered (a `request/3` caller
  # still gets its one `{:reply, nil}`), and a tool an approval started for it
  # is killed: its result could only ever have been pushed to this connection.
  defp drop_connection(conn_id, state) do
    {mine, rest} =
      Enum.split_with(state.pending_elicitations, fn {_id, p} -> p.owner == conn_id end)

    state =
      Enum.reduce(mine, %{state | pending_elicitations: Map.new(rest)}, fn {_id, p}, acc ->
        Process.cancel_timer(p.timer)
        drop_parked(acc, p)
      end)

    pushed = for {ref, %{delivery: {:push, %{owner: ^conn_id}}}} <- state.in_flight, do: ref
    state = Enum.reduce(pushed, state, &cancel_in_flight(&2, &1))

    %{
      state
      | subscribers: Map.delete(state.subscribers, conn_id),
        client_capabilities: Map.delete(state.client_capabilities, conn_id),
        parked_counts: Map.delete(state.parked_counts, conn_id)
    }
  end

  defp drop_parked(state, %{caller: %{from: from}} = pending) do
    GenServer.reply(from, {:reply, nil})
    release_pending_caller(state, pending)
  end

  defp drop_parked(state, _pending), do: state

  defp release_pending_caller(state, %{caller: %{monitor: monitor}}),
    do: %{state | caller_refs: release_caller(state.caller_refs, monitor)}

  defp release_pending_caller(state, _pending), do: state

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
            description: "Approve running the #{inspect(tool)} tool"
          }
        },
        required: ["approve"]
      }
    })
  end

  # The parked call is never answered as the reply to the message that unparked
  # it: what arrived was a JSON-RPC *response*, and a response never gets a
  # reply. It is pushed, or, for a call still outstanding as a `request/3`
  # request, sent as that request's reply. This also makes all three
  # resolutions -- answered, errored, timed out -- take one identical path out.
  # The answer goes to the connection that made the call and nowhere else. The
  # payload is that call's tool RESULT, so broadcasting it handed every other
  # connected client the output of a tool they did not run.
  defp answer_parked(state, %{caller: %{from: from}}, response) do
    GenServer.reply(from, {:reply, response})
    state
  end

  defp answer_parked(state, pending, response) do
    send_to(state, pending.owner, response)
    state
  end

  defp take_pending(state, id) do
    {pending, rest} = Map.pop(state.pending_elicitations, id)
    state = %{state | pending_elicitations: rest, parked_counts: unpark(state, pending)}
    {pending, release_pending_caller(state, pending)}
  end

  defp unpark(state, nil), do: state.parked_counts

  defp unpark(state, %{owner: owner}) do
    case Map.fetch!(state.parked_counts, owner) do
      1 -> Map.delete(state.parked_counts, owner)
      count -> Map.put(state.parked_counts, owner, count - 1)
    end
  end

  # Approved answers are intercepted by `async_action/3` and run in a worker.
  # Every answer that reaches this synchronous fallback fails closed.
  defp resume(pending, result) do
    action = fetch_field(result, "action", nil)

    authorization_required(
      pending.request_id,
      pending.tool,
      :ask,
      "user #{inspect(action || "declined")}"
    )
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

  # Ordinary notifications DO go to every subscriber -- resource updates and log
  # messages are server-wide events, not answers to one client's request. Only
  # the elicitation path is per-connection, and it uses `send_to/3`.
  defp broadcast(subscribers, notification) do
    for {_conn_id, pid} <- subscribers, Process.alive?(pid) do
      send(pid, {:mcp_notification, notification})
    end
  end

  # Deliver to one connection. An unknown or dead connection drops the message:
  # there is no fallback to "everyone", which is the whole point.
  defp send_to(state, conn_id, message) do
    case Map.get(state.subscribers, conn_id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: send(pid, {:mcp_notification, message})
        :ok

      nil ->
        :ok
    end
  end

  defp compute_completions(ref, argument, state, ctx) do
    ref_type = Map.get(ref, "type") || Map.get(ref, :type, "")
    arg_name = Map.get(argument, "name") || Map.get(argument, :name, "")
    arg_value = Map.get(argument, "value") || Map.get(argument, :value, "")

    case {ref_type, arg_name} do
      {"ref/tool", "id"} ->
        # Complete session IDs from headless tools
        complete_session_ids(arg_value, state, ctx)

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

  # The live session ids are exactly what `raxol_list` answers, so they are
  # completed only for a caller the tool authorizer would let call it: an
  # operator who denies `raxol_list` to hide which sessions exist hides them
  # here too. Decided as `tools/list` decides a listing, with no arguments,
  # and ASK hides like DENY. A nil authorizer allows it, as it lists every
  # tool.
  defp session_ids_visible?(%{authorizer: nil}, _ctx), do: true

  defp session_ids_visible?(%{authorizer: authorizer}, ctx),
    do: safe_decide(authorizer, "raxol_list", %{}, ctx) == :allow

  defp complete_session_ids(prefix, state, ctx) when is_binary(prefix) do
    if session_ids_visible?(state, ctx) and Code.ensure_loaded?(Raxol.Headless) and
         function_exported?(Raxol.Headless, :list, 0) do
      Raxol.Headless.list()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.take(20)
    else
      []
    end
  end

  defp complete_session_ids(_prefix, _state, _ctx), do: []
end
