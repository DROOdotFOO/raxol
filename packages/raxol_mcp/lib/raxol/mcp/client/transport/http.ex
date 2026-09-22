if Code.ensure_loaded?(Mint.HTTP) do
  defmodule Raxol.MCP.Client.Transport.Http do
    @moduledoc """
    The hosted-endpoint transport: dual era, target-policed, and metered.

    ADR-0037 decisions 2, 3, 5, 6 and 7. `Raxol.MCP.Client` could only spawn a
    local subprocess, which left every hosted MCP server unreachable by the
    client that ADR-0033 plans to reuse for Tron and Canton.

    ## Dual era

    The current specification (2026-07-28) removed the handshake and the
    session; the servers measured on 2026-08-31 still require both. So the era
    is probed with `server/discover` and cached per `{origin, path}`
    (`Raxol.MCP.Client.Era`), and the probe's demotion rule is deliberately
    narrow: a refusal is not an era. The probe runs in the client's process at
    connect time, once, because nothing can be sent until its answer is known;
    a LATER probe, the one a rejected session triggers, runs in a monitored
    task like every other exchange here.

    ## Every request is a monitored task

    `send/3` returns as soon as the request is on its way, so the client's
    GenServer never blocks its own mailbox for a round trip -- which would make
    the `:pooled` concurrency policy meaningless -- and a task that dies fails
    exactly ONE pending entry instead of orphaning it. The task carries its own
    monitor reference, so a completed request is demonitored precisely rather
    than by scanning.

    ## The target rules, in one place

    ADR-0033 section 7, enforced here rather than per backend:

      1. `https` only, through `Raxol.Core.Outbound.vet/2`'s default.
      2. Every resolved address checked against the reject set, both families,
         refusing the whole request if ANY answer is rejected.
      3. The checked address is the address dialled
         (`Raxol.MCP.Client.Transport.Http.Exchange`).
      4. **Redirects are not followed.** A 3xx is an error. That matters more
         here than for a REST client: this transport sends an `Authorization`
         header, so following a 3xx would replay a bearer token at an
         upstream-chosen origin.
      5. Time and response size are bounded by the exchange; concurrency is
         bounded by the session profile `session/1` reports, which the client
         turns into an in-flight cap and a bounded queue.

    `:transport_opts` is deliberately not an option. TLS options belong to the
    dial, which refuses the four that would weaken a handshake, and accepting
    one here would be a second place to look for a `verify: :verify_none`.

    ## Credentials

    Header values arrive as resolved literals and never reach a log line, a
    telemetry measurement, a cache key or an error term. The error taxonomy is
    closed and carries no upstream text, no query string and no
    caller-influenced host:

        {:blocked, :invalid_url | :address | :source} | :dns_failed | :breaker_open
        | {:http, status} | {:redirect_refused, status} | {:too_large, limit}
        | {:timeout, :connect | :chunk | :deadline} | {:transport, atom()}
        | :session_rejected | {:task_down, atom()}
        | :unmetered_call | {:unknown_price, tool}

    The `Inspect` implementation below redacts header values, because a
    GenServer crash report prints its state and the handle lives in it.

    ## Metering

    A `tools/call` for a tool the spec declares as priced is refused unless the
    call carries a reservation handle, with no request issued. This is not
    redundant with the spend-gate hook: `hook.ex:21-31` records that backends
    whose `handles_tools_internally?/0` returns true drive their own tool loop
    and bypass that seam entirely, so a native harness reaches this transport
    with no hook in the path. An unknown price on a metered origin is denied by
    default and logged with the tool and the origin, so an operator sees a
    reason rather than an absence.
    """

    @behaviour Raxol.MCP.Client.Transport

    require Logger

    alias Raxol.Core.Outbound
    alias Raxol.MCP.CircuitBreaker
    alias Raxol.MCP.Client.Era
    alias Raxol.MCP.Client.Reservation
    alias Raxol.MCP.Client.SSE
    alias Raxol.MCP.Client.Tables
    alias Raxol.MCP.Client.Transport.Http.Exchange
    alias Raxol.MCP.Protocol

    @enforce_keys [:name, :vetted, :key, :tables]
    defstruct [
      :name,
      :vetted,
      :key,
      :tables,
      :era,
      :version,
      :session_id,
      :exchange,
      headers: [],
      bounds: [],
      era_ttl: [],
      prices: %{},
      metered: false,
      tasks: %{},
      reprobed?: false
    ]

    @type t :: %__MODULE__{}

    # Measured mandatory, not defensive: a POST without both types is refused
    # by at least one of the servers ADR-0033 probed
    # (`docs/proposals/web3-upstream-survey.md:79-82`).
    @accept "application/json, text/event-stream"

    @user_agent "raxol_mcp/#{Mix.Project.config()[:version]} (+https://raxol.io)"

    @discover_method "server/discover"

    # Names this transport owns. A spec cannot override them: `accept` is
    # mandatory, the `mcp-*` headers are the era contract, and a browser
    # `user-agent` from one spec would undo identifying honestly everywhere.
    @enforced_headers [
      "accept",
      "accept-encoding",
      "content-type",
      "content-length",
      "host",
      "user-agent",
      "mcp-method",
      "mcp-name",
      "mcp-protocol-version",
      "mcp-session-id"
    ]

    @bound_keys [:max_bytes, :deadline_ms, :chunk_timeout_ms, :connect_timeout_ms]

    # A spec may name any subset of these; the rest come from the process-wide
    # tables. Nothing else is a table.
    @table_keys [:eras, :breakers, :reservations]

    @impl Raxol.MCP.Client.Transport
    def connect(config) do
      # Dialling is the side effect, so the provenance gate is asked HERE and
      # not only by whoever assembled the spec: for a workspace-sourced
      # server, the tool list this connect fetches is what lands in the
      # model's context.
      with :ok <- Raxol.MCP.Client.Transport.permit(config, Map.fetch!(config, :url)),
           {:ok, vetted} <- vet(config) do
        handle = %__MODULE__{
          name: Map.get(config, :name),
          vetted: vetted,
          key: Era.key(vetted.uri),
          tables: tables(config),
          headers: spec_headers(config),
          exchange: Map.get(config, :exchange, &Exchange.run/3),
          bounds: bounds(config),
          era_ttl: era_ttl(config),
          prices: prices(config),
          metered: metered?(config)
        }

        resolve_era(handle)
      end
    end

    @doc """
    The negotiated session profile.

    A modern origin needs no handshake and tolerates a fan-out. A legacy one
    handshakes and defaults to `:serialized`, because one of the three measured
    upstreams answers 500 to BOTH of two parallel calls on one session,
    reproducibly, and the failure is invisible to a single-call test. A spec
    that declares `:concurrency` overrides this.
    """
    @impl Raxol.MCP.Client.Transport
    def session(%__MODULE__{era: :modern}) do
      {:ready, %{version: Protocol.modern_version(), concurrency: :stateless}}
    end

    def session(%__MODULE__{era: :legacy}) do
      {:handshake, %{version: Protocol.legacy_version(), concurrency: :serialized}}
    end

    @impl Raxol.MCP.Client.Transport
    def send(%__MODULE__{} = handle, id, request) do
      with :ok <- meter(handle, request) do
        issue(handle, id, request)
      end
    end

    @impl Raxol.MCP.Client.Transport
    def close(%__MODULE__{tasks: tasks}) do
      Enum.each(tasks, fn {ref, task} ->
        Process.demonitor(ref, [:flush])
        Process.exit(task.pid, :kill)
      end)

      :ok
    end

    # The client's request timer fired while this task was still working. Its
    # `pending` entry is already gone, so `capacity?/1` will admit the next
    # queued request: the task has to go with the entry, or a `:serialized`
    # session ends up with two requests on the wire at once. `drop_task/2`
    # demonitors with `:flush`, so the kill produces no `:DOWN` to decode.
    @impl Raxol.MCP.Client.Transport
    def cancel(%__MODULE__{} = handle, id) do
      case Enum.find(handle.tasks, fn {_ref, task} -> cancels?(task, id) end) do
        {ref, task} ->
          Process.exit(task.pid, :kill)
          drop_task(handle, ref)

        nil ->
          handle
      end
    end

    defp cancels?(%{kind: :probe}, _id), do: false
    defp cancels?(%{id: {:notify, id}}, id), do: true
    defp cancels?(%{id: task_id}, id), do: task_id == id

    # The monitor reference identifies the task, so membership is checked
    # before the outcome is applied. `drop_task/2` hands back the handle
    # unchanged for a reference it does not know and the outcome was still
    # applied, so any process on the node could send `{:mcp_http, ref, id,
    # {:ok, messages, session_id}}` and feed `handle_line/2` forged JSON-RPC
    # payloads -- or set `mcp-session-id` through `remember_session/2`.
    @impl Raxol.MCP.Client.Transport
    def decode_info(%__MODULE__{} = handle, {:mcp_http, ref, id, outcome}) do
      case Map.get(handle.tasks, ref) do
        %{kind: :request, id: ^id} -> apply_outcome(drop_task(handle, ref), id, outcome)
        _unknown -> :ignore
      end
    end

    # The re-probe's verdict, applied here because this is where the handle
    # lives: only the exchange itself ran in the task. A refused probe is not
    # an era, so the handle keeps the verdict it already had -- `classify/2`
    # has recorded whatever the response said about the origin's health.
    def decode_info(%__MODULE__{} = handle, {:mcp_http_probe, ref, result}) do
      case Map.get(handle.tasks, ref) do
        %{kind: :probe} -> probe_verdict(drop_task(handle, ref), result)
        _unknown -> :ignore
      end
    end

    def decode_info(%__MODULE__{} = handle, {:DOWN, ref, :process, _pid, reason}) do
      case Map.pop(handle.tasks, ref) do
        {nil, _tasks} -> :ignore
        {task, tasks} -> task_down(handle, task, tasks, reason)
      end
    end

    def decode_info(%__MODULE__{}, _message), do: :ignore

    defp probe_verdict(handle, result) do
      case classify(result, handle) do
        {:ok, handle} -> {:messages, [], handle}
        {:error, _reason} -> {:messages, [], handle}
      end
    end

    # A dead task releases its in-flight slot under the same three id shapes
    # `fail/3` answers: a tracked notification and a request are reported so
    # the client can release the entry, an untracked notification has nobody
    # to answer and only leaves `tasks`.
    defp task_down(handle, %{kind: :probe}, tasks, _reason) do
      Logger.warning("[MCP.Client.Http] #{handle.name} era re-probe died")
      {:messages, [], %{handle | tasks: tasks}}
    end

    defp task_down(handle, %{id: {:notify, id}}, tasks, reason) do
      Logger.warning("[MCP.Client.Http] #{handle.name} notification task died")
      {:failed, id, {:task_down, exit_atom(reason)}, %{handle | tasks: tasks}}
    end

    defp task_down(handle, %{id: id}, tasks, reason) when is_integer(id) do
      {:failed, id, {:task_down, exit_atom(reason)}, %{handle | tasks: tasks}}
    end

    defp task_down(handle, %{id: nil}, tasks, _reason) do
      Logger.warning("[MCP.Client.Http] #{handle.name} notification task died")
      {:messages, [], %{handle | tasks: tasks}}
    end

    defp apply_outcome(handle, id, outcome) do
      case outcome do
        {:ok, messages, session_id} ->
          # A round trip that succeeded is the path back to a fresh probe.
          # `reprobed?` was set in `reprobe/2` and reset nowhere at all, so a
          # legacy origin whose session expired a SECOND time -- routine across
          # a server restart -- reached the guard clause and then failed every
          # later request as `:session_rejected` forever.
          #
          # Reset here rather than in `decide/2`, because that keeps the other
          # half of the guard: a burst of concurrent rejections with no
          # success between them still re-probes exactly once, instead of once
          # per rejected request.
          handle = %{handle | reprobed?: false}
          delivered(messages, id, remember_session(handle, session_id))

        :session_rejected ->
          reprobe(handle, id)

        {:error, reason} ->
          fail(handle, id, reason)
      end
    end

    # A notification's POST has an in-flight slot and no reply to deliver, so
    # its completion is the settle. Its body is not a response to anything
    # (the spec gives a notification none), so nothing is decoded from it.
    defp delivered(_messages, {:notify, id}, handle), do: {:settled, id, handle}
    defp delivered(messages, _id, handle), do: {:messages, messages, handle}

    # -- the target policy -------------------------------------------------------

    # `https` only, and the scheme list is not widened from the spec: the
    # default in `Raxol.Core.Outbound` is already `[:https]` and an `http://`
    # URL is refused as `:invalid_url`, which is the same answer to a caller as
    # a malformed one -- this is not a target we will dial.
    defp vet(config) do
      url = Map.fetch!(config, :url)
      opts = [schemes: [:https]] ++ resolver(config)

      case Outbound.vet(url, opts) do
        {:ok, vetted} -> {:ok, vetted}
        {:error, :invalid_url} -> {:error, {:blocked, :invalid_url}}
        {:error, {:blocked_address, _host}} -> {:error, {:blocked, :address}}
        {:error, {:dns_failed, _host}} -> {:error, :dns_failed}
      end
    end

    defp resolver(config) do
      case Map.get(config, :resolver) do
        fun when is_function(fun, 2) -> [resolver: fun]
        _absent -> []
      end
    end

    # -- the era probe -----------------------------------------------------------

    defp resolve_era(handle) do
      case Era.verdict(handle.tables.eras, handle.key, handle.era_ttl) do
        {:ok, era} -> {:ok, %{handle | era: era, version: version(era)}}
        :miss -> probe(handle)
      end
    end

    defp probe(handle) do
      with :ok <- breaker(handle) do
        request = wire(%{handle | era: :probe, version: Protocol.legacy_version()}, 1, discover())

        handle.exchange.(handle.vetted, request, handle.bounds)
        |> classify(handle)
      end
    end

    defp discover, do: %{method: @discover_method, params: %{}}

    defp classify({:error, reason}, handle) do
      record_failure(handle)
      {:error, reason}
    end

    defp classify({:ok, %{status: status} = response}, handle) when status in 200..299 do
      record_success(handle)

      case Era.evidence(jsonrpc_error(response)) do
        :demote -> decide(handle, :legacy)
        _no_evidence -> decide(handle, :modern)
      end
    end

    defp classify({:ok, %{status: status}}, _handle) when status in 300..399 do
      {:error, {:redirect_refused, status}}
    end

    # A JSON-RPC error does not only arrive under a 200. Measured on
    # 2026-09-14, one stateful upstream answers the probe `400` with
    # `{"code":-32601,...}` in the body, so a rule that read the body for a 2xx
    # only would classify nothing and leave that origin unreachable. The code
    # is the more specific evidence, so it is asked first and the status is the
    # fallback.
    defp classify({:ok, %{status: status} = response}, handle) do
      case era_evidence(response, status) do
        :demote ->
          record_success(handle)
          decide(handle, :legacy)

        :health ->
          # Health information, not era information. The verdict is left
          # untouched, so one Cloudflare mitigation or one rate-limit burst
          # cannot cache `legacy` forever.
          record_failure(handle)
          {:error, {:http, status}}

        :none ->
          {:error, {:http, status}}
      end
    end

    defp era_evidence(response, status) do
      case Era.evidence(jsonrpc_error(response)) do
        :none -> Era.evidence({:status, status})
        evidence -> evidence
      end
    end

    defp decide(handle, era) do
      Era.remember(handle.tables.eras, handle.key, era)
      {:ok, %{handle | era: era, version: version(era)}}
    end

    defp version(:modern), do: Protocol.modern_version()
    defp version(:legacy), do: Protocol.legacy_version()

    # A session-rejected response re-probes exactly once per successful round
    # trip, then fails. The in-flight request fails either way: re-establishing
    # a legacy session means a fresh handshake, which belongs to the client's
    # session machine and not to a retry hidden inside a transport.
    #
    # The probe runs in a monitored task, like every other exchange this
    # module performs, and its verdict arrives as `{:mcp_http_probe, ref,
    # result}`. Calling `resolve_era/1` from here instead meant a synchronous
    # connect-and-read inside the client's `handle_manager_info`, which stalled
    # the whole mailbox -- every queued `call_tool` and every
    # `{:request_timeout, id}` -- for up to `deadline_ms`.
    defp reprobe(%__MODULE__{reprobed?: true} = handle, id) do
      fail(handle, id, :session_rejected)
    end

    defp reprobe(handle, id) do
      Era.forget(handle.tables.eras, handle.key)

      # The era is kept rather than cleared: a request issued while the probe
      # is in flight still has to build headers for a known era, and the
      # rejection established that the SESSION is gone, nothing more.
      handle = spawn_probe(%{handle | session_id: nil, reprobed?: true})

      fail(handle, id, :session_rejected)
    end

    # An open breaker means no probe, and the handle keeps `reprobed?` set: the
    # next successful round trip is what re-arms it.
    defp spawn_probe(handle) do
      case breaker(handle) do
        :ok -> monitored_probe(handle)
        {:error, _reason} -> handle
      end
    end

    defp monitored_probe(handle) do
      request = wire(%{handle | era: :probe, version: Protocol.legacy_version()}, 1, discover())
      owner = self()
      exchange = handle.exchange
      vetted = handle.vetted
      bounds = handle.bounds

      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            {:monitored, ref} ->
              Kernel.send(owner, {:mcp_http_probe, ref, exchange.(vetted, request, bounds)})
          end
        end)

      Kernel.send(pid, {:monitored, ref})
      %{handle | tasks: Map.put(handle.tasks, ref, %{id: nil, pid: pid, kind: :probe})}
    end

    # A notification has no caller to answer, but it does hold an in-flight
    # slot, and dropping the failure silently would leave the client holding
    # that slot until the request timer fired. Reported under its tracking
    # id, and logged, because nothing downstream will.
    defp fail(handle, {:notify, id}, reason) do
      Logger.warning("[MCP.Client.Http] #{handle.name} notification failed: #{inspect(reason)}")

      {:failed, id, reason, handle}
    end

    defp fail(handle, id, reason) when is_integer(id), do: {:failed, id, reason, handle}

    # A bare `nil` id: a notification nothing is tracking.
    defp fail(handle, _id, reason) do
      Logger.warning("[MCP.Client.Http] #{handle.name} notification failed: #{inspect(reason)}")

      {:messages, [], handle}
    end

    # -- metering ----------------------------------------------------------------

    defp meter(handle, %{method: "tools/call", params: params} = request) do
      tool = tool_name(params)

      case price(handle, tool) do
        :free ->
          :ok

        :priced ->
          consume(handle, Map.get(request, :reservation))

        :unknown ->
          Logger.warning(
            "[MCP.Client.Http] Refusing tool #{inspect(tool)} on " <>
              "#{Era.origin(handle.vetted.uri)}: no declared price on a metered origin"
          )

          {:error, {:unknown_price, tool}}
      end
    end

    defp meter(_handle, _request), do: :ok

    # Truthiness was the whole check, so any caller of the public
    # `Client.call_tool/4` could pass `reservation: "anything"` and this
    # transport could not tell a live reservation from a settled, refused or
    # invented one -- a nominal gate on the function that issues the request.
    # A handle is minted by `Raxol.Agent.McpSpendHook` against a budget and
    # SPENT here: a literal, a replay and one past its TTL are all as absent
    # as no handle at all.
    defp consume(handle, token) do
      case Reservation.consume(handle.tables.reservations, token) do
        :ok -> :ok
        :error -> {:error, :unmetered_call}
      end
    end

    defp price(%__MODULE__{metered: false}, _tool), do: :free

    defp price(%__MODULE__{prices: prices}, tool) do
      case Map.fetch(prices, tool) do
        {:ok, price} when is_integer(price) and price > 0 -> :priced
        {:ok, price} when is_number(price) -> :unknown
        _unknown -> :unknown
      end
    end

    defp tool_name(%{name: name}), do: name
    defp tool_name(%{"name" => name}), do: name
    defp tool_name(_params), do: nil

    # -- issuing a request -------------------------------------------------------

    defp issue(handle, id, request) do
      wire = wire(handle, id, request)
      owner = self()
      session = handle.session_id
      era = handle.era
      exchange = handle.exchange
      vetted = handle.vetted
      bounds = handle.bounds
      tables = handle.tables

      # The task learns its own monitor reference before it does any work, so
      # the reply identifies the exact monitor to release. Scanning the task map
      # for an id would misattribute two concurrent notifications, which both
      # carry no id.
      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            {:monitored, ref} ->
              outcome =
                deliver(%{
                  exchange: exchange,
                  vetted: vetted,
                  bounds: bounds,
                  tables: tables,
                  era: era,
                  session_id: session,
                  request: wire
                })

              Kernel.send(owner, {:mcp_http, ref, id, outcome})
          end
        end)

      Kernel.send(pid, {:monitored, ref})
      {:ok, %{handle | tasks: Map.put(handle.tasks, ref, %{id: id, pid: pid, kind: :request})}}
    end

    defp deliver(context) do
      with :ok <- task_breaker(context) do
        context.exchange.(context.vetted, context.request, context.bounds)
        |> outcome(context)
      end
    end

    defp outcome({:ok, %{status: status} = response}, context) when status in 200..299 do
      record(context, :success)
      {:ok, messages(response), session_header(response)}
    end

    defp outcome({:ok, %{status: status}}, _context) when status in 300..399 do
      {:error, {:redirect_refused, status}}
    end

    defp outcome({:ok, %{status: 404}}, %{era: :legacy, session_id: session})
         when is_binary(session) do
      :session_rejected
    end

    defp outcome({:ok, %{status: status}}, context) do
      if Era.unhealthy?(status),
        do: record(context, :failure),
        else: record(context, :success)

      {:error, {:http, status}}
    end

    # Our refusal of a well-formed response is not evidence about the upstream,
    # so it records neither success nor failure: quarantining an origin for
    # answering a question we should not have asked would be our bug charged to
    # it.
    defp outcome({:error, {:too_large, _limit} = reason}, _context), do: {:error, reason}

    defp outcome({:error, reason}, context) do
      record(context, :failure)
      {:error, reason}
    end

    defp messages(response) do
      case content_type(response.headers) do
        "text/event-stream" ->
          {payloads, _remainder} = SSE.payloads(response.body)
          payloads

        _json ->
          case String.trim(response.body) do
            "" -> []
            body -> [body]
          end
      end
    end

    # -- the wire request --------------------------------------------------------

    defp wire(handle, id, request) do
      %{
        method: "POST",
        path: path(handle.vetted.uri),
        headers: headers(handle, request),
        body: encode(id, request)
      }
    end

    defp encode(nil, %{method: method, params: params}) do
      Jason.encode_to_iodata!(Protocol.notification(method, params))
    end

    # Tracked by the client, id-less on the wire: nothing answers a
    # notification, so it must not carry a JSON-RPC id.
    defp encode({:notify, _id}, request), do: encode(nil, request)

    defp encode(id, %{method: method, params: params}) do
      Jason.encode_to_iodata!(Protocol.request(id, method, params))
    end

    defp headers(handle, request) do
      era_headers(handle, request) ++
        [
          {"accept", @accept},
          {"accept-encoding", "identity"},
          {"content-type", "application/json"},
          {"user-agent", @user_agent}
        ] ++ handle.headers
    end

    # Modern posts route on the method and the target name; legacy posts carry
    # the revision and, when the server issued one, the session. No
    # `mcp-session-id` is ever sent to a modern origin: SEP-2567 removed it, and
    # sending it would be a header a stateless server is entitled to reject.
    defp era_headers(%__MODULE__{era: :modern}, request) do
      [{"mcp-method", request.method}, {"mcp-name", target_name(request)}]
    end

    # The probe predates the verdict, so it carries what BOTH eras require. A
    # 2025-06-18 server refuses a request with no revision header -- and it
    # refuses it with a 400, which is not era evidence, so a modern-only probe
    # would wedge against exactly the servers the probe exists to recognise. A
    # modern server ignores the extra header. Measured against both reference
    # servers rather than assumed.
    defp era_headers(%__MODULE__{era: :probe} = handle, request) do
      [
        {"mcp-method", request.method},
        {"mcp-name", target_name(request)},
        {"mcp-protocol-version", handle.version}
      ]
    end

    defp era_headers(%__MODULE__{era: :legacy, session_id: nil} = handle, _request) do
      [{"mcp-protocol-version", handle.version}]
    end

    defp era_headers(%__MODULE__{era: :legacy} = handle, _request) do
      [
        {"mcp-protocol-version", handle.version},
        {"mcp-session-id", handle.session_id}
      ]
    end

    # The name of the thing the method addresses. A method that addresses no
    # named target repeats the method, because the header is required on every
    # modern post and an empty required header says less than a redundant one.
    defp target_name(%{method: "tools/call", params: params}) do
      tool_name(params) || "tools/call"
    end

    defp target_name(%{method: "resources/read", params: params}) do
      Map.get(params, :uri) || Map.get(params, "uri") || "resources/read"
    end

    defp target_name(%{method: method}), do: method

    defp path(%URI{path: path, query: nil}), do: path || "/"
    defp path(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

    # -- health ------------------------------------------------------------------

    defp breaker(handle) do
      case CircuitBreaker.check(handle.tables.breakers, {:origin, origin(handle)}) do
        :open ->
          Logger.debug(fn ->
            "[MCP.Client.Http] breaker open for #{Era.origin(handle.vetted.uri)}"
          end)

          {:error, :breaker_open}

        state when state in [:closed, :half_open] ->
          :ok
      end
    end

    defp task_breaker(context) do
      case CircuitBreaker.check(context.tables.breakers, {:origin, task_origin(context)}) do
        :open -> {:error, :breaker_open}
        state when state in [:closed, :half_open] -> :ok
      end
    end

    defp record(context, :success) do
      CircuitBreaker.record_success(context.tables.breakers, {:origin, task_origin(context)})
    end

    defp record(context, :failure) do
      CircuitBreaker.record_failure(context.tables.breakers, {:origin, task_origin(context)})
    end

    defp record_success(handle) do
      CircuitBreaker.record_success(handle.tables.breakers, {:origin, origin(handle)})
    end

    defp record_failure(handle) do
      CircuitBreaker.record_failure(handle.tables.breakers, {:origin, origin(handle)})
    end

    defp origin(handle), do: Era.origin(handle.vetted.uri)
    defp task_origin(context), do: Era.origin(context.vetted.uri)

    # -- configuration -----------------------------------------------------------

    # A supplied table is never discarded. The three keys are independent -- a
    # caller may own the breaker and not care which era cache it shares, which
    # is what `Raxol.Web3.Backend.Tron` asks for -- so a partial map fills its
    # gaps from the process-wide tables instead of being ignored. Ignoring it
    # sent the transport's breaker verdicts to a table nobody read.
    #
    # A key that is not one of the three is a typo for one that is, and
    # answering that with the process-wide table would be the same silent
    # substitution in a smaller disguise, so it raises at connect instead.
    defp tables(config) do
      case Map.get(config, :tables) do
        %{eras: _eras, breakers: _breakers, reservations: _reservations} = tables ->
          tables

        %{} = partial ->
          Map.merge(Tables.ensure_started(), vetted_tables(partial))

        _absent ->
          Tables.ensure_started()
      end
    end

    defp vetted_tables(partial) do
      case Map.keys(partial) -- @table_keys do
        [] ->
          partial

        unknown ->
          raise ArgumentError,
                ":tables has no #{inspect(unknown)}, only #{inspect(@table_keys)}"
      end
    end

    # Only the four bounds are read from the spec. `:transport_opts` is not a
    # key here by design, so there is no path from a spec to a TLS option.
    defp bounds(config) do
      config |> Map.take(@bound_keys) |> Map.to_list()
    end

    # A TTL of zero is a legitimate configuration and not an absent one: it
    # means never trust a cached verdict, which is what an origin mid-upgrade
    # or a test of the expiry wants.
    defp era_ttl(config) do
      case Map.get(config, :era_ttl_ms) do
        ttl when is_integer(ttl) and ttl >= 0 -> [ttl_ms: ttl]
        _absent -> []
      end
    end

    defp spec_headers(config) do
      config
      |> Map.get(:headers, [])
      |> Enum.map(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
      |> Enum.reject(fn {name, _value} -> name in @enforced_headers end)
    end

    defp prices(config) do
      case Map.get(config, :prices) do
        %{} = prices -> prices
        _absent -> %{}
      end
    end

    # An origin is metered either because it says so or because it declares a
    # price for anything at all. The second half is what makes "unknown price"
    # a denial rather than a free pass: a vendor that prices one tool is a
    # vendor that bills, and an undeclared tool on it is a bill we cannot see.
    defp metered?(config) do
      case Map.get(config, :metered) do
        flag when is_boolean(flag) -> flag
        _absent -> prices(config) != %{}
      end
    end

    # -- responses ---------------------------------------------------------------

    defp content_type(headers) do
      case List.keyfind(headers, "content-type", 0) do
        {_name, value} -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
        nil -> "application/json"
      end
    end

    defp session_header(response) do
      case List.keyfind(response.headers, "mcp-session-id", 0) do
        {_name, value} when is_binary(value) and value != "" -> value
        _absent -> nil
      end
    end

    defp remember_session(%__MODULE__{era: :legacy} = handle, session) when is_binary(session) do
      %{handle | session_id: session}
    end

    defp remember_session(handle, _session), do: handle

    # The probe's JSON-RPC error code, if it answered with one. A modern server
    # answers a result; a legacy one answers method-not-found, and only that
    # code demotes.
    defp jsonrpc_error(response) do
      with [payload | _rest] <- messages(response),
           {:ok, %{error: %{"code" => code}}} <- Protocol.decode(payload) do
        {:jsonrpc_error, code}
      else
        _no_error -> :none
      end
    end

    defp drop_task(handle, ref) do
      case Map.pop(handle.tasks, ref) do
        {nil, _tasks} ->
          handle

        {_task, tasks} ->
          Process.demonitor(ref, [:flush])
          %{handle | tasks: tasks}
      end
    end

    defp exit_atom(reason) when is_atom(reason), do: reason
    defp exit_atom({reason, _stack}) when is_atom(reason), do: reason
    defp exit_atom(_other), do: :unknown
  end

  defimpl Inspect, for: Raxol.MCP.Client.Transport.Http do
    import Inspect.Algebra

    # A GenServer crash report prints its state, and the client's state holds
    # this handle. ADR-0033 section 7 names the error path as where an upstream
    # credential leaks in practice, so the values never render.
    def inspect(handle, opts) do
      redacted = %{
        era: handle.era,
        version: handle.version,
        headers: Enum.map(handle.headers, fn {name, _value} -> {name, "[redacted]"} end),
        session_id: if(handle.session_id, do: "[redacted]"),
        in_flight: map_size(handle.tasks)
      }

      concat(["#Raxol.MCP.Client.Transport.Http<", to_doc(redacted, opts), ">"])
    end
  end
end
