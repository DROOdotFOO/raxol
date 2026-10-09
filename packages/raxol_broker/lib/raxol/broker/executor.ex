defmodule Raxol.Broker.Executor do
  @moduledoc """
  The one path every order takes: intent, policy, `review_*`, policy again,
  `placing`, `place_*`, each step journaled before the next one runs.

      run(intent, context)
        open_group       intent + context (policy and counters set here)
        verdict          :pre_review; DENY ends here
        review           the review tool's response; its warnings feed the context
        verdict          :post_review; DENY ends here, ASK parks the group
        [approval]       approve/3 or decline/3 on a parked group
        placing          Raxol.Broker.Executor.Place, with the ReviewReceipt
        order            :placed | :failed | :unknown

  ## Context

  The executor overwrites these `Raxol.Broker.Policy.Context` fields,
  whatever the caller passed:

    * `policy`, from the `:policy` start option.
    * `today_notional` and `orders_last_minute`, read from
      `Raxol.Broker.Journal` at decision time.
    * `review_warnings`, from this executor's own review call (empty
      before it).

  Every other field is trusted from the caller until #1185 sources it:
  `quotes`, `positions`, `portfolio_value`, `start_of_day_value`,
  `day_pnl` and `market_session`.

  Trusted means its values, never its code: the intent and the context are
  rebuilt from plain data with `Raxol.Broker.Intent.normalize/1` and
  `Raxol.Broker.Policy.Context.normalize/1` in the caller (`run/3`) and
  again in this process before anything else, by pattern matching only.
  A struct, float, pid or function anywhere in them is `{:error,
  {:invalid_intent, reason}}` or `{:error, {:invalid_context, reason}}`
  and nothing is journaled or sent: no protocol of caller data
  (Enumerable, Inspect, ...) ever runs in this process.

  ## Guards

  Everything is re-checked here, whatever the caller did:

    * Decisions are serialized through this process, so two callers cannot
      both pass the daily cap before either writes `placing`.
    * One executor per journal: `init/1` claims the journal with
      `Raxol.Broker.Journal.claim/1`, and a second executor on the same
      journal fails to start with `{:journal_claimed, pid}`. The journal
      only grants the claim to a process started as an executor, and
      refuses `placing` from any process but the claimant.
    * The claim lives in the journal's memory. The executor monitors the
      journal and stops with `{:journal_down, reason}` when it goes down,
      so its supervisor restarts it; the new executor claims again and
      closes the groups this one left open. Queued callers get an exit
      from their call, and an in-flight review task dies with the
      executor.
    * Review is mandatory: `Raxol.Broker.Executor.Place` is the only
      module that names an order tool, and it needs a
      `Raxol.Broker.Executor.ReviewReceipt` for the same intent and group,
      verified under a key this process generates and keeps in its own
      process dictionary (`receipt_key/0` is nil in any other process).
      The key is put there only after the claim succeeds. No caller code
      runs in this process: `:journal` must be an atom or pid, and the
      `:clock` runs in a task. The journal refuses every group write from
      any process but the claimant, and `placing` for a group without a
      review record and an ALLOW or an approval after it.
    * Threat model: the BEAM cannot stop code that deliberately writes
      into another module's private state, e.g. `Process.put` into its
      slots or `:sys.replace_state`. The guarantee is that no path through
      public APIs can send an order tool without this review pipeline.
      Every remaining bypass requires impersonating the executor's private
      process-dictionary slots on purpose.
    * Any journal error before `placing` is written, any review error, and
      any intent without an order tool mean no order is sent.
    * Once the order call has been made the result is always `{:ok, map}`.
      If the `order` record could not be written the map has
      `journaled: false` and `journal_error: reason`; the order may exist
      at the broker, so reconcile before retrying.
    * Idempotency: an intent id that already has a group with a `placing`
      record whose outcome is not `:failed` (including a crash closed as
      `crash_outcome_unknown`) returns `{:ok, :duplicate}` and calls
      nothing. Each place also sends a `ref_id` derived from the intent id,
      which Robinhood deduplicates on. Intent ids must be stable for a
      re-run to be recognised: pass `:id` to the `Raxol.Broker.Intent`
      constructor.

  ## ASK

  A post-review ASK parks the group and returns `{:ask, group_id, prompts}`;
  the group id is the token. `approve/3` rebuilds the counters from the
  journal, journals the approval and runs the policy again: a DENY now (the
  cap moved while it was parked) ends the group; an ASK (the questions the
  human just answered) or ALLOW goes on to `placing`. `decline/3` and
  `close/3` end the group. Routing an ASK to a person and denying on
  timeout are #1180's.

  `approve/3` and `decline/3` need a non-empty `by`, `close/3` a non-nil
  atom reason; anything else raises `FunctionClauseError` in the caller and
  leaves the group parked. An approve refused before the approval is
  journaled (port down, journal unreadable, or the approval entry rejected
  as invalid) also leaves the group parked.

  Parked groups live in this process. On start, every group the journal
  still has open is closed with `{:close, :executor_restarted}`, so a group
  parked before a restart cannot be approved after it.

  ## Concurrency

  The review call runs in a task, so `parked/2` and `await_port/2` answer
  while a review is in flight; other calls queue behind it in arrival
  order. Each queued caller is monitored: one that dies is dropped from
  the queue, never dispatched (a remote caller is judged by its monitor
  alone). The place call runs in this process (the journal only accepts
  `placing` from the claimant), so nothing answers until it returns or
  `:place_timeout` passes. At most one queued request is dispatched per
  callback; the next waits for a `:drain` message, so one callback never
  runs two place calls and the shutdown bound covers the one in progress.

  If the port goes down after the review but before the place (its EXIT
  handled first), the group is closed with `:port_not_ready`, no `placing`
  is written and nothing is sent; a re-run of the intent places once the
  port is back.

  ## Port

  The port is a `Raxol.Broker.Executor.Port.MCP` session built from
  `:session`. `init/1` only checks the spec (`Port.MCP.prepare/2`, so a
  live spec still fails start); the client starts after `init/1`, linked
  to this process, and a task waits for it to be ready, so the executor
  answers while it connects. Until it is ready, `run/3` and `approve/3`
  return `{:error, :port_not_ready}` before opening or journaling
  anything; `await_port/2` waits for readiness.

  Exits are trapped. When the client dies (also mid-connect) or fails to
  become ready the executor stays up, logs the failure and starts a new
  client after a backoff (`:reconnect_ms`, default 1 s, doubling to 60 s,
  reset once ready); the client itself retries a failed connect on the
  same schedule. A port that is down never restarts the executor, so an
  unreachable endpoint cannot exhaust its supervisor's restart budget.

  ## Mode

  Only `mode: :dry_run` (the default) runs. `Raxol.Broker.Executor.Port.MCP`
  refuses to connect a live session in dry-run (`{:error,
  :live_port_in_dry_run}`): a dry-run `:session` must carry `sandbox: true`
  and a URL that is not on `robinhood.com`. The intent record carries
  `"mode": "dry_run"`. `mode: :armed` is `{:error, :not_armed}` until
  arming exists (#1179).

  ## Options

    * `:policy` (required) - a policy keyword list, validated with
      `Raxol.Broker.PolicyFile.validate/1`; `{:invalid_policy, reason}`
      otherwise.
    * `:session` (required) - a `Raxol.MCP.Client` spec for
      `Raxol.Broker.Executor.Port.MCP.prepare/2` and `start_client/1`.
    * `:account_number` (required) - the account orders are sent for.
    * `:journal` - the `Raxol.Broker.Journal` server, a registered name
      (atom) or a pid (default that module). Anything else, such as
      `{:via, module, name}` or `{:global, name}`, is
      `{:invalid_journal, value}`: resolving it would run caller code in
      this process.
    * `:mode` - `:dry_run` (default) or `:armed`.
    * `:clock` - zero-arity function returning the UTC `DateTime` used for
      the counters (default `DateTime.utc_now/0`). It runs in a short-lived
      task, never in this process, with a 5 s budget. Its result is rebuilt
      with `Raxol.Broker.Plain.normalize/1` before any `DateTime` function
      sees it; anything but a UTC `DateTime` in the ISO calendar fails the
      call with `{:error, {:context, reason}}` and nothing is opened or sent.
    * `:review_timeout`, `:place_timeout` - per tool call, an integer of
      milliseconds in 1..4_294_000_000 (default 30 s; the cap leaves
      headroom under the VM's timer limit); anything else is
      `{:invalid_timeout, key, value}`.
    * `:reconnect_ms` - the first port reconnect delay, same range
      (default 1 s, doubling to 60 s).
    * `:shutdown` - the child spec's shutdown bound in milliseconds, a
      positive integer (default `place_timeout + 5_000`).
    * `:name`.

  `child_spec/1` sets `shutdown` from `:shutdown`, else `place_timeout +
  5_000`: a supervisor stopping the executor during a place waits up to
  that bound for the order call. A stop is handled between callbacks, so
  a review in flight is never waited for (its task dies with the
  executor). A journal write stalled past the bound is killed with the
  executor; the group is then closed as `crash_outcome_unknown` on
  restart (counted, never re-placed), and recovery reports it as such.

  `today_notional` counts a rolling 24 hours back from the clock's now,
  which counts at least as much as any calendar day would. No caller input
  moves the window; a calendar the executor owns (New York trading day) is
  #1185's.
  """

  use GenServer

  require Logger

  alias Raxol.Broker.Executor.{Place, Port, Review, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.{Intent, Journal, Plain, Policy, PolicyFile}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Tools.Catalog

  @default_timeout 30_000
  @default_reconnect_ms 1_000
  @max_backoff 60_000
  @clock_timeout 5_000
  # `receive after` and `Process.send_after/3` refuse anything above
  # 4_294_967_295 ms; the cap leaves headroom under that.
  @max_timeout 4_294_000_000

  @type placed :: %{
          required(:group_id) => String.t(),
          required(:status) => Place.status(),
          required(:response) => map(),
          required(:journaled) => boolean(),
          optional(:journal_error) => term()
        }

  @type result ::
          {:ok, placed()}
          | {:ok, :duplicate}
          | {:ask, String.t(), [{Policy.rule_id(), String.t()}]}
          | {:deny, String.t(), term()}
          | {:error, term()}

  # -- API ----------------------------------------------------------------------

  @doc "Start the executor. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run `intent` through the pipeline. See the moduledoc.

  Both structs are rebuilt from plain data here (`Intent.normalize/1`,
  `Context.normalize/1`) and again inside the executor; anything else is
  `{:error, {:invalid_intent, reason}}` or `{:error, {:invalid_context,
  reason}}` and nothing is sent to the executor.
  """
  @spec run(GenServer.server(), Intent.t(), Context.t()) :: result()
  def run(server, %Intent{} = intent, %Context{} = context) do
    with {:ok, intent, context} <- Policy.normalize(intent, context),
         do: GenServer.call(server, {:run, intent, context}, :infinity)
  end

  @doc "Approve a parked ASK; `by` names who approved (non-empty string)."
  @spec approve(GenServer.server(), String.t(), String.t()) :: result()
  def approve(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:approve, token, by}, :infinity)

  @doc "Decline a parked ASK; the group ends as DENY. `by` is a non-empty string."
  @spec decline(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def decline(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:decline, token, by}, :infinity)

  @doc "Abandon a parked ASK with `{:close, reason}`; `reason` is a non-nil atom."
  @spec close(GenServer.server(), String.t(), atom()) :: :ok | {:error, term()}
  def close(server, token, reason)
      when is_binary(token) and is_atom(reason) and not is_nil(reason),
      do: GenServer.call(server, {:close, token, reason}, :infinity)

  @doc "Parked ASKs: `[%{group_id, intent, prompts}]`, oldest first."
  @spec parked(GenServer.server(), timeout()) :: [map()]
  def parked(server, timeout \\ :infinity), do: GenServer.call(server, :parked, timeout)

  @doc """
  Wait until the port session is ready: `:ok`, or `{:error, :port_not_ready}`
  once `timeout` milliseconds pass first. Answered even while a review is in
  flight. A timeout above 4_294_000_000 ms is `{:error, {:invalid_timeout,
  :await_port, timeout}}`.
  """
  @spec await_port(GenServer.server(), non_neg_integer()) ::
          :ok | {:error, :port_not_ready | {:invalid_timeout, :await_port, term()}}
  def await_port(server, timeout \\ @default_timeout) when is_integer(timeout) and timeout >= 0,
    do: GenServer.call(server, {:await_port, timeout}, :infinity)

  @doc """
  A child spec whose `:shutdown` covers one place call (`place_timeout +
  5_000`, or the `:shutdown` option), so a supervisor stopping the executor
  mid-place waits for the order response. A `:shutdown` that is not a
  positive integer raises `ArgumentError`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: shutdown(opts)
    }
  end

  defp shutdown(opts) do
    case Keyword.fetch(opts, :shutdown) do
      {:ok, ms} when is_integer(ms) and ms > 0 ->
        ms

      {:ok, other} ->
        raise ArgumentError,
              "invalid :shutdown #{inspect(other, structs: false)}, expected a positive integer"

      :error ->
        place_shutdown(Keyword.get(opts, :place_timeout))
    end
  end

  defp place_shutdown(ms) when is_integer(ms) and ms > 0 and ms <= @max_timeout, do: ms + 5_000
  defp place_shutdown(_unset_or_refused), do: @default_timeout + 5_000

  # The receipt key lives in the executor's own process dictionary, so it is
  # nil in every other process. `Raxol.Broker.Executor.Place` verifies
  # receipts with it, which means only this process can place.
  @doc false
  @spec receipt_key() :: binary() | nil
  def receipt_key, do: Process.get({__MODULE__, :receipt_key})

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- check_opts(opts),
         {:ok, client_spec} <- prepare_port(config),
         {:ok, journal_ref} <- monitor_journal(config.journal),
         :ok <- safe(fn -> Journal.claim(config.journal) end) do
      state = base_state(config, client_spec, journal_ref)
      Process.put({__MODULE__, :receipt_key}, state.key)
      close_orphans(state)
      {:ok, state, {:continue, :connect}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # `:journal` comes first: a `{:via, module, name}` or `{:global, name}`
  # would run caller code in this process to resolve it.
  defp check_opts(opts) do
    with {:ok, journal} <- fetch_journal(opts),
         {:ok, timeouts} <- fetch_timeouts(opts),
         {:ok, clock} <- fetch_clock(opts),
         :ok <- check_mode(Keyword.get(opts, :mode, :dry_run)),
         {:ok, account} <- fetch_account(opts),
         {:ok, policy} <- fetch_policy(opts),
         {:ok, session} <- fetch_session(opts) do
      {:ok,
       Map.merge(timeouts, %{
         journal: journal,
         clock: clock,
         account: account,
         policy: policy,
         session: session
       })}
    end
  end

  defp fetch_timeouts(opts) do
    with {:ok, review_timeout} <- fetch_timeout(opts, :review_timeout),
         {:ok, place_timeout} <- fetch_timeout(opts, :place_timeout),
         {:ok, reconnect_ms} <- fetch_timeout(opts, :reconnect_ms, @default_reconnect_ms) do
      {:ok,
       %{review_timeout: review_timeout, place_timeout: place_timeout, reconnect_ms: reconnect_ms}}
    end
  end

  defp fetch_journal(opts) do
    case Keyword.get(opts, :journal, Journal) do
      journal when (is_atom(journal) and not is_nil(journal)) or is_pid(journal) ->
        {:ok, journal}

      other ->
        {:error, {:invalid_journal, other}}
    end
  end

  defp fetch_timeout(opts, key, default \\ @default_timeout) do
    case Keyword.get(opts, key, default) do
      ms when is_integer(ms) and ms > 0 and ms <= @max_timeout -> {:ok, ms}
      other -> {:error, {:invalid_timeout, key, other}}
    end
  end

  defp fetch_clock(opts) do
    case Keyword.get(opts, :clock, &DateTime.utc_now/0) do
      clock when is_function(clock, 0) -> {:ok, clock}
      other -> {:error, {:invalid_clock, other}}
    end
  end

  # Pure: refuses a live spec before anything connects.
  defp prepare_port(config),
    do:
      PortMCP.prepare(config.session,
        mode: :dry_run,
        call_timeout: max(config.review_timeout, config.place_timeout),
        reconnect_ms: config.reconnect_ms
      )

  # The claim lives in the journal's memory, so a journal restart drops it.
  # The executor stops with the journal; its supervisor restarts it, and the
  # new one claims again and closes the groups this one left open.
  defp monitor_journal(journal) when is_pid(journal), do: {:ok, Process.monitor(journal)}

  defp monitor_journal(journal) do
    case Process.whereis(journal) do
      pid when is_pid(pid) -> {:ok, Process.monitor(pid)}
      nil -> {:error, :journal_not_running}
    end
  end

  defp base_state(config, client_spec, journal_ref) do
    %{
      journal: config.journal,
      journal_ref: journal_ref,
      clock: config.clock,
      account: config.account,
      policy: config.policy,
      review_timeout: config.review_timeout,
      place_timeout: config.place_timeout,
      key: :crypto.strong_rand_bytes(32),
      client_spec: client_spec,
      port: nil,
      port_status: :connecting,
      connect: nil,
      catalog: %{},
      reconnect_ms: config.reconnect_ms,
      backoff: config.reconnect_ms,
      port_waiters: %{},
      parked: %{},
      busy: nil,
      queue: :queue.new()
    }
  end

  defp check_mode(:dry_run), do: :ok
  defp check_mode(:armed), do: {:error, :not_armed}
  defp check_mode(other), do: {:error, {:invalid_mode, other}}

  defp fetch_account(opts) do
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) and account != "" -> {:ok, account}
      other -> {:error, {:invalid_account_number, other}}
    end
  end

  defp fetch_policy(opts) do
    case PolicyFile.validate(Keyword.get(opts, :policy)) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> {:error, {:invalid_policy, reason}}
    end
  end

  defp fetch_session(opts) do
    case Keyword.get(opts, :session) do
      spec when is_list(spec) and spec != [] -> {:ok, spec}
      _ -> {:error, :session_required}
    end
  end

  # A group the journal still has open was parked or mid-flight in an
  # executor that is gone; nothing may resume it.
  defp close_orphans(state) do
    case safe(fn -> Journal.open_groups(state.journal) end) do
      {:ok, ids} ->
        Enum.each(ids, &close_group(state, &1, :executor_restarted))

      {:error, reason} ->
        Logger.warning(
          "[Broker.Executor] could not list open groups: #{inspect(reason, structs: false)}"
        )
    end
  end

  @impl GenServer
  def handle_call(:parked, _from, state) do
    list =
      state.parked
      |> Enum.sort_by(fn {_id, group} -> group.seq end)
      |> Enum.map(fn {id, group} ->
        %{group_id: id, intent: group.intent, prompts: group.prompts}
      end)

    {:reply, list, state}
  end

  def handle_call({:await_port, _timeout}, _from, %{port_status: :ready} = state),
    do: {:reply, :ok, state}

  def handle_call({:await_port, timeout}, from, state)
      when is_integer(timeout) and timeout >= 0 and timeout <= @max_timeout do
    timer = Process.send_after(self(), {:await_port_timeout, from}, timeout)
    {:noreply, %{state | port_waiters: Map.put(state.port_waiters, from, timer)}}
  end

  def handle_call({:await_port, timeout}, _from, state),
    do: {:reply, {:error, {:invalid_timeout, :await_port, timeout}}, state}

  # Nothing jumps the queue: a request that arrives while earlier ones wait
  # for their `:drain` turn is queued behind them.
  def handle_call(request, {pid, _tag} = from, state) do
    if state.busy == nil and :queue.is_empty(state.queue) do
      case dispatch(request, from, state) do
        {:reply, reply, state} -> {:reply, reply, state}
        {:await, state} -> {:noreply, state}
      end
    else
      entry = {request, from, Process.monitor(pid)}
      {:noreply, %{state | queue: :queue.in(entry, state.queue)}}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl GenServer
  def handle_info({ref, result}, %{busy: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    review_done(state, result)
  end

  def handle_info({ref, result}, %{connect: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, connected(%{state | connect: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{busy: %{ref: ref}} = state),
    do: review_done(state, {:error, {:review_crashed, reason}})

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connect: %Task{ref: ref}} = state),
    do: {:noreply, connected(%{state | connect: nil}, {:error, {:connect_crashed, reason}})}

  # Queued callers get an exit from their call; the linked review task dies
  # with this process; the groups left open are closed by the next executor.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{journal_ref: ref} = state) do
    Logger.warning("[Broker.Executor] journal went down: #{inspect(reason, structs: false)}")
    {:stop, {:journal_down, reason}, state}
  end

  # A queued caller died: drop its request.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {gone, queue} = :queue.to_list(state.queue) |> Enum.split_with(&(elem(&1, 2) == ref))
    Enum.each(gone, fn {request, _from, _ref} -> dropped(request) end)
    {:noreply, %{state | queue: :queue.from_list(queue)}}
  end

  # The connect task is shut down for its side effect only; the state is
  # updated whatever `Task.shutdown/2` returns.
  def handle_info({:EXIT, pid, reason}, %{port: {PortMCP, %PortMCP{pid: pid}}} = state) do
    if state.connect, do: Task.shutdown(state.connect, :brutal_kill)
    {:noreply, port_failed(%{state | port: nil, connect: nil}, {:port_exited, reason})}
  end

  # Review, clock and connect tasks are linked; their exits are handled
  # through their monitors. A port this process stopped exits here too.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, %{port: nil} = state), do: {:noreply, connect(state)}

  # A `:drain` left over from an earlier turn can arrive while a review is
  # in flight; `review_done/2` sends a fresh one when it finishes.
  def handle_info(:drain, %{busy: nil} = state), do: {:noreply, drain(state)}
  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({:await_port_timeout, from}, state) do
    case Map.pop(state.port_waiters, from) do
      {nil, _waiters} ->
        {:noreply, state}

      {_timer, waiters} ->
        GenServer.reply(from, {:error, :port_not_ready})
        {:noreply, %{state | port_waiters: waiters}}
    end
  end

  # Only the shape is logged: the message is any term, and inspecting a
  # struct would run its Inspect implementation here.
  def handle_info(message, state) do
    Logger.debug("[Broker.Executor] unexpected message: #{shape(message)}")
    {:noreply, state}
  end

  # Nothing is cast to the executor. The default clause would crash it, and
  # the crash report would inspect the message in this process.
  @impl GenServer
  def handle_cast(message, state) do
    Logger.debug("[Broker.Executor] unexpected cast: #{shape(message)}")
    {:noreply, state}
  end

  defp shape(message) when is_tuple(message) and tuple_size(message) > 0,
    do: "{#{inspect(elem(message, 0), structs: false)}, ...}"

  defp shape(_message), do: "term"

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, state), do: Port.stop(state.port)

  # -- Port ---------------------------------------------------------------------

  # The client connects on its own (retrying a failed connect with backoff
  # from `:reconnect_ms`); a task waits for it, so this process keeps
  # answering meanwhile.
  defp connect(state) do
    case PortMCP.start_client(state.client_spec) do
      {:ok, port} ->
        task = Task.async(fn -> await_catalog(port) end)
        %{state | port: port, port_status: :connecting, connect: task}

      {:error, reason} ->
        port_failed(state, {:connect_failed, reason})
    end
  end

  # The session's tool classes: the live list reconciled against the frozen
  # capture (`Raxol.Broker.Tools.Catalog`). A port whose list cannot be read
  # never becomes ready, so no tool is ever called unclassified.
  defp await_catalog(port) do
    with :ok <- PortMCP.await_ready(port),
         {:ok, tools} <- PortMCP.list_tools(port) do
      {:ok, Catalog.reconcile(tools)}
    end
  end

  defp connected(state, {:ok, catalog}) do
    Enum.each(state.port_waiters, fn {from, timer} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, :ok)
    end)

    %{
      state
      | port_status: :ready,
        catalog: catalog,
        backoff: state.reconnect_ms,
        port_waiters: %{}
    }
  end

  defp connected(%{port: port} = state, {:error, reason}) do
    if port, do: Port.stop(port)
    port_failed(%{state | port: nil}, {:connect_failed, reason})
  end

  defp port_failed(state, reason) do
    Logger.warning(
      "[Broker.Executor] port not ready (#{inspect(reason, structs: false)}); " <>
        "reconnecting in #{state.backoff} ms"
    )

    Process.send_after(self(), :reconnect, state.backoff)

    %{
      state
      | port_status: {:down, reason},
        backoff: min(state.backoff * 2, @max_backoff)
    }
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, %{} = state} -> {:state, %{state | key: :redacted}}
      other -> other
    end)
  end

  # -- Dispatch -----------------------------------------------------------------

  defp dispatch({:run, intent, context}, from, state) do
    case Policy.normalize(intent, context) do
      {:ok, intent, context} -> awaiting(run_intent(state, intent, context), from)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch({:approve, token, by}, _from, state),
    do: approve_parked(state, token, by)

  defp dispatch({:decline, token, by}, _from, state),
    do: finish_parked(state, token, {:approval, :declined, by})

  defp dispatch({:close, token, reason}, _from, state),
    do: finish_parked(state, token, {:close, reason})

  defp dispatch(_request, _from, state), do: {:reply, {:error, :unknown_request}, state}

  defp awaiting({:await, pending, state}, from),
    do: {:await, %{state | busy: Map.put(pending, :from, from)}}

  defp awaiting(done, _from), do: done

  defp review_done(%{busy: pending} = state, result) do
    {:reply, reply, state} = reviewed(%{state | busy: nil}, pending, result)
    GenServer.reply(pending.from, reply)
    {:noreply, drain_later(state)}
  end

  defp drain(%{busy: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, entry}, queue} ->
        drain_entry(%{state | queue: queue}, entry)
    end
  end

  # A caller that died while queued is never dispatched: its order would be
  # placed with nobody to receive the result. Its monitor tells: a DOWN
  # already delivered (but not yet handled) makes the demonitor report
  # false. `Process.alive?/1` is only asked about a local pid.
  #
  # At most one request is dispatched per callback, so one callback never
  # runs more than one place call: the rest wait for a `:drain` message,
  # and the shutdown bound covers the one in progress.
  defp drain_entry(state, {request, {pid, _tag} = from, ref}) do
    if Process.demonitor(ref, [:flush, :info]) and (node(pid) != node() or Process.alive?(pid)) do
      case dispatch(request, from, state) do
        {:reply, reply, state} ->
          GenServer.reply(from, reply)
          drain_later(state)

        {:await, state} ->
          state
      end
    else
      dropped(request)
      drain(state)
    end
  end

  defp drain_later(state) do
    unless :queue.is_empty(state.queue), do: send(self(), :drain)
    state
  end

  defp dropped(request),
    do: Logger.info("[Broker.Executor] dropped a queued #{request_kind(request)}: caller is gone")

  defp request_kind(request) when is_tuple(request) and is_atom(elem(request, 0)),
    do: elem(request, 0)

  defp request_kind(_request), do: :request

  # -- Pipeline -----------------------------------------------------------------

  defp run_intent(state, intent, context) do
    with :ok <- port_up(state),
         :ok <- not_parked(state, intent),
         {:ok, nil} <- placed_before(state, intent),
         {:ok, _tool} <- Review.tool(intent),
         {:ok, context} <- fill(state, %{context | review_warnings: []}),
         {:ok, group_id} <- open(state, intent, context) do
      pre_review(state, intent, context, group_id)
    else
      {:ok, group_id} when is_binary(group_id) -> {:reply, {:ok, :duplicate}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp port_up(%{port_status: :ready}), do: :ok
  defp port_up(_state), do: {:error, :port_not_ready}

  defp not_parked(state, intent) do
    case Enum.find(state.parked, fn {_id, group} -> group.intent.id == intent.id end) do
      nil -> :ok
      {id, _group} -> {:error, {:parked, id}}
    end
  end

  defp placed_before(state, intent),
    do: safe(fn -> Journal.placing_for_intent(intent.id, state.journal) end)

  defp open(state, intent, context),
    do: safe(fn -> Journal.open_group(intent, context, state.journal, mode: :dry_run) end)

  defp pre_review(state, intent, context, group_id) do
    verdict = Policy.evaluate(intent, context)

    case {append(state, group_id, {:verdict, :pre_review, verdict}), verdict} do
      {{:error, reason}, _verdict} -> {:reply, {:error, reason}, state}
      {:ok, {:deny, reason}} -> {:reply, {:deny, group_id, reason}, state}
      {:ok, _allow_or_ask} -> review(state, intent, context, group_id)
    end
  end

  defp review(state, intent, context, group_id) do
    %{port: port, catalog: catalog, account: account, review_timeout: timeout} = state
    task = Task.async(fn -> Review.run(port, catalog, intent, account, timeout) end)
    pending = %{ref: task.ref, pid: task.pid, intent: intent, context: context}
    {:await, Map.put(pending, :group_id, group_id), state}
  end

  defp reviewed(state, %{group_id: group_id}, {:error, reason}) do
    _ = close_group(state, group_id, :review_failed)
    {:reply, {:error, reason}, state}
  end

  defp reviewed(state, pending, {:ok, response, warnings}) do
    pending = %{pending | context: %{pending.context | review_warnings: warnings}}

    case append(state, pending.group_id, {:review, response}) do
      :ok -> post_review(state, pending)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp post_review(state, %{intent: intent, group_id: group_id} = pending) do
    receipt = ReviewReceipt.issue(state.key, intent, group_id)
    verdict = Policy.evaluate(intent, pending.context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} -> {:reply, {:error, reason}, state}
      {:ok, {:deny, reason}} -> {:reply, {:deny, group_id, reason}, state}
      {:ok, {:ask, prompts}} -> park(state, pending, receipt, prompts)
      {:ok, {:allow, _intent}} -> place(state, intent, group_id, receipt)
    end
  end

  defp park(state, %{group_id: group_id} = pending, receipt, prompts) do
    group = %{
      intent: pending.intent,
      context: pending.context,
      receipt: receipt,
      prompts: prompts,
      seq: System.unique_integer([:monotonic])
    }

    parked = Map.put(state.parked, group_id, group)
    {:reply, {:ask, group_id, prompts}, %{state | parked: parked}}
  end

  # Everything before the approval is journaled leaves the group parked.
  defp approve_parked(state, token, by) do
    with :ok <- port_up(state),
         {:ok, group} <- fetch_parked(state, token),
         {:ok, context} <- fill(state, group.context) do
      approved(state, token, group, by, context)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_parked(state, token) do
    case Map.fetch(state.parked, token) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, {:not_parked, token}}
    end
  end

  defp approved(state, group_id, group, by, context) do
    unparked = %{state | parked: Map.delete(state.parked, group_id)}

    case append(state, group_id, {:approval, :approved, by}) do
      :ok ->
        recheck(unparked, group_id, group, context)

      {:error, {:invalid_entry, _} = reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        _ = close_group(unparked, group_id, :approval_failed)
        {:reply, {:error, reason}, unparked}
    end
  end

  defp recheck(state, group_id, group, context) do
    verdict = Policy.evaluate(group.intent, context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} ->
        _ = close_group(state, group_id, :approval_failed)
        {:reply, {:error, reason}, state}

      {:ok, {:deny, reason}} ->
        {:reply, {:deny, group_id, reason}, state}

      {:ok, _ask_answered_or_allow} ->
        place(state, group.intent, group_id, group.receipt)
    end
  end

  # Dropped from the parked map whatever the journal says: without its
  # receipt the group can never reach `placing`.
  defp finish_parked(state, token, entry) do
    case Map.pop(state.parked, token) do
      {nil, _parked} -> {:reply, {:error, {:not_parked, token}}, state}
      {_group, parked} -> {:reply, append(state, token, entry), %{state | parked: parked}}
    end
  end

  # The port can go down between review and here (its EXIT handled before
  # the review result): close the group without `placing`, send nothing.
  defp place(%{port_status: status, port: port} = state, _intent, group_id, _receipt)
       when status != :ready or is_nil(port) do
    _ = close_group(state, group_id, :port_not_ready)
    {:reply, {:error, :port_not_ready}, state}
  end

  defp place(state, intent, group_id, receipt) do
    env = %{
      port: state.port,
      catalog: state.catalog,
      journal: state.journal,
      account: state.account,
      timeout: state.place_timeout
    }

    reply =
      case Place.run(receipt, intent, group_id, env) do
        {:ok, status, response} ->
          {:ok, %{group_id: group_id, status: status, response: response, journaled: true}}

        {:error, {:order_unjournaled, status, response, reason}} ->
          {:ok,
           %{
             group_id: group_id,
             status: status,
             response: response,
             journaled: false,
             journal_error: reason
           }}

        # `placing` was refused, the receipt failed, or the intent has no
        # order tool: nothing was sent.
        {:error, reason} ->
          _ = close_group(state, group_id, :placing_refused)
          {:error, reason}
      end

    {:reply, reply, state}
  end

  # -- Context and journal ------------------------------------------------------

  # The window is a rolling 24 hours back from this executor's clock; no
  # caller input moves it.
  defp fill(state, %Context{} = context) do
    with {:ok, now} <- now(state.clock),
         day_start = DateTime.add(now, -24, :hour),
         {:ok, notional} <- safe(fn -> Journal.today_notional(day_start, state.journal) end),
         {:ok, count} <- safe(fn -> Journal.orders_last_minute(now, state.journal) end) do
      {:ok,
       %{context | policy: state.policy, today_notional: notional, orders_last_minute: count}}
    else
      {:error, reason} -> {:error, {:context, reason}}
    end
  end

  # The clock is caller code, so it runs in a task: never in this process,
  # where it would hold the executor's identity and receipt key. Its result
  # is rebuilt by pattern matching before any Calendar function sees it.
  defp now(clock) do
    task = Task.async(clock)

    case Task.yield(task, @clock_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, %DateTime{} = now} -> utc(Plain.normalize(now))
      {:ok, other} -> {:error, {:invalid_clock, other}}
      {:exit, reason} -> {:error, {:clock_crashed, reason}}
      nil -> {:error, :clock_timeout}
    end
  end

  # Plain rebuilds an ISO DateTime with integer fields; the offsets and the
  # field ranges are checked here so no Calendar.ISO function can raise.
  defp utc(
         {:ok,
          %DateTime{
            time_zone: "Etc/UTC",
            utc_offset: 0,
            std_offset: 0,
            microsecond: {micro, precision}
          } = now}
       )
       when precision in 0..6 do
    if Calendar.ISO.valid_date?(now.year, now.month, now.day) and
         Calendar.ISO.valid_time?(now.hour, now.minute, now.second, {micro, precision}),
       do: {:ok, now},
       else: {:error, {:invalid_clock, now}}
  end

  defp utc({:ok, other}), do: {:error, {:invalid_clock, other}}
  defp utc({:error, reason}), do: {:error, {:invalid_clock, reason}}

  defp close_group(state, group_id, reason) do
    with {:error, error} <- append(state, group_id, {:close, reason}) do
      Logger.warning(
        "[Broker.Executor] could not close group #{group_id} (#{reason}): " <>
          inspect(error, structs: false)
      )

      {:error, error}
    end
  end

  defp append(state, group_id, entry),
    do: safe(fn -> Journal.append_to_group(group_id, entry, state.journal) end)

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:journal_down, reason}}
  end
end
