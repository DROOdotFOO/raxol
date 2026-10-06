defmodule Raxol.Broker.MCP.Client do
  @moduledoc """
  The authenticated session to Robinhood's agent MCP server
  (`https://agent.robinhood.com/mcp/trading`), and the only way to reach it.

  It owns one unregistered `Raxol.MCP.Client`, so nothing else in the VM can
  call the upstream around `call/3`'s authorization. Headers are fixed when an
  MCP client connects, so a new bearer means a new inner client: on refresh
  the old one is stopped and another is started with the new token.

  ## Read-only, fail closed

  `call/3` admits only the tools the server annotated `readOnlyHint: true`
  when its tool list was captured (`get_*`, `preview_scan`, `run_scan`,
  `search`). Everything else -- orders, cancels, reviews, watchlist, alert
  and scan mutators, and any name not on the list -- is
  `{:error, {:tool_denied, name}}` before any request is made. `list_tools/1`
  returns only the allowed tools, so what is offered is what may be called.

  ## Tokens

  * The tool list is fetched on connect and cached.
  * A refresh is scheduled `:refresh_skew` seconds (default 300) before
    `expires_at`; a credential without an expiry is never refreshed early.
    A credential already expired is refreshed before it is used.
  * A 401 (on a call, or at connect) starts ONE refresh: concurrent callers
    wait on it, and a 401 for a request sent with an older token is retried
    with the current one instead of refreshing again. The rotated credential
    is persisted with `Raxol.Broker.CredentialStore` BEFORE it is used, the
    inner client is restarted with it, and each waiting request is retried
    once.
  * A 401 on the retry, or on a token fresh from a refresh that has not yet
    succeeded once, means the grant is gone: every caller gets
    `{:error, :unauthorized}`, the inner client is stopped (so nothing keeps
    reconnecting with a dead token), and this process stays up answering
    `{:error, :unauthorized}` until it is restarted with a new sign-in. A
    refresh the server rejects (`invalid_grant`) ends the same way.
  * A 403 is never a reason to refresh; it is returned as `{:error, {:http, 403}}`.
  * A refresh whose rotated credential cannot be stored keeps the new
    credential in memory without using it (the old refresh token is spent),
    answers `{:error, {:store_failed, reason}}`, and retries the write on the
    next request.

  ## Throttling

  Every call this session makes is read-only, so a `429`, `502`, `503` or
  `504` is retried after a delay doubling from `:backoff`'s `:base_ms`
  (default 500, with jitter of up to half the delay) up to `:max_ms`
  (default 8000), at most `:retries` times (default 3). The throttle status
  comes back as `{:error, {:http, status}}` when the retries run out, when the
  next delay would pass the caller's `call/4` timeout, or when one more
  failure would open the session's circuit breaker.

  A connect throttled at its `initialize` handshake or its `tools/list`,
  including the reconnect after each refresh, is retried the same way, at
  most `:retries` times in a row, each time on a new inner client. The inner
  client runs with `fail_fast: true`, so a throttled handshake is seen at
  once and the client is stopped before its own retry: each broker attempt
  sends one `initialize`, and a throttled run sends at most `:retries + 1`.
  Queued callers wait for it, except one whose timeout would pass before the
  next delay plus a whole `:connect_timeout`, which gets
  `{:error, {:http, status}}` at once; when the retries run out they all get
  it, and the session stays up for the next call. A connect retry does not
  ask the breaker: each inner client starts on fresh breaker tables, and a
  run is bounded by `:retries` instead.

  Throttled answers are real failures on that breaker (5 in a row, by
  default, open it for 30 s). A call's retry is only sent if, counting every
  request in flight and every retry already scheduled as a failure, it still
  cannot open the breaker; sustained throttling across calls can still open
  it, and calls then answer `{:error, :breaker_open}` without a request until
  it recovers.
  A retry keeps the request's one post-refresh retry: a 401 after a throttle
  still locks the session out rather than refreshing again. The delay does
  not read `Retry-After`: the transport answers a non-2xx status without its
  headers. A caller that has exited is not retried for. Order tools never
  take this path (see `Raxol.Broker.Executor.Port`), so a throttled order is
  never resent. Invalid `:backoff` values stop `start_link/1` with
  `{:invalid_backoff, value}`.

  ## Options

  `:credential` (else read from the store), `:store` (options for
  `Raxol.Broker.CredentialStore`), `:url`, `:auth` (options for
  `Raxol.Agent.Auth.Robinhood.refresh/2`, e.g. `:http_fn`), `:mcp` (extra
  `Raxol.MCP.Client` spec keys such as `:resolver` or `:exchange`),
  `:refresh_skew`, `:backoff` (`:base_ms`, `:max_ms`, `:retries`),
  `:connect_timeout`, `:name`.

  Neither `Inspect` nor `format_status/1` (what `:sys.get_status/1` and crash
  reports print) shows the credential, and no log line here carries a token.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Agent.Auth.Robinhood
  alias Raxol.Broker.CredentialStore
  alias Raxol.MCP.CircuitBreaker
  alias Raxol.MCP.Client, as: Upstream
  alias Raxol.MCP.Client.Era
  alias Raxol.MCP.Client.Reservation

  @default_url "https://agent.robinhood.com/mcp/trading"
  @default_skew 300
  @default_connect_timeout 30_000
  @default_call_timeout 60_000
  @default_backoff %{base_ms: 500, max_ms: 8_000, retries: 3}
  @throttle_statuses [429, 502, 503, 504]
  # Observed 2026-10-03: the endpoint speaks 2025-06-18 (initialize +
  # Mcp-Session-Id) and refuses `server/discover` with a plain-text 400, which
  # the transport's probe correctly does not read as era evidence. Pinned, so
  # the probe is never sent.
  @era :legacy
  # `Process.send_after/3` refuses delays past 2^32 - 1 ms.
  @max_timer_ms 4_294_967_295

  # The tools Robinhood's server annotated `readOnlyHint: true` in the tool
  # list captured on 2026-10-02 (76 tools). Static and fail-closed on purpose:
  # an unannotated or unknown tool is denied. #1174 replaces this with the
  # generated catalog; order tools never go through this session, only through
  # the executor's own write port (`Raxol.Broker.Executor.Port`).
  @read_only_tools MapSet.new(~w(
    get_accounts get_alert_log get_alerts get_crypto_account_onboarding_info
    get_crypto_orders get_crypto_positions get_crypto_quotes get_currency_pairs
    get_earnings_calendar get_earnings_results get_equity_analyst_ratings
    get_equity_fundamentals get_equity_historicals get_equity_orders
    get_equity_positions get_equity_price_book get_equity_quotes
    get_equity_tax_lots get_equity_technical_indicators get_equity_tradability
    get_financials get_index_historicals get_index_quotes get_indexes
    get_limited_margin_upgrade_info get_option_chains get_option_historicals
    get_option_instruments get_option_level_upgrade_info get_option_orders
    get_option_positions get_option_quotes get_option_watchlist
    get_pnl_trade_history get_politician_trades get_popular_watchlists
    get_portfolio get_realized_pnl get_scanner_datapoints
    get_scanner_filter_specs get_scans get_sec_filing get_sec_filing_facts
    get_sec_filing_facts_catalog get_sec_filing_index get_watchlist_items
    get_watchlists preview_scan run_scan search
  ))

  defmodule State do
    @moduledoc false
    defstruct [
      :credential,
      :inner,
      :tables,
      :reservations,
      :tools,
      :task,
      :reconnect,
      :timer,
      :unpersisted,
      status: :connecting,
      generation: 0,
      reconnects: 0,
      scheduled_retries: 0,
      fresh: false,
      queue: [],
      requests: %{},
      config: %{}
    ]

    defimpl Inspect do
      def inspect(state, _opts) do
        "#Raxol.Broker.MCP.Client.State<status: #{inspect(state.status)}, " <>
          "generation: #{state.generation}, tools: #{tool_count(state.tools)}>"
      end

      defp tool_count(nil), do: "nil"
      defp tool_count(tools), do: Integer.to_string(length(tools))
    end
  end

  # -- public API -------------------------------------------------------------

  @doc "Start the broker session. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The allowed (read-only) tools, from the list fetched at connect."
  @spec list_tools(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(server, timeout \\ @default_call_timeout) do
    GenServer.call(server, {:list_tools, timeout}, timeout)
  end

  @doc """
  Call `tool_name` with `args`. A tool outside the read-only allowlist is
  `{:error, {:tool_denied, tool_name}}` and nothing is sent.
  """
  @spec call(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def call(server, tool_name, args, timeout \\ @default_call_timeout)
      when is_binary(tool_name) and is_map(args) do
    with :ok <- authorize_tool(tool_name) do
      GenServer.call(server, {:call, tool_name, args, timeout}, timeout)
    end
  end

  @doc """
  The authorization `call/3` applies: `:ok` for a read-only tool,
  `{:error, {:tool_denied, name}}` for anything else.
  """
  # The single decision point #1174's Catalog replaces. Order tools have their
  # own session (`Raxol.Broker.Executor.Port`). Checked again right before the
  # upstream call.
  @spec authorize_tool(String.t()) :: :ok | {:error, {:tool_denied, String.t()}}
  def authorize_tool(name) when is_binary(name) do
    if MapSet.member?(@read_only_tools, name), do: :ok, else: {:error, {:tool_denied, name}}
  end

  # -- GenServer --------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, credential} <- initial_credential(opts),
         {:ok, backoff} <- backoff_config(Keyword.get(opts, :backoff, [])) do
      url = Keyword.get(opts, :url, @default_url)

      config = %{
        url: url,
        origin: {:origin, Era.origin(URI.parse(url))},
        store: Keyword.get(opts, :store, []),
        auth: Keyword.get(opts, :auth, []),
        mcp: Keyword.get(opts, :mcp, []),
        skew: Keyword.get(opts, :refresh_skew, @default_skew),
        connect_timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout),
        backoff: backoff
      }

      state = %State{
        credential: credential,
        config: config,
        reservations: Reservation.new(:robinhood_reservations)
      }

      {:ok, state, {:continue, :start}}
    end
  end

  defp initial_credential(opts) do
    case Keyword.fetch(opts, :credential) do
      {:ok, %Credential{provider: :robinhood} = credential} ->
        {:ok, credential}

      :error ->
        case CredentialStore.fetch(Keyword.get(opts, :store, [])) do
          {:ok, credential} -> {:ok, credential}
          {:error, reason} -> {:stop, {:no_credential, reason}}
        end
    end
  end

  @impl GenServer
  def handle_continue(:start, state) do
    state = schedule_refresh(state)

    if expired?(state),
      do: {:noreply, start_refresh(state)},
      else: {:noreply, connect(state)}
  end

  @impl GenServer
  def handle_call({:list_tools, _timeout}, _from, %State{status: :unauthorized} = state),
    do: {:reply, {:error, :unauthorized}, state}

  def handle_call({:list_tools, _timeout}, _from, %State{tools: tools} = state)
      when is_list(tools),
      do: {:reply, {:ok, tools}, state}

  def handle_call({:list_tools, timeout}, from, state),
    do: {:noreply, admit(state, from, :list_tools, attempt(timeout))}

  def handle_call({:call, name, args, timeout}, from, state) do
    case authorize_tool(name) do
      :ok -> {:noreply, admit(state, from, {:call, name, args}, attempt(timeout))}
      denied -> {:reply, denied, state}
    end
  end

  @impl GenServer
  def handle_info({ref, result}, %State{task: {kind, ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finished(%{state | task: nil}, kind, result)
  end

  def handle_info({ref, result}, %State{requests: requests} = state)
      when is_reference(ref) and is_map_key(requests, ref) do
    Process.demonitor(ref, [:flush])
    {entry, requests} = Map.pop(requests, ref)
    {:noreply, completed(%{state | requests: requests}, entry, result)}
  end

  # A task that died never sent its result. Its exit reason is not logged:
  # it could be an exception carrying a request.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{task: {kind, ref}} = state) do
    failure = if kind == :connect, do: {:error, :upstream_down}, else: {:error, :refresh_crashed}
    finished(%{state | task: nil}, kind, failure)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{requests: requests} = state)
      when is_map_key(requests, ref) do
    {entry, requests} = Map.pop(requests, ref)
    {:noreply, completed(%{state | requests: requests}, entry, {:error, :upstream_down})}
  end

  def handle_info(
        {:refresh_due, generation},
        %State{generation: generation, status: :ready} = state
      ),
      do: {:noreply, start_refresh(%{state | timer: nil})}

  def handle_info({:refresh_due, _stale}, state), do: {:noreply, state}

  # The inner client is linked; this process traps exits so its death is a
  # message, not ours. A client that died unasked is replaced on next use.
  def handle_info({:EXIT, pid, _reason}, %State{inner: pid} = state) do
    drop_tables(state.tables)
    {:noreply, %{state | inner: nil, tables: nil, tools: nil}}
  end

  def handle_info({:backoff_retry, {pid, _tag} = from, request, attempt}, state) do
    state = %{state | scheduled_retries: max(state.scheduled_retries - 1, 0)}

    if caller_gone?(pid),
      do: {:noreply, state},
      else: {:noreply, admit(state, from, request, attempt)}
  end

  # The wait after a throttled connect. A refresh or a connect started
  # meanwhile cleared `reconnect`; a lock-out changed the status.
  def handle_info({:reconnect, ref}, %State{status: :connecting, reconnect: ref} = state),
    do: {:noreply, connect(%{state | reconnect: nil})}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    stop_inner(state)
    :ok
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {key, value} when key in [:state, :message, :reason] -> {key, scrub(value)}
      other -> other
    end)
  end

  defp finished(state, :connect, result), do: {:noreply, connected(state, result)}
  defp finished(state, :refresh, result), do: {:noreply, refreshed(state, result)}

  # -- admission --------------------------------------------------------------

  defp admit(%State{status: :unauthorized} = state, from, _request, _attempt) do
    GenServer.reply(from, {:error, :unauthorized})
    state
  end

  defp admit(%State{status: status} = state, from, request, attempt)
       when status in [:connecting, :refreshing] do
    enqueue(state, from, request, attempt)
  end

  defp admit(%State{unpersisted: %Credential{}} = state, from, request, attempt) do
    state |> start_refresh() |> enqueue(from, request, attempt)
  end

  defp admit(state, from, request, attempt) do
    cond do
      expired?(state) -> state |> start_refresh() |> enqueue(from, request, attempt)
      is_nil(state.inner) -> state |> connect() |> enqueue(from, request, attempt)
      true -> send_request(state, from, request, attempt)
    end
  end

  # Newest first; `flush_queue/1` and `fail_queue/2` restore arrival order.
  defp enqueue(state, from, request, attempt) do
    %{state | queue: [{from, request, attempt} | state.queue]}
  end

  defp send_request(state, from, request, attempt) do
    inner = state.inner
    task = Task.async(fn -> perform(inner, request) end)
    entry = {from, request, attempt, state.generation}
    %{state | requests: Map.put(state.requests, task.ref, entry)}
  end

  defp flush_queue(%State{queue: queue} = state) do
    queue
    |> Enum.reverse()
    |> Enum.reduce(%{state | queue: []}, fn {from, request, attempt}, acc ->
      admit(acc, from, request, attempt)
    end)
  end

  defp fail_queue(%State{queue: queue} = state, reply) do
    queue
    |> Enum.reverse()
    |> Enum.each(fn {from, _request, _attempt} -> GenServer.reply(from, reply) end)

    %{state | queue: []}
  end

  # Runs in a task: the only place the upstream is called.
  defp perform(inner, :list_tools), do: guarded(fn -> Upstream.list_tools(inner) end)

  defp perform(inner, {:call, name, args}) do
    with :ok <- authorize_tool(name) do
      guarded(fn -> Upstream.call_tool(inner, name, args) end)
    end
  end

  defp guarded(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :upstream_down}
  end

  # -- results ----------------------------------------------------------------

  defp completed(state, entry, result) do
    state |> disposition(entry, result) |> act(state, entry, result)
  end

  defp act(:unauthorized, state, {from, _request, _attempt, _generation}, _result) do
    GenServer.reply(from, {:error, :unauthorized})
    state
  end

  defp act(:retry_now, state, {from, request, attempt, _generation}, _result),
    do: admit(state, from, request, %{attempt | retried: true})

  defp act(:retry_after_refresh, state, {from, request, attempt, _generation}, _result),
    do: enqueue(state, from, request, %{attempt | retried: true})

  defp act(:reply, state, {from, request, attempt, generation}, result) do
    GenServer.reply(from, reply(request, attempt, result))
    mark_verified(state, generation, request, result)
  end

  defp act(:lock_out, state, {from, request, attempt, _generation}, _result),
    do: state |> enqueue(from, request, attempt) |> lock_out()

  defp act(:refresh, state, {from, request, attempt, _generation}, _result),
    do: state |> start_refresh() |> enqueue(from, request, %{attempt | retried: true})

  defp act(:backoff, state, {from, request, attempt, _generation}, result) do
    attempt = %{attempt | throttled: attempt.throttled + 1, last: result}

    Process.send_after(
      self(),
      {:backoff_retry, from, request, attempt},
      backoff_delay(state, attempt)
    )

    %{state | scheduled_retries: state.scheduled_retries + 1}
  end

  # A request sent with a token (or on an inner client) that has since been
  # replaced, or answered while that replacement is under way, is retried on
  # the new one rather than spending another refresh on a stale answer. A
  # 401 on a retry, or on a token fresh from a refresh, ends the session.
  defp disposition(state, {_from, _request, attempt, generation}, result) do
    cond do
      locked_out?(state, result) -> :unauthorized
      stale?(state, generation, result) -> :retry_now
      awaiting_refresh?(state, result) -> :retry_after_refresh
      retry_throttle?(state, attempt, result) -> :backoff
      not unauthorized?(result) -> :reply
      attempt.retried or state.fresh -> :lock_out
      true -> :refresh
    end
  end

  defp locked_out?(state, result),
    do: state.status == :unauthorized and match?({:error, _}, result)

  defp stale?(state, generation, result), do: generation < state.generation and retryable?(result)
  defp awaiting_refresh?(state, result), do: state.status == :refreshing and retryable?(result)

  # What a burst of 401s leaves behind on the inner client it hit: the
  # 401s themselves, the per-client breaker they opened, or the client this
  # process stopped to replace. None of them says anything about the new token.
  defp retryable?({:error, :upstream_down}), do: true
  defp retryable?({:error, :breaker_open}), do: true
  defp retryable?(result), do: unauthorized?(result)

  # What a request carries through the queue and its retries: whether it was
  # already retried after a refresh (a second 401 then locks out), how often
  # it was throttled and the last throttle answer, and the caller's deadline.
  defp attempt(timeout) do
    deadline = if timeout == :infinity, do: :infinity, else: now_ms() + timeout
    %{retried: false, throttled: 0, last: nil, deadline: deadline}
  end

  # A throttle status is retried while retries remain, the next delay ends
  # before the caller's deadline, and one more failure cannot open the breaker.
  defp retry_throttle?(state, attempt, {:error, {:http, status}})
       when status in @throttle_statuses do
    attempt.throttled < state.config.backoff.retries and
      within_deadline?(attempt, max_delay(state, attempt)) and
      breaker_headroom?(state)
  end

  defp retry_throttle?(_state, _attempt, _result), do: false

  defp max_delay(state, attempt) do
    %{base_ms: base, max_ms: max} = state.config.backoff
    min(base * Integer.pow(2, attempt.throttled), max)
  end

  # Between half the doubled delay and all of it, so callers throttled
  # together do not retry together.
  defp backoff_delay(state, attempt) do
    delay = max_delay(state, %{attempt | throttled: attempt.throttled - 1})
    half = div(delay, 2)
    half + :rand.uniform(delay - half + 1) - 1
  end

  defp within_deadline?(%{deadline: :infinity}, _delay), do: true
  defp within_deadline?(%{deadline: deadline}, delay), do: now_ms() + delay < deadline

  # Every request still in flight and every retry already scheduled may fail
  # too, so each counts as a failure the breaker has not seen yet.
  defp breaker_headroom?(%State{tables: %{breakers: breakers}, config: config} = state) do
    %{failures: failures} = CircuitBreaker.status(breakers, config.origin)
    pending = state.scheduled_retries + map_size(state.requests)
    failures + pending + 1 < CircuitBreaker.failure_threshold()
  end

  defp breaker_headroom?(_state), do: false

  # A throttled request whose retry found the breaker open answers with the
  # throttle status it was retrying, not with the breaker.
  defp reply(_request, %{last: {:error, _} = last}, {:error, :breaker_open}), do: last
  defp reply(request, _attempt, result), do: shape(request, result)

  defp caller_gone?(pid) when node(pid) == node(), do: not Process.alive?(pid)
  defp caller_gone?(_remote), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp backoff_config(opts) do
    with true <- Keyword.keyword?(opts),
         %{base_ms: base, max_ms: max, retries: retries} = backoff when map_size(backoff) == 3 <-
           Map.merge(@default_backoff, Map.new(opts)),
         true <- valid_backoff?(base, max, retries) do
      {:ok, backoff}
    else
      _invalid -> {:stop, {:invalid_backoff, opts}}
    end
  end

  defp valid_backoff?(base, max, retries),
    do:
      is_integer(base) and base >= 0 and is_integer(max) and max >= base and
        max <= @max_timer_ms and is_integer(retries) and retries >= 0

  defp shape(:list_tools, {:ok, tools}), do: {:ok, allowed(tools)}
  defp shape(_request, result), do: result

  defp mark_verified(%State{generation: generation} = state, generation, request, {:ok, value}) do
    state = %{state | fresh: false}
    if request == :list_tools, do: %{state | tools: allowed(value)}, else: state
  end

  defp mark_verified(state, _generation, _request, _result), do: state

  defp allowed(tools) do
    Enum.filter(tools, fn tool -> authorize_tool(tool_name(tool)) == :ok end)
  end

  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(_tool), do: ""

  # The status a request or connect failed with. A connect's is wrapped in
  # `{:connect_failed, _}`, and a handshake's in `{:initialization_failed, _}`
  # inside that.
  defp http_status({:error, {:http, status}}), do: status
  defp http_status({:error, {:connect_failed, {:http, status}}}), do: status

  defp http_status({:error, {:connect_failed, {:initialization_failed, {:http, status}}}}),
    do: status

  defp http_status(_result), do: nil

  defp unauthorized?(result), do: http_status(result) == 401

  # A throttle status as a throttled call answers it, unwrapped; else nil.
  defp throttle(result) do
    status = http_status(result)
    if status in @throttle_statuses, do: {:http, status}
  end

  # -- connecting -------------------------------------------------------------

  defp connect(state) do
    state = stop_inner(state)
    tables = new_tables(state)

    spec =
      [
        name: :robinhood,
        url: state.config.url,
        headers: [{"authorization", Credential.bearer(state.credential)}],
        era: @era,
        tables: tables,
        fail_fast: true
      ] ++
        Keyword.drop(state.config.mcp, [:name, :url, :headers, :tables, :registry, :fail_fast])

    case Upstream.start_link(spec) do
      {:ok, pid} ->
        timeout = state.config.connect_timeout
        task = Task.async(fn -> await_tools(pid, timeout) end)

        %{
          state
          | inner: pid,
            tables: tables,
            tools: nil,
            status: :connecting,
            task: {:connect, task.ref},
            reconnect: nil
        }

      {:error, reason} ->
        drop_tables(tables)
        log_failure("could not start the MCP client", reason)
        fail_queue(%{state | status: :ready}, {:error, reason})
    end
  end

  # A legacy session handshakes after the probe; `await_ready/2` waits for
  # that. The inner client is fail-fast, so a failed connect or handshake
  # (a 401, a throttle) answers the wait at once instead of after the budget.
  defp await_tools(pid, timeout) do
    guarded(fn ->
      case Upstream.list_tools(pid) do
        {:error, {:not_ready, _status}} ->
          with {:ok, _ready} <- Upstream.await_ready(pid, timeout),
               do: Upstream.list_tools(pid)

        other ->
          other
      end
    end)
  end

  # A connect throttled at its handshake or its tool list is retried while
  # `:retries` remain in this run of throttled connects; any other outcome
  # ends the run.
  defp connected(state, result) do
    if reconnect?(state, result),
      do: reconnect_later(state, {:error, throttle(result)}),
      else: settled(%{state | reconnects: 0}, result)
  end

  defp settled(state, {:ok, tools}) do
    flush_queue(%{state | status: :ready, tools: allowed(tools), fresh: false})
  end

  defp settled(state, result) do
    cond do
      unauthorized?(result) and state.fresh ->
        lock_out(state)

      unauthorized?(result) ->
        start_refresh(state)

      true ->
        reason = throttle(result) || error_reason(result)
        log_failure("could not connect", reason)
        fail_queue(%{state | status: :ready}, {:error, reason})
    end
  end

  defp reconnect?(state, result),
    do: throttle(result) != nil and state.reconnects < state.config.backoff.retries

  # A throttled call's backoff, per connect: the delay doubles with each
  # throttled connect in the run. A queued caller whose deadline would pass
  # before the next delay and a whole connect budget is answered now instead
  # of kept. The throttled inner client is stopped, which also cancels its own
  # retry, so the broker's `:retries` bounds the run.
  defp reconnect_later(state, reply) do
    limit = max_delay(state, %{throttled: state.reconnects}) + state.config.connect_timeout

    {waiting, expiring} =
      Enum.split_with(state.queue, fn {_from, _request, attempt} ->
        within_deadline?(attempt, limit)
      end)

    state = stop_inner(fail_queue(%{state | queue: expiring}, reply))
    reconnects = state.reconnects + 1
    ref = make_ref()
    Process.send_after(self(), {:reconnect, ref}, backoff_delay(state, %{throttled: reconnects}))
    %{state | queue: waiting, reconnects: reconnects, reconnect: ref}
  end

  defp error_reason({:error, reason}), do: reason
  defp error_reason(_other), do: :unexpected_response

  # Fresh era and breaker tables per inner client: a burst of 401s is an
  # authorization event, and must not leave a breaker open (or a cached era
  # that skips the probe) in front of the client started with the new token.
  defp new_tables(state) do
    %{
      eras: :ets.new(:robinhood_eras, [:set, :public]),
      breakers: CircuitBreaker.new(:robinhood_breakers),
      reservations: state.reservations
    }
  end

  defp stop_inner(%State{inner: nil} = state), do: state

  defp stop_inner(%State{inner: pid} = state) do
    try do
      Upstream.stop(pid)
    catch
      :exit, _reason -> :ok
    end

    drop_tables(state.tables)
    %{state | inner: nil, tables: nil}
  end

  defp drop_tables(nil), do: :ok

  defp drop_tables(tables) do
    :ets.delete(tables.eras)
    :ets.delete(tables.breakers)
    :ok
  end

  # -- refresh ----------------------------------------------------------------

  defp start_refresh(%State{status: :refreshing} = state), do: state

  defp start_refresh(state) do
    task = Task.async(refresh_work(state))
    %{state | status: :refreshing, task: {:refresh, task.ref}, reconnect: nil}
  end

  # The persist happens inside the task, before the result reaches this
  # process: a rotated credential is never used before it is on disk. A
  # credential that refreshed but failed to persist is kept (the old refresh
  # token is spent) and the next attempt only retries the write.
  defp refresh_work(%State{unpersisted: %Credential{} = pending, config: config}) do
    fn -> persist(pending, config.store) end
  end

  defp refresh_work(%State{credential: credential, config: config}) do
    fn ->
      case Robinhood.refresh(credential, config.auth) do
        {:ok, rotated} -> persist(rotated, config.store)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist(credential, store_opts) do
    case CredentialStore.put(credential, store_opts) do
      :ok -> {:ok, credential}
      {:error, reason} -> {:unpersisted, credential, reason}
    end
  end

  defp refreshed(state, {:ok, credential}) do
    Logger.info("[Broker.MCP] Robinhood token refreshed")

    %{
      state
      | credential: credential,
        unpersisted: nil,
        generation: state.generation + 1,
        fresh: true
    }
    |> schedule_refresh()
    |> connect()
  end

  defp refreshed(state, {:unpersisted, credential, reason}) do
    log_failure("refreshed but could not store the rotated credential", reason)

    %{state | unpersisted: credential, status: :ready}
    |> fail_queue({:error, {:store_failed, reason}})
  end

  defp refreshed(state, {:error, {:token_rejected, status, _code}}) when status in [400, 401] do
    lock_out(state)
  end

  defp refreshed(state, {:error, :no_refresh_token}), do: lock_out(state)

  defp refreshed(state, {:error, reason}) do
    log_failure("token refresh failed", reason)

    %{state | status: :ready}
    |> fail_queue({:error, {:refresh_failed, reason}})
  end

  defp lock_out(state) do
    Logger.warning("[Broker.MCP] Robinhood rejected the credential; sign in again")
    state = state |> stop_inner() |> cancel_timer()
    fail_queue(%{state | status: :unauthorized, tools: nil}, {:error, :unauthorized})
  end

  defp schedule_refresh(state) do
    state = cancel_timer(state)

    case state.credential.expires_at do
      nil ->
        state

      %DateTime{} = at ->
        delay =
          at
          |> DateTime.add(-state.config.skew, :second)
          |> DateTime.diff(DateTime.utc_now(), :millisecond)
          |> max(0)
          |> min(@max_timer_ms)

        %{state | timer: Process.send_after(self(), {:refresh_due, state.generation}, delay)}
    end
  end

  defp cancel_timer(%State{timer: nil} = state), do: state

  defp cancel_timer(%State{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp expired?(%State{credential: credential}),
    do: Credential.expired?(credential, DateTime.utc_now(), 0)

  # Reasons here are closed sets (atoms, statuses); never a token or a body.
  defp log_failure(what, reason) do
    Logger.warning("[Broker.MCP] #{what}: #{inspect(reason)}")
  end

  # -- redaction --------------------------------------------------------------

  defp scrub(%Credential{}), do: :redacted_credential

  defp scrub(%State{} = state) do
    %{
      state
      | credential: scrub(state.credential),
        unpersisted: scrub(state.unpersisted),
        config: Map.take(state.config, [:url, :skew, :connect_timeout]),
        queue: length(state.queue),
        requests: map_size(state.requests)
    }
  end

  defp scrub(%_{} = struct), do: struct

  defp scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()

  defp scrub([_ | _] = list) do
    if List.improper?(list), do: list, else: Enum.map(list, &scrub/1)
  end

  defp scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)
  defp scrub(other), do: other
end
